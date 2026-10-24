//! M20, the simulator pool's provenance and cleanup policy
//! (docs/fsm-architecture.md).
//!
//! Only proven Squircle creation or boot makes a simulator Squircle's to
//! shut down (Q4): a device an agent's own `simctl create` made, or a boot
//! by a session's open or an agent's own `simctl boot`, until the device is
//! next seen shut down (that boot is over). A session merely using a
//! simulator, an install or a build is an observation, never ownership.
//! Anything not proven is the user's and is never touched.
//!
//! Protection comes from explicit observed state, never a display label: a
//! simulator a session reserves, the preview's, one with a T3 device
//! session of a thread that is busy, waiting on the user, of unknown state,
//! or not Squircle's; one an agent used outside a session while that agent
//! may still be working; and every one while T3's activity log, which
//! could show such a use, couldn't be read. A cleanup is saved as an intent
//! before it runs, revalidated against a fresh snapshot right before, and
//! its outcome is only what simctl or a later inventory shows.
//!
//! Two rules reach past proven ownership, because simulators otherwise pile
//! up and hold the Mac (2026-10-19, owner-requested): a shut-down device
//! nobody has used for `stale_after` (14 days) is deleted whoever created it,
//! unless the owner keeps it (`squircle sim keep`); and one of ours that only
//! a working Squircle thread's T3 device session keeps booted is shut down
//! once nothing has used it for `hold_idle` (30 minutes).

use super::Seen;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// An outside-a-session use by an agent protects the simulator only this
/// long after the command, and only while that agent may be working.
pub const TOUCH_WINDOW: f64 = 3.0 * 3600.0;

#[derive(Clone, Copy, Debug)]
pub struct Policy {
    /// Concurrent reserved simulators (`SQUIRCLE_MAX_SIMULATORS`, default 3).
    pub max_leases: usize,
    /// Seconds a free simulator of ours stays booted (`SQUIRCLE_SIM_IDLE_MINUTES`, default 10).
    pub idle: f64,
    /// Seconds unused before a device an agent created is deleted.
    pub delete_after: f64,
    /// Seconds unused before any shut-down device is deleted, whoever made
    /// it (`SQUIRCLE_SIM_STALE_DAYS`, default 14; 0 turns it off).
    pub stale_after: f64,
    /// Seconds unused before one of ours that only a working Squircle
    /// thread's T3 device session keeps booted is shut down
    /// (`SQUIRCLE_SIM_HOLD_IDLE_MINUTES`, default 30).
    pub hold_idle: f64,
}

/// One simulator device, as simctl lists it.
#[derive(Clone, Debug)]
pub struct Device {
    pub udid: String,
    pub name: String,
    /// simctl's state: "Booted", "Shutdown", "Booting", ...
    pub state: String,
    /// When CoreSimulator last wrote its device.plist (boot and shutdown do); 0 if unknown.
    pub changed_at: f64,
    /// CoreSimulator's own `lastUsedAt` (set when it boots); 0 if unknown.
    pub last_booted: f64,
    /// Its data and logs on disk, as simctl reports them.
    pub bytes: u64,
}

impl Device {
    /// When anything last used it, by every signal there is: CoreSimulator's
    /// last boot, its device.plist's last write (a boot, shutdown or rename),
    /// and what Squircle saw (sessions, agents' commands). 0 if none is known.
    pub fn last_use(&self, known: Option<&Provenance>) -> f64 {
        self.last_booted
            .max(self.changed_at)
            .max(known.map_or(0.0, |k| k.last_used))
    }

    /// The owner keeps it: its UDID or exact name is on the keep list.
    pub fn kept(&self, keep: &[String]) -> bool {
        keep.iter()
            .any(|k| k.eq_ignore_ascii_case(&self.udid) || *k == self.name)
    }
}

/// A simulator a session reserves.
#[derive(Clone, Debug)]
pub struct Lease {
    pub device_id: String,
    pub thread_id: String,
}

/// A boot Squircle or its agents did.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BootReceipt {
    /// When the boot was asked for (seconds since 1970).
    pub at: f64,
    /// The agent thread whose own command booted it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thread: Option<String>,
    /// The session whose open booted it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    Shutdown,
    Delete,
}

/// A cleanup saved before it runs.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Acting {
    pub action: Action,
    pub at: f64,
}

/// What Squircle knows of a device's history, kept in `simpool.json`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Provenance {
    /// A session used it (an observation; not ownership).
    #[serde(default)]
    pub leased: bool,
    /// The thread whose command created it: a creation receipt.
    #[serde(default)]
    pub created_by: Option<String>,
    /// The latest boot Squircle or its agents did.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub booted: Option<BootReceipt>,
    /// When it was last seen (or made) shut down: boots before this are over.
    #[serde(default)]
    pub shut_down_at: f64,
    /// The latest thread that used it outside a session, and when.
    #[serde(default)]
    pub touched_by: Option<String>,
    #[serde(default)]
    pub touched_at: f64,
    /// The latest of any use.
    #[serde(default)]
    pub last_used: f64,
    /// A cleanup saved and not yet answered: reconciled from the next inventory.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub acting: Option<Acting>,
    /// Why the last cleanup failed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl Provenance {
    /// A boot of ours that is still the current one.
    pub fn boot(&self) -> Option<&BootReceipt> {
        self.booted.as_ref().filter(|b| b.at > self.shut_down_at)
    }

    /// Proven Squircle's: an agent created it, or the current boot is ours.
    pub fn owned(&self) -> bool {
        self.created_by.is_some() || self.boot().is_some()
    }

    pub fn note_boot(&mut self, receipt: BootReceipt) {
        self.last_used = self.last_used.max(receipt.at);
        if self.booted.as_ref().is_none_or(|b| b.at < receipt.at) {
            self.booted = Some(receipt);
        }
    }

    pub fn note_touch(&mut self, thread: &str, at: f64) {
        if at >= self.touched_at {
            self.touched_by = Some(thread.into());
            self.touched_at = at;
        }
        self.last_used = self.last_used.max(at);
    }
}

/// Folds a fresh inventory taken at `now` into what is known: a device
/// seen shut down ends every boot recorded before.
pub fn observe(known: &mut HashMap<String, Provenance>, devices: &[Device], now: f64) {
    for device in devices.iter().filter(|d| d.state == "Shutdown") {
        // Receipts are taken once a boot is confirmed, so none predates its boot.
        if let Some(entry) = known.get_mut(&device.udid) {
            entry.shut_down_at = entry.shut_down_at.max(now);
        }
    }
}

/// On the first inventory after a restart: a cleanup a previous run saved
/// and never answered (a crash, an unknown outcome) is settled by what the
/// inventory shows, never assumed done.
pub fn reconcile(known: &mut HashMap<String, Provenance>, devices: &[Device]) {
    known.retain(|udid, p| {
        !(p.acting
            .as_ref()
            .is_some_and(|a| a.action == Action::Delete)
            && !devices.iter().any(|d| &d.udid == udid))
    });
    for entry in known.values_mut() {
        entry.acting = None;
    }
}

/// A cleanup's answer.
pub fn settle(
    known: &mut HashMap<String, Provenance>,
    udid: &str,
    action: Action,
    result: Result<(), String>,
    now: f64,
) {
    match (action, result) {
        (Action::Delete, Ok(())) => {
            known.remove(udid);
        }
        (Action::Shutdown, Ok(())) => {
            if let Some(entry) = known.get_mut(udid) {
                entry.shut_down_at = entry.shut_down_at.max(now);
                entry.last_used = now;
                entry.acting = None;
                entry.error = None;
            }
        }
        // Unknown: the next inventory says what happened.
        (_, Err(error)) => {
            if let Some(entry) = known.get_mut(udid) {
                entry.error = Some(error);
            }
        }
    }
}

/// A thread as the pool sees it.
#[derive(Clone, Debug)]
pub struct ThreadInfo {
    pub seen: Seen,
    /// An app agent or worker Squircle started.
    pub squircle: bool,
}

pub struct Facts<'a> {
    pub now: f64,
    pub devices: &'a [Device],
    /// Simulators sessions reserve (including ones still being cleaned up).
    pub leases: &'a [Lease],
    /// Open T3 device sessions: (thread, device).
    pub t3_sessions: &'a [(String, String)],
    pub known: &'a HashMap<String, Provenance>,
    pub thread: &'a dyn Fn(&str) -> ThreadInfo,
    /// T3's activity log was read up to now: no unseen outside use.
    pub activity_complete: bool,
    /// When each simulator was first seen booted and free.
    pub idle_since: &'a HashMap<String, f64>,
    /// Never touched (the preview capture's `SQUIRCLE_SIMULATOR_ID`).
    pub reserved: &'a [String],
    pub policy: Policy,
    /// `sim cleanup` and a lease ending: no idle wait.
    pub now_please: bool,
    /// Device names and UDIDs the owner keeps (`squircle sim keep`): never deleted.
    pub keep: &'a [String],
    /// When each simulator was first seen kept booted only by a working
    /// Squircle thread's T3 device session.
    pub held_since: &'a HashMap<String, f64>,
}

#[derive(Clone, Debug, Serialize)]
pub struct Row {
    pub udid: String,
    pub name: String,
    pub booted: bool,
    /// "lease", "t3 session", "agent outside a lease", "agent (idle)",
    /// "unowned" (not proven Squircle's) or "reserved".
    pub owner: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thread: Option<String>,
    pub ours: bool,
    /// Booted, ours and held by nothing: a start can take it.
    pub free: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub action: Option<Action>,
    pub why: String,
    /// Its data and logs on disk.
    #[serde(skip_serializing_if = "is_zero")]
    pub bytes: u64,
    /// Booted, ours, and kept only by a working Squircle thread's T3 device
    /// session: the hold's idle clock runs.
    #[serde(skip)]
    pub hold: bool,
}

fn is_zero(n: &u64) -> bool {
    *n == 0
}

/// The policy: one row per booted simulator, plus devices to delete.
pub fn plan(facts: &Facts) -> Vec<Row> {
    let mut rows = Vec::new();
    for device in facts.devices {
        let known = facts.known.get(&device.udid).cloned().unwrap_or_default();
        let ours = known.owned();
        let row = |owner, thread: Option<&str>, free, action, why: String| Row {
            udid: device.udid.clone(),
            name: device.name.clone(),
            booted: device.state == "Booted",
            owner,
            thread: thread.map(str::to_string),
            ours,
            free,
            action,
            why,
            bytes: device.bytes,
            hold: false,
        };
        let lease = facts
            .leases
            .iter()
            .find(|l| l.device_id.eq_ignore_ascii_case(&device.udid));
        // A T3 device session protects while its thread may be working, and
        // always while the thread is the user's own (not one Squircle started).
        let holders: Vec<(&String, ThreadInfo)> = facts
            .t3_sessions
            .iter()
            .filter(|(_, d)| d.eq_ignore_ascii_case(&device.udid))
            .map(|(thread, _)| (thread, (facts.thread)(thread)))
            .filter(|(_, info)| info.seen.protects() || (info.seen != Seen::Gone && !info.squircle))
            .collect();
        let session = holders.first().map(|(thread, _)| *thread);
        // Every hold is a Squircle thread's turn that is running: one waiting
        // on the user, of unknown state or the user's own keeps protecting.
        let working_hold = !holders.is_empty()
            && holders
                .iter()
                .all(|(_, info)| info.squircle && matches!(info.seen, Seen::Busy { .. }));
        let recent_touch = known
            .touched_by
            .as_deref()
            .filter(|_| facts.now - known.touched_at < TOUCH_WINDOW);
        let toucher = [
            recent_touch,
            known.boot().and_then(|b| b.thread.as_deref()),
            known.created_by.as_deref(),
        ]
        .into_iter()
        .flatten()
        .find(|t| (facts.thread)(t).seen.protects());

        if device.state != "Booted" {
            let last_use = device.last_use(Some(&known));
            let unused = facts.now - last_use;
            let deletable = device.state == "Shutdown"
                && lease.is_none()
                && facts.activity_complete
                && !facts.reserved.contains(&device.udid)
                && !device.kept(facts.keep)
                && !facts
                    .t3_sessions
                    .iter()
                    .any(|(_, d)| d.eq_ignore_ascii_case(&device.udid))
                && toucher.is_none();
            if deletable && known.created_by.is_some() && unused >= facts.policy.delete_after {
                rows.push(row(
                    "agent (idle)",
                    known.created_by.as_deref(),
                    false,
                    Some(Action::Delete),
                    format!("an agent created it; unused for {}", span(unused)),
                ));
            } else if deletable
                && facts.policy.stale_after > 0.0
                // Without any sign of its last use its age is unknown: kept.
                && last_use > 0.0
                && unused >= facts.policy.stale_after
            {
                rows.push(row(
                    "stale",
                    None,
                    false,
                    Some(Action::Delete),
                    format!("shut down and unused for {}", span(unused)),
                ));
            }
            continue;
        }
        let r = if let Some(lease) = lease {
            row(
                "lease",
                Some(&lease.thread_id),
                false,
                None,
                "leased through squircle sim start".into(),
            )
        } else if facts.reserved.contains(&device.udid) {
            row(
                "reserved",
                None,
                false,
                None,
                "the preview capture's simulator".into(),
            )
        } else if let Some(thread) = session {
            let held = working_hold && ours && facts.activity_complete;
            let since = facts
                .held_since
                .get(&device.udid)
                .copied()
                .unwrap_or(facts.now)
                .max(device.last_use(Some(&known)));
            let unused = facts.now - since;
            let due = held && unused >= facts.policy.hold_idle;
            Row {
                hold: held,
                ..row(
                    "t3 session",
                    Some(thread),
                    false,
                    due.then_some(Action::Shutdown),
                    if due {
                        format!(
                            "only a working thread's T3 device session keeps it, unused for {}",
                            span(unused)
                        )
                    } else {
                        "open in T3's device tools".into()
                    },
                )
            }
        } else if !ours {
            row(
                "unowned",
                None,
                false,
                None,
                "not created or booted by Squircle or its agents; left alone".into(),
            )
        } else if let Some(thread) = toucher {
            row(
                "agent outside a lease",
                Some(thread),
                false,
                None,
                "used by an agent that may still be working".into(),
            )
        } else if !facts.activity_complete {
            row(
                "agent (idle)",
                None,
                false,
                None,
                "T3's activity log couldn't be read; kept until it can".into(),
            )
        } else {
            let since = facts
                .idle_since
                .get(&device.udid)
                .copied()
                .unwrap_or(facts.now);
            let idle = facts.now - since;
            let due = facts.now_please || idle >= facts.policy.idle;
            let thread = known
                .touched_by
                .as_deref()
                .or(known.boot().and_then(|b| b.thread.as_deref()))
                .or(known.created_by.as_deref());
            let failed = known
                .error
                .as_deref()
                .map(|e| format!("; the last shutdown failed: {e}"))
                .unwrap_or_default();
            row(
                "agent (idle)",
                thread,
                true,
                due.then_some(Action::Shutdown),
                if due {
                    format!(
                        "Squircle's or an agent's, held by nothing (idle {}){failed}",
                        span(idle)
                    )
                } else {
                    format!("free; shut down after {} idle", span(facts.policy.idle))
                },
            )
        };
        rows.push(r);
    }
    rows
}

/// Whether a cleanup saved from an earlier plan may still run: the fresh
/// plan, from a snapshot taken right now, asks for the same action.
pub fn revalidate(intent: Action, fresh: Option<&Row>) -> bool {
    fresh.is_some_and(|row| row.action == Some(intent))
}

pub fn span(seconds: f64) -> String {
    let minutes = (seconds / 60.0).round() as i64;
    match minutes {
        m if m < 1 => "under a minute".into(),
        m if m < 120 => format!("{m} min"),
        m if m < 48 * 60 => format!("{} h", m / 60),
        m => format!("{} days", m / 1440),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOUR: f64 = 3600.0;
    const POLICY: Policy = Policy {
        max_leases: 3,
        idle: 600.0,
        delete_after: 24.0 * HOUR,
        stale_after: 14.0 * 24.0 * 3600.0,
        hold_idle: 1800.0,
    };

    fn device(udid: &str, state: &str) -> Device {
        Device {
            udid: udid.into(),
            name: format!("sim {udid}"),
            state: state.into(),
            changed_at: 0.0,
            last_booted: 0.0,
            bytes: 0,
        }
    }

    fn booted_by_session(at: f64) -> Provenance {
        Provenance {
            leased: true,
            booted: Some(BootReceipt {
                at,
                thread: None,
                session: Some("s".into()),
            }),
            ..Provenance::default()
        }
    }

    fn info(seen: Seen, squircle: bool) -> ThreadInfo {
        ThreadInfo { seen, squircle }
    }

    /// Which simulators the policy stops or deletes, and the owners it
    /// reports: only proven creation or a current boot of ours is ours,
    /// and needs-you or unknown state protects like working.
    #[test]
    fn policy_acts_only_on_proven_free_simulators() {
        let now = 100.0 * HOUR;
        let devices = [
            device("LEASED", "Booted"),
            device("USER", "Booted"),
            device("PANEL", "Booted"),
            device("ASKING", "Booted"),
            device("ADHOC", "Booted"),
            device("IDLE", "Booted"),
            device("FRESH", "Booted"),
            device("PREVIEW", "Booted"),
            device("USEDONLY", "Booted"),
            device("REBOOTED", "Booted"),
            device("STALE", "Shutdown"),
            device("RECENT", "Shutdown"),
        ];
        let known: HashMap<String, Provenance> = [
            ("LEASED", booted_by_session(1.0)),
            ("PANEL", booted_by_session(1.0)),
            ("IDLE", booted_by_session(1.0)),
            ("FRESH", booted_by_session(1.0)),
            ("PREVIEW", booted_by_session(1.0)),
            ("ASKING", booted_by_session(1.0)),
            (
                "ADHOC",
                Provenance {
                    booted: Some(BootReceipt {
                        at: now - 60.0,
                        thread: Some("worker".into()),
                        session: None,
                    }),
                    ..Provenance::default()
                },
            ),
            // Used by sessions and agents, never booted or created by them: not ours.
            (
                "USEDONLY",
                Provenance {
                    leased: true,
                    touched_by: Some("gone".into()),
                    touched_at: now - 60.0,
                    ..Provenance::default()
                },
            ),
            // Ours once, but seen shut down since: this boot is someone else's.
            (
                "REBOOTED",
                Provenance {
                    shut_down_at: 2.0,
                    ..booted_by_session(1.0)
                },
            ),
            (
                "STALE",
                Provenance {
                    last_used: now - 30.0 * HOUR,
                    created_by: Some("old-worker".into()),
                    ..Provenance::default()
                },
            ),
            (
                "RECENT",
                Provenance {
                    last_used: now - HOUR,
                    created_by: Some("old-worker".into()),
                    ..Provenance::default()
                },
            ),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
        let thread = |id: &str| match id {
            "worker" => info(Seen::Busy { turn: None }, true),
            "user" => info(Seen::Idle { turn: None }, false),
            "asking" => info(Seen::Waiting { turn: None }, true),
            _ => info(Seen::Gone, true),
        };
        let idle_since: HashMap<String, f64> = [
            ("IDLE".to_string(), now - 700.0),
            ("FRESH".to_string(), now - 60.0),
        ]
        .into();
        let leases = [Lease {
            device_id: "LEASED".into(),
            thread_id: "worker".into(),
        }];
        let sessions = [
            ("user".to_string(), "PANEL".to_string()),
            ("asking".to_string(), "ASKING".to_string()),
            ("gone".to_string(), "IDLE".to_string()),
        ];
        let reserved = ["PREVIEW".to_string()];
        let no_holds = HashMap::new();
        let facts = |now_please, activity_complete| Facts {
            now,
            devices: &devices,
            leases: &leases,
            t3_sessions: &sessions,
            known: &known,
            thread: &thread,
            activity_complete,
            idle_since: &idle_since,
            reserved: &reserved,
            policy: POLICY,
            now_please,
            keep: &[],
            held_since: &no_holds,
        };
        let summary = |rows: Vec<Row>| {
            rows.into_iter()
                .map(|r| (r.udid, r.owner, r.action))
                .collect::<Vec<_>>()
        };

        assert_eq!(
            summary(plan(&facts(false, true))),
            vec![
                ("LEASED".into(), "lease", None),
                ("USER".into(), "unowned", None),
                ("PANEL".into(), "t3 session", None),
                ("ASKING".into(), "t3 session", None),
                ("ADHOC".into(), "agent outside a lease", None),
                ("IDLE".into(), "agent (idle)", Some(Action::Shutdown)),
                ("FRESH".into(), "agent (idle)", None),
                ("PREVIEW".into(), "reserved", None),
                ("USEDONLY".into(), "unowned", None),
                ("REBOOTED".into(), "unowned", None),
                ("STALE".into(), "agent (idle)", Some(Action::Delete)),
            ]
        );
        // On demand the idle wait goes, nothing else.
        let acted = |rows: Vec<Row>| {
            rows.into_iter()
                .filter(|r| r.action.is_some())
                .map(|r| r.udid)
                .collect::<Vec<_>>()
        };
        assert_eq!(acted(plan(&facts(true, true))), ["IDLE", "FRESH", "STALE"]);
        // Without the activity log an unseen use could protect any of ours: nothing is acted on.
        assert!(acted(plan(&facts(true, false))).is_empty());
    }

    /// A user's or unknown device is never acted on whatever else is
    /// true of it (within the stale age), and an unknown thread state on a T3 session protects
    /// even an owned one. Generated over every combination of the facts.
    #[test]
    fn unproven_devices_are_never_destroyed() {
        let now = 1000.0;
        let seens = [
            Seen::Gone,
            Seen::Idle { turn: None },
            Seen::Busy { turn: None },
            Seen::Waiting { turn: None },
            Seen::Unknown { turn: None },
        ];
        for state in ["Booted", "Shutdown"] {
            for seen in &seens {
                for squircle in [false, true] {
                    for (provenance, owned) in [
                        (
                            Provenance {
                                leased: true,
                                touched_by: Some("t".into()),
                                touched_at: 1.0,
                                last_used: 1.0,
                                ..Provenance::default()
                            },
                            false,
                        ),
                        (
                            Provenance {
                                booted: Some(BootReceipt {
                                    at: 1.0,
                                    thread: None,
                                    session: None,
                                }),
                                shut_down_at: 5.0,
                                ..Provenance::default()
                            },
                            false,
                        ),
                        (booted_by_session(1.0), true),
                    ] {
                        for session in [false, true] {
                            let devices = [Device {
                                udid: "D".into(),
                                name: "d".into(),
                                state: state.into(),
                                changed_at: 0.0,
                                last_booted: 0.0,
                                bytes: 0,
                            }];
                            let known: HashMap<String, Provenance> =
                                [("D".to_string(), provenance.clone())].into();
                            let sessions: Vec<(String, String)> = if session {
                                vec![("t".into(), "D".into())]
                            } else {
                                vec![]
                            };
                            let thread = |_: &str| info(seen.clone(), squircle);
                            let rows = plan(&Facts {
                                now,
                                devices: &devices,
                                leases: &[],
                                t3_sessions: &sessions,
                                known: &known,
                                thread: &thread,
                                activity_complete: true,
                                idle_since: &HashMap::new(),
                                reserved: &[],
                                policy: POLICY,
                                now_please: true,
                                keep: &[],
                                held_since: &HashMap::new(),
                            });
                            let acted = rows.iter().any(|r| r.action.is_some());
                            if !owned {
                                assert!(
                                    !acted,
                                    "acted on an unproven device: {provenance:?} {seen:?}"
                                );
                            }
                            if session && (seen.protects() || (!squircle && *seen != Seen::Gone)) {
                                assert!(
                                    !acted,
                                    "acted under a protecting T3 session: {seen:?} squircle={squircle}"
                                );
                            }
                        }
                    }
                }
            }
        }
    }

    /// An inventory showing the device shut down ends our boot; after a
    /// restart it settles a cleanup left unanswered by what it shows; a stale plan no longer
    /// asking for the action cancels it.
    #[test]
    fn inventory_settles_unanswered_cleanups_and_ends_boots() {
        let mut known: HashMap<String, Provenance> = [
            (
                "A".to_string(),
                Provenance {
                    acting: Some(Acting {
                        action: Action::Shutdown,
                        at: 5.0,
                    }),
                    ..booted_by_session(1.0)
                },
            ),
            (
                "B".to_string(),
                Provenance {
                    acting: Some(Acting {
                        action: Action::Delete,
                        at: 5.0,
                    }),
                    created_by: Some("w".into()),
                    ..Provenance::default()
                },
            ),
            (
                "C".to_string(),
                Provenance {
                    acting: Some(Acting {
                        action: Action::Shutdown,
                        at: 5.0,
                    }),
                    ..booted_by_session(1.0)
                },
            ),
        ]
        .into();
        let devices = [
            Device {
                udid: "A".into(),
                name: "a".into(),
                state: "Shutdown".into(),
                changed_at: 6.0,
                last_booted: 0.0,
                bytes: 0,
            },
            device("C", "Booted"),
        ];
        observe(&mut known, &devices, 10.0);
        reconcile(&mut known, &devices);
        assert!(
            !known["A"].owned() && known["A"].acting.is_none(),
            "a shut-down device stays ours"
        );
        assert!(!known.contains_key("B"), "a deleted device is still known");
        // Still booted: nothing assumed; it is ours and planned again.
        assert!(known["C"].owned() && known["C"].acting.is_none());
        // A later boot of ours is current again.
        known.get_mut("A").unwrap().note_boot(BootReceipt {
            at: 20.0,
            thread: Some("w".into()),
            session: None,
        });
        assert!(known["A"].owned());
        assert!(!revalidate(Action::Shutdown, None));
        let kept = Row {
            udid: "C".into(),
            name: "c".into(),
            booted: true,
            owner: "t3 session",
            thread: None,
            ours: true,
            free: false,
            action: None,
            why: String::new(),
            bytes: 0,
            hold: false,
        };
        assert!(!revalidate(Action::Shutdown, Some(&kept)));
    }

    /// Any shut-down device unused past the stale age goes, whoever made
    /// it, by its latest sign of use; never a kept, leased, previewed,
    /// T3-open or recently touched one, one of unknown age, or while the
    /// activity log can't be read.
    #[test]
    fn stale_devices_go_unless_kept_or_in_use() {
        const DAY: f64 = 24.0 * HOUR;
        let now = 100.0 * DAY;
        let old = |udid: &str, name: &str| Device {
            udid: udid.into(),
            name: name.into(),
            state: "Shutdown".into(),
            changed_at: now - 20.0 * DAY,
            last_booted: now - 30.0 * DAY,
            bytes: 2_000_000_000,
        };
        let devices = [
            old("OLD", "Old"),
            old("KEPTID", "Mine"),
            old("KEPTNAME", "iPhone 18 Pro"),
            // The plist was written recently (a shutdown 2 days ago).
            Device {
                changed_at: now - 2.0 * DAY,
                ..old("PLIST", "Plist")
            },
            // CoreSimulator booted it recently.
            Device {
                last_booted: now - DAY,
                ..old("BOOTED", "Recently booted")
            },
            // Squircle saw a session use it recently.
            old("LEASEDBEFORE", "Leased before"),
            old("LEASED", "Leased"),
            old("PREVIEW", "Preview"),
            old("PANEL", "Panel"),
            old("TOUCHED", "Touched"),
            Device {
                changed_at: 0.0,
                last_booted: 0.0,
                ..old("AGELESS", "Ageless")
            },
            Device {
                state: "Booted".into(),
                ..old("UP", "Up")
            },
            Device {
                state: "Shutting Down".into(),
                ..old("DOWN", "Going down")
            },
        ];
        let known: HashMap<String, Provenance> = [
            (
                "LEASEDBEFORE".to_string(),
                Provenance {
                    leased: true,
                    last_used: now - 3.0 * DAY,
                    ..Provenance::default()
                },
            ),
            (
                "TOUCHED".to_string(),
                Provenance {
                    touched_by: Some("worker".into()),
                    touched_at: now - 60.0,
                    last_used: now - 60.0,
                    ..Provenance::default()
                },
            ),
        ]
        .into();
        let thread = |id: &str| match id {
            "worker" => info(Seen::Busy { turn: None }, true),
            _ => info(Seen::Gone, true),
        };
        let leases = [Lease {
            device_id: "LEASED".into(),
            thread_id: "worker".into(),
        }];
        let sessions = [("gone".to_string(), "PANEL".to_string())];
        let keep = ["keptid".to_string(), "iPhone 18 Pro".to_string()];
        let reserved = ["PREVIEW".to_string()];
        let plan_with = |activity_complete| {
            plan(&Facts {
                now,
                devices: &devices,
                leases: &leases,
                t3_sessions: &sessions,
                known: &known,
                thread: &thread,
                activity_complete,
                idle_since: &HashMap::new(),
                reserved: &reserved,
                policy: POLICY,
                now_please: true,
                keep: &keep,
                held_since: &HashMap::new(),
            })
        };
        let deleted: Vec<(String, &str)> = plan_with(true)
            .into_iter()
            .filter(|r| r.action == Some(Action::Delete))
            .map(|r| (r.udid, r.owner))
            .collect();
        assert_eq!(deleted, [("OLD".to_string(), "stale")]);
        assert!(
            plan_with(false).iter().all(|r| r.action.is_none()),
            "deleted without the activity log"
        );
    }

    /// One of ours kept booted only by a working Squircle thread's T3
    /// device session is shut down once unused for the hold's idle time,
    /// counted from the later of the hold's first sighting and its last
    /// use; a user's, waiting or unknown hold, or one not ours, keeps it.
    #[test]
    fn idle_working_holds_end() {
        let now = 100.0 * HOUR;
        let ids = [
            "IDLE", "USED", "NEW", "USERS", "WAITING", "MIXED", "NOTOURS",
        ];
        let devices: Vec<Device> = ids.iter().map(|id| device(id, "Booted")).collect();
        let mut known: HashMap<String, Provenance> = ids
            .iter()
            .filter(|id| **id != "NOTOURS")
            .map(|id| (id.to_string(), booted_by_session(1.0)))
            .collect();
        known
            .get_mut("USED")
            .unwrap()
            .note_touch("worker", now - 600.0);
        let thread = |id: &str| match id {
            "worker" => info(Seen::Busy { turn: None }, true),
            "asking" => info(Seen::Waiting { turn: None }, true),
            "user" => info(Seen::Busy { turn: None }, false),
            _ => info(Seen::Gone, true),
        };
        let sessions: Vec<(String, String)> = [
            ("worker", "IDLE"),
            ("worker", "USED"),
            ("worker", "NEW"),
            ("user", "USERS"),
            ("asking", "WAITING"),
            ("worker", "MIXED"),
            ("user", "MIXED"),
            ("worker", "NOTOURS"),
        ]
        .iter()
        .map(|(t, d)| (t.to_string(), d.to_string()))
        .collect();
        let held_since: HashMap<String, f64> = ids
            .iter()
            .filter(|id| **id != "NEW")
            .map(|id| (id.to_string(), now - 2.0 * HOUR))
            .collect();
        let rows = plan(&Facts {
            now,
            devices: &devices,
            leases: &[],
            t3_sessions: &sessions,
            known: &known,
            thread: &thread,
            activity_complete: true,
            idle_since: &HashMap::new(),
            reserved: &[],
            policy: POLICY,
            now_please: true,
            keep: &[],
            held_since: &held_since,
        });
        let summary: Vec<(&str, bool, bool)> = rows
            .iter()
            .map(|r| (r.udid.as_str(), r.hold, r.action == Some(Action::Shutdown)))
            .collect();
        assert_eq!(
            summary,
            [
                ("IDLE", true, true),
                ("USED", true, false),
                ("NEW", true, false),
                ("USERS", false, false),
                ("WAITING", false, false),
                ("MIXED", false, false),
                ("NOTOURS", false, false),
            ]
        );
    }
}
