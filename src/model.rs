use serde::{Deserialize, Serialize};
use std::path::PathBuf;

pub const SCHEMA_VERSION: u32 = 1;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum BuildMode {
    Archive,
    Simulator,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct BuildRequest {
    pub project: PathBuf,
    pub scheme: String,
    pub configuration: String,
    pub mode: BuildMode,
    pub export_options: Option<PathBuf>,
    #[serde(default)]
    pub allow_provisioning_updates: bool,
    pub request_id: Option<String>,
    /// Device builds get the Squircle debug overlay unless this is set.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub no_overlay: bool,
    /// The T3 thread that started it (an app agent or a worker), so its app
    /// agent hears when it finishes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thread: Option<String>,
}

/// A finished product's artifacts and app metadata.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct BuildOutput {
    pub archive_path: Option<PathBuf>,
    pub ipa_path: Option<PathBuf>,
    pub app_path: Option<PathBuf>,
    pub dsym_paths: Vec<PathBuf>,
    pub bundle_id: String,
    pub version: String,
    pub build_number: String,
    pub title: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum BuildState {
    Queued,
    Running,
    Succeeded,
    Failed,
    Cancelled,
    Interrupted,
}

impl BuildState {
    pub fn terminal(&self) -> bool {
        !matches!(self, Self::Queued | Self::Running)
    }
}

/// Where a job's product comes from.
#[derive(Clone, Debug, PartialEq, Eq)]
#[allow(
    clippy::large_enum_variant,
    reason = "Imported jobs are rare; the job owns its recipe inline like its phase."
)]
pub enum BuildOrigin {
    /// A validated project recipe and what was observed at submission.
    Project {
        request: BuildRequest,
        provenance: Provenance,
    },
    /// An IPA imported as is; its signature is not verified.
    Imported,
}

/// Best-effort submission-time observations, not a source snapshot.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Provenance {
    /// Git HEAD observed at submission.
    pub revision: Option<String>,
    /// Working-tree status observed at submission; None means unavailable.
    pub dirty: Option<bool>,
    /// The same project in its repository's main checkout, for a build of
    /// a linked git worktree (T3's worktrees): the app it belongs to.
    pub main_project: Option<PathBuf>,
}

/// A job's lifecycle. Each phase carries exactly what it has: only a
/// succeeded job has artifacts.
#[derive(Clone, Debug, PartialEq, Eq)]
#[allow(
    clippy::large_enum_variant,
    reason = "The job owns its result inline; the queue is capped and splitting storage obscures that ownership."
)]
pub enum JobPhase {
    Queued,
    Running,
    Succeeded {
        output: BuildOutput,
    },
    Failed {
        message: String,
    },
    /// Cancelled before it started has no message.
    Cancelled {
        message: Option<String>,
    },
    /// The service stopped while it was queued or running.
    Interrupted {
        message: String,
    },
}

impl JobPhase {
    pub fn state(&self) -> BuildState {
        match self {
            Self::Queued => BuildState::Queued,
            Self::Running => BuildState::Running,
            Self::Succeeded { .. } => BuildState::Succeeded,
            Self::Failed { .. } => BuildState::Failed,
            Self::Cancelled { .. } => BuildState::Cancelled,
            Self::Interrupted { .. } => BuildState::Interrupted,
        }
    }
}

/// A build job. `origin` and `phase` are the whole truth; the persisted and
/// wire JSON keep the older flat shape through `JobRecord`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "JobRecord", into = "JobRecord")]
pub struct Job {
    pub id: String,
    pub created_at: u64,
    pub updated_at: u64,
    pub origin: BuildOrigin,
    pub phase: JobPhase,
}

impl Job {
    pub fn state(&self) -> BuildState {
        self.phase.state()
    }
    pub fn request(&self) -> Option<&BuildRequest> {
        match &self.origin {
            BuildOrigin::Project { request, .. } => Some(request),
            BuildOrigin::Imported => None,
        }
    }
    /// The project an app owns this build by: the main checkout's for a
    /// build of a linked worktree, otherwise the one it built.
    pub fn app_project(&self) -> Option<&std::path::Path> {
        match &self.origin {
            BuildOrigin::Project {
                request,
                provenance,
            } => Some(
                provenance
                    .main_project
                    .as_deref()
                    .unwrap_or(&request.project),
            ),
            BuildOrigin::Imported => None,
        }
    }
    pub fn provenance(&self) -> Option<&Provenance> {
        match &self.origin {
            BuildOrigin::Project { provenance, .. } => Some(provenance),
            BuildOrigin::Imported => None,
        }
    }
    pub fn output(&self) -> Option<&BuildOutput> {
        match &self.phase {
            JobPhase::Succeeded { output, .. } => Some(output),
            _ => None,
        }
    }
    pub fn error(&self) -> Option<&str> {
        match &self.phase {
            JobPhase::Failed { message } | JobPhase::Interrupted { message } => Some(message),
            JobPhase::Cancelled { message } => message.as_deref(),
            _ => None,
        }
    }
    /// An exported IPA this job can install.
    pub fn ipa(&self) -> Option<&std::path::Path> {
        self.output().and_then(|o| o.ipa_path.as_deref())
    }
}

const PROJECT_SOURCE: &str = "xcodebuild";
const IMPORTED_SOURCE: &str = "imported_ipa_signature_not_verified";

/// The persisted and wire shape of a job, unchanged from before the typed
/// model. Reading one validates it; an inconsistent record is an error, not
/// a default.
#[derive(Clone, Debug, Serialize, Deserialize)]
struct JobRecord {
    id: String,
    created_at: u64,
    updated_at: u64,
    state: BuildState,
    request: Option<BuildRequest>,
    output: Option<BuildOutput>,
    error: Option<String>,
    source: String,
    /// Git HEAD observed at submission, not a source snapshot.
    #[serde(default)]
    source_revision: Option<String>,
    /// Working-tree status observed at submission; None means unavailable.
    #[serde(default)]
    source_dirty: Option<bool>,
    /// The project in the main checkout when built from a linked worktree.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    source_main_project: Option<PathBuf>,
}

impl TryFrom<JobRecord> for Job {
    type Error = String;
    fn try_from(r: JobRecord) -> Result<Self, String> {
        let origin = match (r.source.as_str(), r.request) {
            (PROJECT_SOURCE, Some(request)) => BuildOrigin::Project {
                request,
                provenance: Provenance {
                    revision: r.source_revision,
                    dirty: r.source_dirty,
                    main_project: r.source_main_project,
                },
            },
            (IMPORTED_SOURCE, None) => BuildOrigin::Imported,
            (source, request) => {
                return Err(format!(
                    "job source {source:?} does not match its recipe (present: {})",
                    request.is_some()
                ));
            }
        };
        let no_output = |phase: JobPhase, output: &Option<BuildOutput>| match output {
            Some(_) => Err(format!("{:?} job has build output", phase.state())),
            None => Ok(phase),
        };
        let phase = match (r.state, r.error) {
            (BuildState::Succeeded, None) => {
                let output = r.output.ok_or("succeeded job has no output")?;
                let artifact = match &origin {
                    BuildOrigin::Project { request, .. }
                        if request.mode == BuildMode::Simulator =>
                    {
                        output.app_path.is_some()
                    }
                    _ => output.ipa_path.is_some(),
                };
                if !artifact {
                    return Err("succeeded job is missing its product".into());
                }
                JobPhase::Succeeded { output }
            }
            (BuildState::Succeeded, Some(_)) => return Err("succeeded job has an error".into()),
            (_, _) if origin == BuildOrigin::Imported => {
                return Err("imported job did not succeed".into());
            }
            (BuildState::Queued, None) => no_output(JobPhase::Queued, &r.output)?,
            (BuildState::Running, None) => no_output(JobPhase::Running, &r.output)?,
            (BuildState::Failed, Some(message)) => {
                no_output(JobPhase::Failed { message }, &r.output)?
            }
            (BuildState::Interrupted, Some(message)) => {
                no_output(JobPhase::Interrupted { message }, &r.output)?
            }
            (BuildState::Cancelled, message) => {
                no_output(JobPhase::Cancelled { message }, &r.output)?
            }
            (state, error) => {
                return Err(format!(
                    "{state:?} job with error present: {}",
                    error.is_some()
                ));
            }
        };
        Ok(Job {
            id: r.id,
            created_at: r.created_at,
            updated_at: r.updated_at,
            origin,
            phase,
        })
    }
}

impl From<Job> for JobRecord {
    fn from(job: Job) -> Self {
        let state = job.state();
        let error = job.error().map(str::to_owned);
        let (source, request, provenance) = match job.origin {
            BuildOrigin::Project {
                request,
                provenance,
            } => (PROJECT_SOURCE, Some(request), provenance),
            BuildOrigin::Imported => (IMPORTED_SOURCE, None, Provenance::default()),
        };
        let output = match job.phase {
            JobPhase::Succeeded { output } => Some(output),
            _ => None,
        };
        JobRecord {
            id: job.id,
            created_at: job.created_at,
            updated_at: job.updated_at,
            state,
            request,
            output,
            error,
            source: source.into(),
            source_revision: provenance.revision,
            source_dirty: provenance.dirty,
            source_main_project: provenance.main_project,
        }
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Settings {
    pub schema_version: u32,
    pub control_token: String,
    pub diagnostic_token: String,
    /// serve's last --public-url, used by starts without one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub public_url: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Ticket {
    pub token: String,
    pub build_id: String,
    pub expires_at: u64,
    pub base_url: String,
    #[serde(flatten)]
    pub transfer: TransferEvidence,
}

/// What the service saw of a link's IPA transfer. iOS fetches the IPA only
/// after the person confirms the install prompt, and transfers can fail or be
/// aborted: none of these proves installation or launch.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "TransferRecord", into = "TransferRecord")]
pub enum TransferEvidence {
    #[default]
    NotStarted,
    /// The service opened the IPA for a download request.
    Opened { started_at: u64 },
    /// Every byte of the IPA was handed to the connection.
    Completed { started_at: u64, completed_at: u64 },
}

impl TransferEvidence {
    pub fn opened(self, at: u64) -> Self {
        match self {
            Self::NotStarted => Self::Opened { started_at: at },
            other => other,
        }
    }
    pub fn completed(self, at: u64) -> Self {
        match self {
            Self::NotStarted => Self::Completed {
                started_at: at,
                completed_at: at,
            },
            Self::Opened { started_at } => Self::Completed {
                started_at,
                completed_at: at,
            },
            done => done,
        }
    }
}

/// The ticket's persisted and wire fields: `download_started_at` (the IPA
/// was opened) and `downloaded_at` (every byte was sent).
#[derive(Clone, Copy, Serialize, Deserialize)]
struct TransferRecord {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    download_started_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    downloaded_at: Option<u64>,
}

impl TryFrom<TransferRecord> for TransferEvidence {
    type Error = &'static str;
    fn try_from(r: TransferRecord) -> Result<Self, Self::Error> {
        match (r.download_started_at, r.downloaded_at) {
            (None, None) => Ok(Self::NotStarted),
            (Some(started_at), None) => Ok(Self::Opened { started_at }),
            (Some(started_at), Some(completed_at)) => Ok(Self::Completed {
                started_at,
                completed_at,
            }),
            (None, Some(_)) => Err("ticket finished a download it never started"),
        }
    }
}

impl From<TransferEvidence> for TransferRecord {
    fn from(evidence: TransferEvidence) -> Self {
        let (download_started_at, downloaded_at) = match evidence {
            TransferEvidence::NotStarted => (None, None),
            TransferEvidence::Opened { started_at } => (Some(started_at), None),
            TransferEvidence::Completed {
                started_at,
                completed_at,
            } => (Some(started_at), Some(completed_at)),
        };
        Self {
            download_started_at,
            downloaded_at,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Diagnostic {
    pub event_id: String,
    pub build_id: String,
    pub kind: DiagnosticKind,
    pub message: String,
    pub timestamp: u64,
    #[serde(default)]
    pub attributes: serde_json::Value,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticKind {
    Launch,
    Log,
    Crash,
}

pub fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

pub fn token() -> String {
    format!(
        "{}{}",
        uuid::Uuid::new_v4().simple(),
        uuid::Uuid::new_v4().simple()
    )
}

pub fn success(data: impl Serialize) -> serde_json::Value {
    serde_json::json!({"schema_version": SCHEMA_VERSION, "ok": true, "data": data})
}

pub fn failure(code: &str, message: impl AsRef<str>, next_step: &str) -> serde_json::Value {
    failure_with(code, message, next_step, false)
}

/// `retryable` means the request was refused before any side effect, so the
/// same request may be sent again as is. Failures whose outcome is ambiguous
/// (a mutation that may have happened) are never retryable.
pub fn failure_with(
    code: &str,
    message: impl AsRef<str>,
    next_step: &str,
    retryable: bool,
) -> serde_json::Value {
    serde_json::json!({"schema_version": SCHEMA_VERSION, "ok": false, "error": {
        "code": code, "message": message.as_ref(), "retryable": retryable, "next_step": next_step
    }})
}
