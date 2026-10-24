//! M19, a simulator session with its recorder and cleanup obligations
//! (docs/fsm-architecture.md).
//!
//! A session is saved, reserving its simulator, before T3 is asked to open
//! anything. From then on what it acquired is owed back, each obligation on
//! its own and only from what was actually acquired:
//!
//! - the recorder is stopped before the recording is filed (`Stopping` →
//!   `Filing` → `Finished`/`Failed`);
//! - T3's device session (`DeviceLease`) is closed, retried with backoff
//!   and never given up; an authoritative "T3 has no such session" also
//!   settles it;
//! - the pool's release (`Release`: shut the simulator down unless the
//!   policy keeps it) runs only once the recorder has stopped and T3's
//!   device session is closed, and is retried until the pool answers.
//!
//! The session reserves its simulator, and counts against the limit, until
//! both cleanup obligations are settled: a blocked close keeps its slot
//! (Q4). Failed media never erases cleanup; failed cleanup never erases
//! media. On the wire the session keeps the flat shape the phone reads.

use super::{RetryState, Seen};
use crate::fsm::core::{Disposition, Reduction, Violation};
use serde::{Deserialize, Serialize};

/// A turn that stops working this long ends its sessions.
pub const IDLE_GRACE: f64 = 8.0;
/// Recordings never run longer than this (product policy).
pub const MAX_SECONDS: f64 = 30.0 * 60.0;

/// The recorder process: its PID and, when known, when it started, so a
/// reused PID can't pass for it. Identifies; doesn't own.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecorderID {
    pub pid: u32,
    /// Seconds and microseconds since 1970 the process started.
    pub start: Option<(u64, u64)>,
}

/// Where a session is in its life; the recording and filing obligations
/// as one sum type (filing can't start before the recorder stopped).
#[derive(Clone, Debug, PartialEq)]
pub enum Phase {
    Starting {
        recorder: Option<RecorderID>,
    },
    Recording {
        recorder: Option<RecorderID>,
    },
    /// Claimed by a stop; the recorder is being stopped.
    Stopping {
        reason: String,
        recorder: Option<RecorderID>,
    },
    /// The recorder stopped; the recording is still to be filed.
    /// `warning`: something about the stop worth knowing (a recorder left alone).
    Filing {
        reason: String,
        ended_at: f64,
        warning: Option<String>,
    },
    Finished {
        reason: String,
        ended_at: f64,
        media_id: String,
        warning: Option<String>,
    },
    Failed {
        reason: Option<String>,
        ended_at: f64,
        error: String,
    },
}

/// T3's device session for the thread and simulator.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "phase", rename_all = "snake_case")]
pub enum DeviceLease {
    /// Saved before T3 is asked to open it: whatever happens next, a close is owed.
    Opening,
    Open,
    /// The session ended; T3 has not confirmed the close yet. Earlier
    /// ledgers gave a close up as `abandoned`; it is owed again.
    #[serde(alias = "abandoned")]
    CloseOwed(RetryState),
    Closed,
}

impl DeviceLease {
    /// T3's device session may still be open.
    pub fn owed(&self) -> bool {
        !matches!(self, DeviceLease::Closed)
    }
}

/// The pool's release of the simulator once the session no longer uses it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "phase", rename_all = "snake_case")]
pub enum Release {
    /// The session still uses its simulator.
    NotDue,
    /// Owed once T3's device session is closed.
    Owed(RetryState),
    Done {
        outcome: Released,
        at: f64,
    },
}

/// What the pool did with the simulator.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Released {
    ShutDown,
    /// It was not booted when the pool looked.
    NotBooted,
    /// The policy keeps it (another session, the user's own, not proven Squircle's, ...).
    Kept {
        why: String,
    },
    /// Settled by a ledger from before release receipts.
    Earlier,
}

/// Whether this session's open booted the simulator: the evidence that
/// makes it Squircle's to shut down (Q4).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Boot {
    /// From a ledger before this was recorded.
    Unknown,
    /// T3 listed it booted when the session chose it.
    WasBooted,
    /// T3 listed it shut down when the session chose it; its open boots it.
    WasShutdown,
    /// The session's open booted it, confirmed at `at`: a boot receipt.
    BootedHere { at: f64 },
}

#[derive(Clone, Debug, PartialEq)]
pub struct Session {
    pub id: String,
    pub thread_id: String,
    pub host_id: String,
    pub device_id: String,
    pub device_name: String,
    /// Seconds since 1970, fractional.
    pub started_at: f64,
    pub phase: Phase,
    pub device: DeviceLease,
    pub release: Release,
    pub boot: Boot,
    /// What the service did to the simulator meanwhile (a runaway app it
    /// stopped), for the agent and `sim status`.
    pub notes: Vec<String>,
}

impl Session {
    /// The reservation as first saved, before T3 is asked anything.
    pub fn reserve(
        id: String,
        thread_id: String,
        device_id: String,
        device_name: String,
        booted: bool,
        now: f64,
    ) -> Self {
        Session {
            id,
            thread_id,
            host_id: "local".into(),
            device_id,
            device_name,
            started_at: now,
            phase: Phase::Starting { recorder: None },
            device: DeviceLease::Opening,
            release: Release::NotDue,
            boot: if booted {
                Boot::WasBooted
            } else {
                Boot::WasShutdown
            },
            notes: vec![],
        }
    }

    /// Recording, as the phone shows it.
    pub fn active(&self) -> bool {
        matches!(self.phase, Phase::Recording { .. })
    }

    /// The recorder may run or T3 may still be opening: the session uses its simulator.
    pub fn holds_device(&self) -> bool {
        matches!(
            self.phase,
            Phase::Starting { .. } | Phase::Recording { .. } | Phase::Stopping { .. }
        )
    }

    /// The media obligation is settled.
    pub fn ended(&self) -> bool {
        matches!(self.phase, Phase::Finished { .. } | Phase::Failed { .. })
    }

    /// Its simulator is reserved: in use, or its cleanup isn't settled.
    pub fn reserves(&self) -> bool {
        self.holds_device() || self.device.owed() || matches!(self.release, Release::Owed(_))
    }

    /// Nothing is owed any more: the machine's terminal state.
    pub fn settled(&self) -> bool {
        self.ended() && !self.reserves()
    }

    pub fn ended_at(&self) -> Option<f64> {
        match self.phase {
            Phase::Filing { ended_at, .. }
            | Phase::Finished { ended_at, .. }
            | Phase::Failed { ended_at, .. } => Some(ended_at),
            _ => None,
        }
    }

    pub fn recorder(&self) -> Option<RecorderID> {
        match self.phase {
            Phase::Starting { recorder }
            | Phase::Recording { recorder }
            | Phase::Stopping { recorder, .. } => recorder,
            _ => None,
        }
    }

    /// A close of T3's device session is owed and due.
    pub fn close_due(&self, now: f64) -> bool {
        !self.holds_device()
            && match &self.device {
                DeviceLease::Opening | DeviceLease::Open => true,
                DeviceLease::CloseOwed(retry) => retry.due(now),
                DeviceLease::Closed => false,
            }
    }

    /// The pool's release is owed and due: the recorder has stopped and T3's device session is closed.
    pub fn release_due(&self, now: f64) -> bool {
        !self.holds_device()
            && !self.device.owed()
            && matches!(&self.release, Release::Owed(retry) if retry.due(now))
    }

    pub fn release_owed(&self) -> bool {
        matches!(self.release, Release::Owed(_))
    }
}

/// How one attempt to close T3's device session ended.
#[derive(Clone, Debug, PartialEq)]
pub enum Closed {
    Closed,
    /// T3's current device sessions don't include it.
    Absent,
    Failed(String),
}

#[derive(Debug)]
pub enum Event {
    /// T3 opened its device session.
    Opened,
    /// The simulator finished booting.
    Booted {
        at: f64,
    },
    /// A previous run's recorder proved to be this session's, with its start time.
    RecorderAdopted(RecorderID),
    /// The recorder was spawned (saved before it is trusted to keep running).
    RecorderStarted(RecorderID),
    /// The recorder survived its start: recording.
    Recording,
    /// Opening failed or was cancelled; whatever was opened is owed back.
    StartFailed {
        error: String,
        now: f64,
    },
    /// Claims the session for a stop. `recovering`: a previous run's session,
    /// which may be claimed in any phase that still holds its simulator.
    Stop {
        reason: String,
        recovering: bool,
    },
    /// The recorder has stopped (or was left alone, with `warning`).
    RecorderStopped {
        now: f64,
        warning: Option<String>,
    },
    /// Filing ended: the media ID, or why no recording was filed.
    Filed(Result<String, String>),
    CloseResult {
        outcome: Closed,
        now: f64,
    },
    ReleaseResult {
        outcome: Result<Released, String>,
        now: f64,
    },
    /// The service did something to the simulator while the session holds it.
    Noted(String),
}

#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    /// Save the session. Effects after it run only once it is saved.
    Commit,
    /// Stop the recorder (SIGINT, then reap) and answer with `RecorderStopped`.
    StopRecorder,
    /// File the recording and answer with `Filed`.
    File,
    /// Close T3's device session and answer with `CloseResult`.
    Close,
    /// Ask the pool to release the simulator and answer with `ReleaseResult`.
    Release,
}

fn fault<E>(session: Session, why: &str) -> Reduction<Session, E> {
    Reduction::same(session, Disposition::ProtocolFault(why.into()))
}

/// Ends what was acquired: T3's device session owes a close, the simulator a release.
fn owe_cleanup(mut session: Session) -> Session {
    if matches!(session.device, DeviceLease::Opening | DeviceLease::Open) {
        session.device = DeviceLease::CloseOwed(RetryState::default());
    }
    if session.release == Release::NotDue {
        session.release = Release::Owed(RetryState::default());
    }
    session
}

pub fn reduce(session: Session, event: Event) -> Reduction<Session, Effect> {
    match (session.phase.clone(), event) {
        (_, Event::Noted(note)) if session.holds_device() => {
            let mut notes = session.notes.clone();
            notes.push(note);
            Reduction::applied(Session { notes, ..session }, vec![Effect::Commit])
        }
        (_, Event::Noted(_)) => Reduction::same(session, Disposition::NotApplicable),
        (Phase::Starting { .. }, Event::Opened) if session.device == DeviceLease::Opening => {
            Reduction::applied(
                Session {
                    device: DeviceLease::Open,
                    ..session
                },
                vec![Effect::Commit],
            )
        }
        (_, Event::Opened) => fault(session, "T3 opened a session that isn't opening"),

        (Phase::Starting { .. }, Event::Booted { at }) if session.boot == Boot::WasShutdown => {
            Reduction::applied(
                Session {
                    boot: Boot::BootedHere { at },
                    ..session
                },
                vec![Effect::Commit],
            )
        }
        (Phase::Starting { .. }, Event::Booted { .. }) => {
            Reduction::same(session, Disposition::Unchanged)
        }
        (_, Event::Booted { .. }) => fault(session, "a boot answered outside a start"),

        (Phase::Recording { .. }, Event::RecorderAdopted(recorder)) => Reduction::applied(
            Session {
                phase: Phase::Recording {
                    recorder: Some(recorder),
                },
                ..session
            },
            vec![Effect::Commit],
        ),
        (_, Event::RecorderAdopted(_)) => fault(
            session,
            "adopted a recorder of a session that isn't recording",
        ),

        (Phase::Starting { .. }, Event::RecorderStarted(recorder)) => Reduction::applied(
            Session {
                phase: Phase::Starting {
                    recorder: Some(recorder),
                },
                ..session
            },
            vec![Effect::Commit],
        ),
        (
            Phase::Starting {
                recorder: Some(recorder),
            },
            Event::Recording,
        ) => Reduction::applied(
            Session {
                phase: Phase::Recording {
                    recorder: Some(recorder),
                },
                ..session
            },
            vec![Effect::Commit],
        ),
        (_, Event::RecorderStarted(_) | Event::Recording) => {
            fault(session, "a recorder started outside a start")
        }

        (Phase::Starting { .. }, Event::StartFailed { error, now }) => {
            let session = owe_cleanup(Session {
                phase: Phase::Failed {
                    reason: None,
                    ended_at: now,
                    error,
                },
                ..session
            });
            Reduction::applied(session, vec![Effect::Commit, Effect::Close])
        }
        // The start was claimed by a stop meanwhile (a shutdown); that stop finishes it.
        (_, Event::StartFailed { .. }) => Reduction::same(session, Disposition::Stale),

        (Phase::Recording { recorder }, Event::Stop { reason, .. }) => Reduction::applied(
            Session {
                phase: Phase::Stopping { reason, recorder },
                ..session
            },
            vec![Effect::Commit, Effect::StopRecorder],
        ),
        (
            Phase::Starting { recorder },
            Event::Stop {
                reason,
                recovering: true,
            },
        ) => Reduction::applied(
            Session {
                phase: Phase::Stopping { reason, recorder },
                ..session
            },
            vec![Effect::Commit, Effect::StopRecorder],
        ),
        // A stop a previous run (or a failed save) left part-way resumes with its own reason.
        (
            Phase::Stopping { .. },
            Event::Stop {
                recovering: true, ..
            },
        ) => Reduction {
            state: session,
            effects: vec![Effect::StopRecorder],
            disposition: Disposition::Applied,
        },
        // Already being stopped, or over: no second stop.
        (_, Event::Stop { .. }) => Reduction::same(session, Disposition::NotApplicable),

        (Phase::Stopping { reason, .. }, Event::RecorderStopped { now, warning }) => {
            let session = owe_cleanup(Session {
                phase: Phase::Filing {
                    reason,
                    ended_at: now,
                    warning,
                },
                ..session
            });
            Reduction::applied(session, vec![Effect::Commit, Effect::Close, Effect::File])
        }
        (_, Event::RecorderStopped { .. }) => fault(
            session,
            "a recorder stopped for a session that wasn't stopping",
        ),

        (
            Phase::Filing {
                reason,
                ended_at,
                warning,
            },
            Event::Filed(result),
        ) => {
            let phase = match result {
                Ok(media_id) => Phase::Finished {
                    reason,
                    ended_at,
                    media_id,
                    warning,
                },
                Err(error) => Phase::Failed {
                    reason: Some(reason),
                    ended_at,
                    error,
                },
            };
            Reduction::applied(Session { phase, ..session }, vec![Effect::Commit])
        }
        (_, Event::Filed(_)) => Reduction::same(session, Disposition::Duplicate),

        (_, Event::CloseResult { .. }) if session.holds_device() => fault(
            session,
            "T3's device session closed while the session still uses it",
        ),
        (_, Event::CloseResult { .. }) if !session.device.owed() => {
            Reduction::same(session, Disposition::Duplicate)
        }
        (
            _,
            Event::CloseResult {
                outcome: Closed::Closed | Closed::Absent,
                ..
            },
        ) => {
            let release = session.release_owed();
            let session = Session {
                device: DeviceLease::Closed,
                ..session
            };
            Reduction::applied(
                session,
                if release {
                    vec![Effect::Commit, Effect::Release]
                } else {
                    vec![Effect::Commit]
                },
            )
        }
        (
            _,
            Event::CloseResult {
                outcome: Closed::Failed(error),
                now,
            },
        ) => {
            let retry = match &session.device {
                DeviceLease::CloseOwed(retry) => retry.clone(),
                _ => RetryState::default(),
            };
            Reduction::applied(
                Session {
                    device: DeviceLease::CloseOwed(retry.failed(error, now)),
                    ..session
                },
                vec![Effect::Commit],
            )
        }

        (_, Event::ReleaseResult { .. }) if session.holds_device() || session.device.owed() => {
            fault(
                session,
                "a release answered before the recorder stopped and T3's device session closed",
            )
        }
        (_, Event::ReleaseResult { outcome, now }) => match (&session.release, outcome) {
            (Release::Owed(_), Ok(outcome)) => Reduction::applied(
                Session {
                    release: Release::Done { outcome, at: now },
                    ..session
                },
                vec![Effect::Commit],
            ),
            (Release::Owed(retry), Err(error)) => {
                let retry = retry.failed(error, now);
                Reduction::applied(
                    Session {
                        release: Release::Owed(retry),
                        ..session
                    },
                    vec![Effect::Commit],
                )
            }
            _ => Reduction::same(session, Disposition::Duplicate),
        },
    }
}

/// Whether a recording session's turn has ended: the time T3 last
/// confirmed the thread idle (or gone), since then. Kept in memory: a
/// restart starts the grace again.
#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct IdleClock {
    pub since: Option<f64>,
}

/// Why a recording session is due to stop now, if it is: its recorder
/// exited, it ran past the limit, or T3 has confirmed its turn over for the
/// grace. Busy, waiting on the user or unknown state disarms the clock:
/// uncertain time never counts as idle.
pub fn watch(
    session: &Session,
    clock: IdleClock,
    recorder_alive: bool,
    seen: &Seen,
    now: f64,
) -> (IdleClock, Option<&'static str>) {
    let clock = match seen {
        Seen::Busy { .. } | Seen::Waiting { .. } | Seen::Unknown { .. } => {
            IdleClock { since: None }
        }
        Seen::Idle { .. } | Seen::Gone => IdleClock {
            since: Some(clock.since.unwrap_or(now)),
        },
    };
    let due = if !recorder_alive {
        Some("recorder stopped")
    } else if now - session.started_at > MAX_SECONDS {
        Some("time limit")
    } else if clock.since.is_some_and(|since| now - since >= IDLE_GRACE) {
        Some("turn ended")
    } else {
        None
    };
    (clock, due)
}

/// The times `watch`, `close_due` and `release_due` would next decide
/// differently with nothing else changing: the policy's own clocks.
pub fn due_at(session: &Session, clock: IdleClock) -> Vec<f64> {
    let mut due = vec![];
    if session.active() {
        due.push(session.started_at + MAX_SECONDS);
        due.extend(clock.since.map(|since| since + IDLE_GRACE));
    }
    if !session.holds_device() {
        if let DeviceLease::CloseOwed(retry) = &session.device {
            due.push(retry.retry_at);
        }
        if let Release::Owed(retry) = &session.release
            && !session.device.owed()
        {
            due.push(retry.retry_at);
        }
    }
    due
}

pub fn violations(session: &Session) -> Vec<Violation> {
    let mut found = vec![];
    if session.holds_device() && session.release != Release::NotDue {
        found.push(Violation(
            "a release is owed while the session still uses its simulator".into(),
        ));
    }
    if !session.holds_device() && matches!(session.device, DeviceLease::Opening | DeviceLease::Open)
    {
        found.push(Violation(
            "an ended session claims T3's device session is open".into(),
        ));
    }
    if matches!(&session.release, Release::Done { outcome, .. } if *outcome != Released::Earlier)
        && session.device.owed()
    {
        found.push(Violation(
            "released before T3's device session closed".into(),
        ));
    }
    if !session.holds_device() && session.release == Release::NotDue {
        found.push(Violation(
            "an ended session owes no release decision".into(),
        ));
    }
    found
}

// MARK: Stored and served

/// A session as saved: the flat fields the phone and earlier ledgers have,
/// plus the cleanup receipts, which only the ledger keeps.
#[derive(Serialize, Deserialize)]
pub struct Stored {
    #[serde(flatten)]
    pub served: Served,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recorder_start: Option<(u64, u64)>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release: Option<Release>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub boot: Option<Boot>,
}

/// A session as `/v1/sims` serves it (unchanged wire format).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Served {
    pub id: String,
    pub thread_id: String,
    pub host_id: String,
    pub device_id: String,
    pub device_name: String,
    pub started_at: f64,
    pub state: String,
    #[serde(default)]
    pub ended_at: Option<f64>,
    #[serde(default)]
    pub media_id: Option<String>,
    #[serde(default)]
    pub stop_reason: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub recorder_pid: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_session: Option<DeviceLease>,
    /// Before `device_session`: whether a close was owed, and why it last failed.
    #[serde(default, skip_serializing)]
    pub close_pending: bool,
    #[serde(default, skip_serializing)]
    pub close_error: Option<String>,
    #[serde(default)]
    pub release_pending: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub notes: Vec<String>,
}

impl From<Stored> for Session {
    fn from(stored: Stored) -> Self {
        let r = stored.served;
        let ended_at = r.ended_at.unwrap_or(r.started_at);
        let reason = r.stop_reason.clone().unwrap_or_default();
        let recorder = r.recorder_pid.map(|pid| RecorderID {
            pid,
            start: stored.recorder_start,
        });
        let phase = match (r.state.as_str(), r.media_id) {
            ("starting", _) => Phase::Starting { recorder },
            ("recording", _) => Phase::Recording { recorder },
            ("stopping", _) => Phase::Stopping { reason, recorder },
            ("filing", _) => Phase::Filing {
                reason,
                ended_at,
                warning: r.error,
            },
            ("finished", Some(media_id)) => Phase::Finished {
                reason,
                ended_at,
                media_id,
                warning: r.error,
            },
            ("failed", _) => Phase::Failed {
                reason: r.stop_reason,
                ended_at,
                error: r.error.unwrap_or_else(|| "Failed".into()),
            },
            (state, _) => Phase::Failed {
                reason: r.stop_reason,
                ended_at,
                error: format!("Unreadable saved state {state:?}"),
            },
        };
        let held = matches!(
            phase,
            Phase::Starting { .. } | Phase::Recording { .. } | Phase::Stopping { .. }
        );
        let device = r.device_session.unwrap_or(match (r.close_pending, held) {
            (false, _) => DeviceLease::Closed,
            (true, true) => DeviceLease::Open,
            (true, false) => DeviceLease::CloseOwed(RetryState {
                error: r.close_error,
                ..RetryState::default()
            }),
        });
        // An ended session still claiming an open device session owes its close.
        let device = match device {
            DeviceLease::Opening | DeviceLease::Open if !held => {
                DeviceLease::CloseOwed(RetryState::default())
            }
            device => device,
        };
        let release = match stored.release {
            Some(Release::NotDue) | None if held => Release::NotDue,
            Some(release @ (Release::Owed(_) | Release::Done { .. })) => release,
            // Earlier ledgers: `release_pending` was the whole obligation.
            _ if r.release_pending => Release::Owed(RetryState::default()),
            _ => Release::Done {
                outcome: Released::Earlier,
                at: ended_at,
            },
        };
        Session {
            id: r.id,
            thread_id: r.thread_id,
            host_id: r.host_id,
            device_id: r.device_id,
            device_name: r.device_name,
            started_at: r.started_at,
            phase,
            device,
            release,
            boot: stored.boot.unwrap_or(Boot::Unknown),
            notes: r.notes,
        }
    }
}

impl From<&Session> for Served {
    fn from(s: &Session) -> Self {
        let (state, ended_at, media_id, stop_reason, error, recorder) = match s.phase.clone() {
            Phase::Starting { recorder } => ("starting", None, None, None, None, recorder),
            Phase::Recording { recorder } => ("recording", None, None, None, None, recorder),
            Phase::Stopping { reason, recorder } => {
                ("stopping", None, None, Some(reason), None, recorder)
            }
            Phase::Filing {
                reason,
                ended_at,
                warning,
            } => ("filing", Some(ended_at), None, Some(reason), warning, None),
            Phase::Finished {
                reason,
                ended_at,
                media_id,
                warning,
            } => (
                "finished",
                Some(ended_at),
                Some(media_id),
                Some(reason),
                warning,
                None,
            ),
            Phase::Failed {
                reason,
                ended_at,
                error,
            } => ("failed", Some(ended_at), None, reason, Some(error), None),
        };
        Served {
            id: s.id.clone(),
            thread_id: s.thread_id.clone(),
            host_id: s.host_id.clone(),
            device_id: s.device_id.clone(),
            device_name: s.device_name.clone(),
            started_at: s.started_at,
            state: state.into(),
            ended_at,
            media_id,
            stop_reason,
            error,
            recorder_pid: recorder.map(|r| r.pid),
            device_session: Some(s.device.clone()),
            close_pending: false,
            close_error: None,
            release_pending: s.release_owed(),
            notes: s.notes.clone(),
        }
    }
}

impl From<&Session> for Stored {
    fn from(s: &Session) -> Self {
        Stored {
            served: s.into(),
            recorder_start: s.recorder().and_then(|r| r.start),
            release: Some(s.release.clone()),
            boot: Some(s.boot.clone()),
        }
    }
}

impl Serialize for Session {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        Stored::from(self).serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for Session {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(Stored::deserialize(deserializer)?.into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn session() -> Session {
        Session::reserve(
            "s".into(),
            "t".into(),
            "SIM1".into(),
            "iPhone".into(),
            false,
            10.0,
        )
    }

    fn step(session: Session, event: Event) -> (Session, Vec<Effect>) {
        let r = reduce(session, event);
        assert!(
            !matches!(r.disposition, Disposition::ProtocolFault(_)),
            "{:?}",
            r.disposition
        );
        assert_eq!(violations(&r.state), vec![]);
        (r.state, r.effects)
    }

    fn recording() -> Session {
        let rec = RecorderID {
            pid: 7,
            start: Some((1, 2)),
        };
        let (s, _) = step(session(), Event::Opened);
        let (s, _) = step(s, Event::Booted { at: 11.0 });
        assert_eq!(s.boot, Boot::BootedHere { at: 11.0 });
        let (s, _) = step(s, Event::RecorderStarted(rec));
        step(s, Event::Recording).0
    }

    /// Every way the obligations can be answered, in every order: the slot
    /// is held until close and release are both settled, release never runs
    /// before the close, a failed close or release is retried and never
    /// erased, and failed media never erases cleanup.
    #[test]
    fn cleanup_obligations_never_vanish_in_any_order() {
        let (stopping, effects) = step(
            recording(),
            Event::Stop {
                reason: "stopped".into(),
                recovering: false,
            },
        );
        assert_eq!(effects, vec![Effect::Commit, Effect::StopRecorder]);
        // A second stop is no stop.
        assert_eq!(
            reduce(
                stopping.clone(),
                Event::Stop {
                    reason: "again".into(),
                    recovering: false
                }
            )
            .disposition,
            Disposition::NotApplicable
        );
        let (filing, effects) = step(
            stopping,
            Event::RecorderStopped {
                now: 20.0,
                warning: None,
            },
        );
        assert_eq!(effects, vec![Effect::Commit, Effect::Close, Effect::File]);
        // A release can't answer before the close.
        assert!(matches!(
            reduce(
                filing.clone(),
                Event::ReleaseResult {
                    outcome: Ok(Released::ShutDown),
                    now: 21.0
                }
            )
            .disposition,
            Disposition::ProtocolFault(_)
        ));

        type Answer = fn(Session) -> Session;
        let close_fails: Answer = |s| {
            step(
                s,
                Event::CloseResult {
                    outcome: Closed::Failed("offline".into()),
                    now: 21.0,
                },
            )
            .0
        };
        let close_ok: Answer = |s| {
            step(
                s,
                Event::CloseResult {
                    outcome: Closed::Absent,
                    now: 22.0,
                },
            )
            .0
        };
        let file_ok: Answer = |s| step(s, Event::Filed(Ok("m".into()))).0;
        let file_err: Answer = |s| step(s, Event::Filed(Err("no video".into()))).0;
        let release_fails: Answer = |s| {
            if s.release_due(1e9) {
                step(
                    s,
                    Event::ReleaseResult {
                        outcome: Err("simctl".into()),
                        now: 23.0,
                    },
                )
                .0
            } else {
                s
            }
        };
        let release_ok: Answer = |s| {
            if s.release_due(1e9) {
                step(
                    s,
                    Event::ReleaseResult {
                        outcome: Ok(Released::ShutDown),
                        now: 24.0,
                    },
                )
                .0
            } else {
                s
            }
        };
        let orders: Vec<Vec<Answer>> = vec![
            vec![close_fails, file_ok, close_ok, release_fails, release_ok],
            vec![file_err, close_ok, release_ok],
            vec![close_ok, release_fails, file_ok, release_ok],
            vec![
                close_fails,
                close_fails,
                file_err,
                release_ok,
                close_ok,
                release_ok,
            ],
        ];
        for order in orders {
            let mut s = filing.clone();
            for answer in order {
                s = answer(s);
                let cleanup_settled = !s.device.owed() && matches!(s.release, Release::Done { .. });
                assert_eq!(
                    s.reserves(),
                    !cleanup_settled,
                    "the slot must be held exactly until cleanup settles"
                );
            }
            assert!(s.settled() && !s.reserves());
        }
    }

    /// A start that fails after acquiring nothing still owes the close it
    /// saved before asking T3 (its open may have landed) and the release.
    #[test]
    fn a_failed_start_owes_only_what_it_may_have_acquired() {
        let (failed, effects) = step(
            session(),
            Event::StartFailed {
                error: "boot".into(),
                now: 11.0,
            },
        );
        assert_eq!(effects, vec![Effect::Commit, Effect::Close]);
        assert!(failed.close_due(11.0) && failed.reserves() && !failed.release_due(1e9));
        let (closed, effects) = step(
            failed,
            Event::CloseResult {
                outcome: Closed::Closed,
                now: 12.0,
            },
        );
        assert_eq!(effects, vec![Effect::Commit, Effect::Release]);
        assert!(closed.release_due(12.0));
        // A stop that claimed the start first (a shutdown) finishes it instead.
        let stopping = step(
            recording(),
            Event::Stop {
                reason: "service stopped".into(),
                recovering: false,
            },
        )
        .0;
        assert_eq!(
            reduce(
                stopping,
                Event::StartFailed {
                    error: "late".into(),
                    now: 1.0
                }
            )
            .disposition,
            Disposition::Stale
        );
    }

    /// Unknown or busy state disarms the idle clock; only confirmed idle for
    /// the grace ends a session.
    #[test]
    fn uncertain_time_never_counts_as_idle() {
        let s = recording();
        let idle = Seen::Idle { turn: None };
        let (clock, due) = watch(&s, IdleClock::default(), true, &idle, 100.0);
        assert_eq!((clock.since, due), (Some(100.0), None));
        let (clock, due) = watch(&s, clock, true, &Seen::Unknown { turn: None }, 200.0);
        assert_eq!((clock.since, due), (None, None));
        let (clock, _) = watch(&s, clock, true, &idle, 201.0);
        assert_eq!(
            watch(&s, clock, true, &Seen::Waiting { turn: None }, 300.0).1,
            None
        );
        assert_eq!(watch(&s, clock, true, &idle, 209.0).1, Some("turn ended"));
        assert_eq!(
            watch(
                &s,
                IdleClock::default(),
                false,
                &Seen::Busy { turn: None },
                11.0
            )
            .1,
            Some("recorder stopped")
        );
    }

    /// Ledgers from before typed phases and before cleanup receipts keep
    /// their running sessions, owed closes and owed releases; an abandoned
    /// close is owed again. The wire shape is the earlier one.
    #[test]
    fn earlier_ledger_records_keep_their_obligations() {
        let record = |state: &str, extra: serde_json::Value| {
            let mut value = json!({"id": "a", "thread_id": "t", "host_id": "local", "device_id": "SIM1", "device_name": "iPhone",
                "started_at": 1.0, "ended_at": null, "state": state, "media_id": if state == "finished" { json!("m") } else { json!(null) },
                "stop_reason": null, "error": null, "recorder_pid": 7, "release_pending": false});
            value
                .as_object_mut()
                .unwrap()
                .extend(extra.as_object().unwrap().clone());
            serde_json::from_value::<Session>(value).unwrap()
        };
        let running = record("recording", json!({"close_pending": true}));
        assert_eq!(
            (
                running.phase.clone(),
                running.device.clone(),
                running.release.clone()
            ),
            (
                Phase::Recording {
                    recorder: Some(RecorderID {
                        pid: 7,
                        start: None
                    })
                },
                DeviceLease::Open,
                Release::NotDue
            )
        );
        assert_eq!(running.boot, Boot::Unknown);
        let finished = record(
            "finished",
            json!({"close_pending": true, "close_error": "x"}),
        );
        assert!(matches!(
            finished.device,
            DeviceLease::CloseOwed(RetryState { tries: 0, .. })
        ));
        assert_eq!(
            finished.release,
            Release::Done {
                outcome: Released::Earlier,
                at: 1.0
            }
        );
        let pending = record(
            "failed",
            json!({"device_session": {"phase": "closed"}, "release_pending": true}),
        );
        assert!(pending.release_due(0.0) && pending.reserves());
        let abandoned = record(
            "finished",
            json!({"device_session": {"phase": "abandoned", "error": "gone"}}),
        );
        assert!(
            matches!(&abandoned.device, DeviceLease::CloseOwed(RetryState { error: Some(e), .. }) if e == "gone")
        );
        for s in [running, finished, pending, abandoned] {
            assert_eq!(violations(&s), vec![], "{s:?}");
            let again: Session = serde_json::from_value(serde_json::to_value(&s).unwrap()).unwrap();
            assert_eq!(again, s);
            let served = serde_json::to_value(Served::from(&s)).unwrap();
            let mut keys: Vec<&str> = served
                .as_object()
                .unwrap()
                .keys()
                .map(String::as_str)
                .collect();
            keys.sort();
            assert_eq!(
                keys,
                [
                    "device_id",
                    "device_name",
                    "device_session",
                    "ended_at",
                    "error",
                    "host_id",
                    "id",
                    "media_id",
                    "recorder_pid",
                    "release_pending",
                    "started_at",
                    "state",
                    "stop_reason",
                    "thread_id"
                ]
            );
        }
    }
}
