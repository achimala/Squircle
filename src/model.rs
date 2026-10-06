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
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BuildOutput {
    #[serde(default)]
    pub preview_path: Option<PathBuf>,
    #[serde(default)]
    pub preview_state: Option<String>,
    #[serde(default)]
    pub preview_error: Option<String>,
    #[serde(default)]
    pub preview_captured_at: Option<u64>,
    /// A simulator product from this job, or a rebuild of the current working tree.
    #[serde(default)]
    pub preview_source: Option<String>,
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

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Job {
    pub id: String,
    pub created_at: u64,
    pub updated_at: u64,
    pub state: BuildState,
    pub request: Option<BuildRequest>,
    pub output: Option<BuildOutput>,
    pub error: Option<String>,
    pub source: String,
    /// Git HEAD observed at submission, not a source snapshot.
    #[serde(default)]
    pub source_revision: Option<String>,
    /// Working-tree status observed at submission; None means unavailable.
    #[serde(default)]
    pub source_dirty: Option<bool>,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Settings {
    pub schema_version: u32,
    pub control_token: String,
    pub diagnostic_token: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Ticket {
    pub token: String,
    pub build_id: String,
    pub expires_at: u64,
    pub base_url: String,
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
    serde_json::json!({"schema_version": SCHEMA_VERSION, "ok": false, "error": {
        "code": code, "message": message.as_ref(), "retryable": false, "next_step": next_step
    }})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn older_job_records_load_without_source_provenance() {
        let job: Job = serde_json::from_value(serde_json::json!({
            "id": "ed8c7cf6-45ac-4a0f-90ef-67e4901e9386",
            "created_at": 1, "updated_at": 1, "state": "succeeded",
            "request": null, "output": null, "error": null, "source": "xcodebuild"
        }))
        .unwrap();
        assert_eq!(job.source_revision, None);
        assert_eq!(job.source_dirty, None);
    }
}
