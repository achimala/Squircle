//! M26, idle upkeep (docs/fsm-architecture.md): what the service does about
//! an app agent's context size, kept apart from the policy that judges a
//! reading (`crate::upkeep`) and from the owner that reads T3. A tick may
//! only start a check; the owner sends `Checked` only for an agent that is
//! eligible right then (current shell, no turn that may be running, no
//! worker working, between resets), revalidated after its read.
//!
//! A compaction is saved with its exact command before it is sent, so an
//! answer lost to a disconnect or a restart is settled by sending that same
//! command again (T3 answers a known ID from its receipt), never a second
//! one. A reading counts as acted on only once T3 accepted it, and one T3
//! refused is not tried again. A fresh start is M14's: here it is only the
//! request, saved together with the agent's queued reset.

use super::{Command, Dispatched};
use crate::fsm::core::{Disposition, Reduction};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Origin {
    /// The service's own check.
    Automatic,
    /// `agent compact`.
    Manual,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Decision {
    Compact,
    Fresh { nightly: bool },
}

/// The context reading a decision was made on.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Reading {
    pub origin: Origin,
    pub decision: Decision,
    /// When T3 recorded that context size (its `context-window.updated`
    /// activity); none for a manual compaction.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub at: Option<String>,
    pub tokens: u64,
}

impl Reading {
    fn same(&self, other: &Reading) -> bool {
        self.decision == other.decision && self.at.is_some() && self.at == other.at
    }
}

/// What became of the latest upkeep decision for one agent thread.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "kebab-case")]
pub enum Intent {
    /// The compaction is saved and sent, or about to be, with no answer
    /// yet. Only this command is ever sent for it.
    Unknown {
        reading: Reading,
        command: Command,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    /// T3 accepted the compaction, or the fresh start was queued.
    Applied { reading: Reading },
    /// T3 refused the compaction; this reading is not tried again.
    Blocked { reading: Reading, error: String },
}

/// One app's upkeep, for its agent's current thread.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Record {
    pub thread: String,
    #[serde(flatten)]
    pub intent: Intent,
}

#[derive(Debug)]
pub enum Event {
    /// The agent of `thread` is eligible now and policy wants `reading`
    /// (`None`: nothing to do). `compact` is the exact command a new
    /// compaction would send.
    Checked {
        thread: String,
        reading: Option<Reading>,
        compact: Command,
    },
    /// `agent compact` for an agent eligible now.
    Manual { thread: String, compact: Command },
    /// What sending the record's command got.
    Sent(Dispatched),
}

#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    /// Save the record. Effects after it run only once it is saved.
    Commit,
    /// Send this command.
    Send(Command),
    /// Save the record together with the agent's queued fresh start, then
    /// run that reset.
    StartFresh(Reading),
}

pub fn reduce(state: Option<Record>, event: Event) -> Reduction<Option<Record>, Effect> {
    use Disposition::*;
    // A record of an agent thread that has since been replaced decides nothing.
    let current = |thread: &str, state: Option<Record>| state.filter(|r| r.thread == thread);
    match event {
        Event::Checked {
            thread,
            reading,
            compact,
        } => match (current(&thread, state.clone()), reading) {
            // Settle the earlier compaction first: its own command, once it is wanted again.
            (
                Some(Record {
                    intent:
                        Intent::Unknown {
                            reading: pending,
                            command,
                            ..
                        },
                    ..
                }),
                wanted,
            ) => {
                let again = pending.origin == Origin::Manual
                    || wanted.is_some_and(|w| w.decision == Decision::Compact);
                if again {
                    Reduction::applied(state, vec![Effect::Send(command)])
                } else {
                    Reduction::same(state, Unchanged)
                }
            }
            (_, None) => Reduction::same(state, Unchanged),
            (
                Some(Record {
                    intent:
                        Intent::Applied { reading: done } | Intent::Blocked { reading: done, .. },
                    ..
                }),
                Some(wanted),
            ) if done.same(&wanted) => Reduction::same(state, Duplicate),
            (_, Some(wanted)) => match wanted.decision {
                Decision::Compact => compact_now(thread, wanted, compact),
                Decision::Fresh { .. } => {
                    let effects = vec![Effect::StartFresh(wanted.clone())];
                    Reduction::applied(
                        Some(Record {
                            thread,
                            intent: Intent::Applied { reading: wanted },
                        }),
                        effects,
                    )
                }
            },
        },
        Event::Manual { thread, compact } => match current(&thread, state.clone()) {
            Some(Record {
                intent: Intent::Unknown { command, .. },
                ..
            }) => Reduction::applied(state, vec![Effect::Send(command)]),
            _ => compact_now(
                thread,
                Reading {
                    origin: Origin::Manual,
                    decision: Decision::Compact,
                    at: None,
                    tokens: 0,
                },
                compact,
            ),
        },
        Event::Sent(outcome) => {
            let Some(Record {
                thread,
                intent: Intent::Unknown {
                    reading, command, ..
                },
            }) = state
            else {
                return Reduction::same(
                    state,
                    ProtocolFault("a compaction answered that was not sent".into()),
                );
            };
            let intent = match outcome {
                Dispatched::Accepted(_) => Intent::Applied { reading },
                Dispatched::Refused(error) => Intent::Blocked { reading, error },
                Dispatched::NotSent(error) | Dispatched::Unknown(error) => Intent::Unknown {
                    reading,
                    command,
                    error: Some(error),
                },
            };
            Reduction::applied(Some(Record { thread, intent }), vec![Effect::Commit])
        }
    }
}

fn compact_now(
    thread: String,
    reading: Reading,
    command: Command,
) -> Reduction<Option<Record>, Effect> {
    let effects = vec![Effect::Commit, Effect::Send(command.clone())];
    Reduction::applied(
        Some(Record {
            thread,
            intent: Intent::Unknown {
                reading,
                command,
                error: None,
            },
        }),
        effects,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fsm::coordinator::Identity;
    use crate::fsm::core::CommandID;
    use serde_json::json;

    fn compact() -> Command {
        Command::new(
            &Identity {
                id: CommandID::fresh(),
                created_at: "t".into(),
            },
            json!({"type": "thread.turn.start"}),
        )
    }

    fn reading(at: &str, decision: Decision) -> Reading {
        Reading {
            origin: Origin::Automatic,
            decision,
            at: Some(at.into()),
            tokens: 250_000,
        }
    }

    fn checked(
        state: Option<Record>,
        wanted: Option<Reading>,
    ) -> Reduction<Option<Record>, Effect> {
        reduce(
            state,
            Event::Checked {
                thread: "a".into(),
                reading: wanted,
                compact: compact(),
            },
        )
    }

    /// A compaction whose answer is lost (or that a restart interrupted) is
    /// only ever settled by its own command, and counts once accepted.
    #[test]
    fn an_unanswered_compaction_is_sent_again_never_replaced() {
        let first = checked(None, Some(reading("r1", Decision::Compact)));
        let Some(Effect::Send(original)) = first.effects.get(1).cloned() else {
            panic!("{:?}", first.effects)
        };
        assert_eq!(first.effects[0], Effect::Commit);
        let lost = reduce(
            first.state,
            Event::Sent(Dispatched::Unknown("closed".into())),
        );
        // Restored from disk, the next check settles it with that same command…
        let restored: Option<Record> =
            serde_json::from_value(serde_json::to_value(&lost.state).unwrap()).unwrap();
        let again = checked(restored.clone(), Some(reading("r2", Decision::Compact)));
        assert_eq!(again.effects, vec![Effect::Send(original.clone())]);
        // …and not while compaction isn't wanted, nor for a fresh start.
        assert_eq!(checked(restored.clone(), None).effects, vec![]);
        assert_eq!(
            checked(
                restored.clone(),
                Some(reading("r2", Decision::Fresh { nightly: false }))
            )
            .effects,
            vec![]
        );
        assert_eq!(
            reduce(
                restored.clone(),
                Event::Manual {
                    thread: "a".into(),
                    compact: compact()
                }
            )
            .effects,
            vec![Effect::Send(original)]
        );
        let applied = reduce(
            again.state,
            Event::Sent(Dispatched::Accepted(json!({"sequence": 3}))),
        );
        assert!(
            matches!(&applied.state, Some(Record { intent: Intent::Applied { reading }, .. }) if reading.at.as_deref() == Some("r1"))
        );
        // A replaced agent's record is not settled on its successor.
        let successor = reduce(
            restored,
            Event::Checked {
                thread: "b".into(),
                reading: Some(reading("r3", Decision::Compact)),
                compact: compact(),
            },
        );
        assert!(matches!(&successor.state, Some(Record { thread, .. }) if thread == "b"));
    }

    #[test]
    fn a_reading_is_acted_on_once_and_a_refused_one_not_again() {
        let applied = Some(Record {
            thread: "a".into(),
            intent: Intent::Applied {
                reading: reading("r1", Decision::Compact),
            },
        });
        assert_eq!(
            checked(applied.clone(), Some(reading("r1", Decision::Compact))).disposition,
            Disposition::Duplicate
        );
        let sent = checked(None, Some(reading("r1", Decision::Compact)));
        let refused = reduce(sent.state, Event::Sent(Dispatched::Refused("no".into())));
        assert_eq!(
            checked(
                refused.state.clone(),
                Some(reading("r1", Decision::Compact))
            )
            .disposition,
            Disposition::Duplicate
        );
        // A new reading is a new decision.
        assert_eq!(
            checked(refused.state, Some(reading("r2", Decision::Compact)))
                .effects
                .len(),
            2
        );
        let fresh = checked(
            applied,
            Some(reading("r1", Decision::Fresh { nightly: true })),
        );
        assert_eq!(
            fresh.effects,
            vec![Effect::StartFresh(reading(
                "r1",
                Decision::Fresh { nightly: true }
            ))]
        );
    }
}
