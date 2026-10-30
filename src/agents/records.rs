use super::*;

#[derive(Clone, Serialize, Deserialize)]
pub struct Agent {
    pub project_id: String,
    pub thread_id: String,
    pub created_at: u64,
    pub lifecycle: Lifecycle,
    /// The newest of the user's messages the agent said asks nothing to
    /// track (`task heard`); with the tracker's sources, where its unheard
    /// messages start.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub heard: Option<String>,
}

pub use crate::fsm::coordinator::agent::Lifecycle;
pub use crate::fsm::coordinator::thread::{Execution, Phase, ThreadObservation};
pub use crate::fsm::coordinator::worker::{ArchiveStep, Stage};

impl Lifecycle {
    /// Records a restart attempt's outcome; returns the backoff before the
    /// next attempt after a failure.
    pub(super) fn attempted(&mut self, failure: Option<String>) -> Option<Duration> {
        let (Lifecycle::RestartQueued { error, failures }
        | Lifecycle::Restarting {
            error, failures, ..
        }) = self
        else {
            return None;
        };
        *failures = if failure.is_some() {
            (*failures + 1).min(6)
        } else {
            0
        };
        *error = failure;
        error.is_some().then(|| Duration::from_secs(4 << *failures))
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Worker {
    pub coordinator: String,
    pub project_id: String,
    pub title: String,
    pub branch: String,
    pub base: String,
    pub created_at: u64,
    /// The last event its coordinator was told about, so a restart neither
    /// repeats nor misses a wake-up.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notified: Option<WorkerEvent>,
    #[serde(default, alias = "archived", deserialize_with = "stage_or_legacy")]
    pub stage: Stage,
}

pub(super) fn stage_or_legacy<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> std::result::Result<Stage, D::Error> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum File {
        Archived(bool),
        Stage(Stage),
    }
    Ok(match File::deserialize(d)? {
        File::Archived(true) => Stage::Archived,
        File::Archived(false) => Stage::Active,
        File::Stage(stage) => stage,
    })
}

/// What a worker's coordinator is told about: a turn that stopped (done,
/// error), one waiting on a request, or one working again after a question
/// was answered (so the next question in the same turn is new).
#[derive(Clone, Serialize, PartialEq, Eq, Debug)]
pub struct WorkerEvent {
    pub turn: String,
    pub kind: EventKind,
    /// For `needs-you`: the question or approval, which T3's shell row does
    /// not carry; added from the thread's detail before it is queued.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request: Option<String>,
}

#[derive(Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Debug)]
#[serde(rename_all = "kebab-case")]
pub enum EventKind {
    Done,
    Error,
    NeedsYou,
    Working,
}

impl WorkerEvent {
    /// Whether telling the coordinator about `self` already covers `due`
    /// (an event without its request matches any request of the same kind).
    pub(super) fn covers(&self, due: &WorkerEvent) -> bool {
        self.turn == due.turn
            && self.kind == due.kind
            && (due.request.is_none() || self.request == due.request)
    }
}

impl<'de> Deserialize<'de> for WorkerEvent {
    /// Also reads the colon-delimited keys written before (`turn:needs-you:request`).
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct Fields {
            turn: String,
            kind: EventKind,
            #[serde(default)]
            request: Option<String>,
        }
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum File {
            Key(String),
            Fields(Fields),
        }
        match File::deserialize(d)? {
            File::Fields(Fields {
                turn,
                kind,
                request,
            }) => Ok(WorkerEvent {
                turn,
                kind,
                request,
            }),
            File::Key(key) => {
                let mut parts = key.splitn(3, ':');
                let (turn, kind) = (
                    parts.next().unwrap_or_default(),
                    parts.next().unwrap_or_default(),
                );
                let kind = serde_json::from_value(json!(kind)).map_err(|_| {
                    serde::de::Error::custom(format!("unknown worker event {key:?}"))
                })?;
                Ok(WorkerEvent {
                    turn: turn.into(),
                    kind,
                    request: parts.next().map(str::to_string),
                })
            }
        }
    }
}

/// A worker update for one agent, recorded before it is sent so a lost
/// acknowledgement or a restart re-sends the same message, never a second.
/// Removing it from the outbox and advancing its workers' `notified` is one
/// registry transition. Every decision about its delivery is M16's
/// (`crate::fsm::coordinator::outbox`).
#[derive(Clone, Serialize, Deserialize)]
pub struct Wake {
    pub coordinator: String,
    pub message_id: String,
    /// Each worker and the event this update tells about.
    pub workers: Vec<(String, WorkerEvent)>,
    pub text: String,
    pub record: Value,
    #[serde(flatten)]
    pub outbound: Outbound,
    /// For a build update: the build it tells about.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub build: Option<String>,
}

/// What an app agent has been told about one of its builds.
#[derive(Clone, Serialize, Deserialize, PartialEq, Debug)]
#[serde(tag = "state", rename_all = "kebab-case")]
pub enum BuildWatch {
    /// The agent started it in this turn of its own: a build that finishes
    /// while that turn still runs is already in its conversation.
    Started { turn: Option<String>, at: u64 },
    /// Its update is queued or delivered, or it needed none.
    Told { at: u64 },
}

impl BuildWatch {
    pub(super) fn at(&self) -> u64 {
        match self {
            BuildWatch::Started { at, .. } | BuildWatch::Told { at } => *at,
        }
    }
}

/// A build that finished, as its app agent is told.
pub struct FinishedBuild {
    pub id: String,
    /// The thread that started it, if known.
    pub thread: Option<String>,
    pub app: String,
    pub succeeded: bool,
    /// Why it failed, in a line.
    pub reason: Option<String>,
}

/// An outbox entry that left without reaching anyone, kept as its receipt.
#[derive(Clone, Serialize, Deserialize)]
pub struct Undelivered {
    pub message_id: String,
    pub coordinator: String,
    pub reason: String,
    pub at: u64,
}

#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Registry {
    #[serde(default)]
    pub agents: BTreeMap<String, Agent>,
    #[serde(default)]
    pub workers: BTreeMap<String, Worker>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub outbox: Vec<Wake>,
    /// Builds by ID, from their start (an agent's own) or their update.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub builds: BTreeMap<String, BuildWatch>,
    /// Per project, what idle upkeep last decided for its agent (M26).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub upkeep: BTreeMap<String, m26::Record>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub undelivered: Vec<Undelivered>,
    /// Commands callers wait for whose answer was lost, newest last.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub intents: Vec<Pending>,
}
