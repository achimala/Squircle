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
    #[serde(default)]
    pub capture_preview: bool,
    pub request_id: Option<String>,
    /// Device builds get the Squircle debug overlay unless this is set.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub no_overlay: bool,
    /// The T3 thread that started it (an app agent or a worker), so its app
    /// agent hears when it finishes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thread: Option<String>,
}

/// A finished product's artifacts and app metadata. Preview captures are a
/// separate operation (`PreviewState`) and never change what is installable.
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
/// succeeded job has artifacts, and only it can have a preview.
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
        preview: PreviewState,
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

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PreviewSource {
    /// The simulator product this job built.
    BuiltSimulatorProduct,
    /// A simulator rebuild of the project's current working tree.
    CurrentWorkingTree,
}

impl PreviewSource {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::BuiltSimulatorProduct => "built_simulator_product",
            Self::CurrentWorkingTree => "current_working_tree",
        }
    }
    pub fn parse(value: &str) -> Option<Self> {
        [Self::BuiltSimulatorProduct, Self::CurrentWorkingTree]
            .into_iter()
            .find(|s| s.as_str() == value)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PreviewArtifact {
    pub path: PathBuf,
    pub captured_at: u64,
    /// None for captures recorded before the source was kept.
    pub source: Option<PreviewSource>,
}

/// A succeeded build's screenshot, captured as its own operation. A failed
/// or running recapture keeps the prior image.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum PreviewState {
    #[default]
    Absent,
    Queued {
        prior: Option<PreviewArtifact>,
    },
    Capturing {
        prior: Option<PreviewArtifact>,
    },
    Ready(PreviewArtifact),
    Failed {
        reason: String,
        prior: Option<PreviewArtifact>,
    },
}

impl PreviewState {
    /// The newest image this build has, whatever its latest attempt did.
    pub fn artifact(&self) -> Option<&PreviewArtifact> {
        match self {
            Self::Absent => None,
            Self::Ready(artifact) => Some(artifact),
            Self::Queued { prior } | Self::Capturing { prior } | Self::Failed { prior, .. } => {
                prior.as_ref()
            }
        }
    }
    pub fn in_progress(&self) -> bool {
        matches!(self, Self::Queued { .. } | Self::Capturing { .. })
    }
    pub fn queued(&self) -> Self {
        Self::Queued {
            prior: self.artifact().cloned(),
        }
    }
    pub fn capturing(&self) -> Self {
        Self::Capturing {
            prior: self.artifact().cloned(),
        }
    }
    pub fn failed(&self, reason: impl Into<String>) -> Self {
        Self::Failed {
            reason: reason.into(),
            prior: self.artifact().cloned(),
        }
    }
    /// A capture's result; a failure keeps the previous image.
    pub fn finish(&self, result: anyhow::Result<PreviewArtifact>) -> Self {
        match result {
            Ok(artifact) => Self::Ready(artifact),
            Err(error) => self.failed(format!("{error:#}")),
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
    pub fn preview(&self) -> Option<&PreviewState> {
        match &self.phase {
            JobPhase::Succeeded { preview, .. } => Some(preview),
            _ => None,
        }
    }
    /// Replaces a succeeded job's preview; other phases have none.
    pub fn set_preview(&mut self, next: PreviewState) -> bool {
        match &mut self.phase {
            JobPhase::Succeeded { preview, .. } => {
                *preview = next;
                true
            }
            _ => false,
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
    output: Option<OutputRecord>,
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

#[derive(Clone, Debug, Serialize, Deserialize)]
struct OutputRecord {
    #[serde(default)]
    preview_path: Option<PathBuf>,
    /// `pending`, `running`, `succeeded` or `failed`.
    #[serde(default)]
    preview_state: Option<String>,
    #[serde(default)]
    preview_error: Option<String>,
    #[serde(default)]
    preview_captured_at: Option<u64>,
    #[serde(default)]
    preview_source: Option<String>,
    #[serde(flatten)]
    output: BuildOutput,
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
        let no_output = |phase: JobPhase, output: &Option<OutputRecord>| match output {
            Some(_) => Err(format!("{:?} job has build output", phase.state())),
            None => Ok(phase),
        };
        let phase = match (r.state, r.error) {
            (BuildState::Succeeded, None) => {
                let record = r.output.ok_or("succeeded job has no output")?;
                let preview = preview_from_record(&record)?;
                let output = record.output;
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
                JobPhase::Succeeded { output, preview }
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

fn preview_from_record(record: &OutputRecord) -> Result<PreviewState, String> {
    let source = match record.preview_source.as_deref() {
        None => None,
        Some(value) => Some(
            PreviewSource::parse(value)
                .ok_or_else(|| format!("unknown preview source {value:?}"))?,
        ),
    };
    let artifact = match (&record.preview_path, record.preview_captured_at) {
        (Some(path), Some(captured_at)) => Some(PreviewArtifact {
            path: path.clone(),
            captured_at,
            source,
        }),
        (None, None) => None,
        _ => return Err("preview path and capture time must come together".into()),
    };
    let reason = record.preview_error.clone();
    Ok(match (record.preview_state.as_deref(), artifact, reason) {
        (None, None, None) => PreviewState::Absent,
        // Records from before preview state was kept.
        (None | Some("succeeded"), Some(artifact), None) => PreviewState::Ready(artifact),
        (Some("pending"), prior, None) => PreviewState::Queued { prior },
        (Some("running"), prior, None) => PreviewState::Capturing { prior },
        (Some("failed"), prior, Some(reason)) => PreviewState::Failed { reason, prior },
        (state, artifact, reason) => {
            return Err(format!(
                "inconsistent preview: state {state:?}, image {}, error {}",
                artifact.is_some(),
                reason.is_some()
            ));
        }
    })
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
            JobPhase::Succeeded { output, preview } => {
                let artifact = preview.artifact().cloned();
                let (preview_state, preview_error) = match &preview {
                    PreviewState::Absent => (None, None),
                    PreviewState::Queued { .. } => (Some("pending"), None),
                    PreviewState::Capturing { .. } => (Some("running"), None),
                    PreviewState::Ready(_) => (Some("succeeded"), None),
                    PreviewState::Failed { reason, .. } => (Some("failed"), Some(reason.clone())),
                };
                Some(OutputRecord {
                    preview_path: artifact.as_ref().map(|a| a.path.clone()),
                    preview_state: preview_state.map(str::to_owned),
                    preview_error,
                    preview_captured_at: artifact.as_ref().map(|a| a.captured_at),
                    preview_source: artifact
                        .and_then(|a| a.source)
                        .map(|s| s.as_str().to_owned()),
                    output,
                })
            }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn record(
        state: &str,
        output: serde_json::Value,
        error: serde_json::Value,
    ) -> serde_json::Value {
        serde_json::json!({
            "id": "ed8c7cf6-45ac-4a0f-90ef-67e4901e9386", "created_at": 1, "updated_at": 1,
            "state": state, "output": output, "error": error, "source": "xcodebuild",
            "request": {"project": "/P.xcodeproj", "scheme": "P", "configuration": "Debug",
                "mode": "archive", "export_options": "/E.plist", "request_id": null}
        })
    }

    fn ipa(extra: serde_json::Value) -> serde_json::Value {
        let mut output = serde_json::json!({"archive_path": "/A.xcarchive", "ipa_path": "/A.ipa", "app_path": null,
            "dsym_paths": [], "bundle_id": "b", "version": "1", "build_number": "1", "title": "A"});
        output
            .as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        output
    }

    #[test]
    fn persisted_jobs_are_validated_not_defaulted() {
        use serde_json::{Value, json};
        let load = |value: Value| serde_json::from_value::<Job>(value);
        // Legacy records: no provenance, a preview without its state.
        let legacy = load(record(
            "succeeded",
            ipa(json!({"preview_path": "/p.png", "preview_captured_at": 3})),
            Value::Null,
        ))
        .unwrap();
        assert_eq!(legacy.provenance(), Some(&Provenance::default()));
        assert!(
            matches!(legacy.preview(), Some(PreviewState::Ready(a)) if a.captured_at == 3 && a.source.is_none())
        );
        // A failed recapture keeps the prior image, and survives a round trip.
        let failed = legacy.preview().unwrap().failed("crashed");
        let mut job = legacy.clone();
        job.set_preview(failed.clone());
        assert_eq!(failed.artifact(), legacy.preview().unwrap().artifact());
        assert_eq!(load(serde_json::to_value(&job).unwrap()).unwrap(), job);
        // States a flat record could hold but a job cannot.
        for bad in [
            record("succeeded", Value::Null, Value::Null),
            record("succeeded", ipa(json!({"ipa_path": null})), Value::Null),
            record("succeeded", ipa(json!({})), json!("but it failed")),
            record("failed", ipa(json!({})), json!("boom")),
            record("failed", Value::Null, Value::Null),
            record("running", Value::Null, json!("boom")),
            record(
                "succeeded",
                ipa(json!({"preview_state": "succeeded"})),
                Value::Null,
            ),
            record(
                "succeeded",
                ipa(json!({"preview_path": "/p.png"})),
                Value::Null,
            ),
            record(
                "succeeded",
                ipa(json!({"preview_state": "failed"})),
                Value::Null,
            ),
            record(
                "succeeded",
                ipa(
                    json!({"preview_path": "/p.png", "preview_captured_at": 1, "preview_source": "drawn"}),
                ),
                Value::Null,
            ),
            {
                let mut r = record("running", Value::Null, Value::Null);
                r["source"] = "imported_ipa_signature_not_verified".into();
                r
            },
            {
                let mut r = record("succeeded", ipa(json!({})), Value::Null);
                r["request"] = Value::Null;
                r
            },
        ] {
            assert!(load(bad.clone()).is_err(), "accepted {bad}");
        }
    }
}
