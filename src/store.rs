use crate::actor::{Owner, Published, Snapshot};
use crate::model::{
    BuildState, Diagnostic, DiagnosticKind, Job, JobPhase, PreviewState, SCHEMA_VERSION, Settings,
    Ticket, now, token,
};
use anyhow::{Context, Result, ensure};
use serde::{Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::{collections::HashMap, sync::Arc};
use tokio::sync::watch;
use uuid::Uuid;

pub const MAX_DIAGNOSTIC_BYTES: u64 = 64 * 1024 * 1024;
pub const MAX_DIAGNOSTIC_MESSAGE_BYTES: usize = 512 * 1024;
const MAX_DIAGNOSTIC_EVENT_BYTES: usize = 1024 * 1024;
const MAX_PAGE_SIZE: usize = 1000;

/// Files under the data directory. Records are replaced atomically, so reads
/// need no coordination; each kind of read/modify/write has one owner in the
/// service (jobs: `Jobs`; tickets, the catalog and diagnostics: the server's
/// owner and lanes), and the service holds the exclusive service lock.
#[derive(Clone)]
pub struct Store {
    pub root: PathBuf,
    pub settings: Settings,
}

impl Store {
    pub fn open(root: PathBuf) -> Result<Self> {
        private_dir(&root)?;
        // Persisted artifact paths must survive a restart from a different cwd.
        let root = root
            .canonicalize()
            .context("could not resolve storage directory")?;
        private_dir(&root.join("jobs"))?;
        private_dir(&root.join("tickets"))?;
        let path = root.join("config.json");
        let settings = if path.try_exists()? {
            read_json(&path)?
        } else {
            let settings = Settings {
                schema_version: SCHEMA_VERSION,
                control_token: token(),
                diagnostic_token: token(),
            };
            if persist_json(&path, &settings, false)? {
                settings
            } else {
                // Another first-time client won initialization. Never replace
                // credentials that it may already have returned to its caller.
                read_json(&path)?
            }
        };
        ensure!(
            settings.schema_version == SCHEMA_VERSION,
            "unsupported config schema version {}; expected {}",
            settings.schema_version,
            SCHEMA_VERSION
        );
        validate_token(&settings.control_token)?;
        validate_token(&settings.diagnostic_token)?;
        ensure!(
            settings.control_token != settings.diagnostic_token,
            "control and diagnostic tokens must differ"
        );
        Ok(Self { root, settings })
    }

    pub fn job_dir(&self, id: &str) -> Result<PathBuf> {
        validate_id(id)?;
        Ok(self.root.join("jobs").join(id))
    }

    pub fn load_job(&self, id: &str) -> Result<Job> {
        let directory = self.job_dir(id)?;
        check_dir(&directory)?;
        let job: Job = read_json(&directory.join("job.json"))?;
        ensure!(job.id == id, "job record ID does not match its directory");
        Ok(job)
    }

    pub fn save_job(&self, job: &Job) -> Result<()> {
        let directory = self.job_dir(&job.id)?;
        private_dir(&directory)?;
        atomic_json(&directory.join("job.json"), job)
    }

    /// Every valid job record, newest first. An invalid record is reported on
    /// stderr and left out rather than hiding the others.
    pub fn list_jobs(&self) -> Result<Vec<Job>> {
        let (jobs, invalid) = self.scan_jobs()?;
        for (id, error) in invalid {
            eprintln!("Skipping invalid build record {id}: {error:#}");
        }
        Ok(jobs)
    }

    /// Valid job records, newest first, and the invalid ones with their errors.
    pub fn scan_jobs(&self) -> Result<(Vec<Job>, Vec<(String, anyhow::Error)>)> {
        let mut jobs = Vec::new();
        let mut invalid = Vec::new();
        for entry in fs::read_dir(self.root.join("jobs"))? {
            let entry = entry?;
            let Some(id) = entry.file_name().to_str().map(str::to_owned) else {
                continue;
            };
            if validate_id(&id).is_err() {
                continue;
            }
            check_dir(&entry.path())?;
            // A failed first write can leave an empty job directory.
            if entry.path().join("job.json").try_exists()? {
                match self.load_job(&id) {
                    Ok(job) => jobs.push(job),
                    Err(error) => invalid.push((id, error)),
                }
            }
        }
        jobs.sort_by(|left, right| {
            right
                .created_at
                .cmp(&left.created_at)
                .then_with(|| left.id.cmp(&right.id))
        });
        Ok((jobs, invalid))
    }

    pub fn save_ticket(&self, ticket: &Ticket) -> Result<()> {
        validate_token(&ticket.token)?;
        self.load_job(&ticket.build_id)?;
        atomic_json(
            &self
                .root
                .join("tickets")
                .join(format!("{}.json", ticket.token)),
            ticket,
        )
    }

    pub fn load_ticket(&self, token: &str) -> Result<Ticket> {
        validate_token(token)?;
        let ticket: Ticket = read_json(&self.root.join("tickets").join(format!("{token}.json")))?;
        ensure!(
            ticket.token == token,
            "ticket token does not match its filename"
        );
        validate_id(&ticket.build_id)?;
        Ok(ticket)
    }

    /// Returns false only for an exact replay. Reusing an event ID with a
    /// different payload is an error rather than silently losing new content.
    pub fn append_diagnostic(&self, diagnostic: &Diagnostic) -> Result<bool> {
        validate_id(&diagnostic.event_id)?;
        let job = self.load_job(&diagnostic.build_id)?;
        ensure!(
            job.output().is_some(),
            "build has no output to associate diagnostics with"
        );
        ensure!(
            diagnostic.message.len() <= MAX_DIAGNOSTIC_MESSAGE_BYTES,
            "diagnostic message exceeds 512 KiB"
        );
        let payload = serde_json::to_value(diagnostic)?;
        let mut encoded = serde_json::to_vec(diagnostic)?;
        ensure!(
            encoded.len() <= MAX_DIAGNOSTIC_EVENT_BYTES,
            "diagnostic event exceeds 1 MiB"
        );
        encoded.push(b'\n');
        let path = self
            .job_dir(&diagnostic.build_id)?
            .join("diagnostics.jsonl");
        let mut file = open_private_append(&path)?;
        let length = file.metadata()?.len();
        ensure!(
            length <= MAX_DIAGNOSTIC_BYTES,
            "diagnostic file exceeds 64 MiB; existing data preserved"
        );
        let mut reader = BufReader::new(file.try_clone()?);
        let mut line = String::new();
        while reader.read_line(&mut line)? != 0 {
            ensure!(
                line.ends_with('\n'),
                "incomplete diagnostic record; existing data preserved"
            );
            let existing: Diagnostic = serde_json::from_str(&line)
                .context("invalid persisted diagnostic; existing data preserved")?;
            if existing.event_id == diagnostic.event_id {
                ensure!(
                    serde_json::to_value(existing)? == payload,
                    "diagnostic event_id conflict: payload differs"
                );
                return Ok(false);
            }
            line.clear();
        }
        ensure!(
            length + encoded.len() as u64 <= MAX_DIAGNOSTIC_BYTES,
            "diagnostic storage limit of 64 MiB reached; existing data preserved"
        );
        // Roll back an incomplete append if a write fails (for example ENOSPC).
        // A process crash may still leave a partial tail, which is detected and
        // reported on the next read instead of being silently discarded.
        if let Err(error) = file.write_all(&encoded).and_then(|_| file.sync_data()) {
            file.set_len(length)
                .context("diagnostic append failed and rollback failed")?;
            file.sync_data()?;
            return Err(error).context("could not persist diagnostic");
        }
        sync_dir(path.parent().context("diagnostic path has no parent")?)?;
        Ok(true)
    }

    /// Cursors count every stored record, even when filtering by kind. `limit`
    /// bounds returned events, and is clamped to 1..=1000.
    pub fn diagnostics(
        &self,
        build_id: &str,
        since: usize,
        limit: usize,
        kind: Option<DiagnosticKind>,
    ) -> Result<Value> {
        self.load_job(build_id)?;
        let path = self.job_dir(build_id)?.join("diagnostics.jsonl");
        if !path.try_exists()? {
            ensure!(since == 0, "diagnostic cursor exceeds available records");
            return Ok(json!({"events": [], "next_cursor": 0, "has_more": false}));
        }
        let file = open_private_read(&path)?;
        ensure!(
            file.metadata()?.len() <= MAX_DIAGNOSTIC_BYTES,
            "diagnostic file exceeds 64 MiB"
        );
        let mut reader = BufReader::new(file);
        let mut line = String::new();
        let mut cursor = 0;
        let mut events = Vec::new();
        let mut has_more = false;
        while reader.read_line(&mut line)? != 0 {
            if cursor >= since && events.len() == limit.clamp(1, MAX_PAGE_SIZE) {
                has_more = true;
                break;
            }
            ensure!(
                line.ends_with('\n'),
                "incomplete diagnostic record; existing data preserved"
            );
            let event: Diagnostic =
                serde_json::from_str(&line).context("invalid persisted diagnostic")?;
            if cursor >= since && kind.as_ref().is_none_or(|expected| *expected == event.kind) {
                events.push(event);
            }
            cursor += 1;
            line.clear();
        }
        ensure!(
            since <= cursor,
            "diagnostic cursor exceeds available records"
        );
        Ok(json!({"events": events, "next_cursor": cursor, "has_more": has_more}))
    }
}

/// Build jobs as the service sees them, with one owner: each job's record
/// (committed, or a terminal result the disk refused), its revision, and
/// the live operation (build or preview) that alone may change it. Every
/// view reads the index the owner publishes; nothing rescans the jobs
/// directory after startup.
pub struct Jobs {
    owner: Owner<JobIndex>,
    views: Snapshot<Views>,
}

/// What readers see: every job, and how many builds and previews are live.
#[derive(Clone, Default)]
struct Views {
    jobs: HashMap<String, Arc<JobView>>,
    operations: usize,
}

struct JobIndex {
    store: Store,
    entries: HashMap<String, JobEntry>,
    leases: u64,
    /// The service is stopping: no new builds or previews.
    closed: bool,
    views: Views,
    published: Published<Views>,
}

struct JobEntry {
    job: Job,
    revision: u64,
    record: Record,
    operation: Option<Operation>,
}

/// Whether a job's state is what its record on disk says.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Record {
    Committed,
    /// A terminal result the disk refused. It is served until shutdown; the
    /// record on disk is older.
    UnpersistedTerminal {
        reason: String,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OperationKind {
    Build,
    Preview,
}

struct Operation {
    kind: OperationKind,
    lease: u64,
    cancel: watch::Sender<bool>,
}

/// The right to run a job's build or preview and commit its progress.
/// Cancellation reaches the job through `cancelled`. One dropped before
/// `finish` (its runner panicked or went away) tells the owner, which ends
/// the operation as interrupted.
pub struct Lease {
    id: String,
    lease: u64,
    pub cancelled: watch::Receiver<bool>,
    owner: Owner<JobIndex>,
}

impl Drop for Lease {
    fn drop(&mut self) {
        let (id, lease) = (self.id.clone(), self.lease);
        self.owner.tell(move |index| index.abandon(&id, lease));
    }
}

/// One job as every reader sees it.
#[derive(Clone, Debug)]
pub struct JobView {
    pub job: Job,
    pub revision: u64,
    pub record: Record,
}

impl Serialize for JobView {
    fn serialize<S: serde::Serializer>(
        &self,
        serializer: S,
    ) -> std::result::Result<S::Ok, S::Error> {
        let mut value = serde_json::to_value(&self.job).map_err(serde::ser::Error::custom)?;
        value["revision"] = json!(self.revision);
        if let Record::UnpersistedTerminal { reason } = &self.record {
            value["persistence_error"] = json!(reason);
        }
        value.serialize(serializer)
    }
}

#[derive(Debug)]
pub enum AdmitError {
    /// Sixteen builds and previews are already queued or running.
    Full,
    /// This job already has a build or preview in progress.
    Busy,
    /// The job is unknown, or cannot run this operation.
    Refused(String),
    Persist(anyhow::Error),
    /// The service is stopping.
    Closed,
    /// A job with this request ID exists already.
    Duplicate(Box<JobView>),
}

/// Live operations at once, across builds and previews.
pub const MAX_OPERATIONS: usize = 16;

impl Jobs {
    /// Loads every record once, marking work the previous service left
    /// unfinished as interrupted. Invalid records are reported and skipped.
    pub fn open(store: &Store) -> Result<Self> {
        let (jobs, invalid) = store.scan_jobs()?;
        for (id, error) in invalid {
            eprintln!("Skipping invalid build record {id}: {error:#}");
        }
        let mut entries = HashMap::new();
        for mut job in jobs {
            if let Some(preview) = job.preview().filter(|p| p.in_progress()) {
                let next = preview
                    .failed("Service stopped during preview capture; no automatic retry was made");
                job.set_preview(next);
                job.updated_at = now();
                store.save_job(&job)?;
            }
            if !job.state().terminal() {
                job.phase = JobPhase::Interrupted { message: "Service stopped during this job. Inspect artifacts/processes before submitting new work; no automatic retry was made.".into() };
                job.updated_at = now();
                store.save_job(&job)?;
            }
            entries.insert(
                job.id.clone(),
                JobEntry {
                    job,
                    revision: 1,
                    record: Record::Committed,
                    operation: None,
                },
            );
        }
        let views = Views {
            jobs: entries
                .iter()
                .map(|(id, e)| (id.clone(), Arc::new(e.view())))
                .collect(),
            operations: 0,
        };
        let (published, snapshot) = Published::new(views.clone());
        let index = JobIndex {
            store: store.clone(),
            entries,
            leases: 0,
            closed: false,
            views,
            published,
        };
        Ok(Self {
            owner: Owner::spawn("build jobs", index),
            views: snapshot,
        })
    }

    pub fn list(&self) -> Vec<JobView> {
        let mut jobs: Vec<JobView> = self
            .views
            .get()
            .jobs
            .values()
            .map(|v| (**v).clone())
            .collect();
        jobs.sort_by(|l, r| {
            r.job
                .created_at
                .cmp(&l.job.created_at)
                .then_with(|| l.job.id.cmp(&r.job.id))
        });
        jobs
    }

    pub fn get(&self, id: &str) -> Option<JobView> {
        self.views.get().jobs.get(id).map(|v| (**v).clone())
    }

    pub fn state(&self, id: &str) -> Option<BuildState> {
        self.views.get().jobs.get(id).map(|v| v.job.state())
    }

    /// The project build submitted with this idempotency key.
    pub fn with_request_id(&self, key: &str) -> Option<JobView> {
        self.views
            .get()
            .jobs
            .values()
            .find(|v| v.job.request().and_then(|r| r.request_id.as_deref()) == Some(key))
            .map(|v| (**v).clone())
    }

    /// Builds and previews queued or running.
    pub fn operations(&self) -> usize {
        self.views.get().operations
    }

    /// Persists a new queued job and leases its build, unless the service
    /// is stopping, the queue is full, or its request ID has a job already.
    pub async fn admit(&self, job: Job) -> std::result::Result<Lease, AdmitError> {
        let owner = self.owner.clone();
        self.owner
            .ask(move |index| {
                if index.closed {
                    return Err(AdmitError::Closed);
                }
                let key = job.request().and_then(|r| r.request_id.as_deref());
                if let Some(prior) = index.entries.values().find(|e| {
                    key.is_some() && e.job.request().and_then(|r| r.request_id.as_deref()) == key
                }) {
                    return Err(AdmitError::Duplicate(Box::new(prior.view())));
                }
                if index.operations() >= MAX_OPERATIONS {
                    return Err(AdmitError::Full);
                }
                index.store.save_job(&job).map_err(AdmitError::Persist)?;
                let (operation, lease) = index.lease(&job.id, OperationKind::Build, owner);
                let id = job.id.clone();
                index.entries.insert(
                    id.clone(),
                    JobEntry {
                        job,
                        revision: 1,
                        record: Record::Committed,
                        operation: Some(operation),
                    },
                );
                index.publish(&id);
                Ok(lease)
            })
            .await
    }

    /// Persists a finished job that runs nothing (an import).
    pub async fn insert(&self, job: Job) -> Result<()> {
        self.owner
            .ask(move |index| {
                index.store.save_job(&job)?;
                let id = job.id.clone();
                index.entries.insert(
                    id.clone(),
                    JobEntry {
                        job,
                        revision: 1,
                        record: Record::Committed,
                        operation: None,
                    },
                );
                index.publish(&id);
                Ok(())
            })
            .await
    }

    /// Queues a new preview of a succeeded project build, keeping its
    /// current image until the capture replaces it.
    pub async fn begin_preview(&self, id: &str) -> std::result::Result<(Job, Lease), AdmitError> {
        let (id, owner) = (id.to_string(), self.owner.clone());
        self.owner
            .ask(move |index| {
                if index.closed {
                    return Err(AdmitError::Closed);
                }
                let operations = index.operations();
                let entry = index
                    .entries
                    .get(&id)
                    .ok_or_else(|| AdmitError::Refused(format!("No build {id}")))?;
                if entry.operation.is_some() {
                    return Err(AdmitError::Busy);
                }
                if operations >= MAX_OPERATIONS {
                    return Err(AdmitError::Full);
                }
                if entry.job.request().is_none() || entry.job.preview().is_none() {
                    return Err(AdmitError::Refused(
                        "Preview requires a succeeded project build with a simulator build recipe"
                            .into(),
                    ));
                }
                let mut job = entry.job.clone();
                let queued = job.preview().map(PreviewState::queued).unwrap_or_default();
                job.set_preview(queued);
                job.updated_at = now();
                index.store.save_job(&job).map_err(AdmitError::Persist)?;
                let (operation, lease) = index.lease(&id, OperationKind::Preview, owner);
                let entry = index.entries.get_mut(&id).expect("jobs are never removed");
                entry.job = job.clone();
                entry.revision += 1;
                entry.operation = Some(operation);
                index.publish(&id);
                Ok((job, lease))
            })
            .await
    }

    /// Commits progress made under a lease. A stale lease commits nothing.
    pub async fn commit(&self, lease: &Lease, job: &Job) -> Result<()> {
        anyhow::ensure!(job.id == lease.id, "lease belongs to another job");
        let (job, held) = (job.clone(), lease.lease);
        self.owner
            .ask(move |index| {
                anyhow::ensure!(
                    index.holds(&job.id, held),
                    "build operation no longer owns this job"
                );
                index.store.save_job(&job)?;
                let id = job.id.clone();
                let entry = index.entries.get_mut(&id).expect("jobs are never removed");
                entry.job = job;
                entry.revision += 1;
                entry.record = Record::Committed;
                index.publish(&id);
                Ok(())
            })
            .await
    }

    /// Ends a lease with the job's terminal result. When the disk refuses it,
    /// the result is still published as `UnpersistedTerminal` and the error
    /// returned so the service can stop admitting work.
    pub async fn finish(&self, lease: Lease, job: &Job) -> Result<()> {
        anyhow::ensure!(job.id == lease.id, "lease belongs to another job");
        let (job, held) = (job.clone(), lease.lease);
        self.owner
            .ask(move |index| {
                let persisted = index.store.save_job(&job);
                let id = job.id.clone();
                let entry = index.entries.get_mut(&id).expect("jobs are never removed");
                if entry.operation.as_ref().is_some_and(|o| o.lease == held) {
                    entry.operation = None;
                }
                entry.job = job;
                entry.revision += 1;
                entry.record = match &persisted {
                    Ok(()) => Record::Committed,
                    Err(error) => Record::UnpersistedTerminal {
                        reason: format!("{error:#}"),
                    },
                };
                index.publish(&id);
                persisted
            })
            .await
    }

    /// Asks a job's live operation to stop. None for an unknown job; false
    /// when nothing is running.
    pub async fn cancel(&self, id: &str) -> Option<(BuildState, Option<OperationKind>)> {
        let id = id.to_string();
        self.owner
            .ask(move |index| {
                let entry = index.entries.get(&id)?;
                let kind = entry
                    .operation
                    .as_ref()
                    .filter(|o| o.cancel.send(true).is_ok())
                    .map(|o| o.kind);
                Some((entry.job.state(), kind))
            })
            .await
    }

    /// For the service's exit: refuses new builds and previews, then asks
    /// every live one to stop, in one turn, so none is admitted after.
    pub async fn close(&self) {
        self.owner
            .ask(|index| {
                index.closed = true;
                for entry in index.entries.values() {
                    if let Some(operation) = &entry.operation {
                        let _ = operation.cancel.send(true);
                    }
                }
            })
            .await
    }
}

impl JobIndex {
    /// `owner` is this index's own handle, for the lease to tell when dropped.
    fn lease(
        &mut self,
        id: &str,
        kind: OperationKind,
        owner: Owner<JobIndex>,
    ) -> (Operation, Lease) {
        self.leases += 1;
        let (cancel, cancelled) = watch::channel(false);
        let lease = Lease {
            id: id.into(),
            lease: self.leases,
            cancelled,
            owner,
        };
        (
            Operation {
                kind,
                lease: self.leases,
                cancel,
            },
            lease,
        )
    }

    fn operations(&self) -> usize {
        self.entries
            .values()
            .filter(|e| e.operation.is_some())
            .count()
    }

    fn holds(&self, id: &str, lease: u64) -> bool {
        self.entries
            .get(id)
            .and_then(|e| e.operation.as_ref())
            .is_some_and(|o| o.lease == lease)
    }

    /// A lease dropped while it still holds its job: the runner is gone, so
    /// the job ends interrupted (saved if it can be) and frees its slot.
    fn abandon(&mut self, id: &str, lease: u64) {
        if !self.holds(id, lease) {
            return;
        }
        let store = self.store.clone();
        let entry = self.entries.get_mut(id).expect("jobs are never removed");
        entry.operation = None;
        if !entry.job.state().terminal() {
            entry.job.phase = JobPhase::Interrupted {
                message: "Its runner stopped before finishing; no automatic retry was made.".into(),
            };
            entry.job.updated_at = now();
            entry.revision += 1;
            entry.record = match store.save_job(&entry.job) {
                Ok(()) => Record::Committed,
                Err(error) => Record::UnpersistedTerminal {
                    reason: format!("{error:#}"),
                },
            };
        }
        self.publish(id);
    }

    /// Publishes the index with `id`'s entry as it now is.
    fn publish(&mut self, id: &str) {
        if let Some(entry) = self.entries.get(id) {
            self.views
                .jobs
                .insert(id.to_string(), Arc::new(entry.view()));
        }
        self.views.operations = self.operations();
        self.published.set(self.views.clone());
    }
}

impl JobEntry {
    fn view(&self) -> JobView {
        JobView {
            job: self.job.clone(),
            revision: self.revision,
            record: self.record.clone(),
        }
    }
}

fn validate_id(id: &str) -> Result<()> {
    let parsed = Uuid::parse_str(id).context("invalid UUID")?;
    ensure!(
        parsed.hyphenated().to_string() == id,
        "UUID must use canonical lowercase hyphenated form"
    );
    Ok(())
}

fn validate_token(token: &str) -> Result<()> {
    ensure!(
        token.len() == 64 && token.bytes().all(|byte| byte.is_ascii_hexdigit()),
        "token must contain 64 hexadecimal characters"
    );
    Ok(())
}

pub(crate) fn check_dir(path: &Path) -> Result<()> {
    ensure!(
        fs::symlink_metadata(path)?.file_type().is_dir(),
        "storage directory must be a real directory: {}",
        path.display()
    );
    Ok(())
}

pub(crate) fn private_dir(path: &Path) -> Result<()> {
    if !path.try_exists()? {
        let mut builder = fs::DirBuilder::new();
        builder.recursive(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder.create(path)?;
    }
    check_dir(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

fn private_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    options
}

fn check_private_file(file: &File) -> Result<()> {
    ensure!(
        file.metadata()?.is_file(),
        "storage path must be a regular file"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

pub(crate) fn open_private_read(path: &Path) -> Result<File> {
    let file = private_options()
        .read(true)
        .open(path)
        .with_context(|| format!("could not read {}", path.display()))?;
    check_private_file(&file)?;
    Ok(file)
}

fn open_private_append(path: &Path) -> Result<File> {
    let file = private_options()
        .read(true)
        .append(true)
        .create(true)
        .open(path)?;
    check_private_file(&file)?;
    Ok(file)
}

pub(crate) fn read_json<T: DeserializeOwned>(path: &Path) -> Result<T> {
    serde_json::from_reader(BufReader::new(open_private_read(path)?))
        .with_context(|| format!("invalid JSON in {}", path.display()))
}

pub(crate) fn atomic_json(path: &Path, value: &impl Serialize) -> Result<()> {
    persist_json(path, value, true).map(|_| ())
}

fn persist_json(path: &Path, value: &impl Serialize, replace: bool) -> Result<bool> {
    write_private(path, replace, |file| {
        serde_json::to_writer_pretty(&mut *file, value)?;
        Ok(file.write_all(b"\n")?)
    })
}

/// A new private file (0600); fails if anything, a symlink included, is
/// already at `path`.
pub(crate) fn create_private(path: &Path) -> Result<File> {
    private_options()
        .write(true)
        .create_new(true)
        .open(path)
        .with_context(|| format!("Creating {}", path.display()))
}

/// Writes a private file whole: `write` fills a hidden file beside `path`,
/// which is synced and then moved in with its directory synced, so a reader
/// or a crash sees the old contents or the new, never part. With `replace`
/// false an existing `path` is kept and `false` returned.
pub(crate) fn write_private(
    path: &Path,
    replace: bool,
    write: impl FnOnce(&mut File) -> Result<()>,
) -> Result<bool> {
    let parent = path.parent().context("storage path has no parent")?;
    check_dir(parent)?;
    if let Ok(metadata) = fs::symlink_metadata(path) {
        ensure!(
            metadata.is_file() && !metadata.file_type().is_symlink(),
            "refusing to replace non-regular storage file"
        );
    }
    let temporary = parent.join(format!(".{}.tmp", Uuid::new_v4()));
    let result = (|| -> Result<bool> {
        let mut file = create_private(&temporary)?;
        write(&mut file)?;
        file.sync_all()?;
        if replace {
            fs::rename(&temporary, path)?;
        } else {
            // A same-directory hard link publishes the already-synced complete
            // file atomically and fails rather than replacing an existing name.
            match fs::hard_link(&temporary, path) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    return Ok(false);
                }
                Err(error) => return Err(error.into()),
            }
        }
        sync_dir(parent)?;
        Ok(true)
    })();
    let _ = fs::remove_file(&temporary);
    result
}

/// Moves a finished file (written elsewhere on the same volume) to `path` as
/// a private file, durably: synced, renamed, and its new directory synced.
pub(crate) fn publish_private(finished: &Path, path: &Path) -> Result<()> {
    let file = private_options().read(true).open(finished)?;
    check_private_file(&file)?;
    file.sync_all()?;
    fs::rename(finished, path)?;
    sync_dir(path.parent().context("storage path has no parent")?)
}

fn sync_dir(path: &Path) -> Result<()> {
    File::open(path)?
        .sync_all()
        .context("could not sync storage directory")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{BuildOrigin, BuildOutput};

    fn job() -> Job {
        Job {
            id: Uuid::new_v4().to_string(),
            created_at: 1,
            updated_at: 1,
            origin: BuildOrigin::Imported,
            phase: JobPhase::Succeeded {
                preview: PreviewState::Absent,
                output: BuildOutput {
                    archive_path: None,
                    ipa_path: Some("/Example.ipa".into()),
                    app_path: None,
                    dsym_paths: vec![],
                    bundle_id: "dev.example.app".into(),
                    version: "1.0".into(),
                    build_number: "1".into(),
                    title: "Example".into(),
                },
            },
        }
    }

    fn diagnostic(job: &Job, kind: DiagnosticKind) -> Diagnostic {
        Diagnostic {
            event_id: Uuid::new_v4().to_string(),
            build_id: job.id.clone(),
            kind,
            message: "line one\nline two".into(),
            timestamp: 12,
            attributes: json!({"nested": true}),
        }
    }

    #[test]
    fn records_and_tokens_survive_restart() -> Result<()> {
        let temporary = tempfile::tempdir()?;
        let root = temporary.path().join("store");
        let store = Store::open(root.clone())?;
        let job = job();
        store.save_job(&job)?;
        let ticket = Ticket {
            token: token(),
            build_id: job.id.clone(),
            expires_at: 44,
            base_url: "https://example.test".into(),
            transfer: crate::model::TransferEvidence::NotStarted,
        };
        store.save_ticket(&ticket)?;
        let control_token = store.settings.control_token.clone();
        let diagnostic_token = store.settings.diagnostic_token.clone();
        drop(store);
        let store = Store::open(root)?;
        assert_eq!(store.settings.control_token, control_token);
        assert_eq!(store.settings.diagnostic_token, diagnostic_token);
        assert_ne!(control_token, diagnostic_token);
        assert_eq!(
            store.load_job(&job.id)?.output().unwrap().bundle_id,
            "dev.example.app"
        );
        assert_eq!(store.list_jobs()?.len(), 1);
        assert_eq!(store.load_ticket(&ticket.token)?.build_id, job.id);
        Ok(())
    }

    #[test]
    fn relative_root_persists_artifact_paths_independent_of_working_directory() -> Result<()> {
        let temporary = tempfile::tempdir_in(std::env::current_dir()?)?;
        let relative_root = PathBuf::from(temporary.path().file_name().unwrap()).join("store");
        assert!(relative_root.is_relative());
        let store = Store::open(relative_root)?;
        assert!(store.root.is_absolute());
        let root = store.root.clone();
        let mut job = job();
        store.save_job(&job)?;
        let artifact_path = store.job_dir(&job.id)?.join("app.ipa");
        fs::write(&artifact_path, b"artifact bytes")?;
        if let JobPhase::Succeeded { output, .. } = &mut job.phase {
            output.ipa_path = Some(artifact_path);
        }
        store.save_job(&job)?;
        drop(store);

        let restarted = Store::open(root)?;
        let stored_path = restarted.load_job(&job.id)?.ipa().unwrap().to_path_buf();
        assert!(stored_path.is_absolute());
        // Joining an unrelated cwd has no effect on an absolute persisted path;
        // avoid changing the process-wide cwd while other tests run in parallel.
        let unrelated_directory = tempfile::tempdir()?;
        assert_eq!(
            fs::read(unrelated_directory.path().join(stored_path))?,
            b"artifact bytes"
        );
        Ok(())
    }

    #[test]
    fn concurrent_first_opens_keep_one_credential_pair() -> Result<()> {
        let temporary = tempfile::tempdir()?;
        let root = temporary.path().join("store");
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(8));
        let handles: Vec<_> = (0..8)
            .map(|_| {
                let root = root.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    Store::open(root).map(|store| {
                        (
                            store.settings.control_token,
                            store.settings.diagnostic_token,
                        )
                    })
                })
            })
            .collect();
        let pairs: Vec<_> = handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .collect::<Result<_>>()?;
        assert!(pairs.iter().all(|pair| *pair == pairs[0]));
        let store = Store::open(root)?;
        assert_eq!(store.settings.control_token, pairs[0].0);
        Ok(())
    }

    #[test]
    fn diagnostic_retries_deduplicate_across_restart_and_conflicts_fail() -> Result<()> {
        let temporary = tempfile::tempdir()?;
        let store = Store::open(temporary.path().to_owned())?;
        let job = job();
        store.save_job(&job)?;
        let mut event = diagnostic(&job, DiagnosticKind::Log);
        assert!(store.append_diagnostic(&event)?);
        drop(store);
        let store = Store::open(temporary.path().to_owned())?;
        assert!(!store.append_diagnostic(&event)?);
        event.message = "different".into();
        assert!(
            store
                .append_diagnostic(&event)
                .unwrap_err()
                .to_string()
                .contains("conflict")
        );
        let page = store.diagnostics(&job.id, 0, 10, None)?;
        assert_eq!(page["events"].as_array().unwrap().len(), 1);
        assert_eq!(page["events"][0]["message"], "line one\nline two");
        Ok(())
    }

    #[test]
    fn filtered_pagination_tracks_all_records_without_skipping_matches() -> Result<()> {
        let temporary = tempfile::tempdir()?;
        let store = Store::open(temporary.path().to_owned())?;
        let job = job();
        store.save_job(&job)?;
        for kind in [
            DiagnosticKind::Log,
            DiagnosticKind::Crash,
            DiagnosticKind::Log,
            DiagnosticKind::Crash,
            DiagnosticKind::Launch,
        ] {
            store.append_diagnostic(&diagnostic(&job, kind))?;
        }
        let first = store.diagnostics(&job.id, 0, 1, Some(DiagnosticKind::Crash))?;
        assert_eq!(first["next_cursor"], 2);
        assert_eq!(first["has_more"], true);
        let second = store.diagnostics(&job.id, 2, 1, Some(DiagnosticKind::Crash))?;
        assert_eq!(second["next_cursor"], 4);
        let final_page = store.diagnostics(&job.id, 4, 1, Some(DiagnosticKind::Crash))?;
        assert_eq!(final_page["next_cursor"], 5);
        assert_eq!(final_page["has_more"], false);
        assert_eq!(final_page["events"], json!([]));
        assert!(store.diagnostics(&job.id, 6, 1, None).is_err());
        Ok(())
    }

    #[test]
    fn invalid_paths_schema_and_unassociated_diagnostics_are_rejected() -> Result<()> {
        let temporary = tempfile::tempdir()?;
        let store = Store::open(temporary.path().to_owned())?;
        for id in ["../outside", "/tmp/outside", "not-a-uuid"] {
            assert!(store.job_dir(id).is_err());
            assert!(store.load_ticket(id).is_err());
        }
        let mut job = job();
        job.origin = BuildOrigin::Project {
            request: serde_json::from_value(
                json!({"project": "/P.xcodeproj", "scheme": "P", "configuration": "Debug",
                "mode": "simulator", "export_options": null, "request_id": null}),
            )?,
            provenance: Default::default(),
        };
        job.phase = JobPhase::Failed {
            message: "no product".into(),
        };
        store.save_job(&job)?;
        assert!(
            store
                .append_diagnostic(&diagnostic(&job, DiagnosticKind::Log))
                .is_err()
        );
        let config = temporary.path().join("config.json");
        let mut settings = store.settings.clone();
        settings.schema_version = SCHEMA_VERSION + 1;
        atomic_json(&config, &settings)?;
        let original = fs::read(&config)?;
        assert!(Store::open(temporary.path().to_owned()).is_err());
        assert_eq!(fs::read(config)?, original);
        Ok(())
    }

    #[test]
    fn rejected_diagnostics_do_not_change_existing_data() -> Result<()> {
        let temporary = tempfile::tempdir()?;
        let store = Store::open(temporary.path().to_owned())?;
        let job = job();
        store.save_job(&job)?;
        let event = diagnostic(&job, DiagnosticKind::Log);
        store.append_diagnostic(&event)?;
        let path = store.job_dir(&job.id)?.join("diagnostics.jsonl");
        let original = fs::read(&path)?;
        let mut oversized = diagnostic(&job, DiagnosticKind::Log);
        oversized.message = "x".repeat(MAX_DIAGNOSTIC_MESSAGE_BYTES + 1);
        assert!(store.append_diagnostic(&oversized).is_err());
        assert_eq!(fs::read(&path)?, original);
        // A corrupt or crash-truncated tail is reported without erasing evidence.
        open_private_append(&path)?.write_all(b"{\"partial\":")?;
        let original = fs::read(&path)?;
        assert!(
            store
                .append_diagnostic(&diagnostic(&job, DiagnosticKind::Log))
                .is_err()
        );
        assert_eq!(fs::read(&path)?, original);
        assert!(store.diagnostics(&job.id, 0, 100, None).is_err());
        Ok(())
    }

    #[test]
    fn storage_quota_preserves_existing_file() -> Result<()> {
        let temporary = tempfile::tempdir()?;
        let store = Store::open(temporary.path().to_owned())?;
        let job = job();
        store.save_job(&job)?;
        let path = store.job_dir(&job.id)?.join("diagnostics.jsonl");
        let file = open_private_append(&path)?;
        // A sparse file exercises the size guard without allocating 64 MiB.
        file.set_len(MAX_DIAGNOSTIC_BYTES + 1)?;
        let error = store
            .append_diagnostic(&diagnostic(&job, DiagnosticKind::Log))
            .unwrap_err();
        assert!(error.to_string().contains("64 MiB"));
        assert_eq!(fs::metadata(&path)?.len(), MAX_DIAGNOSTIC_BYTES + 1);
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn secrets_and_records_are_private_and_symlinks_are_refused() -> Result<()> {
        use std::os::unix::fs::{PermissionsExt, symlink};
        let temporary = tempfile::tempdir()?;
        let root = temporary.path().join("store");
        let store = Store::open(root.clone())?;
        let job = job();
        store.save_job(&job)?;
        let event = diagnostic(&job, DiagnosticKind::Log);
        store.append_diagnostic(&event)?;
        let ticket = Ticket {
            token: token(),
            build_id: job.id.clone(),
            expires_at: 10,
            base_url: "https://example.test".into(),
            transfer: crate::model::TransferEvidence::NotStarted,
        };
        store.save_ticket(&ticket)?;
        for path in [
            &root,
            &root.join("jobs"),
            &root.join("tickets"),
            &store.job_dir(&job.id)?,
        ] {
            assert_eq!(fs::metadata(path)?.permissions().mode() & 0o777, 0o700);
        }
        for path in [
            root.join("config.json"),
            store.job_dir(&job.id)?.join("job.json"),
            store.job_dir(&job.id)?.join("diagnostics.jsonl"),
            root.join("tickets").join(format!("{}.json", ticket.token)),
        ] {
            assert_eq!(fs::metadata(path)?.permissions().mode() & 0o777, 0o600);
        }
        let outside = temporary.path().join("outside.json");
        fs::write(&outside, b"do not change")?;
        let path = store.job_dir(&job.id)?.join("job.json");
        fs::remove_file(&path)?;
        symlink(&outside, &path)?;
        assert!(store.load_job(&job.id).is_err());
        assert!(store.save_job(&job).is_err());
        assert_eq!(fs::read(&outside)?, b"do not change");
        Ok(())
    }

    #[tokio::test]
    async fn job_index_owns_leases_and_serves_a_result_the_disk_refused() -> Result<()> {
        let temporary = tempfile::tempdir()?;
        let store = Store::open(temporary.path().to_owned())?;
        let jobs = Jobs::open(&store)?;
        let project = |key: &str| -> Result<Job> {
            let mut queued = job();
            queued.origin = BuildOrigin::Project {
                request: serde_json::from_value(
                    json!({"project": "/P.xcodeproj", "scheme": "P", "configuration": "Debug",
                    "mode": "simulator", "export_options": null, "request_id": key}),
                )?,
                provenance: Default::default(),
            };
            queued.phase = JobPhase::Queued;
            Ok(queued)
        };
        let queued = project("k")?;
        let lease = jobs.admit(queued.clone()).await.unwrap();
        assert!(matches!(
            jobs.begin_preview(&queued.id).await,
            Err(AdmitError::Busy)
        ));
        assert_eq!(
            jobs.with_request_id("k").map(|v| v.job.id),
            Some(queued.id.clone())
        );
        // The same request ID again, even as a new job, admits nothing.
        assert!(
            matches!(jobs.admit(project("k")?).await, Err(AdmitError::Duplicate(prior)) if prior.job.id == queued.id)
        );
        // Cancellation reaches the live operation.
        assert_eq!(
            jobs.cancel(&queued.id).await,
            Some((BuildState::Queued, Some(OperationKind::Build)))
        );
        assert!(*lease.cancelled.borrow());
        // The disk refuses the terminal write: the result is still what readers see.
        let directory = store.job_dir(&queued.id)?;
        fs::remove_dir_all(&directory)?;
        fs::write(&directory, b"not a directory")?;
        let mut cancelled = queued.clone();
        cancelled.phase = JobPhase::Cancelled { message: None };
        let stale = Lease {
            id: queued.id.clone(),
            lease: 0,
            cancelled: lease.cancelled.clone(),
            owner: jobs.owner.clone(),
        };
        assert!(jobs.finish(lease, &cancelled).await.is_err());
        let view = jobs.get(&queued.id).unwrap();
        assert_eq!(
            (view.job.state(), view.revision),
            (BuildState::Cancelled, 2)
        );
        assert!(matches!(view.record, Record::UnpersistedTerminal { .. }));
        assert!(serde_json::to_value(&view)?["persistence_error"].is_string());
        assert_eq!(jobs.operations(), 0);
        // An ended lease commits nothing more.
        assert!(jobs.commit(&stale, &queued).await.is_err());
        assert_eq!(
            jobs.get(&queued.id).unwrap().job.state(),
            BuildState::Cancelled
        );
        // A lease whose runner went away frees its slot and ends its job interrupted.
        let orphan = project("o")?;
        drop(jobs.admit(orphan.clone()).await.unwrap());
        jobs.owner.ask(|_| ()).await;
        assert_eq!(
            (jobs.operations(), jobs.state(&orphan.id)),
            (0, Some(BuildState::Interrupted))
        );
        assert_eq!(store.load_job(&orphan.id)?.state(), BuildState::Interrupted);
        Ok(())
    }
}
