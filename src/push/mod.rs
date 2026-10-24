//! Notifications and the Live Activity on the phone. The service decides what
//! to say (`Push`) and hands each message to a `Transport`. Today that is
//! `Apns`: Apple's HTTP/2 API, signed with the user's own APNs auth key
//! (`squircle push setup`). A relay for App Store builds would be another
//! `Transport`; the phone's contract (registration endpoints, the `squircle`
//! payload key, the activity's content state) stays the same.

use crate::actor::Owner;
use crate::store::{atomic_json, private_dir, read_json};
use anyhow::{Context, Result, bail, ensure};
use base64::Engine;
use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap},
    future::Future,
    path::{Path, PathBuf},
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, SystemTime},
};
use tokio::sync::Notify;
// Tokio's clock: the policy's waits below run on it, and tests pause it.
use tokio::time::Instant;

mod apns;
pub use apns::*;
mod payload;
pub use payload::*;
mod devices;
pub use devices::*;
mod projection;
pub use projection::*;
mod state;
use state::*;
mod delivery;

/// The Swift type name of the activity's attributes (`attributes-type`).
pub const ACTIVITY_TYPE: &str = "SquircleActivityAttributes";

const COALESCE: Duration = Duration::from_secs(3);

/// A phone's report that it shows a thread counts for this long.
const PRESENCE: Duration = Duration::from_secs(300);

/// The durations of the notification and Live Activity policy.
#[derive(Clone, Copy)]
pub struct Timing {
    /// Events this close together arrive as one notification.
    pub coalesce: Duration,
    /// The first retry after a transient failure; each further one waits 4×
    /// longer, up to `RETRY_CAP`.
    pub retry: Duration,
    /// Idle this long before a running activity ends.
    pub pause: Duration,
    /// Minor updates (the step text) go out at most this often per activity.
    pub throttle: Duration,
}

impl Default for Timing {
    fn default() -> Self {
        Self {
            coalesce: COALESCE,
            retry: Duration::from_secs(2),
            pause: Duration::from_secs(20),
            throttle: Duration::from_secs(10),
        }
    }
}

/// A push-to-start without a token reported back is retried after this.
const START_WAIT: Duration = Duration::from_secs(300);

/// The step text is read again when T3 writes its database, at most this
/// often per turn.
const STEP_EVERY: Duration = Duration::from_secs(5);

const RETRY_CAP: Duration = Duration::from_secs(300);

/// An alert that keeps failing transiently is dropped after this many tries.
const ALERT_ATTEMPTS: u32 = 4;

fn backoff(base: Duration, failures: u32) -> Duration {
    base.saturating_mul(4u32.saturating_pow(failures.saturating_sub(1)))
        .min(RETRY_CAP)
}

/// Whether a send's outcome is worth trying again later.
fn transient(outcome: &Result<Outcome>) -> bool {
    matches!(outcome, Err(_) | Ok(Outcome::Retry(_)))
}

fn describe(outcome: &Result<Outcome>) -> String {
    match outcome {
        Ok(Outcome::Sent) => "sent".into(),
        Ok(Outcome::Unregistered) => "token no longer valid; forgotten".into(),
        Ok(Outcome::Rejected(reason) | Outcome::Retry(reason)) => reason.clone(),
        Err(error) => format!("{error:#}"),
    }
}

pub struct Push {
    root: PathBuf,
    /// Devices, presence, apps and pending notes; reached only by letters.
    owner: Owner<State>,
    fixed: Option<Arc<dyn Transport>>,
    timing: Timing,
    alerts_sent: AtomicU64,
    /// Wakes the reconciler after a shell change, a phone report, a result
    /// or a write to T3's database.
    wake: Notify,
}

#[cfg(test)]
mod tests;
