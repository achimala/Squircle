//! What T3's shell row says a thread is doing, decoded once (M01's
//! observation side as the coordinator's machines read it).

use serde_json::Value;

/// Whether T3 runs a provider session for a thread. T3 counts any session
/// not `stopped` as live (it stops one before archiving), and a stop it
/// carries out always ends in `stopped`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Execution {
    /// No session, or T3 reports it stopped.
    Stopped,
    /// A session between turns (`idle`, `ready`, `interrupted`, `error`).
    Idle,
    /// A turn is running, possibly waiting on a question or approval.
    Running,
    /// A session status this service does not know; possibly running.
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
    pub fn decode(row: &Value) -> Self {
        let session = &row["session"];
        let waiting = row["hasPendingApprovals"] == true || row["hasPendingUserInput"] == true;
        let turn_running = row["latestTurn"]["state"] == "running" || session["activeTurnId"].is_string();
        let execution = match session["status"].as_str() {
            Some("stopped") => Execution::Stopped,
            _ if turn_running => Execution::Running,
            _ if session.is_null() => Execution::Stopped,
            Some("starting" | "running") => Execution::Running,
            // T3 asks only from within a turn.
            Some("idle" | "ready" | "interrupted" | "error") if waiting => Execution::Running,
            Some("idle" | "ready" | "interrupted" | "error") => Execution::Idle,
            _ => Execution::Unknown,
        };
        ThreadObservation {
            turn: row["latestTurn"]["turnId"].as_str().map(str::to_string),
            execution,
            waiting,
            failed: session["status"] == "error" || row["latestTurn"]["state"] == "error",
            archived: !row["archivedAt"].is_null(),
        }
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
