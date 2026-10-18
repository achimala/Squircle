//! M14, an app agent's creation, restart and fresh replacement
//! (docs/fsm-architecture.md). Every step that changes T3 is saved, with the
//! exact identity of the command it sends, before that command goes out; a
//! step whose answer is lost is sent again under the same identity (T3
//! answers a known ID from its receipt), and a new identity is made only
//! after T3 refused one. So a crash or a lost answer at any point resumes
//! the same operation, never a second agent, stop or handoff.
//!
//! Nothing is stopped while a turn may be running (Q1: the check and the
//! stop race another client starting a turn in between; the user accepted
//! that). A thread whose runtime mode T3 does not report blocks a fresh
//! start; it never defaults to a mode.
//!
//! The owner (`crate::agents::Agents`) supplies observations, new
//! identities and T3's answers, turns orders into commands, and saves each
//! reduction before the effects after its `Commit`/`Rebind` run.

use super::outbox::{self, Delivery};
use super::thread::ThreadObservation;
use super::{Command, Dispatched, Identity};
use crate::fsm::core::{Disposition, Observed, Reduction, Violation};
use serde::{Deserialize, Serialize};

fn is_zero(n: &u32) -> bool {
    *n == 0
}

fn is_queued(d: &Delivery) -> bool {
    *d == Delivery::Queued
}

/// Where an app agent is between creation, ordinary use and a reset. Each
/// operation owns its own progress and last error, so a replacement cannot
/// exist without the fresh start it belongs to.
#[derive(Clone, Serialize, Deserialize, PartialEq, Debug)]
#[serde(tag = "state", rename_all = "kebab-case")]
pub enum Lifecycle {
    /// Reserved before T3 is asked to create the thread, so a retry or a
    /// restart finishes that thread instead of creating a second agent.
    /// `command` is the creation as sent (none before the first attempt,
    /// or after T3 refused one).
    Creating {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        command: Option<Command>,
    },
    /// `refresh`: after a restart, the next turn's note carries the current
    /// instructions, because Claude restores a resumed session's original
    /// system prompt.
    Ready {
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        refresh: bool,
    },
    /// A restart or fresh start that has not begun: it runs once no turn is
    /// running (an agent cannot stop its own session while it runs, and a
    /// newer turn is never stopped), and is retried after a failure.
    ResetQueued {
        reset: Reset,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
        #[serde(default, skip_serializing_if = "is_zero")]
        failures: u32,
    },
    /// A restart whose stop is saved and sent, or about to be.
    Restarting {
        stop: Identity,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
        #[serde(default, skip_serializing_if = "is_zero")]
        failures: u32,
    },
    /// A fresh start past its first step: its identities and handoff are
    /// fixed, and each step resumes where it stood.
    Replacing {
        replacement: Replacement,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
        #[serde(default, skip_serializing_if = "is_zero")]
        failures: u32,
    },
}

/// `restart` relaunches the agent's Claude session on the same thread, so the
/// next message starts with the current plugin instructions and the same
/// history. `fresh` replaces the thread with a new one seeded by a handoff.
#[derive(Clone, Serialize, Deserialize, PartialEq, Debug)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Reset {
    Restart,
    Fresh { note: Option<String> },
}

/// A fresh start: the old and new thread, what the new one is created with
/// and told, and the step it stands at.
#[derive(Clone, Serialize, Deserialize, PartialEq, Debug)]
pub struct Replacement {
    pub previous: String,
    pub thread_id: String,
    pub model: String,
    pub runtime_mode: String,
    pub handoff: String,
    pub message_id: String,
    /// The old thread's new title.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// The request's note, kept so a fresh start that has to wait can be
    /// queued again as it was asked.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    /// None for a replacement saved before steps were: its old thread was
    /// already stopped and renamed, and `delivery` says whether its handoff
    /// may have been sent (then it is looked for before it is sent again).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub step: Option<Step>,
    #[serde(
        default,
        alias = "handoff_sent",
        deserialize_with = "outbox::delivery_or_legacy",
        skip_serializing_if = "is_queued"
    )]
    pub delivery: Delivery,
}

/// A fresh start's steps, in order, each with its command's identity.
#[derive(Clone, Serialize, Deserialize, PartialEq, Debug)]
#[serde(tag = "step", rename_all = "kebab-case")]
pub enum Step {
    /// Stopping the old thread's session.
    Stop { command: Identity },
    /// Renaming the old thread.
    Rename { command: Identity },
    /// Creating the new thread.
    Create { command: Identity },
    /// The agent, its workers and its unsent updates follow the new thread;
    /// the handoff starts its first turn.
    Handoff { command: Identity },
}

/// A command the owner builds for an order: from the lifecycle's own data
/// and the identity given.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Order {
    /// Stop the agent thread's session (a restart's, or the old thread's).
    Stop,
    /// Give the old thread its new title.
    Rename,
    /// Create the new thread.
    Create,
    /// Start the new thread's first turn with the handoff.
    Handoff,
}

#[derive(Debug)]
pub enum Event {
    /// Creation: whether T3's shell has the reserved thread, and the
    /// creation a first attempt sends.
    Create {
        exists: Observed<bool>,
        create: Command,
    },
    /// `agent restart` / `agent fresh`.
    Request(Reset),
    /// What T3 shows now: the agent's thread, and the replacement's new one.
    Look {
        agent: Observed<Option<ThreadObservation>>,
        successor: Observed<bool>,
        next: Identity,
    },
    /// A fresh start's plan (handoff and identities, without a step yet),
    /// and the agent's thread as it is right after gathering it.
    Gathered {
        plan: Result<Replacement, String>,
        agent: Observed<Option<ThreadObservation>>,
        next: Identity,
    },
    /// What sending the current step's command got.
    Sent { outcome: Dispatched, next: Identity },
    /// For a replacement saved before steps: whether the handoff is in the new thread.
    LookedUp {
        found: Result<bool, String>,
        next: Identity,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    /// Save the lifecycle. Effects after it run only once it is saved.
    Commit,
    /// Save the lifecycle together with the agent, its workers and its
    /// never-sent updates moving from the old thread to the new one.
    Rebind,
    /// Send the creation, exactly.
    SendCreate(Command),
    /// Send this order under this identity.
    Send(Order, Identity),
    /// Gather the handoff, then look at the agent's thread again.
    Gather,
    /// Look for the handoff in the new thread.
    LookUp,
    /// A turn may be running: the reset waits for it to end.
    Deferred,
    /// The operation is finished.
    Done,
    /// This attempt ends here; the operation is retried or reported.
    Failed(String),
}

const NOT_CURRENT: &str = "T3's thread list is not current; the reset is retried";
const GONE: &str = "The app agent's thread is gone";

/// The agent's thread as a reset may act on it: only a current observation.
fn now(agent: &Observed<Option<ThreadObservation>>) -> Result<&ThreadObservation, &'static str> {
    match agent {
        Observed::Current {
            value: Some(observation),
            ..
        } => Ok(observation),
        Observed::Current { value: None, .. } => Err(GONE),
        Observed::Stale { .. } | Observed::Unavailable(_) => Err(NOT_CURRENT),
    }
}

fn effects(state: Lifecycle, effects: Vec<Effect>) -> Reduction<Lifecycle, Effect> {
    Reduction::applied(state, effects)
}

/// Nothing changes; this attempt reports `detail`.
fn fail(state: Lifecycle, detail: impl Into<String>) -> Reduction<Lifecycle, Effect> {
    Reduction {
        state,
        effects: vec![Effect::Failed(detail.into())],
        disposition: Disposition::Unchanged,
    }
}

fn report(state: Lifecycle, effect: Effect) -> Reduction<Lifecycle, Effect> {
    Reduction {
        state,
        effects: vec![effect],
        disposition: Disposition::Unchanged,
    }
}

fn fault(state: Lifecycle, what: &str) -> Reduction<Lifecycle, Effect> {
    Reduction::same(state, Disposition::ProtocolFault(what.into()))
}

/// A replacement at `step`, keeping the operation's error and failures.
fn replacing(
    replacement: Replacement,
    step: Step,
    error: Option<String>,
    failures: u32,
) -> Lifecycle {
    Lifecycle::Replacing {
        replacement: Replacement {
            step: Some(step),
            delivery: Delivery::Queued,
            ..replacement
        },
        error,
        failures,
    }
}

pub fn reduce(state: Lifecycle, event: Event) -> Reduction<Lifecycle, Effect> {
    use Lifecycle::*;
    match (state, event) {
        // Creation.
        (
            Creating { .. },
            Event::Create {
                exists: Observed::Current { value: true, .. },
                ..
            },
        ) => effects(Ready { refresh: false }, vec![Effect::Commit, Effect::Done]),
        (
            Creating { command },
            Event::Create {
                exists: Observed::Current { value: false, .. },
                create,
            },
        ) => match command {
            Some(command) => effects(
                Creating {
                    command: Some(command.clone()),
                },
                vec![Effect::SendCreate(command)],
            ),
            None => effects(
                Creating {
                    command: Some(create.clone()),
                },
                vec![Effect::Commit, Effect::SendCreate(create)],
            ),
        },
        (state @ Creating { .. }, Event::Create { .. }) => {
            fail(state, "T3's thread list is not current; try again")
        }
        (
            Creating { .. },
            Event::Sent {
                outcome: Dispatched::Accepted(_),
                ..
            },
        ) => effects(Ready { refresh: false }, vec![Effect::Commit, Effect::Done]),
        (
            Creating { .. },
            Event::Sent {
                outcome: Dispatched::Refused(detail),
                ..
            },
        ) => effects(
            Creating { command: None },
            vec![Effect::Commit, Effect::Failed(detail)],
        ),
        (
            state @ Creating { .. },
            Event::Sent {
                outcome: Dispatched::NotSent(detail) | Dispatched::Unknown(detail),
                ..
            },
        ) => fail(
            state,
            format!(
                "T3 has not confirmed the app agent's thread ({detail}); try again: the same one is finished, not a second"
            ),
        ),

        // A request. A newer one replaces a queued one.
        (Ready { .. } | ResetQueued { .. }, Event::Request(reset)) => effects(
            ResetQueued {
                reset,
                error: None,
                failures: 0,
            },
            vec![Effect::Commit],
        ),
        (state @ Creating { .. }, Event::Request(_)) => Reduction {
            state,
            effects: vec![Effect::Failed(
                "The app's agent is still being created".into(),
            )],
            disposition: Disposition::NotApplicable,
        },
        (state @ Restarting { .. }, Event::Request(_)) => Reduction {
            state,
            effects: vec![Effect::Failed(
                "A restart of this agent is already under way".into(),
            )],
            disposition: Disposition::Busy,
        },
        (state @ Replacing { .. }, Event::Request(_)) => Reduction {
            state,
            effects: vec![Effect::Failed(
                "A fresh start of this agent is already under way".into(),
            )],
            disposition: Disposition::Busy,
        },

        // Nothing to do.
        (state @ (Ready { .. } | Creating { .. }), Event::Look { .. }) => {
            report(state, Effect::Done)
        }

        // Restart.
        (
            state @ ResetQueued {
                reset: Reset::Restart,
                ..
            },
            Event::Look { agent, next, .. },
        ) => match now(&agent) {
            Err(why) => fail(state, why),
            Ok(o) if o.busy() => report(state, Effect::Deferred),
            Ok(o) if o.stopped() => {
                effects(Ready { refresh: true }, vec![Effect::Commit, Effect::Done])
            }
            Ok(_) => {
                let ResetQueued {
                    error, failures, ..
                } = state
                else {
                    unreachable!()
                };
                effects(
                    Restarting {
                        stop: next.clone(),
                        error,
                        failures,
                    },
                    vec![Effect::Commit, Effect::Send(Order::Stop, next)],
                )
            }
        },
        (state @ Restarting { .. }, Event::Look { agent, .. }) => match now(&agent) {
            Err(why) => fail(state, why),
            // The stop may never have arrived; a newer turn is never stopped.
            Ok(o) if o.busy() => report(state, Effect::Deferred),
            Ok(o) if o.stopped() => {
                effects(Ready { refresh: true }, vec![Effect::Commit, Effect::Done])
            }
            Ok(_) => {
                let Restarting { stop, .. } = &state else {
                    unreachable!()
                };
                let send = Effect::Send(Order::Stop, stop.clone());
                report(state, send)
            }
        },
        (
            Restarting { .. },
            Event::Sent {
                outcome: Dispatched::Accepted(_),
                ..
            },
        ) => effects(Ready { refresh: true }, vec![Effect::Commit, Effect::Done]),
        (
            Restarting {
                error, failures, ..
            },
            Event::Sent {
                outcome: Dispatched::Refused(detail),
                ..
            },
        ) => effects(
            ResetQueued {
                reset: Reset::Restart,
                error,
                failures,
            },
            vec![Effect::Commit, Effect::Failed(detail)],
        ),
        (
            state @ Restarting { .. },
            Event::Sent {
                outcome: Dispatched::NotSent(detail) | Dispatched::Unknown(detail),
                ..
            },
        ) => fail(state, detail),

        // Fresh start: gather the handoff, then look again right before stopping.
        (
            state @ ResetQueued {
                reset: Reset::Fresh { .. },
                ..
            },
            Event::Look { agent, .. },
        ) => match now(&agent) {
            Err(why) => fail(state, why),
            Ok(o) if o.busy() => report(state, Effect::Deferred),
            Ok(_) => report(state, Effect::Gather),
        },
        (
            ResetQueued {
                reset: Reset::Fresh { note },
                error,
                failures,
            },
            Event::Gathered { plan, agent, next },
        ) => {
            let state = ResetQueued {
                reset: Reset::Fresh { note: note.clone() },
                error: error.clone(),
                failures,
            };
            let plan = match plan {
                Ok(plan) => plan,
                Err(detail) => return fail(state, detail),
            };
            match now(&agent) {
                Err(why) => fail(state, why),
                Ok(o) if o.busy() => report(state, Effect::Deferred),
                Ok(o) => {
                    let plan = Replacement {
                        note,
                        step: None,
                        delivery: Delivery::Queued,
                        ..plan
                    };
                    let (step, order) = if o.stopped() {
                        (
                            Step::Rename {
                                command: next.clone(),
                            },
                            Order::Rename,
                        )
                    } else {
                        (
                            Step::Stop {
                                command: next.clone(),
                            },
                            Order::Stop,
                        )
                    };
                    effects(
                        replacing(plan, step, error, failures),
                        vec![Effect::Commit, Effect::Send(order, next)],
                    )
                }
            }
        }

        (
            Replacing {
                replacement,
                error,
                failures,
            },
            Event::Look {
                agent,
                successor,
                next,
            },
        ) => match replacement.step.clone() {
            Some(Step::Stop { command }) => {
                let state = Replacing {
                    replacement: replacement.clone(),
                    error: error.clone(),
                    failures,
                };
                match now(&agent) {
                    Err(why) => fail(state, why),
                    // A turn started before the stop took: wait for it, then
                    // gather a handoff that includes it.
                    Ok(o) if o.busy() => effects(
                        ResetQueued {
                            reset: Reset::Fresh {
                                note: replacement.note,
                            },
                            error,
                            failures,
                        },
                        vec![Effect::Commit, Effect::Deferred],
                    ),
                    Ok(o) if o.stopped() => effects(
                        replacing(
                            replacement,
                            Step::Rename {
                                command: next.clone(),
                            },
                            error,
                            failures,
                        ),
                        vec![Effect::Commit, Effect::Send(Order::Rename, next)],
                    ),
                    Ok(_) => report(state, Effect::Send(Order::Stop, command)),
                }
            }
            Some(Step::Rename { command }) => report(
                Replacing {
                    replacement,
                    error,
                    failures,
                },
                Effect::Send(Order::Rename, command),
            ),
            Some(Step::Create { command }) => match successor {
                Observed::Current { value: true, .. } => effects(
                    replacing(
                        replacement,
                        Step::Handoff {
                            command: next.clone(),
                        },
                        error,
                        failures,
                    ),
                    vec![Effect::Rebind, Effect::Send(Order::Handoff, next)],
                ),
                Observed::Current { value: false, .. } => report(
                    Replacing {
                        replacement,
                        error,
                        failures,
                    },
                    Effect::Send(Order::Create, command),
                ),
                _ => fail(
                    Replacing {
                        replacement,
                        error,
                        failures,
                    },
                    NOT_CURRENT,
                ),
            },
            Some(Step::Handoff { command }) => report(
                Replacing {
                    replacement,
                    error,
                    failures,
                },
                Effect::Send(Order::Handoff, command),
            ),
            // Saved before steps: stopped and renamed already.
            None => match successor {
                Observed::Current { value: true, .. }
                    if replacement.delivery == Delivery::OutcomeUnknown =>
                {
                    effects(
                        Replacing {
                            replacement,
                            error,
                            failures,
                        },
                        vec![Effect::Rebind, Effect::LookUp],
                    )
                }
                Observed::Current { value: true, .. } => effects(
                    replacing(
                        replacement,
                        Step::Handoff {
                            command: next.clone(),
                        },
                        error,
                        failures,
                    ),
                    vec![Effect::Rebind, Effect::Send(Order::Handoff, next)],
                ),
                Observed::Current { value: false, .. } => effects(
                    replacing(
                        replacement,
                        Step::Create {
                            command: next.clone(),
                        },
                        error,
                        failures,
                    ),
                    vec![Effect::Commit, Effect::Send(Order::Create, next)],
                ),
                _ => fail(
                    Replacing {
                        replacement,
                        error,
                        failures,
                    },
                    NOT_CURRENT,
                ),
            },
        },

        (
            Replacing {
                replacement,
                error,
                failures,
            },
            Event::Sent { outcome, next },
        ) => {
            let Some(step) = replacement.step.clone() else {
                return fault(
                    Replacing {
                        replacement,
                        error,
                        failures,
                    },
                    "a send answered for a replacement without a step",
                );
            };
            match outcome {
                Dispatched::Accepted(_) => match step {
                    Step::Stop { .. } => effects(
                        replacing(
                            replacement,
                            Step::Rename {
                                command: next.clone(),
                            },
                            error,
                            failures,
                        ),
                        vec![Effect::Commit, Effect::Send(Order::Rename, next)],
                    ),
                    Step::Rename { .. } => effects(
                        replacing(
                            replacement,
                            Step::Create {
                                command: next.clone(),
                            },
                            error,
                            failures,
                        ),
                        vec![Effect::Commit, Effect::Send(Order::Create, next)],
                    ),
                    Step::Create { .. } => effects(
                        replacing(
                            replacement,
                            Step::Handoff {
                                command: next.clone(),
                            },
                            error,
                            failures,
                        ),
                        vec![Effect::Rebind, Effect::Send(Order::Handoff, next)],
                    ),
                    Step::Handoff { .. } => {
                        effects(Ready { refresh: false }, vec![Effect::Commit, Effect::Done])
                    }
                },
                // T3 said no: nothing of this step happened. A refused stop
                // ends the attempt before anything changed; any later step
                // tries again under a new identity.
                Dispatched::Refused(detail) => match step {
                    Step::Stop { .. } => effects(
                        ResetQueued {
                            reset: Reset::Fresh {
                                note: replacement.note,
                            },
                            error,
                            failures,
                        },
                        vec![Effect::Commit, Effect::Failed(detail)],
                    ),
                    Step::Rename { .. } => effects(
                        replacing(replacement, Step::Rename { command: next }, error, failures),
                        vec![Effect::Commit, Effect::Failed(detail)],
                    ),
                    Step::Create { .. } => effects(
                        replacing(replacement, Step::Create { command: next }, error, failures),
                        vec![Effect::Commit, Effect::Failed(detail)],
                    ),
                    Step::Handoff { .. } => effects(
                        replacing(
                            replacement,
                            Step::Handoff { command: next },
                            error,
                            failures,
                        ),
                        vec![Effect::Commit, Effect::Failed(detail)],
                    ),
                },
                Dispatched::NotSent(detail) | Dispatched::Unknown(detail) => fail(
                    Replacing {
                        replacement,
                        error,
                        failures,
                    },
                    detail,
                ),
            }
        }

        (
            Replacing {
                replacement,
                error,
                failures,
            },
            Event::LookedUp { found, next },
        ) if replacement.step.is_none() => match found {
            Ok(true) => effects(Ready { refresh: false }, vec![Effect::Commit, Effect::Done]),
            Ok(false) => effects(
                replacing(
                    replacement,
                    Step::Handoff {
                        command: next.clone(),
                    },
                    error,
                    failures,
                ),
                vec![Effect::Commit, Effect::Send(Order::Handoff, next)],
            ),
            Err(detail) => fail(
                Replacing {
                    replacement,
                    error,
                    failures,
                },
                detail,
            ),
        },

        (state, Event::Gathered { .. }) => {
            fault(state, "a handoff gathered outside a queued fresh start")
        }
        (state, Event::Sent { .. }) => fault(state, "a send answered with nothing sent"),
        (state, Event::LookedUp { .. }) => {
            fault(state, "a look-up answered with nothing looked for")
        }
        (state, Event::Create { .. }) => Reduction {
            state,
            effects: vec![],
            disposition: Disposition::NotApplicable,
        },
    }
}

/// What must hold for one lifecycle.
pub fn violations(state: &Lifecycle) -> Vec<Violation> {
    let mut found = vec![];
    if let Lifecycle::Replacing { replacement, .. } = state {
        if replacement.previous == replacement.thread_id {
            found.push(Violation(
                "a replacement replaces its thread with itself".into(),
            ));
        }
        if replacement.step.is_some() && replacement.delivery != Delivery::Queued {
            found.push(Violation(
                "a stepped replacement carries a legacy delivery".into(),
            ));
        }
    }
    if let Lifecycle::Creating {
        command: Some(command),
    } = state
        && command.id().is_none()
    {
        found.push(Violation("a saved creation has no identity".into()));
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fsm::coordinator::thread::Execution;
    use crate::fsm::core::{CommandID, Epoch, Revision};
    use serde_json::json;

    fn id(n: u8) -> Identity {
        Identity {
            id: CommandID::parse(&format!("00000000-0000-4000-8000-0000000000{n:02}")).unwrap(),
            created_at: format!("t{n}"),
        }
    }

    fn current<T>(value: T) -> Observed<T> {
        Observed::Current {
            epoch: Epoch(1),
            revision: Revision(0),
            value,
        }
    }

    fn agent(execution: Execution) -> Observed<Option<ThreadObservation>> {
        current(Some(ThreadObservation {
            turn: Some("t".into()),
            execution,
            waiting: false,
            failed: false,
            archived: false,
        }))
    }

    fn look(
        state: Lifecycle,
        execution: Execution,
        successor: bool,
        n: u8,
    ) -> Reduction<Lifecycle, Effect> {
        reduce(
            state,
            Event::Look {
                agent: agent(execution),
                successor: current(successor),
                next: id(n),
            },
        )
    }

    fn sent(state: Lifecycle, outcome: Dispatched, n: u8) -> Reduction<Lifecycle, Effect> {
        reduce(
            state,
            Event::Sent {
                outcome,
                next: id(n),
            },
        )
    }

    fn accepted() -> Dispatched {
        Dispatched::Accepted(json!({"sequence": 1}))
    }

    fn plan() -> Replacement {
        Replacement {
            previous: "old".into(),
            thread_id: "new".into(),
            model: "m".into(),
            runtime_mode: "auto".into(),
            handoff: "h".into(),
            message_id: "m1".into(),
            title: Some("App agent (until Oct 16)".into()),
            note: None,
            step: None,
            delivery: Delivery::Queued,
        }
    }

    fn fresh() -> Lifecycle {
        Lifecycle::ResetQueued {
            reset: Reset::Fresh {
                note: Some("n".into()),
            },
            error: None,
            failures: 0,
        }
    }

    /// A fresh start through every step, with the answer of each lost once:
    /// each step's identity is saved before it is sent and sent again
    /// unchanged until T3 answers, and the agent is rebound in the same save
    /// that starts the handoff.
    #[test]
    fn each_step_of_a_fresh_start_keeps_its_identity_until_answered() {
        let gather = look(fresh(), Execution::Idle, false, 1);
        assert_eq!(gather.effects, vec![Effect::Gather]);
        let stop = reduce(
            gather.state,
            Event::Gathered {
                plan: Ok(plan()),
                agent: agent(Execution::Idle),
                next: id(2),
            },
        );
        assert_eq!(
            stop.effects,
            vec![Effect::Commit, Effect::Send(Order::Stop, id(2))]
        );
        // The stop's answer is lost; the old thread now shows stopped.
        let lost = sent(stop.state, Dispatched::Unknown("closed".into()), 3);
        assert!(matches!(lost.effects[..], [Effect::Failed(_)]));
        let rename = look(lost.state, Execution::Stopped, false, 4);
        assert_eq!(
            rename.effects,
            vec![Effect::Commit, Effect::Send(Order::Rename, id(4))]
        );
        // A restart while renaming sends the same rename again.
        assert_eq!(
            look(rename.state.clone(), Execution::Stopped, false, 5).effects,
            vec![Effect::Send(Order::Rename, id(4))]
        );
        let create = sent(rename.state, accepted(), 6);
        assert_eq!(
            create.effects,
            vec![Effect::Commit, Effect::Send(Order::Create, id(6))]
        );
        let lost = sent(create.state, Dispatched::Unknown("closed".into()), 7);
        // The new thread hasn't shown up: the same creation goes again.
        assert_eq!(
            look(lost.state.clone(), Execution::Stopped, false, 8).effects,
            vec![Effect::Send(Order::Create, id(6))]
        );
        // It has: rebind and hand off, without creating anything.
        let handoff = look(lost.state, Execution::Stopped, true, 9);
        assert_eq!(
            handoff.effects,
            vec![Effect::Rebind, Effect::Send(Order::Handoff, id(9))]
        );
        let refused = sent(handoff.state, Dispatched::Refused("no".into()), 10);
        assert_eq!(
            refused.effects,
            vec![Effect::Commit, Effect::Failed("no".into())]
        );
        // Only a refusal changes an identity.
        assert_eq!(
            look(refused.state.clone(), Execution::Idle, true, 11).effects,
            vec![Effect::Send(Order::Handoff, id(10))]
        );
        let done = sent(refused.state, accepted(), 12);
        assert_eq!(
            (done.state, done.effects),
            (
                Lifecycle::Ready { refresh: false },
                vec![Effect::Commit, Effect::Done]
            )
        );
    }

    /// Nothing destructive happens on a busy, unknown or stale observation,
    /// and a turn that starts before the stop took sends the request back to
    /// the queue with its note.
    #[test]
    fn a_reset_never_acts_on_a_running_turn_or_an_old_observation() {
        for execution in [Execution::Running, Execution::Unknown] {
            assert_eq!(
                look(fresh(), execution, false, 1).effects,
                vec![Effect::Deferred]
            );
            let restart = Lifecycle::ResetQueued {
                reset: Reset::Restart,
                error: None,
                failures: 0,
            };
            assert_eq!(
                look(restart, execution, false, 1).effects,
                vec![Effect::Deferred]
            );
        }
        let stale = Observed::Stale {
            epoch: Epoch(1),
            revision: Revision(0),
            last: Some(None),
        };
        let deferred = reduce(
            fresh(),
            Event::Look {
                agent: stale,
                successor: current(false),
                next: id(1),
            },
        );
        assert_eq!(deferred.effects, vec![Effect::Failed(NOT_CURRENT.into())]);
        // The handoff took a while and a turn started meanwhile.
        let busy = reduce(
            fresh(),
            Event::Gathered {
                plan: Ok(plan()),
                agent: agent(Execution::Running),
                next: id(2),
            },
        );
        assert_eq!(
            (busy.state, busy.effects),
            (fresh(), vec![Effect::Deferred])
        );
        let stopping = reduce(
            fresh(),
            Event::Gathered {
                plan: Ok(plan()),
                agent: agent(Execution::Idle),
                next: id(2),
            },
        )
        .state;
        let requeued = look(stopping, Execution::Running, false, 3);
        assert_eq!(requeued.effects, vec![Effect::Commit, Effect::Deferred]);
        assert_eq!(requeued.state, fresh());
        // A restart whose stop's answer was lost waits out a newer turn, then stops with the same command.
        let restarting = Lifecycle::Restarting {
            stop: id(4),
            error: None,
            failures: 0,
        };
        assert_eq!(
            look(restarting.clone(), Execution::Running, false, 5).effects,
            vec![Effect::Deferred]
        );
        assert_eq!(
            look(restarting.clone(), Execution::Idle, false, 5).effects,
            vec![Effect::Send(Order::Stop, id(4))]
        );
        assert_eq!(
            look(restarting, Execution::Stopped, false, 5).state,
            Lifecycle::Ready { refresh: true }
        );
    }

    /// A replacement saved before steps were (stopped and renamed, its
    /// handoff possibly sent without an identity) finishes without sending
    /// the handoff twice.
    #[test]
    fn a_replacement_from_before_steps_resumes_at_creation() {
        let legacy: Lifecycle = serde_json::from_value(json!({"state": "replacing", "replacement": {
            "previous": "old", "thread_id": "new", "model": "m", "runtime_mode": "auto", "handoff": "h", "message_id": "m1", "handoff_sent": true}})).unwrap();
        let found = look(legacy.clone(), Execution::Stopped, true, 1);
        assert_eq!(found.effects, vec![Effect::Rebind, Effect::LookUp]);
        let done = reduce(
            found.state.clone(),
            Event::LookedUp {
                found: Ok(true),
                next: id(2),
            },
        );
        assert_eq!(done.state, Lifecycle::Ready { refresh: false });
        let absent = reduce(
            found.state,
            Event::LookedUp {
                found: Ok(false),
                next: id(2),
            },
        );
        assert_eq!(
            absent.effects,
            vec![Effect::Commit, Effect::Send(Order::Handoff, id(2))]
        );
        let Lifecycle::Replacing { replacement, .. } = &absent.state else {
            panic!()
        };
        assert!(violations(&absent.state).is_empty(), "{replacement:?}");
    }

    #[test]
    fn a_creation_is_sent_again_as_itself_until_t3_refuses_it() {
        let create =
            |n: u8| Command::new(&id(n), json!({"type": "thread.create", "threadId": "a"}));
        let first = reduce(
            Lifecycle::Creating { command: None },
            Event::Create {
                exists: current(false),
                create: create(1),
            },
        );
        assert_eq!(
            first.effects,
            vec![Effect::Commit, Effect::SendCreate(create(1))]
        );
        let lost = sent(first.state, Dispatched::Unknown("closed".into()), 2);
        let again = reduce(
            lost.state,
            Event::Create {
                exists: current(false),
                create: create(3),
            },
        );
        assert_eq!(again.effects, vec![Effect::SendCreate(create(1))]);
        let refused = sent(again.state, Dispatched::Refused("no".into()), 4);
        assert_eq!(refused.state, Lifecycle::Creating { command: None });
        let shown = reduce(
            refused.state,
            Event::Create {
                exists: current(true),
                create: create(5),
            },
        );
        assert_eq!(shown.state, Lifecycle::Ready { refresh: false });
    }
}
