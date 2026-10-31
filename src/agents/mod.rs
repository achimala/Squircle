//! One agent per app. The app agent is an ordinary T3 thread on Squircle's
//! own Claude instance (see `setup`), in the project's folder. It can run
//! ordinary T3 worker threads, each in its own worktree. Squircle adds only
//! what T3 lacks: who owns which worker, the agent's thread ID and workers at
//! the start of each turn, and a wake-up when a worker finishes or needs
//! input. How to work is up to the user and the agent. No model runs here.

use crate::actor::{Lane, Lanes, Owner, Published, Rank, Snapshot};
use crate::fsm::coordinator::agent as m14;
use crate::fsm::coordinator::outbox::{self, Outbound, Settled};
use crate::fsm::coordinator::upkeep::{self as m26, Origin, Reading};
use crate::fsm::coordinator::worker::{self as m15, ArchiveOrder, BootEffect, BootEvent};
use crate::fsm::coordinator::{Command, Dispatched, Identity, Pending};
use crate::fsm::core::commit::{Gate, JsonFile};
use crate::fsm::core::{self as core, CommandID, Disposition, Epoch, Revision};
use crate::store::private_dir;
use crate::t3::{T3, T3Config};
use crate::tasks::{Source, Status, Tasks};
use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap},
    convert::Infallible,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

pub use crate::fsm::coordinator::outbox::Delivery;
use tokio::process::Command as Process;

mod records;
pub use records::*;
mod selection;
use selection::*;
mod peer;
pub use peer::*;
mod context;
pub use context::*;
mod shell;
pub use shell::*;
mod state;
use state::*;
mod worktrees;
use worktrees::*;
mod builds;
mod demands;
mod lifecycle;
mod messages;
mod outbox_driver;
mod plugin;
mod runtime;
mod upkeep;
mod waiting;
pub use waiting::*;
mod workers;
pub use plugin::*;

/// The T3 provider instance `squircle agent setup` creates.
pub const INSTANCE: &str = "squircle";

const DEFAULT_MODEL: &str = "claude-opus-5-5";

/// How many undelivered receipts are kept.
const UNDELIVERED_KEPT: usize = 20;

/// How many unanswered caller commands are kept.
const INTENTS_KEPT: usize = 20;

type RegistryGate = Gate<Registry, Infallible, JsonFile>;

/// A new command identity: what the owner allocates for each intent.
fn identity() -> Identity {
    Identity {
        id: CommandID::fresh(),
        created_at: crate::t3::iso_now(),
    }
}

/// How long a build's watch is kept: past this, a build is long finished.
const BUILD_WATCH_SECS: u64 = 14 * 24 * 3600;

pub struct Agents {
    root: PathBuf,
    /// The squircle executable and its arguments, for instructions to agents.
    server: String,
    /// The registry, T3's shell and the connection; reached only by letters.
    owner: Owner<State>,
    view: Snapshot<View>,
    /// Stands in for T3 in tests.
    fake: std::sync::OnceLock<Arc<dyn Peer>>,
    /// One operation at a time per project (create, reset) and per worker
    /// (archive), so concurrent requests see each other's result.
    ops: Lanes<String>,
    /// One spawn at a time per agent and branch.
    spawning: Lanes<String>,
    /// One flush at a time, so overlapping triggers cannot send twice.
    flushing: Lane,
    /// One compaction at a time per project, manual or automatic.
    compacting: Lanes<String>,
    push: std::sync::OnceLock<Arc<crate::push::Push>>,
    tasks: Arc<Tasks>,
}

#[cfg(test)]
mod tests;
