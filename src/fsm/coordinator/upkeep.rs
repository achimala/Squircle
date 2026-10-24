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
