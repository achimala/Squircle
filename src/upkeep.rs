//! Keeping idle app agents' context small. While an agent has no turn
//! running and none of its workers works, the service looks at its latest
//! context size (T3's `context-window.updated` activity) and how long the
//! thread has been quiet, and either asks it to `/compact` (T3 passes slash
//! commands through to Claude) or starts it fresh with the usual handoff.
//! Thresholds come from the environment; `0` or `off` turns a rule off.
//!
//! This is only the policy that judges a reading; what is done about it,
//! and when it counts as done, is M26 (`crate::fsm::coordinator::upkeep`).

use anyhow::{Context, Result};

pub use crate::fsm::coordinator::upkeep::Decision as Tidy;

#[derive(Clone, Copy, Debug)]
pub struct Upkeep {
    /// Compact past this many tokens once idle for `compact_idle` seconds.
    pub compact_tokens: u64,
    pub compact_idle: u64,
    /// Start fresh past this many tokens once idle for `fresh_idle` seconds.
    pub fresh_tokens: u64,
    pub fresh_idle: u64,
    /// Also start fresh during this local hour, idle for `fresh_idle`, past
    /// `nightly_tokens` (a new thread is far below it, so once a night).
    pub nightly_hour: Option<u32>,
    pub nightly_tokens: u64,
}

fn var(name: &str, default: u64) -> Result<u64> {
    match std::env::var(name) {
        Ok(v) if v.trim() == "off" => Ok(0),
        Ok(v) => v
            .trim()
            .parse()
            .with_context(|| format!("{name} must be a whole number or off")),
        Err(_) => Ok(default),
    }
}

impl Upkeep {
    /// `SQUIRCLE_COMPACT_TOKENS` (200000), `SQUIRCLE_COMPACT_IDLE_MINUTES`
    /// (30), `SQUIRCLE_FRESH_TOKENS` (500000), `SQUIRCLE_FRESH_IDLE_MINUTES`
    /// (120), `SQUIRCLE_NIGHTLY_FRESH_HOUR` (4, local time),
    /// `SQUIRCLE_NIGHTLY_FRESH_TOKENS` (100000).
    pub fn from_env() -> Result<Self> {
        let hour = match std::env::var("SQUIRCLE_NIGHTLY_FRESH_HOUR") {
            Ok(v) if v.trim() == "off" => None,
            Ok(v) => Some(
                v.trim()
                    .parse::<u32>()
                    .ok()
                    .filter(|h| *h < 24)
                    .context("SQUIRCLE_NIGHTLY_FRESH_HOUR must be 0-23 or off")?,
            ),
            Err(_) => Some(4),
        };
        Ok(Upkeep {
            compact_tokens: var("SQUIRCLE_COMPACT_TOKENS", 200_000)?,
            compact_idle: var("SQUIRCLE_COMPACT_IDLE_MINUTES", 30)? * 60,
            fresh_tokens: var("SQUIRCLE_FRESH_TOKENS", 500_000)?,
            fresh_idle: var("SQUIRCLE_FRESH_IDLE_MINUTES", 120)? * 60,
            nightly_hour: hour,
            nightly_tokens: var("SQUIRCLE_NIGHTLY_FRESH_TOKENS", 100_000)?,
        })
    }

    /// What an agent idle for `idle` seconds with `tokens` in context needs
    /// at local `hour`.
    pub fn decide(&self, tokens: u64, idle: u64, hour: u32) -> Option<Tidy> {
        let past = |limit: u64| limit > 0 && tokens >= limit;
        if past(self.fresh_tokens) && idle >= self.fresh_idle {
            return Some(Tidy::Fresh { nightly: false });
        }
        if self.nightly_hour == Some(hour) && past(self.nightly_tokens) && idle >= self.fresh_idle {
            return Some(Tidy::Fresh { nightly: true });
        }
        (past(self.compact_tokens) && idle >= self.compact_idle).then_some(Tidy::Compact)
    }
}

/// The local hour now.
pub fn local_hour() -> u32 {
    let now = crate::model::now() as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: localtime_r writes only into `tm`.
    unsafe { libc::localtime_r(&now, &mut tm) };
    tm.tm_hour as u32
}

/// `245K` for a token count.
pub fn tokens(n: u64) -> String {
    if n >= 1000 {
        format!("{}K", (n + 500) / 1000)
    } else {
        n.to_string()
    }
}
