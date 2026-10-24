use super::*;

// MARK: Apps

/// An app as the service sees it: its agent and workers from T3's shell.
pub struct AppView {
    pub project_id: String,
    pub app: String,
    pub agent: Option<(String, Value)>,
    pub workers: Vec<(String, String, Value)>,
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub(super) enum Phase {
    Working,
    NeedsYou,
    Error,
    Done,
}

pub(super) fn phase(row: &Value) -> Phase {
    match crate::agents::worker_state(row) {
        "working" => Phase::Working,
        "needs-you" => Phase::NeedsYou,
        "error" => Phase::Error,
        _ => Phase::Done,
    }
}

/// A turn ended or started waiting: what to tell the user about it.
#[derive(Debug, PartialEq)]
pub(super) enum Change {
    Replied,
    Asks,
    Failed,
}

pub(super) fn change(
    before: Option<&(Option<String>, Phase)>,
    turn: Option<String>,
    now: Phase,
) -> Option<Change> {
    let (was_turn, was) = before?;
    if *was == now && *was_turn == turn || now == Phase::Working {
        return None;
    }
    // A thread that never ran a turn has nothing to report.
    turn.as_ref()?;
    Some(match now {
        Phase::NeedsYou => Change::Asks,
        Phase::Error => Change::Failed,
        _ if *was == Phase::NeedsYou && *was_turn == turn => return None, // answered, still idle
        _ => Change::Replied,
    })
}

/// A plain first line of an agent's reply for a notification body.
pub fn summary_line(text: &str) -> String {
    let line = text
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty() && !l.starts_with("```"))
        .unwrap_or("");
    let line = line
        .trim_start_matches(['#', '>', '-', '*', ' '])
        .replace("**", "")
        .replace('`', "");
    let mut out: String = line.chars().take(160).collect();
    if line.chars().count() > 160 {
        out.push('…');
    }
    out
}

/// The agent turn whose current step the activity shows.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct StepKey {
    pub(super) thread: String,
    pub(super) turn: Option<String>,
}

/// The step text read from T3 for one turn. Replaced whole when the turn
/// changes, so a lookup for an older turn finds nothing to write into.
pub(super) struct Step {
    pub(super) key: StepKey,
    pub(super) text: Option<String>,
    pub(super) checked: Option<Instant>,
    /// T3's database writes counted when the last lookup began.
    pub(super) seen: u64,
    pub(super) looking: bool,
}

/// What an app's activity should be, from T3's latest shell.
#[derive(Clone, Debug)]
pub(super) enum Want {
    /// Work or a question: show this (the status before the step is applied).
    Show(LiveState),
    /// Just went idle; a pause between turns is not the end yet.
    Pausing { since: Instant, last: LiveState },
    /// Idle: running activities end with this.
    Hide(LiveState),
}

pub(super) struct AppLive {
    pub(super) name: String,
    pub(super) want: Want,
    /// The working agent's turn, when its step is what the activity shows.
    pub(super) stepping: Option<StepKey>,
    pub(super) step: Option<Step>,
}

impl AppLive {
    /// Shown content with the current step applied, when the step belongs
    /// to the turn still running.
    pub(super) fn stepped(&self, state: &LiveState) -> LiveState {
        let mut state = state.clone();
        if let (Some(key), Some(step)) = (&self.stepping, &self.step)
            && step.key == *key
            && let Some(text) = &step.text
        {
            state.status = text.clone();
        }
        state
    }
}

/// An app's activity content and the turn to step, from T3's shell row.
pub(super) fn observe(app: &AppView) -> (LiveState, Option<StepKey>) {
    let agent = app.agent.as_ref().map(|(_, row)| phase(row));
    let workers: Vec<Phase> = app.workers.iter().map(|(_, _, row)| phase(row)).collect();
    let busy = workers.iter().filter(|p| **p == Phase::Working).count();
    let needs_you = agent == Some(Phase::NeedsYou) || workers.contains(&Phase::NeedsYou);
    let working = agent == Some(Phase::Working) || busy > 0;
    let status = if needs_you {
        "Needs you"
    } else if agent == Some(Phase::Working) {
        "Working"
    } else if busy > 0 {
        "Waiting on workers"
    } else {
        "Done"
    };
    let stepping = app
        .agent
        .as_ref()
        .filter(|_| agent == Some(Phase::Working) && !needs_you)
        .map(|(id, row)| StepKey {
            thread: id.clone(),
            turn: row["latestRunId"].as_str().map(str::to_string),
        });
    (
        LiveState {
            status: status.into(),
            workers: busy,
            needs_you,
            working,
        },
        stepping,
    )
}

/// What one send to one phone's activity carries.
#[derive(Clone, Debug)]
pub(super) enum Message {
    Start(LiveState),
    Update(LiveState),
    End(LiveState),
}

/// Lookups the hub needs from T3, provided by `Agents`.
pub trait Threads: Send + Sync {
    fn last_reply<'a>(&'a self, thread: &'a str) -> BoxFuture<'a, Option<String>>;
    fn question<'a>(&'a self, thread: &'a str) -> BoxFuture<'a, Option<String>>;
    fn current_step<'a>(&'a self, thread: &'a str) -> BoxFuture<'a, Option<String>>;
    /// Whether the turn that just ended was Squircle's own upkeep (a
    /// compaction while idle), which has nothing to tell the user.
    fn quiet<'a>(&'a self, thread: &'a str) -> BoxFuture<'a, bool>;
}

impl Push {
    // MARK: Builds

    /// A finished device build. `app` is its catalog app, when the caller
    /// knows it, so even a failed build without output opens its app.
    pub fn build_finished(
        self: &Arc<Self>,
        job: &crate::model::Job,
        app: Option<&crate::apps::AppRecord>,
    ) {
        use crate::model::{BuildMode, BuildState};
        let Some(request) = job.request() else { return };
        if request.mode != BuildMode::Archive {
            return; // Agents' simulator builds are their own business.
        }
        let output = job.output();
        let record = app;
        let app = output
            .map(|o| o.title.clone())
            .filter(|t| !t.is_empty())
            .or_else(|| record.map(|r| r.name.clone()))
            .unwrap_or_else(|| request.scheme.clone());
        let line = match job.state() {
            BuildState::Succeeded => match output {
                Some(o) => format!("Build {} is ready to install", o.build_number),
                None => "Build is ready to install".into(),
            },
            BuildState::Failed => {
                let reason = job.error().map(summary_line).filter(|l| !l.is_empty());
                reason.map_or("Build failed".into(), |r| format!("Build failed: {r}"))
            }
            _ => return,
        };
        let target = Target {
            app: record.map(|r| r.id.clone()),
            build: Some(job.id.clone()),
            bundle: output
                .map(|o| o.bundle_id.clone())
                .or_else(|| record.and_then(|r| r.bundle_id.clone())),
            ..Target::default()
        };
        self.notify(Note { app, line, target });
    }

    // MARK: Agents

    /// Called with each change to T3's shell: notes for finished turns and
    /// questions, and what each app's Live Activity should show.
    pub async fn apps_changed(self: &Arc<Self>, apps: Vec<AppView>) {
        let (changes, threads) = self
            .owner
            .ask(move |s| {
                let changes = s.changes(&apps);
                s.observe(&apps);
                (changes, s.threads.clone())
            })
            .await;
        self.wake.notify_one();
        for (app, project, thread, worker, change) in changes {
            let (this, threads) = (self.clone(), threads.clone());
            tokio::spawn(async move {
                if worker.is_none()
                    && change == Change::Replied
                    && let Some(t) = &threads
                    && t.quiet(&thread).await
                {
                    return;
                }
                let line = match (&worker, change) {
                    (Some(title), Change::Replied) => format!("“{title}” finished"),
                    (Some(title), Change::Asks) => format!("“{title}” needs you"),
                    (Some(title), Change::Failed) => format!("“{title}” stopped with an error"),
                    (None, Change::Replied) => match &threads {
                        Some(t) => t
                            .last_reply(&thread)
                            .await
                            .map(|r| summary_line(&r))
                            .filter(|l| !l.is_empty())
                            .unwrap_or_else(|| "Replied".into()),
                        None => "Replied".into(),
                    },
                    (None, Change::Asks) => match &threads {
                        Some(t) => t
                            .question(&thread)
                            .await
                            .map(|q| summary_line(&q))
                            .unwrap_or_else(|| "Needs your approval".into()),
                        None => "Needs you".into(),
                    },
                    (None, Change::Failed) => "Stopped with an error".into(),
                };
                this.notify(Note {
                    app,
                    line,
                    target: Target {
                        project: Some(project),
                        thread: Some(thread),
                        ..Target::default()
                    },
                });
            });
        }
    }
}
