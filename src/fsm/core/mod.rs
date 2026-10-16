//! Contracts every machine shares (docs/fsm-architecture.md §3, §7): typed
//! IDs and revisions, what an observation can say, how an effect can fail,
//! and what a reducer returns. A contract and a driver, not a framework.

pub mod commit;

use serde::{Deserialize, Serialize};
use std::fmt;

/// IDs that are UUIDs at every boundary. The constructor validates; the
/// original string is kept as given, so wire and stored values never change.
macro_rules! uuid_id {
    ($($(#[$doc:meta])* $name:ident),* $(,)?) => {$(
        $(#[$doc])*
        #[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
        #[serde(transparent)]
        pub struct $name(String);

        impl $name {
            pub fn parse(value: &str) -> Result<Self, uuid::Error> {
                uuid::Uuid::parse_str(value)?;
                Ok(Self(value.to_owned()))
            }
            /// A new ID. Owners allocate; reducers only receive them.
            pub fn fresh() -> Self {
                Self(uuid::Uuid::new_v4().to_string())
            }
            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                let value = String::deserialize(deserializer)?;
                Self::parse(&value).map_err(serde::de::Error::custom)
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&self.0)
            }
        }

        impl From<$name> for String {
            fn from(id: $name) -> String {
                id.0
            }
        }
    )*};
}

uuid_id! {
    /// A Squircle task.
    TaskID,
    /// A T3 thread.
    ThreadID,
    /// A Squircle build job.
    BuildID,
    /// One durable operation (an intent), across all its attempts.
    OperationID,
    /// One requested effect.
    EffectID,
    /// One C00 save of an aggregate.
    TransactionID,
    /// One T3 orchestration command; T3 keeps a receipt per ID.
    CommandID,
}

/// A T3 project, as T3 names it (not necessarily a UUID).
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ProjectID(String);

impl ProjectID {
    pub fn parse(value: &str) -> Result<Self, &'static str> {
        if value.trim().is_empty() { Err("A project ID can't be empty") } else { Ok(Self(value.to_owned())) }
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// A committed version of one aggregate; rises by one per commit.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Revision(pub u64);

impl Revision {
    pub fn next(self) -> Self {
        Self(self.0 + 1)
    }
}

/// One connection or process lifetime of a source; facts from an older
/// epoch never count as current.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Epoch(pub u64);

/// What a source says about something. A current `None` is authoritative
/// absence; a stale one is not, and nothing is ever inferred from
/// `Unavailable` (in particular not idle or done).
#[derive(Clone, Debug, PartialEq)]
pub enum Observed<T> {
    Unavailable(String),
    Stale { epoch: Epoch, revision: Revision, last: Option<T> },
    Current { epoch: Epoch, revision: Revision, value: T },
}

impl<T> Observed<T> {
    pub fn current(&self) -> Option<&T> {
        match self {
            Self::Current { value, .. } => Some(value),
            Self::Stale { .. } | Self::Unavailable(_) => None,
        }
    }
}

/// How an effect failed. The kind decides; `detail` is only a diagnostic.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FailureKind {
    /// Nothing happened: the effect provably did not start.
    RefusedBeforeEffect,
    /// It may or may not have happened; reconcile before acting again.
    OutcomeUnknown,
    TransientRead,
    InvalidProtocol,
    Permission,
    Storage,
    ResourceLost,
    Unsupported,
    CancelledBeforeEffect,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Failure {
    pub kind: FailureKind,
    pub detail: String,
}

impl Failure {
    pub fn new(kind: FailureKind, detail: impl fmt::Display) -> Self {
        Self { kind, detail: detail.to_string() }
    }
}

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.detail)
    }
}

impl std::error::Error for Failure {}

/// What a reducer decided about one event (§3's ordered rules).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Disposition {
    /// A table row applied; the state may have changed.
    Applied,
    /// A deliberate self-transition: nothing new, no effect.
    Unchanged,
    /// From a superseded owner, attempt or revision.
    Stale,
    /// Already seen; no repeated effect.
    Duplicate,
    /// Invalid input, refused at the boundary.
    Rejected(String),
    /// A valid command this state does not offer.
    NotApplicable,
    /// Proposed against an older revision.
    Conflict(Revision),
    /// An earlier operation must resolve first; the caller keeps its intent.
    Busy,
    /// A current result no row expects: a bug in the owner.
    ProtocolFault(String),
}

/// A reducer's whole answer: the next state, effects as values, and its decision.
#[derive(Debug)]
pub struct Reduction<S, E> {
    pub state: S,
    pub effects: Vec<E>,
    pub disposition: Disposition,
}

impl<S, E> Reduction<S, E> {
    pub fn applied(state: S, effects: Vec<E>) -> Self {
        Self { state, effects, disposition: Disposition::Applied }
    }
    /// No transition and no effects.
    pub fn same(state: S, disposition: Disposition) -> Self {
        Self { state, effects: vec![], disposition }
    }
}

/// A broken invariant, found by `Machine::violations`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Violation(pub String);

/// One owner's pure transition function. No I/O, clock or randomness inside:
/// time and new IDs arrive in events.
pub trait Machine {
    type State;
    type Event;
    type Effect;
    fn reduce(state: Self::State, event: Self::Event) -> Reduction<Self::State, Self::Effect>;
    fn violations(state: &Self::State) -> Vec<Violation>;
}
