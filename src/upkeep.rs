//! Keeping idle app agents' context small. While an agent has no turn
//! running and none of its workers works, the service looks at its latest
//! context size (T3's `context-window.updated` activity) and how long the
//! thread has been quiet, and asks it to `/compact` (T3 passes slash
//! commands through to Claude). The agent keeps its one thread for good:
//! compaction is the only context management, repeated while it stays large.
//! Thresholds come from the environment; `0` or `off` turns compaction off.
//!
//! This is only the policy that judges a reading; what is done about it,
//! and when it counts as done, is M26 (`crate::fsm::coordinator::upkeep`).

use anyhow::{Context, Result};

#[derive(Clone, Copy, Debug)]
pub struct Upkeep {
    /// Compact past this many tokens once idle for `compact_idle` seconds.
    pub compact_tokens: u64,
    pub compact_idle: u64,
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
    /// `SQUIRCLE_COMPACT_TOKENS` (200000), `SQUIRCLE_COMPACT_IDLE_MINUTES` (30).
    pub fn from_env() -> Result<Self> {
        Ok(Upkeep {
            compact_tokens: var("SQUIRCLE_COMPACT_TOKENS", 200_000)?,
            compact_idle: var("SQUIRCLE_COMPACT_IDLE_MINUTES", 30)? * 60,
        })
    }

    fn large(&self, tokens: u64) -> bool {
        self.compact_tokens > 0 && tokens >= self.compact_tokens
    }

    /// Whether an agent idle for `idle` seconds with `tokens` in context
    /// needs compacting.
    pub fn compact(&self, tokens: u64, idle: u64) -> bool {
        self.large(tokens) && idle >= self.compact_idle
    }

    /// The first time after `now` at which `compact` may start to answer
    /// for an agent with `tokens` in context, quiet since `last` (seconds
    /// since 1970), if nothing else changes. None if it never will.
    pub fn next_due(&self, tokens: u64, last: f64, now: f64) -> Option<f64> {
        let at = last + self.compact_idle as f64;
        (self.large(tokens) && at > now).then_some(at)
    }
}

/// `245K` for a token count.
pub fn tokens(n: u64) -> String {
    if n >= 1000 {
        format!("{}K", (n + 500) / 1000)
    } else {
        n.to_string()
    }
}
