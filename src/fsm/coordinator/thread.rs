//! What T3's shell row says a thread is doing, decoded once (M01's
//! observation side as the coordinator's machines read it).

use serde_json::Value;

/// Whether a thread has work running in T3 and a provider session.
/// T3's (protocol 2) shell row shows only its runs; whether a provider
/// session is still attached between runs is in the thread's projection
/// (`providerSessions`), so a shell row alone says `Stopped` for any thread
/// without a running run, and `Idle` comes only from a projection
/// (`with_sessions`). T3 detaches every session of a thread it archives.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Execution {
    /// No run in progress and, as far as is known, no session.
    Stopped,
    /// No run in progress, but a provider session is still attached.
    Idle,
    /// A run is preparing, queued, starting, running or waiting on the user.
    Running,
    /// A run status this service does not know, or none at all, or a
    /// projection that doesn't say whether a session is attached;
    /// possibly running.
    Unknown,
}

/// A thread as T3's shell row describes it.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct ThreadObservation {
    pub turn: Option<String>,
    pub execution: Execution,
    /// A question or approval waits on the user.
    pub waiting: bool,
    pub failed: bool,
    /// T3 has archived the thread.
    pub archived: bool,
}

/// What a thread shows as: `working`, `needs-you`, `error` or `done`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Phase {
    Working,
    NeedsYou,
    Error,
    Done,
}

impl Phase {
    pub fn label(self) -> &'static str {
        match self {
            Phase::Working => "working",
            Phase::NeedsYou => "needs-you",
            Phase::Error => "error",
            Phase::Done => "done",
        }
    }
}

impl ThreadObservation {
    /// From a protocol 2 shell row (`OrchestrationV2ThreadShell`): `status`
    /// is `idle` or the latest run's status, `latestRunId` names the turn,
    /// and a pending question or approval is `pendingRuntimeRequest`.
    pub fn decode(row: &Value) -> Self {
        let status = row["status"].as_str();
        let waiting = !row["pendingRuntimeRequest"].is_null() || status == Some("waiting");
        let execution = match status {
            Some("preparing" | "queued" | "starting" | "running" | "waiting") => Execution::Running,
            Some("idle" | "completed" | "interrupted" | "failed" | "cancelled" | "rolled_back") => {
                Execution::Stopped
            }
            _ => Execution::Unknown,
        };
        ThreadObservation {
            turn: row["latestRunId"].as_str().map(str::to_string),
            execution,
            waiting,
            failed: status == Some("failed"),
            archived: !row["archivedAt"].is_null(),
        }
    }

    /// Refines a shell observation with the thread's projection: a thread
    /// with no run in progress is `Idle` while a provider session is still
    /// attached to it, and `Unknown` if the projection doesn't say.
    pub fn with_sessions(mut self, projection: &Value) -> Self {
        if self.execution == Execution::Stopped {
            self.execution = match live_session(projection) {
                Ok(None) => Execution::Stopped,
                Ok(Some(_)) => Execution::Idle,
                Err(_) => Execution::Unknown,
            };
        }
        self
    }

    /// What it shows as. A waiting thread shows as needs-you whatever its
    /// session, but a stopped session is never "working".
    pub fn phase(&self) -> Phase {
        if self.waiting {
            Phase::NeedsYou
        } else if self.failed {
            Phase::Error
        } else if matches!(self.execution, Execution::Running | Execution::Unknown) {
            Phase::Working
        } else {
            Phase::Done
        }
    }

    /// Whether a turn may be running: such a session is never stopped by a
    /// reset, nor its files removed without discarding its work.
    pub fn busy(&self) -> bool {
        matches!(self.execution, Execution::Running | Execution::Unknown)
    }

    pub fn stopped(&self) -> bool {
        self.execution == Execution::Stopped
    }
}

/// A provider session T3 still has attached to a thread, from its
/// projection; an error if the projection has no well-formed session list,
/// which proves nothing either way.
pub fn live_session(projection: &Value) -> Result<Option<&str>, String> {
    let sessions = projection["providerSessions"]
        .as_array()
        .filter(|sessions| {
            sessions
                .iter()
                .all(|s| s["id"].is_string() && s["status"].is_string())
        })
        .ok_or("T3's thread projection has no well-formed provider sessions")?;
    Ok(sessions
        .iter()
        .find(|s| s["status"] != "stopped")
        .and_then(|s| s["id"].as_str()))
}
