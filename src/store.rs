use crate::model::{Diagnostic, DiagnosticKind, Job, SCHEMA_VERSION, Settings, Ticket, token};
use anyhow::{Context, Result, ensure};
use serde::{Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use uuid::Uuid;

pub const MAX_DIAGNOSTIC_BYTES: u64 = 64 * 1024 * 1024;
pub const MAX_DIAGNOSTIC_MESSAGE_BYTES: usize = 512 * 1024;
const MAX_DIAGNOSTIC_EVENT_BYTES: usize = 1024 * 1024;
const MAX_PAGE_SIZE: usize = 1000;

/// The service serializes all access to this store, including read/modify/write
/// operations, with its outer mutex and holds the exclusive service lock.
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

    pub fn list_jobs(&self) -> Result<Vec<Job>> {
        let mut jobs = Vec::new();
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
                jobs.push(self.load_job(&id)?);
            }
        }
        jobs.sort_by(|left, right| {
            right
                .created_at
                .cmp(&left.created_at)
                .then_with(|| left.id.cmp(&right.id))
        });
        Ok(jobs)
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
            job.output.is_some(),
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

fn check_dir(path: &Path) -> Result<()> {
    ensure!(
        fs::symlink_metadata(path)?.file_type().is_dir(),
        "storage directory must be a real directory: {}",
        path.display()
    );
    Ok(())
}

fn private_dir(path: &Path) -> Result<()> {
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

fn open_private_read(path: &Path) -> Result<File> {
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

fn read_json<T: DeserializeOwned>(path: &Path) -> Result<T> {
    serde_json::from_reader(BufReader::new(open_private_read(path)?))
        .with_context(|| format!("invalid JSON in {}", path.display()))
}

fn atomic_json(path: &Path, value: &impl Serialize) -> Result<()> {
    persist_json(path, value, true).map(|_| ())
}

fn persist_json(path: &Path, value: &impl Serialize, replace: bool) -> Result<bool> {
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
        let mut file = private_options()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        serde_json::to_writer_pretty(&mut file, value)?;
        file.write_all(b"\n")?;
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

fn sync_dir(path: &Path) -> Result<()> {
    File::open(path)?
        .sync_all()
        .context("could not sync storage directory")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{BuildOutput, BuildState};

    fn job() -> Job {
        Job {
            id: Uuid::new_v4().to_string(),
            created_at: 1,
            updated_at: 1,
            state: BuildState::Succeeded,
            request: None,
            error: None,
            source: "test".into(),
            source_revision: None,
            source_dirty: None,
            output: Some(BuildOutput {
                archive_path: None,
                ipa_path: None,
                app_path: None,
                dsym_paths: vec![],
                bundle_id: "dev.example.app".into(),
                version: "1.0".into(),
                build_number: "1".into(),
                title: "Example".into(),
            }),
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
            store.load_job(&job.id)?.output.unwrap().bundle_id,
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
        job.output.as_mut().unwrap().ipa_path = Some(artifact_path);
        store.save_job(&job)?;
        drop(store);

        let restarted = Store::open(root)?;
        let stored_path = restarted
            .load_job(&job.id)?
            .output
            .unwrap()
            .ipa_path
            .unwrap();
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
        job.output = None;
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
}
