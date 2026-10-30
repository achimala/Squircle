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
//! refused is not tried again. An automatic compaction repeats while it
//! still shrinks the context; once one leaves it about as large, the next
//! waits for new work on the thread (a message after the compaction's own)
//! or a manual compaction. Compaction is the only thing upkeep does: the
//! agent keeps its one thread for good.

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

/// The context reading a compaction was decided on.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Reading {
    pub origin: Origin,
    /// When T3 recorded that context size (its `context-window.updated`
    /// activity); none for a manual compaction.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub at: Option<String>,
    pub tokens: u64,
}

impl Reading {
    fn same(&self, other: &Reading) -> bool {
        self.at.is_some() && self.at == other.at
    }

    /// Whether `after`, read with no new work since this reading was
    /// compacted, shows real progress: at least a tenth smaller.
    fn shrank_to(&self, after: &Reading) -> bool {
        after.tokens < self.tokens - self.tokens / 10
    }
}

/// What became of the latest compaction for one agent thread.
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
    /// T3 accepted the compaction, sent as message `message`.
    Applied {
        reading: Reading,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
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
    /// The agent of `thread` is eligible now and policy wants it compacted
    /// on `reading` (`None`: nothing to do). `latest` is the thread's latest
    /// user message (the user's, a note or a notice: any new work starts
    /// with one). `compact` is the exact command a new compaction would send.
    Checked {
        thread: String,
        reading: Option<Reading>,
        latest: Option<String>,
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
}

pub fn reduce(state: Option<Record>, event: Event) -> Reduction<Option<Record>, Effect> {
    use Disposition::*;
    // A record of an agent thread that has since been replaced decides nothing.
    let current = |thread: &str, state: Option<Record>| state.filter(|r| r.thread == thread);
    match event {
        Event::Checked {
            thread,
            reading,
            latest,
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
                let again = pending.origin == Origin::Manual || wanted.is_some();
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
                        Intent::Applied { reading: done, .. } | Intent::Blocked { reading: done, .. },
                    ..
                }),
                Some(wanted),
            ) if done.same(&wanted) => Reduction::same(state, Duplicate),
            // An automatic compaction that left the context about as large,
            // with nothing new on the thread since: compacting again would too.
            (
                Some(Record {
                    intent:
                        Intent::Applied {
                            reading: done,
                            message: Some(message),
                        },
                    ..
                }),
                Some(wanted),
            ) if done.origin == Origin::Automatic
                && latest.as_ref() == Some(&message)
                && !done.shrank_to(&wanted) =>
            {
                Reduction::same(state, Duplicate)
            }
            (_, Some(wanted)) => compact_now(thread, wanted, compact),
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
                Dispatched::Accepted(_) => Intent::Applied {
                    reading,
                    message: command.body()["messageId"].as_str().map(Into::into),
                },
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
    use serde_json::json;

    fn command(message: &str) -> Command {
        Command(json!({"type": "message.dispatch", "messageId": message, "commandId": message}))
    }

    fn reading(at: &str, tokens: u64) -> Option<Reading> {
        Some(Reading {
            origin: Origin::Automatic,
            at: Some(at.into()),
            tokens,
        })
    }

    /// A check on `at`/`tokens` with `latest` the thread's newest message,
    /// answered by T3 if it sends one; whether it did.
    fn check(state: &mut Option<Record>, at: &str, tokens: u64, latest: &str, next: &str) -> bool {
        let checked = reduce(
            state.take(),
            Event::Checked {
                thread: "t".into(),
                reading: reading(at, tokens),
                latest: Some(latest.into()),
                compact: command(next),
            },
        );
        *state = checked.state;
        if checked.effects.is_empty() {
            return false;
        }
        *state = reduce(state.take(), Event::Sent(Dispatched::Accepted(json!({})))).state;
        true
    }

    #[test]
    fn compaction_repeats_only_while_it_shrinks_or_after_new_work() {
        let mut state = None;
        assert!(check(&mut state, "r1", 400_000, "user1", "c1"));
        // Shrank by a quarter, still large, nothing new: compact again.
        assert!(check(&mut state, "r2", 300_000, "c1", "c2"));
        // Barely smaller, nothing new since: stop, however often it is checked.
        assert!(!check(&mut state, "r3", 290_000, "c2", "c3"));
        assert!(!check(&mut state, "r3", 290_000, "c2", "c3"));
        // New work on the thread: compact again.
        assert!(check(&mut state, "r4", 320_000, "user2", "c4"));
        // Grew, nothing new: stop.
        assert!(!check(&mut state, "r5", 330_000, "c4", "c5"));
        // A manual compaction starts it again.
        state = reduce(
            state,
            Event::Manual {
                thread: "t".into(),
                compact: command("m1"),
            },
        )
        .state;
        state = reduce(state, Event::Sent(Dispatched::Accepted(json!({})))).state;
        assert!(check(&mut state, "r6", 330_000, "m1", "c6"));
    }
}
