//! The service's only clock. Everything else waits for an event (a message
//! from an owner, a channel closing, a process exiting, a file changing, a
//! T3 event); what waits for a time here is a policy rule with a duration
//! the user chose (an idle grace, a recording limit, an ageing period, a
//! retry's pacing), and it waits until exactly when that rule next applies.
//! Rules take the time as an argument, so tests pass it instead of waiting.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Wall-clock now, in seconds since 1970.
pub fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// Resolves at wall-clock time `at` (seconds since 1970), at once if it has
/// passed; never without one.
pub async fn until(at: Option<f64>) {
    match at {
        Some(at) => after(Duration::from_secs_f64((at - now()).max(0.0))).await,
        None => std::future::pending().await,
    }
}

/// Resolves once `wait` has passed.
pub async fn after(wait: Duration) {
    tokio::time::sleep(wait).await
}
