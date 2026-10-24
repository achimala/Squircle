//! M18, simulator admission and the grant queue (docs/fsm-architecture.md).
//!
//! At most `limit` simulators are reserved at once: one per distinct device
//! a session reserves (from its save until its cleanup is settled, see
//! `session::Session::reserves`) plus one per grant not yet claimed. Past
//! that a thread waits in a first-come line saved with the sessions. When a
//! slot frees, the head is granted it, saved, and only then woken (through
//! the agents' outbox, once per waiter ID); its next start claims the slot
//! in the same save that reserves its session. A place is given up by
//! leaving, when T3 currently has no such thread, or when the woken turn
//! ends without claiming; an unknown observation keeps it.

use super::Seen;
use crate::fsm::core::{Disposition, Reduction, Violation};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeSet, HashMap};

/// A thread in line for a simulator.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Waiter {
    /// Also the wake message's ID, so a re-sent wake is the same message.
    pub id: String,
    pub thread_id: String,
    pub queued_at: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grant: Option<Grant>,
}

/// A slot held for a waiter until its thread claims it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(from = "GrantRecord", into = "GrantRecord")]
pub struct Grant {
    pub at: f64,
    /// The thread's latest turn when granted: the woken turn is a later one.
    pub turn: Option<String>,
    pub wake: Wake,
}

/// How far the wake has got. Queuing it in the outbox is not delivery;
/// only a later turn seen in T3 is the woken turn.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Wake {
    /// Granted and saved; the wake is still to be queued.
    Owed,
    /// The agents' outbox has the wake message.
    Queued,
    /// T3 shows a turn after the grant's: the woken one.
    Started { turn: String },
}

/// A grant as saved. `woken` is what earlier ledgers have, and still
/// written so an older reader sees a queued wake as woken.
#[derive(Serialize, Deserialize)]
struct GrantRecord {
    at: f64,
    turn: Option<String>,
    #[serde(default)]
    woken: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    wake: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    woken_turn: Option<String>,
}

impl From<GrantRecord> for Grant {
    fn from(r: GrantRecord) -> Self {
        let wake = match (r.wake.as_deref(), r.woken_turn) {
            (Some("started"), Some(turn)) => Wake::Started { turn },
            (Some("queued"), _) => Wake::Queued,
            (Some("owed"), _) => Wake::Owed,
            // Before `wake`: `woken` meant queued in the outbox, nothing more.
            _ if r.woken => Wake::Queued,
            _ => Wake::Owed,
        };
        Grant {
            at: r.at,
            turn: r.turn,
            wake,
        }
    }
}

impl From<Grant> for GrantRecord {
    fn from(g: Grant) -> Self {
        let (wake, woken_turn) = match g.wake {
            Wake::Owed => ("owed", None),
            Wake::Queued => ("queued", None),
            Wake::Started { turn } => ("started", Some(turn)),
        };
        GrantRecord {
            at: g.at,
            turn: g.turn,
            woken: wake != "owed",
            wake: Some(wake.into()),
            woken_turn,
        }
    }
}

/// A simulator a session reserves, by thread.
#[derive(Clone, Debug, PartialEq)]
pub struct Reservation {
    pub thread: String,
    pub device: String,
    /// The session is recording, not starting or being cleaned up.
    pub running: bool,
}

/// The limit and what holds it now, as one snapshot of the same ledger.
pub struct Capacity<'a> {
    pub limit: usize,
    pub reservations: &'a [Reservation],
}

impl Capacity<'_> {
    /// Slots in use apart from `thread`'s: distinct reserved devices and
    /// unclaimed grants of other threads.
    pub fn used_by_others(&self, queue: &[Waiter], thread: Option<&str>) -> usize {
        let devices: BTreeSet<String> = self
            .reservations
            .iter()
            .filter(|r| thread != Some(r.thread.as_str()))
            .map(|r| r.device.to_ascii_uppercase())
            .collect();
        devices.len()
            + queue
                .iter()
                .filter(|w| w.grant.is_some() && thread != Some(w.thread_id.as_str()))
                .count()
    }
}

#[derive(Debug)]
pub enum Event {
    /// A start: may `thread` reserve a slot now? `waiter` is a new ID, used
    /// only if it joins the line.
    Ask {
        thread: String,
        now: f64,
        waiter: String,
    },
    /// `thread`'s session is reserved in this same save: its place (and any
    /// grant) becomes the reservation.
    Claim { thread: String },
    /// One coherent look at the waiting threads, then grants for free slots.
    Advance {
        now: f64,
        seen: HashMap<String, Seen>,
    },
    /// The outbox has the wake for this waiter.
    WakeQueued { waiter: String },
    /// `sim stop` from a waiting thread.
    Leave { thread: String },
}

#[derive(Clone, Debug, PartialEq)]
pub enum Answer {
    Admitted,
    Queued { position: usize },
}

#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    /// Save the queue. Effects after it run only once it is saved.
    Commit,
    /// Tell the agents which threads wait (their ended turns wake nobody).
    Announce,
    /// Queue the wake for this granted waiter, by its ID.
    Wake(Waiter),
    Answer(Answer),
}

pub fn reduce(
    queue: Vec<Waiter>,
    capacity: &Capacity,
    event: Event,
) -> Reduction<Vec<Waiter>, Effect> {
    match event {
        Event::Ask {
            thread,
            now,
            waiter,
        } => ask(queue, capacity, thread, now, waiter),
        Event::Claim { thread } => {
            let before = queue.len();
            let queue: Vec<Waiter> = queue
                .into_iter()
                .filter(|w| w.thread_id != thread)
                .collect();
            if queue.len() == before {
                return Reduction::same(queue, Disposition::Unchanged);
            }
            Reduction::applied(queue, vec![Effect::Commit, Effect::Announce])
        }
        Event::Advance { now, seen } => advance(queue, capacity, now, &seen),
        Event::WakeQueued { waiter } => {
            let mut queue = queue;
            match queue
                .iter_mut()
                .find(|w| w.id == waiter)
                .and_then(|w| w.grant.as_mut())
            {
                Some(grant) if grant.wake == Wake::Owed => {
                    grant.wake = Wake::Queued;
                    Reduction::applied(queue, vec![Effect::Commit])
                }
                // Already recorded, or the place was given up meanwhile.
                _ => Reduction::same(queue, Disposition::Duplicate),
            }
        }
        Event::Leave { thread } => {
            let before = queue.len();
            let queue: Vec<Waiter> = queue
                .into_iter()
                .filter(|w| w.thread_id != thread)
                .collect();
            if queue.len() == before {
                return Reduction::same(queue, Disposition::NotApplicable);
            }
            Reduction::applied(queue, vec![Effect::Commit, Effect::Announce])
        }
    }
}

fn ask(
    mut queue: Vec<Waiter>,
    capacity: &Capacity,
    thread: String,
    now: f64,
    waiter: String,
) -> Reduction<Vec<Waiter>, Effect> {
    let mine = queue.iter().position(|w| w.thread_id == thread);
    // A running session already holds its slot: starting again returns it
    // (or moves it to another simulator), never a place in line.
    let running = capacity
        .reservations
        .iter()
        .any(|r| r.running && r.thread == thread);
    // A slot is held for it, or one is free and nobody waits ahead of it.
    let granted = running || mine.is_some_and(|i| queue[i].grant.is_some());
    let ahead = queue
        .iter()
        .take(mine.unwrap_or(queue.len()))
        .any(|w| w.grant.is_none());
    if granted || (!ahead && capacity.used_by_others(&queue, Some(&thread)) < capacity.limit) {
        return Reduction {
            state: queue,
            effects: vec![Effect::Answer(Answer::Admitted)],
            disposition: Disposition::Unchanged,
        };
    }
    let mut effects = vec![];
    if mine.is_none() {
        queue.push(Waiter {
            id: waiter,
            thread_id: thread.clone(),
            queued_at: now,
            grant: None,
        });
        effects.extend([Effect::Commit, Effect::Announce]);
    }
    let position = queue
        .iter()
        .filter(|w| w.grant.is_none())
        .position(|w| w.thread_id == thread)
        .unwrap_or(0)
        + 1;
    effects.push(Effect::Answer(Answer::Queued { position }));
    let disposition = if mine.is_none() {
        Disposition::Applied
    } else {
        Disposition::Unchanged
    };
    Reduction {
        state: queue,
        effects,
        disposition,
    }
}

/// Whether a waiter keeps its place, given what T3 currently says of its thread.
fn keeps(waiter: &mut Waiter, seen: Option<&Seen>) -> bool {
    let Some(seen) = seen else { return true };
    match (seen, waiter.grant.as_mut()) {
        (Seen::Gone, _) => false,
        (Seen::Unknown { .. }, _) | (_, None) => true,
        // A turn after the grant's runs: that is the woken turn.
        (Seen::Busy { turn: Some(turn) } | Seen::Waiting { turn: Some(turn) }, Some(grant))
            if grant.wake == Wake::Queued && grant.turn.as_deref() != Some(turn) =>
        {
            grant.wake = Wake::Started { turn: turn.clone() };
            true
        }
        (Seen::Busy { .. } | Seen::Waiting { .. }, Some(_)) => true,
        // The woken turn ended without claiming the slot.
        (Seen::Idle { .. }, Some(grant)) if matches!(grant.wake, Wake::Started { .. }) => false,
        (Seen::Idle { turn }, Some(grant)) if grant.wake == Wake::Queued => {
            turn.is_none() || turn.as_deref() == grant.turn.as_deref()
        }
        (Seen::Idle { .. }, Some(_)) => true,
    }
}

fn advance(
    queue: Vec<Waiter>,
    capacity: &Capacity,
    now: f64,
    seen: &HashMap<String, Seen>,
) -> Reduction<Vec<Waiter>, Effect> {
    let before = queue.clone();
    let mut queue: Vec<Waiter> = queue
        .into_iter()
        .filter_map(|mut w| {
            let s = seen.get(&w.thread_id);
            keeps(&mut w, s).then_some(w)
        })
        .collect();
    let left = queue.len() != before.len();
    while capacity.used_by_others(&queue, None) < capacity.limit {
        let Some(next) = queue.iter_mut().find(|w| w.grant.is_none()) else {
            break;
        };
        let turn = seen
            .get(&next.thread_id)
            .and_then(|s| s.turn())
            .map(str::to_string);
        next.grant = Some(Grant {
            at: now,
            turn,
            wake: Wake::Owed,
        });
    }
    let mut effects = vec![];
    if queue != before {
        effects.push(Effect::Commit);
    }
    if left {
        effects.push(Effect::Announce);
    }
    // Every grant whose wake isn't queued yet, after the save: a wake is
    // queued once per waiter ID, so asking again changes nothing.
    effects.extend(
        queue
            .iter()
            .filter(|w| w.grant.as_ref().is_some_and(|g| g.wake == Wake::Owed))
            .cloned()
            .map(Effect::Wake),
    );
    let disposition = if queue != before {
        Disposition::Applied
    } else {
        Disposition::Unchanged
    };
    Reduction {
        state: queue,
        effects,
        disposition,
    }
}

/// What must hold for the line and the reservations together.
pub fn violations(queue: &[Waiter], capacity: &Capacity) -> Vec<Violation> {
    let mut found = vec![];
    let threads: BTreeSet<&str> = queue.iter().map(|w| w.thread_id.as_str()).collect();
    if threads.len() != queue.len() {
        found.push(Violation("a thread waits twice".into()));
    }
    let grants = queue.iter().filter(|w| w.grant.is_some()).count();
    // Replacing a thread's own session may briefly reserve a second device,
    // so count threads; grants never take a slot past the limit.
    let holders: BTreeSet<&str> = capacity
        .reservations
        .iter()
        .map(|r| r.thread.as_str())
        .collect();
    if grants > 0 && holders.len() + grants > capacity.limit {
        found.push(Violation(format!(
            "{grants} grants with {} threads holding simulators exceed the limit {}",
            holders.len(),
            capacity.limit
        )));
    }
    let reserved: Vec<&str> = capacity
        .reservations
        .iter()
        .map(|r| r.device.as_str())
        .collect();
    let mut seen = BTreeSet::new();
    for device in &reserved {
        let owners: BTreeSet<&str> = capacity
            .reservations
            .iter()
            .filter(|r| r.device.eq_ignore_ascii_case(device))
            .map(|r| r.thread.as_str())
            .collect();
        if owners.len() > 1 && seen.insert(device.to_ascii_uppercase()) {
            found.push(Violation(format!(
                "{device} is reserved by {} threads",
                owners.len()
            )));
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    fn idle(turn: &str) -> Seen {
        Seen::Idle {
            turn: Some(turn.into()),
        }
    }
    /// The woken turn is the one after the grant: a turn that ends before
    /// the wake was queued, or the turn that queued, keeps the place;
    /// unknown state keeps it; a started woken turn ending gives it up.
    #[test]
    fn a_place_goes_only_when_the_woken_turn_ends_or_t3_has_no_thread() {
        let cap = Capacity {
            limit: 1,
            reservations: &[],
        };
        let queue = vec![Waiter {
            id: "w".into(),
            thread_id: "b".into(),
            queued_at: 0.0,
            grant: Some(Grant {
                at: 1.0,
                turn: Some("t1".into()),
                wake: Wake::Owed,
            }),
        }];
        let seen = |s: Seen| Event::Advance {
            now: 2.0,
            seen: [("b".to_string(), s)].into(),
        };
        // Owed: an ended turn (even a later one) isn't the woken one.
        let kept = reduce(queue, &cap, seen(idle("t2")));
        assert_eq!(kept.state.len(), 1);
        let queued = reduce(kept.state, &cap, Event::WakeQueued { waiter: "w".into() }).state;
        assert_eq!(
            reduce(queued.clone(), &cap, seen(idle("t1"))).state.len(),
            1
        );
        assert_eq!(
            reduce(
                queued.clone(),
                &cap,
                seen(Seen::Unknown {
                    turn: Some("t9".into())
                })
            )
            .state
            .len(),
            1
        );
        let started = reduce(
            queued.clone(),
            &cap,
            seen(Seen::Waiting {
                turn: Some("t2".into()),
            }),
        )
        .state;
        assert_eq!(
            started[0].grant.as_ref().unwrap().wake,
            Wake::Started { turn: "t2".into() }
        );
        assert!(reduce(started, &cap, seen(idle("t2"))).state.is_empty());
        assert!(reduce(queued, &cap, seen(Seen::Gone)).state.is_empty());
    }
}
