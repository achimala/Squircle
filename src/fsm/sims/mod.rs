//! The simulator owner's machines (docs/fsm-architecture.md, package P3):
//! admission and the grant queue (M18, `admission`), a session with its
//! recorder and cleanup obligations (M19, `session`), and the pool's
//! provenance and cleanup policy (M20, `pool`). Pure: the owners
//! (`crate::sims::Sims`, `crate::simpool::Pool`) supply the clock, new IDs,
//! T3's and simctl's answers, and commit each reduction before any effect
//! it asks for runs.
//!
//! One capacity authority: a session reserves its simulator from the moment
//! it is saved until its cleanup is settled (T3's device session closed and
//! the pool's release decided), and the queue's unclaimed grants count
//! against the same limit. Admission and pool cleanup take their device
//! reservations from the same owner, so they can't race.

pub mod admission;
pub mod pool;
pub mod session;

use serde::{Deserialize, Serialize};

/// What T3 says a thread is doing, as the simulator machines read it. Only
/// a current observation decides anything; `Unknown` (T3 disconnected, or
/// its shell stale) never counts as idle or gone.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Seen {
    /// T3 currently has no such thread (or has archived an idle one).
    Gone,
    /// A turn may be running (including a session status this service doesn't know).
    Busy { turn: Option<String> },
    /// A question or approval waits on the user, inside a turn.
    Waiting { turn: Option<String> },
    /// Between turns.
    Idle { turn: Option<String> },
    /// Not current; the turn is the last one known, for display and grants.
    Unknown { turn: Option<String> },
}

impl Seen {
    pub fn turn(&self) -> Option<&str> {
        match self {
            Seen::Gone => None,
            Seen::Busy { turn } | Seen::Waiting { turn } | Seen::Idle { turn } | Seen::Unknown { turn } => turn.as_deref(),
        }
    }

    /// The thread may be doing something: busy, waiting on the user, or not known.
    pub fn protects(&self) -> bool {
        matches!(self, Seen::Busy { .. } | Seen::Waiting { .. } | Seen::Unknown { .. })
    }
}

/// An owed effect's failed attempts and when the next is due.
#[derive(Clone, Debug, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct RetryState {
    pub tries: u32,
    /// Not before this (seconds since 1970).
    pub retry_at: f64,
    pub error: Option<String>,
}

impl RetryState {
    /// After one more failure: backs off 3 s doubling to 5 minutes, and
    /// never gives the obligation up.
    pub fn failed(&self, error: String, now: f64) -> Self {
        let tries = self.tries.saturating_add(1);
        let wait = (3.0 * 2f64.powi(tries.min(10) as i32 - 1)).min(300.0);
        Self { tries, retry_at: now + wait, error: Some(error) }
    }

    pub fn due(&self, now: f64) -> bool {
        self.retry_at <= now
    }
}
