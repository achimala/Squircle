//! M14, an app agent's creation and restart (docs/fsm-architecture.md). The
//! agent keeps one T3 thread for good; a restart relaunches its session on
//! that thread, optionally on another provider or model (T3's
//! `provider.switch` or `thread.model-selection.set`, which end the old
//! session themselves). Every step that changes T3 is saved, with the exact identity
//! of the command it sends, before that command goes out; a step whose
//! answer is lost is sent again under the same identity (T3 answers a known
//! ID from its receipt), and a new identity is made only after T3 refused
//! one. So a crash or a lost answer at any point resumes the same
//! operation, never a second agent or stop.
//!
//! Nothing is stopped while a turn may be running (Q1: the check and the
//! stop race another client starting a turn in between; the user accepted
//! that).
//!
//! The owner (`crate::agents::Agents`) supplies observations, new
//! identities and T3's answers, turns orders into commands, and saves each
//! reduction before the effects after its `Commit` run.

use super::thread::ThreadObservation;
use super::{Command, Dispatched, Identity};
use crate::fsm::core::{Disposition, Observed, Reduction, Violation};
use serde::{Deserialize, Serialize};

fn is_zero(n: &u32) -> bool {
    *n == 0
}

/// A restart's switch: the T3 command body (`provider.switch` or
/// `thread.model-selection.set`, with its thread and model selection) sent
/// instead of a stop, decided when the restart was asked for.
pub type Switch = serde_json::Value;

/// Where an app agent is between creation, ordinary use and a restart.
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
    /// A restart that has not begun: it runs once no turn is running (an
    /// agent cannot stop its own session while it runs, and a newer turn is
    /// never stopped), and is retried after a failure.
    RestartQueued {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
        #[serde(default, skip_serializing_if = "is_zero")]
        failures: u32,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        switch: Option<Switch>,
    },
    /// A restart whose stop (or switch, under the same identity) is saved
    /// and sent, or about to be.
    Restarting {
        stop: Identity,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
        #[serde(default, skip_serializing_if = "is_zero")]
        failures: u32,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        switch: Option<Switch>,
    },
}

#[derive(Debug)]
pub enum Event {
    /// Creation: whether T3's shell has the reserved thread, and the
    /// creation a first attempt sends.
    Create {
        exists: Observed<bool>,
        create: Command,
    },
    /// `agent restart`, with the switch to another provider or model if
    /// one was asked for.
    Restart { switch: Option<Switch> },
    /// What T3 shows of the agent's thread now.
    Look {
        agent: Observed<Option<ThreadObservation>>,
        next: Identity,
    },
    /// What sending the current step's command got.
    Sent { outcome: Dispatched, next: Identity },
}

#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    /// Save the lifecycle. Effects after it run only once it is saved.
    Commit,
    /// Send the creation, exactly.
    SendCreate(Command),
    /// Stop the agent thread's session under this identity.
    Stop(Identity),
    /// Send this switch under this identity.
    Switch(Identity, Switch),
    /// A turn may be running: the restart waits for it to end.
    Deferred,
    /// The operation is finished.
    Done,
    /// This attempt ends here; the operation is retried or reported.
    Failed(String),
}

const NOT_CURRENT: &str = "T3's thread list is not current; the restart is retried";
const GONE: &str = "The app agent's thread is gone";

/// The agent's thread as a restart may act on it: only a current observation.
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

        // A request. One already queued stays as it is.
        (Ready { .. }, Event::Restart { switch }) => effects(
            RestartQueued {
                error: None,
                failures: 0,
                switch,
            },
            vec![Effect::Commit],
        ),
        // A queued restart takes the newest switch asked for.
        (
            RestartQueued {
                error, failures, ..
            },
            Event::Restart {
                switch: Some(switch),
            },
        ) => effects(
            RestartQueued {
                error,
                failures,
                switch: Some(switch),
            },
            vec![Effect::Commit],
        ),
        (state @ RestartQueued { .. }, Event::Restart { switch: None }) => {
            Reduction::same(state, Disposition::Duplicate)
        }
        (state @ Creating { .. }, Event::Restart { .. }) => Reduction {
            state,
            effects: vec![Effect::Failed(
                "The app's agent is still being created".into(),
            )],
            disposition: Disposition::NotApplicable,
        },
        (state @ Restarting { .. }, Event::Restart { .. }) => Reduction {
            state,
            effects: vec![Effect::Failed(
                "A restart of this agent is already under way".into(),
            )],
            disposition: Disposition::Busy,
        },

        // Nothing to do.
        (state @ (Ready { .. } | Creating { .. }), Event::Look { .. }) => {
            report(state, Effect::Done)
        }

        // Restart.
        (state @ RestartQueued { .. }, Event::Look { agent, next }) => match now(&agent) {
            Err(why) => fail(state, why),
            Ok(o) if o.busy() => report(state, Effect::Deferred),
            // A switch is sent whether or not a session is attached.
            Ok(o)
                if o.stopped()
                    && !matches!(
                        state,
                        RestartQueued {
                            switch: Some(_),
                            ..
                        }
                    ) =>
            {
                effects(Ready { refresh: true }, vec![Effect::Commit, Effect::Done])
            }
            Ok(_) => {
                let RestartQueued {
                    error,
                    failures,
                    switch,
                } = state
                else {
                    unreachable!()
                };
                let send = match &switch {
                    Some(body) => Effect::Switch(next.clone(), body.clone()),
                    None => Effect::Stop(next.clone()),
                };
                effects(
                    Restarting {
                        stop: next,
                        error,
                        failures,
                        switch,
                    },
                    vec![Effect::Commit, send],
                )
            }
        },
        (state @ Restarting { .. }, Event::Look { agent, .. }) => match now(&agent) {
            Err(why) => fail(state, why),
            // The stop may never have arrived; a newer turn is never stopped.
            Ok(o) if o.busy() => report(state, Effect::Deferred),
            // A switch is sent again under its identity: T3 answers one it
            // already took from its receipt.
            Ok(_)
                if matches!(
                    state,
                    Restarting {
                        switch: Some(_),
                        ..
                    }
                ) =>
            {
                let Restarting {
                    stop,
                    switch: Some(body),
                    ..
                } = &state
                else {
                    unreachable!()
                };
                let send = Effect::Switch(stop.clone(), body.clone());
                report(state, send)
            }
            Ok(o) if o.stopped() => {
                effects(Ready { refresh: true }, vec![Effect::Commit, Effect::Done])
            }
            Ok(_) => {
                let Restarting { stop, .. } = &state else {
                    unreachable!()
                };
                let send = Effect::Stop(stop.clone());
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
        // A refused switch is dropped, not retried: the agent stays where it is.
        (
            Restarting {
                switch: Some(_), ..
            },
            Event::Sent {
                outcome: Dispatched::Refused(detail),
                ..
            },
        ) => effects(
            Ready { refresh: false },
            vec![Effect::Commit, Effect::Failed(detail)],
        ),
        (
            Restarting {
                error, failures, ..
            },
            Event::Sent {
                outcome: Dispatched::Refused(detail),
                ..
            },
        ) => effects(
            RestartQueued {
                error,
                failures,
                switch: None,
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

        (state, Event::Sent { .. }) => fault(state, "a send answered with nothing sent"),
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
    if let Lifecycle::Creating {
        command: Some(command),
    } = state
        && command.id().is_none()
    {
        found.push(Violation("a saved creation has no identity".into()));
    }
    found
}
