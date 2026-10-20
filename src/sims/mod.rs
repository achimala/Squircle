//! Simulator sessions an agent runs through Squircle (`squircle sim`). Starting
//! one opens the simulator for the agent's T3 thread (T3's own `device.open`,
//! so the phone streams it), boots it and records its screen. Stopping it,
//! or the agent's turn ending, finishes the recording and adds it to the
//! thread's media, dated where the session began, closes the T3 device
//! session and lets the pool shut the simulator down. The phone shows active
//! sessions as a live picture-in-picture and in the turn, and the recording
//! there afterwards.
//!
//! This is the owner of the simulator machines (`fsm::sims`): admission and
//! the grant queue (M18), each session's recorder and cleanup obligations
//! (M19), and the device reservations the pool's cleanup (M20) takes from.
//! It is the only executor: every decision is a reducer's, every reduction
//! is saved in `sims.json` through the commit gate before an effect that
//! depends on it runs, and nothing owed is ever dropped. A session reserves
//! its simulator from the moment it is saved until T3 has closed its device
//! session and the pool has decided its release; at most `max_leases`
//! simulators are reserved, unclaimed grants included.
//!
//! Past that, a start joins a first-come queue (saved with the ledger) and
//! the agent ends its turn. When a slot frees, the head is granted it, the
//! grant saved, and only then woken with a service message; its next
//! `sim start` claims the slot. A grant the woken turn leaves unclaimed, or
//! a thread T3 no longer has, gives its place up.
//!
//! A restart hands sessions over rather than ending them (`Exit::Handover`):
//! recorders are separate processes and keep recording, T3's device sessions
//! stay open, and the next run adopts every recording whose recorder is
//! provably still its own (its start time and its command line naming the
//! session's file). Only a real stop (`Exit::Stop`) ends them.

use crate::actor::{Lane, Owner, Rank, Saved, Snapshot};
use crate::agents::{Agents, Observed};
use crate::fsm::core::Disposition;
use crate::fsm::core::commit::{Gate, JsonFile};
use crate::fsm::sims::Seen;
use crate::fsm::sims::admission::{self, Answer, Capacity, Reservation, Waiter};
use crate::fsm::sims::session::{
    self, Boot, Closed, Event, IdleClock, Phase, RecorderID, Released, Served, Session,
};
use crate::media::{self, SimulatorClip};
use crate::simpool::{BootReceipt, Exclusion, Holds, Lease, Pool};
use anyhow::{Context, Result, anyhow, bail, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet, hash_map::Entry},
    convert::Infallible,
    future::Future,
    path::{Path, PathBuf},
    pin::Pin,
    process::Stdio,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::process::{Child, Command};
use tokio::sync::Notify;

pub use crate::fsm::sims::session::DeviceLease;

mod host;
pub use host::*;
mod records;
pub use records::*;
mod recorder;
use recorder::*;
mod state;
use state::*;
mod runtime;
mod sessions;
mod start;
use sessions::*;
mod maintenance;
pub use maintenance::*;

const KEEP: usize = 200;

/// The ledger's format: 2 adds cleanup receipts, boot evidence and grant wakes.
const SCHEMA: u32 = 2;

pub struct Sims {
    root: PathBuf,
    host: Arc<dyn Host>,
    /// The ledger and what runs on it this run; reached only by letters.
    owner: Owner<State>,
    /// The ledger as last saved.
    ledger: Snapshot<Ledger>,
    /// Starts are admitted one at a time.
    starts: Lane,
    /// Set once by `shutdown`: no new starts, and `run` returns.
    draining: tokio::sync::watch::Sender<bool>,
    /// Woken after every save: a start waiting for a release receipt looks again.
    saved: Arc<Notify>,
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

#[cfg(test)]
mod tests;
