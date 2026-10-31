//! M15, a worker's bootstrap and archive (docs/fsm-architecture.md).
//!
//! A bootstrap can't be deduplicated by command ID: T3 prepares the
//! worktree and creates the thread before its receipt check (Q2). So it is
//! saved before it is sent, and an unconfirmed one is settled by looking:
//! the thread in T3's current shell, or its first message, proves it
//! landed; only then is it sent again, never automatically.
//!
//! Archiving is a journal: each step is saved before it acts (the stop and
//! T3's archive with the identity of their command), so a crash or a lost
//! answer resumes where it stood or reports what is left, never removes
//! files of a worker not shown stopped, and never loses the fact that
//! files were removed.

use super::thread::ThreadObservation;
use super::{Dispatched, Identity};
use crate::fsm::core::{Disposition, Observed, Reduction};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// A worker from the moment it is reserved until T3 has archived it.
#[derive(Clone, Serialize, Deserialize, PartialEq, Debug, Default)]
#[serde(rename_all = "kebab-case")]
pub enum Stage {
    /// Recorded before T3 is asked to create the thread. Until T3 shows the
    /// thread, the same bootstrap (same thread and message IDs) is sent
    /// again only when asked, never a second worker.
    Bootstrapping {
        message_id: String,
        command: Value,
    },
    #[default]
    Active,
    /// Being archived; see `ArchiveStep`.
    Archiving(ArchiveStep),
    /// Its session was confirmed stopped and its files removed; T3 has not
    /// been asked to archive the thread yet.
    FilesRemoved,
    Archived,
}

impl Stage {
    /// Owned by its coordinator: shown on the board and woken about.
    pub fn live(&self) -> bool {
        matches!(self, Stage::Bootstrapping { .. } | Stage::Active)
    }
}

/// How far an archive got.
#[derive(Clone, Serialize, Deserialize, PartialEq, Debug)]
#[serde(tag = "step", rename_all = "kebab-case")]
pub enum ArchiveStep {
    /// Its session's stop is saved and sent, or about to be. Nothing removed.
    Stopping { command: Identity },
    /// Shown stopped and its Git state allowed it: its worktree and branch
    /// are being removed, possibly in part already.
    Removing,
    /// Its files are gone; T3's archive of the thread is saved and sent, or
    /// about to be.
    Thread { command: Identity },
}

// MARK: Bootstrap

#[derive(Debug)]
pub enum BootEvent {
    /// Spawn asked again for a reserved worker: whether T3's shell has its thread.
    Look { thread: Observed<bool> },
    /// What sending the bootstrap got.
    Sent(Dispatched),
    /// After an unconfirmed send (`detail`): whether T3 shows the thread or
    /// its first message, or why that couldn't be read.
    Confirmed {
        found: Result<bool, String>,
        detail: String,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub enum BootEffect {
    /// Save the worker as active.
    Commit,
    /// Send the saved bootstrap, under a new identity.
    Send,
    /// Look for the thread or its first message; answer with `Confirmed`.
    Confirm(String),
    Done,
    Failed(String),
}

pub fn bootstrap(stage: Stage, event: BootEvent) -> Reduction<Stage, BootEffect> {
    use Disposition::*;
    if !matches!(stage, Stage::Bootstrapping { .. }) {
        return Reduction {
            state: stage,
            effects: vec![BootEffect::Done],
            disposition: Unchanged,
        };
    }
    let report = |stage, effect| Reduction {
        state: stage,
        effects: vec![effect],
        disposition: Unchanged,
    };
    match event {
        BootEvent::Look {
            thread: Observed::Current { value: true, .. },
        }
        | BootEvent::Sent(Dispatched::Accepted(_))
        | BootEvent::Confirmed {
            found: Ok(true), ..
        } => Reduction::applied(Stage::Active, vec![BootEffect::Commit, BootEffect::Done]),
        BootEvent::Look {
            thread: Observed::Current { value: false, .. },
        } => report(stage, BootEffect::Send),
        BootEvent::Look { .. } => report(
            stage,
            BootEffect::Failed("T3's thread list is not current; try again".into()),
        ),
        BootEvent::Sent(
            Dispatched::Refused(detail) | Dispatched::NotSent(detail) | Dispatched::Unknown(detail),
        ) => report(stage, BootEffect::Confirm(detail)),
        BootEvent::Confirmed {
            found: Ok(false),
            detail,
        } => report(
            stage,
            BootEffect::Failed(format!(
                "{detail}: T3 did not confirm the new worker. Run the same `thread spawn` again to finish this one; it will not start a second"
            )),
        ),
        BootEvent::Confirmed {
            found: Err(error),
            detail,
        } => report(
            stage,
            BootEffect::Failed(format!(
                "{detail}, and its thread couldn't be read to check ({error}). Run the same `thread spawn` again to finish this one; it will not start a second"
            )),
        ),
    }
}

// MARK: Archive

#[derive(Debug)]
pub enum ArchiveEvent {
    /// What T3 shows now (`Current(None)`: no such thread) and what the
    /// request allows; `next` is a new identity, used only if a step needs one.
    Look {
        thread: Observed<Option<ThreadObservation>>,
        discard: bool,
        next: Identity,
    },
    /// What sending the current step's command got.
    Sent { outcome: Dispatched, next: Identity },
    /// Whether T3 showed no run in progress after the stop was accepted
    /// (false: the connection went down first).
    Stopped(bool),
    /// What would stop removal without `discard` (none: merged and clean).
    Inspected {
        blocker: Result<Option<String>, String>,
        discard: bool,
    },
    /// The worktree and branch were removed, or why not all of them.
    Removed(Result<(), String>),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ArchiveOrder {
    Stop,
    Archive,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ArchiveEffect {
    /// Save the stage. Effects after it run only once it is saved.
    Commit,
    Send(ArchiveOrder, Identity),
    /// Wait for T3 to show no run in progress; answer with `Stopped`.
    AwaitStopped,
    /// Inspect the worktree and branch; answer with `Inspected`.
    Inspect,
    /// Remove what was inspected, on a stop receipt taken right then;
    /// answer with `Removed`, then look again.
    Remove,
    /// Look at T3's shell again.
    Look,
    /// Not archived, and nothing (more) was changed: the caller's answer.
    Refused(String),
    /// This attempt ends here; running archive again resumes it.
    Failed(String),
    /// Archived.
    Done,
    /// A reservation T3 never created: dropped without touching Git.
    NeverStarted,
}

fn report(stage: Stage, effect: ArchiveEffect) -> Reduction<Stage, ArchiveEffect> {
    Reduction {
        state: stage,
        effects: vec![effect],
        disposition: Disposition::Unchanged,
    }
}

fn to(stage: Stage, effects: Vec<ArchiveEffect>) -> Reduction<Stage, ArchiveEffect> {
    Reduction::applied(stage, effects)
}

const NOT_CURRENT: &str = "T3's thread list is not current; try again";

/// The live session must stop before anything is removed; one whose turn
/// may still be running only when its work may be discarded.
fn stop_first(
    stage: Stage,
    observation: &ThreadObservation,
    discard: bool,
    command: Identity,
    saved: bool,
) -> Reduction<Stage, ArchiveEffect> {
    if observation.busy() && !discard {
        let what = if observation.waiting {
            "waiting on a question or approval"
        } else {
            "still working"
        };
        return report(
            stage,
            ArchiveEffect::Refused(format!(
                "That worker is {what}; wait for it, or pass --discard to stop it and drop its work"
            )),
        );
    }
    let send = ArchiveEffect::Send(ArchiveOrder::Stop, command.clone());
    if saved {
        report(stage, send)
    } else {
        to(
            Stage::Archiving(ArchiveStep::Stopping { command }),
            vec![ArchiveEffect::Commit, send],
        )
    }
}

/// One step of archiving. The stage is the worker's (an unregistered T3
/// thread is archived as an `Active` stage that is never saved).
pub fn archive(stage: Stage, event: ArchiveEvent) -> Reduction<Stage, ArchiveEffect> {
    use ArchiveEffect as E;
    use ArchiveStep as S;
    match (stage, event) {
        (
            stage,
            ArchiveEvent::Look {
                thread: Observed::Stale { .. } | Observed::Unavailable(_),
                ..
            },
        ) => report(stage, E::Failed(NOT_CURRENT.into())),
        (
            Stage::Bootstrapping { .. },
            ArchiveEvent::Look {
                thread: Observed::Current { value: None, .. },
                ..
            },
        ) => to(Stage::Archived, vec![E::Commit, E::NeverStarted]),

        // Before anything is removed: stop, then inspect.
        (
            stage @ (Stage::Bootstrapping { .. }
            | Stage::Active
            | Stage::Archived
            | Stage::Archiving(S::Removing)),
            ArchiveEvent::Look {
                thread: Observed::Current { value, .. },
                discard,
                next,
            },
        ) => match value {
            Some(o) if !o.stopped() => stop_first(stage, &o, discard, next, false),
            _ => report(stage, E::Inspect),
        },
        (
            stage @ Stage::Archiving(S::Stopping { .. }),
            ArchiveEvent::Look {
                thread: Observed::Current { value, .. },
                discard,
                ..
            },
        ) => {
            let Stage::Archiving(S::Stopping { command }) = &stage else {
                unreachable!()
            };
            let command = command.clone();
            match value {
                Some(o) if !o.stopped() => stop_first(stage, &o, discard, command, true),
                _ => report(stage, E::Inspect),
            }
        }
        (stage @ Stage::Archiving(S::Stopping { .. }), ArchiveEvent::Sent { outcome, next }) => {
            match outcome {
                // That stop is done: a further one (a run interrupted, then
                // its session detached) is its own command.
                Dispatched::Accepted(_) => to(
                    Stage::Archiving(S::Stopping { command: next }),
                    vec![E::Commit, E::AwaitStopped],
                ),
                Dispatched::Refused(detail) => {
                    to(Stage::Active, vec![E::Commit, E::Failed(detail)])
                }
                Dispatched::NotSent(detail) | Dispatched::Unknown(detail) => report(
                    stage,
                    E::Failed(format!(
                        "T3 has not confirmed the stop ({detail}); nothing was removed. Run archive again"
                    )),
                ),
            }
        }
        // No run now; look again, at its session too.
        (stage @ Stage::Archiving(S::Stopping { .. }), ArchiveEvent::Stopped(true)) => {
            report(stage, E::Look)
        }
        (stage @ Stage::Archiving(S::Stopping { .. }), ArchiveEvent::Stopped(false)) => report(
            stage,
            E::Failed("T3 disconnected before the worker stopped; nothing was removed".into()),
        ),

        (
            stage @ (Stage::Bootstrapping { .. }
            | Stage::Active
            | Stage::Archived
            | Stage::Archiving(S::Stopping { .. } | S::Removing)),
            ArchiveEvent::Inspected { blocker, discard },
        ) => match blocker {
            Err(detail) => report(stage, E::Failed(detail)),
            Ok(Some(reason)) if !discard => {
                let refused = E::Refused(format!(
                    "Not archived: {reason}. Merge it first, or pass --discard to drop that work"
                ));
                // A stopped worker is still a worker; an archived one stays archived.
                match stage {
                    Stage::Archived | Stage::Active => report(stage, refused),
                    _ => to(Stage::Active, vec![E::Commit, refused]),
                }
            }
            Ok(_) if stage == Stage::Archiving(S::Removing) => report(stage, E::Remove),
            Ok(_) => to(Stage::Archiving(S::Removing), vec![E::Commit, E::Remove]),
        },
        (stage @ Stage::Archiving(S::Removing), ArchiveEvent::Removed(result)) => match result {
            Ok(()) => to(Stage::FilesRemoved, vec![E::Commit, E::Look]),
            Err(detail) => report(
                stage,
                E::Failed(format!(
                    "{detail}; its files were not all removed. Run archive again"
                )),
            ),
        },

        // Files gone: archive the thread in T3.
        (
            stage @ (Stage::FilesRemoved | Stage::Archiving(S::Thread { .. })),
            ArchiveEvent::Look {
                thread: Observed::Current { value, .. },
                next,
                ..
            },
        ) => match (value, &stage) {
            (Some(o), Stage::Archiving(S::Thread { command })) if !o.archived => {
                let send = E::Send(ArchiveOrder::Archive, command.clone());
                report(stage, send)
            }
            (Some(o), _) if !o.archived => to(
                Stage::Archiving(S::Thread {
                    command: next.clone(),
                }),
                vec![E::Commit, E::Send(ArchiveOrder::Archive, next)],
            ),
            _ => to(Stage::Archived, vec![E::Commit, E::Done]),
        },
        (stage @ Stage::Archiving(S::Thread { .. }), ArchiveEvent::Sent { outcome, next }) => {
            let not = |detail: &str| {
                format!(
                    "Its files were removed, but T3 did not archive the thread ({detail}); run archive again"
                )
            };
            match outcome {
                Dispatched::Accepted(_) => to(Stage::Archived, vec![E::Commit, E::Done]),
                Dispatched::Refused(detail) => to(
                    Stage::Archiving(S::Thread { command: next }),
                    vec![E::Commit, E::Failed(not(&detail))],
                ),
                Dispatched::NotSent(detail) | Dispatched::Unknown(detail) => {
                    report(stage, E::Failed(not(&detail)))
                }
            }
        }

        (stage, event) => Reduction::same(
            stage,
            Disposition::ProtocolFault(format!("archive event {event:?} at this stage")),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fsm::coordinator::thread::Execution;
    use crate::fsm::core::{CommandID, Epoch, Revision};

    fn id(n: u8) -> Identity {
        Identity {
            id: CommandID::parse(&format!("00000000-0000-4000-8000-0000000000{n:02}")).unwrap(),
            created_at: format!("t{n}"),
        }
    }

    fn seen(
        execution: Execution,
        waiting: bool,
        archived: bool,
    ) -> Observed<Option<ThreadObservation>> {
        Observed::Current {
            epoch: Epoch(1),
            revision: Revision(0),
            value: Some(ThreadObservation {
                turn: Some("t".into()),
                execution,
                waiting,
                failed: false,
                archived,
            }),
        }
    }

    fn look(
        stage: Stage,
        thread: Observed<Option<ThreadObservation>>,
        discard: bool,
        n: u8,
    ) -> Reduction<Stage, ArchiveEffect> {
        archive(
            stage,
            ArchiveEvent::Look {
                thread,
                discard,
                next: id(n),
            },
        )
    }

    /// An archive cut at each step resumes from its saved step: the stop and
    /// T3's archive go again under their saved identities, nothing is removed
    /// before T3 shows the session stopped, and removed files stay recorded.
    #[test]
    fn an_archive_resumes_from_each_saved_step() {
        use ArchiveEffect as E;
        let stop = look(Stage::Active, seen(Execution::Idle, false, false), false, 1);
        assert_eq!(
            stop.effects,
            vec![E::Commit, E::Send(ArchiveOrder::Stop, id(1))]
        );
        // Crash after the save: the same stop goes again, even with --discard now.
        let again = look(
            stop.state.clone(),
            seen(Execution::Running, false, false),
            true,
            2,
        );
        assert_eq!(again.effects, vec![E::Send(ArchiveOrder::Stop, id(1))]);
        let lost = archive(
            stop.state,
            ArchiveEvent::Sent {
                outcome: Dispatched::Unknown("closed".into()),
                next: id(3),
            },
        );
        assert!(matches!(lost.effects[..], [E::Failed(_)]));
        // Shown stopped: inspect, then save the removal before removing.
        let inspect = look(lost.state, seen(Execution::Stopped, false, false), false, 4);
        assert_eq!(inspect.effects, vec![E::Inspect]);
        let remove = archive(
            inspect.state,
            ArchiveEvent::Inspected {
                blocker: Ok(None),
                discard: false,
            },
        );
        assert_eq!(
            (remove.state.clone(), remove.effects),
            (
                Stage::Archiving(ArchiveStep::Removing),
                vec![E::Commit, E::Remove]
            )
        );
        // Crash mid-removal: the worker is looked at and inspected again first.
        assert_eq!(
            look(
                remove.state.clone(),
                seen(Execution::Stopped, false, false),
                false,
                5
            )
            .effects,
            vec![E::Inspect]
        );
        let gone = archive(remove.state, ArchiveEvent::Removed(Ok(())));
        assert_eq!(
            (gone.state.clone(), gone.effects),
            (Stage::FilesRemoved, vec![E::Commit, E::Look])
        );
        let thread = look(gone.state, seen(Execution::Stopped, false, false), false, 6);
        assert_eq!(
            thread.effects,
            vec![E::Commit, E::Send(ArchiveOrder::Archive, id(6))]
        );
        let lost = archive(
            thread.state,
            ArchiveEvent::Sent {
                outcome: Dispatched::Unknown("closed".into()),
                next: id(7),
            },
        );
        assert_eq!(
            look(
                lost.state.clone(),
                seen(Execution::Stopped, false, false),
                false,
                8
            )
            .effects,
            vec![E::Send(ArchiveOrder::Archive, id(6))]
        );
        // T3 had it: the thread shows archived.
        let done = look(lost.state, seen(Execution::Stopped, false, true), false, 9);
        assert_eq!(
            (done.state, done.effects),
            (Stage::Archived, vec![E::Commit, E::Done])
        );
    }

    /// An interrupted run can leave its session attached: after an accepted
    /// stop the worker is looked at again, and detaching it is a command of
    /// its own (the interrupt's identity would only replay the interrupt).
    #[test]
    fn a_session_left_attached_after_a_stop_is_detached_under_a_new_command() {
        use ArchiveEffect as E;
        let stop = look(
            Stage::Active,
            seen(Execution::Running, false, false),
            true,
            1,
        );
        let accepted = archive(
            stop.state,
            ArchiveEvent::Sent {
                outcome: Dispatched::Accepted(serde_json::json!({"sequence": 5})),
                next: id(2),
            },
        );
        assert_eq!(accepted.effects, vec![E::Commit, E::AwaitStopped]);
        let ended = archive(accepted.state, ArchiveEvent::Stopped(true));
        assert_eq!(ended.effects, vec![E::Look]);
        let detach = look(ended.state, seen(Execution::Idle, false, false), false, 3);
        assert_eq!(detach.effects, vec![E::Send(ArchiveOrder::Stop, id(2))]);
    }
}
