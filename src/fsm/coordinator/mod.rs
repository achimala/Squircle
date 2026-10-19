//! The app-agent coordinator's machines (docs/fsm-architecture.md, package
//! P1): what a T3 command is and how one attempt can end (M01's command
//! side), the app agent's lifecycle (M14), workers' bootstrap and archive
//! (M15), the durable outbox (M16) and idle upkeep (M26). Pure: the owner
//! (`crate::agents::Agents`) supplies the clock, new IDs and T3's answers,
//! and commits each reduction before any effect it asks for runs.

pub mod agent;
pub mod outbox;
pub mod thread;
pub mod upkeep;
pub mod worker;

use crate::fsm::core::CommandID;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// An orchestration command's identity, fixed when its intent is recorded
/// and sent unchanged on every attempt. T3 keeps a durable receipt
/// per command ID in its own database: an accepted ID sent again answers
/// with its original sequence and does nothing; a rejected one is rejected
/// again. So sending the same identity again is how an unknown outcome is
/// settled, and a new identity is made only once T3 has said no.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Identity {
    pub id: CommandID,
    pub created_at: String,
}

/// Marks a command as a T3 thread launch (`orchestration.launchThread`:
/// create a thread, prepare its workspace and start its first run), which is
/// not one of T3's dispatched commands. T3 ignores the field.
pub const LAUNCH: &str = "squircle.thread-launch";

/// A command ready to send: its body carries its identity.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Command(Value);

impl Command {
    pub fn new(identity: &Identity, mut body: Value) -> Self {
        body["commandId"] = json!(identity.id);
        body["createdAt"] = json!(identity.created_at);
        Self(body)
    }

    /// The T3 method that carries it: `orchestration.launchThread` for a
    /// launch, else `orchestration.dispatchCommand`.
    pub fn method(&self) -> &'static str {
        if self.0["type"] == LAUNCH {
            "orchestration.launchThread"
        } else {
            "orchestration.dispatchCommand"
        }
    }

    /// The command ID, if the body has one (a stored command always does).
    pub fn id(&self) -> Option<&str> {
        self.0["commandId"].as_str()
    }

    pub fn body(&self) -> &Value {
        &self.0
    }
}

/// How one dispatch attempt ended, as far as the connection can tell.
#[derive(Clone, Debug, PartialEq)]
pub enum Dispatched {
    /// T3 accepted it, now or before (the same ID answers with the same receipt).
    Accepted(Value),
    /// T3 answered with a typed failure: the command's events were not
    /// committed. T3 may keep a rejected receipt for the ID, so another
    /// attempt needs a new identity.
    Refused(String),
    /// It never left this service: no connection, or the send queue was full.
    NotSent(String),
    /// It may have reached T3 and taken effect: the connection closed, no
    /// answer came within the caller's budget, or T3 reported an internal
    /// error. Only the same identity may be sent again.
    Unknown(String),
}

/// A command a caller waits for (`thread send`, `thread answer`), saved
/// with its identity before it is sent. `purpose` is the request itself
/// (its thread, kind and text): the same request asked again while T3 has
/// left this one unanswered sends this command again, never a second. Only
/// an unanswered one is kept; the service never sends it by itself.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Pending {
    pub purpose: String,
    pub command: Command,
    pub at: u64,
}
