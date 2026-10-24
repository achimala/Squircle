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

    /// The first time after `now` at which `decide` may start to answer for
    /// an agent with `tokens` in context, quiet since `last` (seconds since
    /// 1970), if nothing else changes: a threshold of idle time reached, or
    /// the nightly hour beginning once the agent is idle long enough. None
    /// if no rule can apply to it.
    pub fn next_due(&self, tokens: u64, last: f64, now: f64) -> Option<f64> {
        let past = |limit: u64| limit > 0 && tokens >= limit;
        let mut due = vec![];
        if past(self.compact_tokens) {
            due.push(last + self.compact_idle as f64);
        }
        if past(self.fresh_tokens) {
            due.push(last + self.fresh_idle as f64);
        }
        if let Some(hour) = self.nightly_hour
            && past(self.nightly_tokens)
        {
            due.push(hour_from(hour, (last + self.fresh_idle as f64).max(now)));
        }
        due.into_iter()
            .filter(|at| *at > now)
            .min_by(f64::total_cmp)
    }
}

/// The local hour at `at` (seconds since 1970).
pub fn local_hour(at: f64) -> u32 {
    local(at).tm_hour as u32
}

fn local(at: f64) -> libc::tm {
    let at = at as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: localtime_r writes only into `tm`.
    unsafe { libc::localtime_r(&at, &mut tm) };
    tm
}

/// The first moment at or after `from` that falls in local `hour`: `from`
/// itself if it does, else that hour's start, today or tomorrow.
fn hour_from(hour: u32, from: f64) -> f64 {
    let mut tm = local(from);
    if tm.tm_hour as u32 == hour {
        return from;
    }
    let today = tm.tm_hour < hour as i32;
    tm.tm_hour = hour as i32;
    tm.tm_min = 0;
    tm.tm_sec = 0;
    tm.tm_mday += (!today) as i32;
    // Daylight saving is whatever applies on that day.
    tm.tm_isdst = -1;
    // SAFETY: mktime normalizes `tm` in place and reads nothing else.
    unsafe { libc::mktime(&mut tm) as f64 }
}

/// `245K` for a token count.
pub fn tokens(n: u64) -> String {
    if n >= 1000 {
        format!("{}K", (n + 500) / 1000)
    } else {
        n.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Upkeep sleeps until `next_due`: a time too late leaves an agent
    /// bloated, one too early (or in the wrong hour) never acts.
    #[test]
    fn next_due_is_the_first_moment_a_rule_can_apply() {
        let config = Upkeep {
            compact_tokens: 200_000,
            compact_idle: 30 * 60,
            fresh_tokens: 500_000,
            fresh_idle: 120 * 60,
            nightly_hour: Some(4),
            nightly_tokens: 100_000,
        };
        let now = 1_790_000_000.0;
        let last = now - 600.0;
        // Compacting comes first; the larger rules later.
        assert_eq!(config.next_due(250_000, last, now), Some(last + 1800.0));
        assert_eq!(config.next_due(50_000, last, now), None);
        // Only the nightly rule: the first moment in its hour once idle
        // long enough, every hour of the day.
        for hour in 0..24 {
            let now = now + hour as f64 * 3600.0;
            let last = now - 600.0;
            let at = config.next_due(150_000, last, now).unwrap();
            assert!(at > now && at >= last + 7200.0 && at - now <= 26.0 * 3600.0);
            assert_eq!(local_hour(at), 4);
            assert!(at == last + 7200.0 || local_hour(at - 1.0) != 4);
            assert!(
                config
                    .decide(150_000, (at - last) as u64, local_hour(at))
                    .is_some()
            );
        }
    }
}
