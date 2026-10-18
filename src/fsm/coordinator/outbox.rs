//! M16, the durable outbox (docs/fsm-architecture.md): every decision about
//! one queued service message (a worker or build update, a simulator-ready
//! notice) on its way into an agent's conversation. The message ID is the
//! logical identity and never changes; each attempt carries a command
//! identity that is saved before it is sent and changes only after T3 has
//! refused it. An attempt whose answer is lost is sent again with the same
//! identity, which T3 answers from its receipt if it already has it.
//!
//! The owner keeps entries in `agents.json`. Delivery removes the entry and
//! advances its workers' last-told events in one commit; an entry whose
//! recipient is gone is settled as undelivered, never as delivered.

use super::{Dispatched, Identity};
use crate::fsm::core::{Disposition, Observed, Reduction};
use serde::{Deserialize, Serialize};

/// Whether a message Squircle sends with a stable ID may have reached T3.
/// Only T3 acknowledging the dispatch, or showing the message, counts as
/// delivered; an attempt alone does not.
#[derive(Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Debug, Default)]
#[serde(rename_all = "kebab-case")]
pub enum Delivery {
    /// Not sent under its current command identity.
    #[default]
    Queued,
    /// Sent, or about to be, without an answer: send the same identity again
    /// (or, for an entry from before identities were saved, look for the
    /// message) before anything else.
    OutcomeUnknown,
}

/// Reads `delivery`, or the `attempted` flag written before it.
pub fn delivery_or_legacy<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Delivery, D::Error> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum File {
        Attempted(bool),
        Delivery(Delivery),
    }
    Ok(match File::deserialize(d)? {
        File::Attempted(true) => Delivery::OutcomeUnknown,
        File::Attempted(false) => Delivery::Queued,
        File::Delivery(delivery) => delivery,
    })
}

fn is_zero(n: &u32) -> bool {
    *n == 0
}

/// One entry's delivery state, kept flat in its outbox entry.
#[derive(Clone, Serialize, Deserialize, PartialEq, Debug, Default)]
pub struct Outbound {
    #[serde(default, alias = "attempted", deserialize_with = "delivery_or_legacy")]
    pub delivery: Delivery,
    /// The current attempt's command identity, saved before it is sent.
    /// Entries written before identities were saved have none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<Identity>,
    /// Failed attempts in a row, and when the next one is due (Unix seconds).
    #[serde(default, skip_serializing_if = "is_zero")]
    pub failures: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retry_at: Option<u64>,
    /// The last failure, for diagnosis.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// How an entry leaves the outbox.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Settled {
    /// T3 has the message.
    Delivered,
    /// Nobody is left to tell: the recipient thread is gone from a current shell.
    Undelivered(&'static str),
}

#[derive(Debug)]
pub enum Event {
    /// A flush reached the entry. `recipient` is whether the live shell has
    /// the thread it goes to; `next` is a new identity, used only if this
    /// attempt needs one.
    Due {
        now: u64,
        recipient: Observed<bool>,
        next: Identity,
    },
    /// For an entry from before identities were saved: whether the message
    /// is in the recipient's thread.
    LookedUp {
        found: Result<bool, String>,
        now: u64,
        next: Identity,
    },
    /// What the attempt with the current identity got.
    Sent {
        outcome: Dispatched,
        now: u64,
        next: Identity,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    /// Save the entry's new state. Effects after it run only once it is saved.
    Commit,
    /// Send the message under this identity.
    Send(Identity),
    /// Look for the message in the recipient's thread.
    LookUp,
    /// Remove the entry, saved as one change with what settling it implies.
    Settle(Settled),
}

/// Backoff after `failures` failed attempts in a row.
pub fn backoff(failures: u32) -> u64 {
    4 << failures.min(6)
}

/// The decision for one event about one entry.
pub fn reduce(state: Outbound, event: Event) -> Reduction<Outbound, Effect> {
    use Disposition::*;
    match event {
        // Nothing is decided on a shell that isn't current.
        Event::Due {
            recipient: Observed::Unavailable(_) | Observed::Stale { .. },
            ..
        } => Reduction::same(state, Unchanged),
        Event::Due {
            recipient: Observed::Current { value: false, .. },
            ..
        } => Reduction::applied(
            state,
            vec![Effect::Settle(Settled::Undelivered(
                "its agent's thread is gone",
            ))],
        ),
        Event::Due { now, .. } if state.retry_at.is_some_and(|at| at > now) => {
            Reduction::same(state, Unchanged)
        }
        Event::Due { next, .. } => match (state.delivery, &state.command) {
            (Delivery::OutcomeUnknown, None) => Reduction::applied(state, vec![Effect::LookUp]),
            (Delivery::OutcomeUnknown, Some(identity)) => {
                let send = Effect::Send(identity.clone());
                Reduction::applied(state, vec![send])
            }
            (Delivery::Queued, _) => send(state, next),
        },

        Event::LookedUp { .. }
            if state.delivery != Delivery::OutcomeUnknown || state.command.is_some() =>
        {
            Reduction::same(
                state,
                ProtocolFault("a look-up answered for an entry that has its identity".into()),
            )
        }
        Event::LookedUp {
            found: Ok(true), ..
        } => Reduction::applied(state, vec![Effect::Settle(Settled::Delivered)]),
        // T3 shows the thread without it: the earlier attempt didn't land.
        Event::LookedUp {
            found: Ok(false),
            next,
            ..
        } => send(
            Outbound {
                delivery: Delivery::Queued,
                ..state
            },
            next,
        ),
        Event::LookedUp {
            found: Err(detail),
            now,
            ..
        } => failed(state, Delivery::OutcomeUnknown, None, detail, now),

        Event::Sent { .. }
            if state.delivery != Delivery::OutcomeUnknown || state.command.is_none() =>
        {
            Reduction::same(
                state,
                ProtocolFault("a send answered for an entry that was not sent".into()),
            )
        }
        Event::Sent {
            outcome: Dispatched::Accepted(_),
            ..
        } => Reduction::applied(state, vec![Effect::Settle(Settled::Delivered)]),
        // T3 kept nothing; it may keep a rejected receipt for that identity.
        Event::Sent {
            outcome: Dispatched::Refused(detail),
            now,
            next,
        } => failed(state, Delivery::Queued, Some(next), detail, now),
        Event::Sent {
            outcome: Dispatched::NotSent(detail),
            now,
            ..
        } => failed(state, Delivery::Queued, None, detail, now),
        Event::Sent {
            outcome: Dispatched::Unknown(detail),
            now,
            ..
        } => failed(state, Delivery::OutcomeUnknown, None, detail, now),
    }
}

/// Saves the attempt as possibly sent, then sends it: under its saved
/// identity, else under `next`.
fn send(state: Outbound, next: Identity) -> Reduction<Outbound, Effect> {
    let identity = state.command.clone().unwrap_or(next);
    let state = Outbound {
        delivery: Delivery::OutcomeUnknown,
        command: Some(identity.clone()),
        ..state
    };
    Reduction::applied(state, vec![Effect::Commit, Effect::Send(identity)])
}

/// A failed attempt or look-up: what is now known, and when to try again.
fn failed(
    state: Outbound,
    delivery: Delivery,
    identity: Option<Identity>,
    detail: String,
    now: u64,
) -> Reduction<Outbound, Effect> {
    let failures = (state.failures + 1).min(6);
    let command = identity.or(state.command);
    let state = Outbound {
        delivery,
        command,
        failures,
        retry_at: Some(now + backoff(failures)),
        error: Some(detail),
    };
    Reduction::applied(state, vec![Effect::Commit])
}

/// What must hold for one entry.
pub fn violations(state: &Outbound) -> Vec<crate::fsm::core::Violation> {
    let mut found = vec![];
    if state.retry_at.is_some() && state.failures == 0 {
        found.push(crate::fsm::core::Violation(
            "a retry is due without a failure".into(),
        ));
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fsm::core::{CommandID, Epoch, Revision};

    fn identity(n: u8) -> Identity {
        Identity {
            id: CommandID::parse(&format!("00000000-0000-4000-8000-0000000000{n:02}")).unwrap(),
            created_at: format!("t{n}"),
        }
    }

    fn current(exists: bool) -> Observed<bool> {
        Observed::Current {
            epoch: Epoch(1),
            revision: Revision(0),
            value: exists,
        }
    }

    fn due(state: Outbound, now: u64, n: u8) -> Reduction<Outbound, Effect> {
        reduce(
            state,
            Event::Due {
                now,
                recipient: current(true),
                next: identity(n),
            },
        )
    }

    fn sent(state: Outbound, outcome: Dispatched, now: u64, n: u8) -> Reduction<Outbound, Effect> {
        reduce(
            state,
            Event::Sent {
                outcome,
                now,
                next: identity(n),
            },
        )
    }

    /// Follows one entry through every way an attempt can end: only T3's
    /// refusal ever changes the identity, and nothing settles it but
    /// acceptance.
    #[test]
    fn an_attempt_keeps_its_identity_until_t3_refuses_it() {
        let first = due(Outbound::default(), 0, 1);
        assert_eq!(
            first.effects,
            vec![Effect::Commit, Effect::Send(identity(1))]
        );
        assert_eq!(first.state.delivery, Delivery::OutcomeUnknown);
        // The answer is lost: the same identity goes again once due, and only then.
        let lost = sent(first.state, Dispatched::Unknown("closed".into()), 100, 2);
        assert_eq!(
            (lost.state.command.clone(), lost.state.retry_at),
            (Some(identity(1)), Some(108))
        );
        assert_eq!(due(lost.state.clone(), 107, 3).effects, vec![]);
        let again = due(lost.state, 108, 3);
        assert_eq!(again.effects, vec![Effect::Send(identity(1))]);
        // It never left: still the same identity, back to queued.
        let unsent = sent(
            again.state,
            Dispatched::NotSent("no connection".into()),
            200,
            4,
        );
        assert_eq!(
            (unsent.state.delivery, unsent.state.command.clone()),
            (Delivery::Queued, Some(identity(1)))
        );
        // T3 refuses it: the next attempt is a new command.
        let resend = due(unsent.state, 300, 5);
        assert_eq!(
            resend.effects,
            vec![Effect::Commit, Effect::Send(identity(1))]
        );
        let refused = sent(
            resend.state,
            Dispatched::Refused("invariant".into()),
            300,
            6,
        );
        assert_eq!(
            (
                refused.state.delivery,
                refused.state.command.clone(),
                refused.state.failures
            ),
            (Delivery::Queued, Some(identity(6)), 3)
        );
        let accepted = sent(
            due(refused.state, 1000, 7).state,
            Dispatched::Accepted(serde_json::json!({"sequence": 9})),
            1000,
            8,
        );
        assert_eq!(accepted.effects, vec![Effect::Settle(Settled::Delivered)]);
    }

    #[test]
    fn a_gone_recipient_is_undelivered_and_an_unknown_shell_decides_nothing() {
        let unknown = Outbound {
            delivery: Delivery::OutcomeUnknown,
            command: Some(identity(1)),
            ..Default::default()
        };
        for recipient in [
            Observed::Unavailable("offline".into()),
            Observed::Stale {
                epoch: Epoch(1),
                revision: Revision(0),
                last: Some(false),
            },
        ] {
            let deferred = reduce(
                unknown.clone(),
                Event::Due {
                    now: 0,
                    recipient,
                    next: identity(2),
                },
            );
            assert_eq!(
                (deferred.disposition, deferred.effects),
                (Disposition::Unchanged, vec![])
            );
        }
        let gone = reduce(
            unknown,
            Event::Due {
                now: 0,
                recipient: current(false),
                next: identity(2),
            },
        );
        assert_eq!(
            gone.effects,
            vec![Effect::Settle(Settled::Undelivered(
                "its agent's thread is gone"
            ))]
        );
    }

    #[test]
    fn an_entry_from_before_identities_is_looked_for_before_it_is_sent_again() {
        let legacy: Outbound =
            serde_json::from_value(serde_json::json!({"attempted": true})).unwrap();
        assert_eq!(due(legacy.clone(), 0, 1).effects, vec![Effect::LookUp]);
        let failed = reduce(
            legacy.clone(),
            Event::LookedUp {
                found: Err("timeout".into()),
                now: 0,
                next: identity(1),
            },
        );
        assert_eq!(
            (failed.state.command.clone(), failed.state.delivery),
            (None, Delivery::OutcomeUnknown)
        );
        let found = reduce(
            legacy.clone(),
            Event::LookedUp {
                found: Ok(true),
                now: 0,
                next: identity(1),
            },
        );
        assert_eq!(found.effects, vec![Effect::Settle(Settled::Delivered)]);
        let absent = reduce(
            legacy,
            Event::LookedUp {
                found: Ok(false),
                now: 0,
                next: identity(1),
            },
        );
        assert_eq!(
            absent.effects,
            vec![Effect::Commit, Effect::Send(identity(1))]
        );
    }
}
