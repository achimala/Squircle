//! M17, tasks (docs/fsm-architecture.md): what each task is and every
//! decision about it, as a pure reducer over the task book. The owner
//! (`crate::tasks::Tasks`) gathers signals, supplies the clock and new IDs,
//! and commits each reduction through C00 before anyone can read it.
//!
//! Held and following (the doc's `Policy`) are not stored: an explicit
//! status records what linked work was doing as the observation baseline,
//! and from then on any news re-derives the status exactly as it does for a
//! followed one. "Held" is only the projection "the last status change was
//! explicit and nothing has moved since".
//!
//! Work items and sub-tasks (2026-10-24): a task with a `parent` is a
//! sub-task of that work item; one level only. Sub-tasks are ordinary tasks
//! (their own links, media, status following and history). A work item with
//! sub-tasks takes the roll-up of them and of its own linked work whenever
//! one of them changes status (`rollup`); an explicit status on it holds
//! until then. Closing a work item closes its open sub-tasks.
//!
//! Needs you (2026-10-31, user: "completely unclear what needs me") is never
//! stored: a task is kept at a `Stage`, and shows as needs you exactly while
//! something waits on the user, an open question on it or one of its
//! sub-tasks, or a linked thread waiting on a question or approval of its
//! own. Once the last of those is answered or withdrawn it shows its stage
//! again.
//!
//! In progress (2026-10-31, user: "working only while a linked thread or
//! build is actually running") is never stored either: a task shows as in
//! progress exactly while a linked thread runs or a linked build is queued or
//! running (`Record::live`). Otherwise it rests at its stage: queued until
//! work has happened, then ready to try, or done or dropped as someone set.

use crate::fsm::core::{BuildID, Disposition, Machine, Reduction, TaskID, ThreadID, Violation};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, clap::ValueEnum)]
#[serde(rename_all = "snake_case")]
#[value(rename_all = "snake_case")]
pub enum Status {
    Queued,
    /// Shown, never set (`Record::live`); parsed only to refuse it with the reason.
    #[value(hide = true)]
    InProgress,
    /// Shown, never set (`Stage`); parsed only to refuse it with the reason.
    #[value(hide = true)]
    NeedsYou,
    ReadyToTry,
    Done,
    Dropped,
}

impl Status {
    pub fn open(self) -> bool {
        !matches!(self, Self::Done | Self::Dropped)
    }
    pub fn label(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::InProgress => "in progress",
            Self::NeedsYou => "needs you",
            Self::ReadyToTry => "ready to try",
            Self::Done => "done",
            Self::Dropped => "dropped",
        }
    }

    /// The stage it names, or why it can't be set: needs you and in
    /// progress are only shown, from what waits on the user and what runs.
    pub fn stage(self) -> Result<Stage, &'static str> {
        match self {
            Self::Queued => Ok(Stage::Queued),
            Self::InProgress => Err(IN_PROGRESS_REFUSED),
            Self::NeedsYou => Err(NEEDS_YOU_REFUSED),
            Self::ReadyToTry => Ok(Stage::ReadyToTry),
            Self::Done => Ok(Stage::Done),
            Self::Dropped => Ok(Stage::Dropped),
        }
    }
}

/// Where a task rests as kept: queued, ready to try, done or dropped. Needs
/// you and in progress are shown over it (`Book::shown`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Stage {
    Queued,
    ReadyToTry,
    Done,
    Dropped,
}

impl Stage {
    pub fn open(self) -> bool {
        !matches!(self, Self::Done | Self::Dropped)
    }
}

impl From<Stage> for Status {
    fn from(stage: Stage) -> Self {
        match stage {
            Stage::Queued => Status::Queued,
            Stage::ReadyToTry => Status::ReadyToTry,
            Stage::Done => Status::Done,
            Stage::Dropped => Status::Dropped,
        }
    }
}

/// Why needs you can't be set: it only shows while something waits.
pub const NEEDS_YOU_REFUSED: &str = "needs_you can't be set: a task shows as needs you only while a question or approval waits on the user. \
Ask with `squircle task ask TASK_ID --thread YOUR_THREAD_ID --question \"...\"` (it clears when they answer, or `task withdraw QUESTION_ID`); \
for anything else, keep its status and say what it waits on with --note.";

/// Why in progress can't be set: it only shows while linked work runs.
pub const IN_PROGRESS_REFUSED: &str = "in_progress can't be set: a task shows as in progress only while a linked thread or build is running. \
Link the work (`squircle thread spawn ... --task TASK_ID`, `squircle build start ... --task TASK_ID`, or `task link`) and it shows by itself; \
otherwise the task rests at queued until work has happened, then ready_to_try, and say what is next with --note.";

/// Who changed a task: the app's agent, the user on the phone, or Squircle
/// following its linked workers and builds.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum By {
    Agent,
    User,
    Auto,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Change {
    pub at: u64,
    pub status: Status,
    pub by: By,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub note: String,
}

/// The chat message a task came from.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Source {
    pub thread_id: String,
    pub message_id: String,
}

/// A question the agent (or a worker) put to the user on a task, in the
/// tracker rather than in chat. The task shows as needs you while one is
/// open.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Question {
    pub id: String,
    pub text: String,
    /// Choices the phone offers as buttons; the user may still type anything.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub options: Vec<String>,
    /// Screenshots, clips and documents it is about: IDs of media in its
    /// task's folder, in the order given. The task lists them as its own
    /// once the question is closed.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub media: Vec<String>,
    /// The thread that asked, which the answer goes to.
    pub thread_id: String,
    pub asked_at: u64,
    pub state: QuestionState,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum QuestionState {
    Open,
    Answered {
        text: String,
        at: u64,
        /// Saved with the answer: it still has to reach the asking thread
        /// (`Agents::relay_answers`), until the notification owner has it.
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        owed: bool,
    },
    /// The asker took it back, or the task was closed.
    Withdrawn {
        at: u64,
    },
}

impl Question {
    pub fn open(&self) -> bool {
        self.state == QuestionState::Open
    }
}

/// A task as readers see it: a copy of one saved revision. Changes go
/// through `Tasks`, which saves them before anyone can read them.
#[derive(Clone, Debug, Serialize)]
pub struct Task {
    pub id: String,
    /// The T3 project of the app.
    pub project_id: String,
    /// The work item this is a sub-task of.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_id: Option<String>,
    /// A work item's sub-tasks, most recently active first; always empty on a sub-task.
    pub subtasks: Vec<Task>,
    /// A short name the agent gave it; empty on tasks from before titles
    /// (2026-10-31) until an agent names them.
    pub title: String,
    /// The ask in the user's own words.
    pub ask: String,
    pub status: Status,
    /// What it waits on or what happened, in a few words.
    pub note: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<Source>,
    /// The later ask that replaces this one (it is dropped and stays so).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub replaced_by: Option<String>,
    pub threads: Vec<String>,
    pub builds: Vec<String>,
    pub created_at: u64,
    pub updated_at: u64,
    /// When it moved out of the active list into History.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub archived_at: Option<u64>,
    /// Rises with every saved change, including what linked work was seen doing.
    pub revision: u64,
    pub history: Vec<Change>,
    /// Questions to the user, oldest first, answered ones kept.
    pub questions: Vec<Question>,
}

impl Task {
    /// What to call it: its title, or the ask until an agent names it.
    pub fn name(&self) -> &str {
        if self.title.is_empty() {
            &self.ask
        } else {
            &self.title
        }
    }
}

/// A linked worker's state as T3 shows it. `Missing` is no fact at all (no
/// row, or a shell that isn't current) and never counts as news.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerPhase {
    Working,
    NeedsYou,
    Done,
    Error,
    /// T3 has no such thread any more (archived or deleted): not running.
    Gone,
    Missing,
}

/// A linked build's state; `Failed` covers cancelled and interrupted.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BuildPhase {
    Queued,
    Running,
    Succeeded,
    Failed,
    Missing,
}

#[derive(Clone, Debug)]
pub struct WorkerSignal {
    pub thread: String,
    /// T3's `latestRunId`: a new run is new work even when the state reads the same.
    pub turn: Option<String>,
    pub phase: WorkerPhase,
}

#[derive(Clone, Debug)]
pub struct BuildSignal {
    pub build: String,
    pub phase: BuildPhase,
}

/// What a task's linked workers and builds are doing now, in the order of
/// `Task::threads` and `Task::builds`.
#[derive(Clone, Debug, Default)]
pub struct Signals {
    /// The `Task::revision` this was read against. An explicit update drops
    /// an observation older than one already recorded; `None` is taken as is.
    pub revision: Option<u64>,
    pub workers: Vec<WorkerSignal>,
    pub builds: Vec<BuildSignal>,
}

/// Where a work item rests given its sub-tasks' stages and whether its own
/// linked work has done anything (`own`): queued while nothing has, ready to
/// try once something has and some are still open. All closed: done when
/// the user closed the last one (`by`), ready to try otherwise, dropped if
/// all were dropped. (Whether any of them waits on the user or runs is
/// shown, not rolled up: `Book::shown`.)
fn rollup(stages: &[Stage], own: bool, by: By) -> Option<Stage> {
    let all: Vec<Stage> = stages
        .iter()
        .copied()
        .chain(own.then_some(Stage::ReadyToTry))
        .collect();
    let any = |s: Stage| all.contains(&s);
    if all.is_empty() {
        None
    } else if all.iter().all(|s| *s == Stage::Queued) {
        Some(Stage::Queued)
    } else if any(Stage::Queued) || any(Stage::ReadyToTry) {
        Some(Stage::ReadyToTry)
    } else if any(Stage::Done) {
        Some(if by == By::User {
            Stage::Done
        } else {
            Stage::ReadyToTry
        })
    } else {
        Some(Stage::Dropped)
    }
}

impl Signals {
    /// The `id:state id:state` signature old `tasks.json` files kept as
    /// `seen` (worker states `working|needs-you|done|error`, build states
    /// `queued|running|succeeded|failed`).
    pub(crate) fn legacy(signature: &str) -> Self {
        let mut signals = Signals::default();
        for (id, state) in signature
            .split(' ')
            .filter_map(|entry| entry.rsplit_once(':'))
        {
            let worker = match state {
                "working" => Some(WorkerPhase::Working),
                "needs-you" => Some(WorkerPhase::NeedsYou),
                "done" => Some(WorkerPhase::Done),
                "error" => Some(WorkerPhase::Error),
                _ => None,
            };
            let build = match state {
                "queued" => Some(BuildPhase::Queued),
                "running" => Some(BuildPhase::Running),
                "succeeded" => Some(BuildPhase::Succeeded),
                "failed" => Some(BuildPhase::Failed),
                _ => None,
            };
            if let Some(phase) = worker {
                signals.workers.push(WorkerSignal {
                    thread: id.into(),
                    turn: None,
                    phase,
                });
            } else if let Some(phase) = build {
                signals.builds.push(BuildSignal {
                    build: id.into(),
                    phase,
                });
            }
        }
        signals
    }
}

/// Done or dropped tasks leave the active list after a day; open ones that
/// nothing has touched for three days, too. Both stay in History.
const DONE_AGE: u64 = 24 * 3600;
const STALE_AGE: u64 = 3 * 24 * 3600;

/// Where a task is listed. Independent of its status: open tasks age into
/// History too, and History tasks still follow their linked work.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Placement {
    Active,
    History { since: u64 },
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
struct WorkerSeen {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    turn: Option<String>,
    phase: WorkerPhase,
}

/// The last known state of each linked worker and build. It always advances,
/// whatever the status, so later work is compared with what was really last
/// seen; links without a fact keep their last known state.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
struct Observation {
    /// The task revision it was recorded at.
    revision: u64,
    workers: BTreeMap<String, WorkerSeen>,
    builds: BTreeMap<String, BuildPhase>,
}

/// How much an observation says compared with the last one.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum News {
    None,
    /// Linked work moved on: finished, failed, a build completing.
    Changed,
    /// A new link, a new turn, or a worker working or asking again.
    NewWork,
}

impl Observation {
    fn next(
        &self,
        threads: &[String],
        builds: &[String],
        signals: &Signals,
    ) -> (Observation, News) {
        let mut next = Observation {
            revision: self.revision,
            ..Default::default()
        };
        let mut news = News::None;
        for id in threads {
            let old = self.workers.get(id);
            let fact = signals
                .workers
                .iter()
                .find(|w| &w.thread == id && w.phase != WorkerPhase::Missing);
            let Some(fact) = fact else {
                if let Some(old) = old {
                    next.workers.insert(id.clone(), old.clone());
                }
                continue;
            };
            news = news.max(match old {
                None => News::NewWork,
                Some(WorkerSeen {
                    turn: Some(turn), ..
                }) if fact.turn.as_ref().is_some_and(|t| t != turn) => News::NewWork,
                Some(old) if old.phase == fact.phase => News::None,
                Some(_) if matches!(fact.phase, WorkerPhase::Working | WorkerPhase::NeedsYou) => {
                    News::NewWork
                }
                // Archiving a thread that had stopped is no news.
                Some(old)
                    if fact.phase == WorkerPhase::Gone
                        && matches!(old.phase, WorkerPhase::Done | WorkerPhase::Error) =>
                {
                    News::None
                }
                Some(_) => News::Changed,
            });
            let turn = fact
                .turn
                .clone()
                .or_else(|| old.and_then(|o| o.turn.clone()));
            next.workers.insert(
                id.clone(),
                WorkerSeen {
                    turn,
                    phase: fact.phase,
                },
            );
        }
        for id in builds {
            let old = self.builds.get(id);
            let fact = signals
                .builds
                .iter()
                .find(|b| &b.build == id && b.phase != BuildPhase::Missing);
            let Some(fact) = fact else {
                if let Some(old) = old {
                    next.builds.insert(id.clone(), *old);
                }
                continue;
            };
            news = news.max(match old {
                None => News::NewWork,
                Some(old) if *old == fact.phase => News::None,
                Some(_) => News::Changed,
            });
            next.builds.insert(id.clone(), fact.phase);
        }
        (next, news)
    }

    /// Whether any of `threads` was last seen running, or any of `builds`
    /// queued or running.
    fn live(&self, threads: &[String], builds: &[String]) -> bool {
        threads.iter().any(|t| {
            self.workers
                .get(t)
                .is_some_and(|w| w.phase == WorkerPhase::Working)
        }) || builds.iter().any(|b| {
            matches!(
                self.builds.get(b),
                Some(BuildPhase::Queued | BuildPhase::Running)
            )
        })
    }

    /// Whether linked work has been seen at all.
    fn any(&self) -> bool {
        !self.workers.is_empty() || !self.builds.is_empty()
    }
}

/// A task as it is kept. Status and its history change together (`set`).
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(from = "StoredRecord")]
struct Record {
    id: String,
    project_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    parent: Option<String>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    title: String,
    ask: String,
    status: Stage,
    note: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    source: Option<Source>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    replaced_by: Option<String>,
    threads: Vec<String>,
    builds: Vec<String>,
    created_at: u64,
    updated_at: u64,
    /// Its latest activity the user can see: added, its status changing, a
    /// question asked or closed, its linked work having news, or the same
    /// on a sub-task. Lists put the most recent first. (`updated_at` also
    /// moves for notes, titles and pictures, which shouldn't reorder rows.)
    active_at: u64,
    placement: Placement,
    revision: u64,
    observed: Observation,
    history: Vec<Change>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    questions: Vec<Question>,
    /// Read from a file that kept needs you or in progress as its status,
    /// and not saved since.
    #[serde(skip)]
    migrated: bool,
    /// Read from a file from before `active_at` (2026-11-01), and not saved since.
    #[serde(skip)]
    undated: bool,
}

/// A record as read from disk, including files from before revisions
/// (2026-10-15), which kept `archived_at` and a `seen` signature instead,
/// from before needs you was derived (2026-10-31), which could keep it, and
/// from before `active_at` (2026-11-01), which kept an `order` instead.
#[derive(Deserialize)]
struct StoredRecord {
    id: String,
    project_id: String,
    #[serde(default)]
    parent: Option<String>,
    #[serde(default)]
    title: String,
    ask: String,
    status: Status,
    #[serde(default)]
    note: String,
    #[serde(default)]
    source: Option<Source>,
    #[serde(default)]
    replaced_by: Option<String>,
    #[serde(default)]
    threads: Vec<String>,
    #[serde(default)]
    builds: Vec<String>,
    created_at: u64,
    updated_at: u64,
    #[serde(default)]
    active_at: Option<u64>,
    #[serde(default)]
    placement: Option<Placement>,
    #[serde(default)]
    revision: u64,
    #[serde(default)]
    observed: Option<Observation>,
    #[serde(default)]
    history: Vec<Change>,
    #[serde(default)]
    archived_at: Option<u64>,
    #[serde(default)]
    seen: String,
    #[serde(default)]
    questions: Vec<Question>,
}

impl From<StoredRecord> for Record {
    fn from(s: StoredRecord) -> Self {
        let placement = s
            .placement
            .or(s.archived_at.map(|since| Placement::History { since }))
            .unwrap_or(Placement::Active);
        let observed = s.observed.unwrap_or_else(|| {
            Observation::default()
                .next(&s.threads, &s.builds, &Signals::legacy(&s.seen))
                .0
        });
        let mut history = s.history;
        // Needs you or in progress as a kept status (from before they were
        // derived): where it rests. Whatever really waits on the user or runs
        // still shows over it.
        let (status, migrated) = match s.status.stage() {
            Ok(stage) => (stage, false),
            Err(_) => {
                let stage = resting(&observed, &history);
                history.push(Change {
                    at: s.updated_at,
                    status: stage.into(),
                    by: By::Auto,
                    note: s.note.clone(),
                });
                (stage, true)
            }
        };
        // From before `active_at`: when its status last changed (the
        // migration takes its sub-tasks' too).
        let active_at = s
            .active_at
            .unwrap_or_else(|| history.iter().map(|c| c.at).fold(s.created_at, u64::max));
        Record {
            id: s.id,
            project_id: s.project_id,
            parent: s.parent,
            title: s.title,
            ask: s.ask,
            status,
            note: s.note,
            source: s.source,
            replaced_by: s.replaced_by,
            threads: s.threads,
            builds: s.builds,
            created_at: s.created_at,
            updated_at: s.updated_at,
            active_at,
            placement,
            revision: s.revision,
            observed,
            history,
            questions: s.questions,
            migrated,
            undated: s.active_at.is_none(),
        }
    }
}

/// A title as kept: one line, at most 80 characters.
fn one_line(title: &str) -> String {
    title
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(80)
        .collect()
}

/// Where an open task rests once nothing runs: queued until work has
/// happened (linked work seen, or a result it was ready to try or done
/// with), ready to try after.
fn resting(observed: &Observation, history: &[Change]) -> Stage {
    if observed.any()
        || history
            .iter()
            .any(|c| matches!(c.status, Status::ReadyToTry | Status::Done))
    {
        Stage::ReadyToTry
    } else {
        Stage::Queued
    }
}

impl Record {
    /// As readers see it, showing `status` (`Book::shown`).
    fn publish(&self, status: Status) -> Task {
        Task {
            id: self.id.clone(),
            project_id: self.project_id.clone(),
            parent_id: self.parent.clone(),
            subtasks: vec![],
            title: self.title.clone(),
            ask: self.ask.clone(),
            status,
            note: self.note.clone(),
            source: self.source.clone(),
            replaced_by: self.replaced_by.clone(),
            threads: self.threads.clone(),
            builds: self.builds.clone(),
            created_at: self.created_at,
            updated_at: self.updated_at,
            archived_at: match self.placement {
                Placement::Active => None,
                Placement::History { since } => Some(since),
            },
            revision: self.revision,
            history: self.history.clone(),
            questions: self.questions.clone(),
        }
    }

    /// Whether a question to the user is open on it.
    fn asking(&self) -> bool {
        self.questions.iter().any(Question::open)
    }

    /// Whether something of its own waits on the user: an open question, or
    /// a linked thread last seen waiting on a question or approval. A closed
    /// task's threads wait on nothing of it.
    fn waiting(&self) -> bool {
        self.status.open()
            && (self.asking()
                || self.threads.iter().any(|t| {
                    self.observed
                        .workers
                        .get(t)
                        .is_some_and(|w| w.phase == WorkerPhase::NeedsYou)
                }))
    }

    /// Whether linked work runs on it now: shown as in progress while it is open.
    fn live(&self) -> bool {
        self.status.open() && self.observed.live(&self.threads, &self.builds)
    }

    fn rest(&self) -> Stage {
        resting(&self.observed, &self.history)
    }

    /// Any change to the task itself: it counts as touched and leaves History.
    fn touch(&mut self, now: u64) {
        self.updated_at = now;
        self.placement = Placement::Active;
        self.revision += 1;
    }

    /// Something the user sees happened to it (`active_at`).
    fn stir(&mut self, now: u64) {
        self.active_at = self.active_at.max(now);
    }

    /// Closing it withdraws its open questions.
    fn set(&mut self, status: Stage, by: By, note: Option<&str>, now: u64) {
        let note = note.map(str::trim);
        if !status.open() {
            for question in self.questions.iter_mut().filter(|q| q.open()) {
                question.state = QuestionState::Withdrawn { at: now };
            }
        }
        if status == self.status && note.is_none_or(|n| n == self.note) {
            return;
        }
        if let Some(note) = note {
            self.note = note.chars().take(300).collect();
        }
        if status != self.status {
            self.stir(now);
        }
        self.status = status;
        self.touch(now);
        self.history.push(Change {
            at: now,
            status: status.into(),
            by,
            note: self.note.clone(),
        });
    }

    fn record(&mut self, observed: Observation) {
        self.revision += 1;
        self.observed = Observation {
            revision: self.revision,
            ..observed
        };
    }

    /// Follows linked workers and builds: when one of them has news since it
    /// was last seen and nothing of it runs any more, it rests at ready to
    /// try (a work item: the roll-up of its sub-tasks with that). While
    /// something runs it shows as in progress over its stage. A done
    /// or dropped task reopens only for new work (a new link, a new turn, a
    /// worker working or asking again), not old work finishing; new work also
    /// brings a task back from History. A replaced one never reopens: its
    /// workers go on with the ask that replaced it. Returns whether anything changed.
    fn follow(&mut self, signals: &Signals, subtasks: &[Stage], now: u64) -> bool {
        let (next, news) = self.observed.next(&self.threads, &self.builds, signals);
        if next == self.observed {
            return false;
        }
        self.record(next);
        if news == News::None
            || (!self.status.open() && (news != News::NewWork || self.replaced_by.is_some()))
        {
            return true;
        }
        self.stir(now);
        if news == News::NewWork {
            self.touch(now);
        }
        if self.live() {
            return true;
        }
        let rest = if subtasks.is_empty() {
            Some(self.rest())
        } else {
            rollup(subtasks, self.observed.any(), By::Auto)
        };
        if let Some(status) = rest.filter(|s| *s != self.status) {
            self.set(status, By::Auto, None, now);
        }
        true
    }

    /// An explicit status holds from what linked work was doing when it was
    /// chosen: that becomes the last observation, unless a newer one was
    /// recorded after `signals` were read.
    fn hold(&mut self, signals: &Signals) {
        if signals
            .revision
            .is_some_and(|base| base < self.observed.revision)
        {
            return;
        }
        let (next, _) = self.observed.next(&self.threads, &self.builds, signals);
        self.record(next);
    }

    fn ages(&self, now: u64) -> bool {
        self.ages_at().is_some_and(|at| now >= at)
    }

    /// When an untouched task goes to History: a day after it closed,
    /// three after it was last touched while open. Sub-tasks go with their
    /// work item.
    fn ages_at(&self) -> Option<u64> {
        if self.parent.is_some() || self.placement != Placement::Active {
            return None;
        }
        let limit = if self.status.open() {
            STALE_AGE
        } else {
            DONE_AGE
        };
        Some(self.updated_at.saturating_add(limit))
    }

    /// Whether linked work can still say anything: History tasks are skipped
    /// only when all they link is builds that have finished.
    fn watched(&self, placement: Placement) -> bool {
        placement == Placement::Active
            || !self.threads.is_empty()
            || self.builds.iter().any(|b| {
                !matches!(
                    self.observed.builds.get(b),
                    Some(BuildPhase::Succeeded | BuildPhase::Failed)
                )
            })
    }
}

/// Every app's tasks: the aggregate one file (`tasks.json`) keeps.
#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Book {
    #[serde(default)]
    tasks: BTreeMap<String, Record>,
}

impl Book {
    /// A task; a work item with its sub-tasks.
    pub fn get(&self, id: &str) -> Option<Task> {
        self.tasks.get(id).map(|t| self.publish(t))
    }

    fn publish(&self, record: &Record) -> Task {
        let mut task = self.flat(record);
        let mut subtasks: Vec<&Record> = self.children(&record.id).collect();
        Self::recent_first(&mut subtasks);
        task.subtasks = subtasks.into_iter().map(|t| self.flat(t)).collect();
        task
    }

    /// A task without its sub-tasks listed.
    fn flat(&self, record: &Record) -> Task {
        record.publish(self.shown(record))
    }

    /// The status a task shows: needs you while it or one of its sub-tasks
    /// waits on the user, else in progress while linked work of it or of an
    /// open sub-task runs, otherwise its stage.
    fn shown(&self, record: &Record) -> Status {
        let open = record.status.open();
        if record.waiting() || (open && self.children(&record.id).any(Record::waiting)) {
            Status::NeedsYou
        } else if record.live() || (open && self.children(&record.id).any(Record::live)) {
            Status::InProgress
        } else {
            record.status.into()
        }
    }

    /// Most recently active first; the newest added first among equals.
    fn recent_first(records: &mut [&Record]) {
        records.sort_by(|a, b| {
            (b.active_at, b.created_at, &b.id).cmp(&(a.active_at, a.created_at, &a.id))
        });
    }

    /// Whether it was read with needs you or in progress kept as its status,
    /// or without `active_at`, and not saved since.
    pub fn migrated(&self) -> bool {
        self.tasks.values().any(|t| t.migrated || t.undated)
    }

    fn children<'a>(&'a self, id: &'a str) -> impl Iterator<Item = &'a Record> + 'a {
        self.tasks
            .values()
            .filter(move |t| t.parent.as_deref() == Some(id))
    }

    fn statuses(&self, id: &str) -> Vec<Stage> {
        self.children(id).map(|t| t.status).collect()
    }

    /// The app's work items (tasks without a parent), each with its
    /// sub-tasks, most recently active first.
    pub fn list(&self, project: &str) -> Vec<Task> {
        let mut items: Vec<&Record> = self
            .tasks
            .values()
            .filter(|t| t.project_id == project && t.parent.is_none())
            .collect();
        Self::recent_first(&mut items);
        items.into_iter().map(|t| self.publish(t)).collect()
    }

    /// The task holding question `id`, and the question.
    pub fn question(&self, id: &str) -> Option<(Task, Question)> {
        self.tasks.values().find_map(|t| {
            let q = t.questions.iter().find(|q| q.id == id)?;
            Some((self.flat(t), q.clone()))
        })
    }

    /// Open questions, each with the task holding it.
    pub fn asking(&self) -> Vec<(Task, Question)> {
        self.tasks
            .values()
            .flat_map(|t| {
                t.questions
                    .iter()
                    .filter(|q| q.open())
                    .map(|q| (self.flat(t), q.clone()))
            })
            .collect()
    }

    /// Answered questions whose answer has not reached its asker yet.
    pub fn owed(&self) -> Vec<(Task, Question)> {
        self.tasks
            .values()
            .flat_map(|t| {
                t.questions
                    .iter()
                    .filter(|q| matches!(q.state, QuestionState::Answered { owed: true, .. }))
                    .map(|q| (self.flat(t), q.clone()))
            })
            .collect()
    }

    /// Every task, sub-tasks as their own entries.
    pub fn all(&self) -> Vec<Task> {
        self.tasks.values().map(|t| self.flat(t)).collect()
    }

    /// When the next task ages into History if nothing touches it.
    pub fn next_age(&self) -> Option<u64> {
        self.tasks.values().filter_map(Record::ages_at).min()
    }

    /// Tasks whose linked work a tick should read, sub-tasks included (they
    /// are listed where their work item is).
    pub fn watched(&self) -> Vec<Task> {
        self.tasks
            .values()
            .filter(|t| {
                let placement = t
                    .parent
                    .as_ref()
                    .and_then(|p| self.tasks.get(p))
                    .map_or(t.placement, |p| p.placement);
                t.watched(placement)
            })
            .map(|t| self.flat(t))
            .collect()
    }

    /// A change to a sub-task counts as touching its work item (it leaves
    /// History), and its activity as the work item's; a status change
    /// re-derives the work item's status.
    fn bubble(&mut self, id: &str, status_changed: bool, by: By, now: u64) {
        let Some((parent, active)) = self
            .tasks
            .get(id)
            .and_then(|t| Some((t.parent.clone()?, t.active_at)))
        else {
            return;
        };
        if let Some(item) = self.tasks.get_mut(&parent) {
            item.touch(now);
            item.stir(active);
        }
        if status_changed {
            self.rederive(&parent, by, now);
        }
    }

    /// A work item takes the roll-up of its sub-tasks and its own linked
    /// work. A closed one reopens only when a sub-task has work again
    /// (queued or in progress); old work finishing leaves it
    /// closed, and a replaced one stays closed.
    fn rederive(&mut self, id: &str, by: By, now: u64) {
        let statuses = self.statuses(id);
        let active = self
            .children(id)
            .any(|t| t.status == Stage::Queued || t.live());
        let Some(item) = self.tasks.get_mut(id) else {
            return;
        };
        if !item.status.open() && (!active || item.replaced_by.is_some()) {
            return;
        }
        let own = item.observed.any();
        if let Some(status) = rollup(&statuses, own, by).filter(|s| *s != item.status) {
            item.set(status, By::Auto, None, now);
        }
    }

    /// Whether `id` may become a sub-task of `target` (or a work item of its
    /// own with `None`): one level, within its app.
    fn can_move(&self, id: &str, target: Option<&str>) -> Result<(), String> {
        let Some(target) = target else {
            return Ok(());
        };
        let task = &self.tasks[id];
        let item = self.tasks.get(target).ok_or(format!("No task {target}"))?;
        if target == id || self.children(id).next().is_some() {
            Err(format!(
                "{id} has sub-tasks of its own; it stays a work item"
            ))
        } else if item.parent.is_some() {
            Err(format!("{target} is itself a sub-task"))
        } else if item.project_id != task.project_id {
            Err(format!("{target} belongs to another app"))
        } else {
            Ok(())
        }
    }

    /// Closing a work item closes its open sub-tasks the same way.
    fn cascade(&mut self, id: &str, status: Stage, by: By, now: u64) {
        let open: Vec<String> = self
            .children(id)
            .filter(|t| t.status.open())
            .map(|t| t.id.clone())
            .collect();
        for child in open {
            if let Some(task) = self.tasks.get_mut(&child) {
                task.set(status, by, None, now);
            }
        }
    }
}

/// A change to a task. Fields left out are kept.
#[derive(Debug, Default, Deserialize)]
pub struct Update {
    pub title: Option<String>,
    pub ask: Option<String>,
    pub status: Option<Status>,
    pub note: Option<String>,
    /// Move it under this work item; empty makes a sub-task a work item of its own.
    pub parent: Option<String>,
    /// A later ask of the same app replaces this one: it is dropped and
    /// stays dropped. Reopening it (an open status) undoes that.
    pub replaced_by: Option<String>,
}

/// Everything that can happen to the task book. Time and new IDs come in
/// the event; the reducer never reads a clock or allocates.
#[derive(Debug)]
pub enum Event {
    /// The user's ask, through the agent or the phone.
    Add {
        id: TaskID,
        project: String,
        /// A few words naming it, written by the agent.
        title: String,
        ask: String,
        status: Option<Status>,
        note: Option<String>,
        by: By,
        source: Option<Source>,
        threads: Vec<String>,
        /// The work item it is a sub-task of.
        parent: Option<String>,
        now: u64,
    },
    /// An explicit change. A status set this way holds from `observed`, what
    /// linked work was doing when it was chosen.
    Edit {
        id: String,
        update: Update,
        by: By,
        observed: Option<Signals>,
        now: u64,
    },
    Link {
        id: String,
        thread: Option<ThreadID>,
        build: Option<BuildID>,
        now: u64,
    },
    Unlink {
        id: String,
        thread: Option<ThreadID>,
        build: Option<BuildID>,
        now: u64,
    },
    /// A screenshot or clip was stored for the task.
    Attached { id: String, now: u64 },
    /// What linked work said, each read against the task revision it names.
    Observe {
        reads: Vec<(String, u64, Signals)>,
        now: u64,
    },
    /// Untouched tasks move into History.
    AgeDue { now: u64 },
    /// A question to the user on task `id`, from `thread`; the task shows
    /// as needs you until it is answered or withdrawn. Asking about a closed
    /// task reopens it: it isn't finished while the user still has to say.
    Ask {
        id: String,
        question: String,
        text: String,
        options: Vec<String>,
        media: Vec<String>,
        thread: String,
        now: u64,
    },
    /// The user's answer to an open question.
    Answer {
        question: String,
        text: String,
        now: u64,
    },
    /// The asker takes an open question back.
    Withdraw { question: String, now: u64 },
    /// An answered question's answer is queued for its asker.
    Delivered { question: String },
    /// Saves, once, what was read from a file that kept needs you or in
    /// progress as a status (`Book::migrated`), and rolls up the work items
    /// among or above them.
    Migrate { now: u64 },
}

#[derive(Debug, PartialEq, Eq)]
pub enum Effect {
    /// Save the new book; only then may anyone see it.
    Commit,
}

pub struct M17;

/// Adds (to the end) or removes a linked worker and build.
fn link(
    mut book: Book,
    id: &str,
    thread: Option<ThreadID>,
    build: Option<BuildID>,
    now: u64,
    remove: bool,
) -> Reduction<Book, Effect> {
    let Some(task) = book.tasks.get_mut(id) else {
        return missing(book, id);
    };
    for (list, value) in [
        (&mut task.threads, thread.map(String::from)),
        (&mut task.builds, build.map(String::from)),
    ] {
        let Some(value) = value else { continue };
        list.retain(|v| *v != value);
        if !remove {
            list.push(value);
        }
    }
    task.touch(now);
    task.stir(now);
    book.bubble(id, false, By::Auto, now);
    changed(book)
}

/// Answers or withdraws an open question; the task shows its stage again
/// once nothing else waits on the user (in progress if the asker, linked,
/// goes on running).
fn close_question(
    mut book: Book,
    question: &str,
    state: QuestionState,
    by: By,
    now: u64,
) -> Reduction<Book, Effect> {
    let Some(task) = book
        .tasks
        .values_mut()
        .find(|t| t.questions.iter().any(|q| q.id == question))
    else {
        return Reduction::same(
            book,
            Disposition::Rejected(format!("No question {question}")),
        );
    };
    let entry = task
        .questions
        .iter_mut()
        .find(|q| q.id == question)
        .expect("found above");
    if !entry.open() {
        let reason = match (&entry.state, &state) {
            // The same answer again (the phone retrying): nothing changes,
            // and an answer not yet delivered is saved again, which wakes its relay.
            (
                QuestionState::Answered { text, owed, .. },
                QuestionState::Answered { text: again, .. },
            ) if text == again => {
                return if *owed {
                    changed(book)
                } else {
                    Reduction::same(book, Disposition::Unchanged)
                };
            }
            (QuestionState::Answered { .. }, _) => "That question was already answered",
            _ => "That question was withdrawn",
        };
        return Reduction::same(book, Disposition::Rejected(reason.into()));
    }
    entry.state = state;
    let id = task.id.clone();
    task.touch(now);
    task.stir(now);
    book.bubble(&id, false, by, now);
    changed(book)
}

fn changed(book: Book) -> Reduction<Book, Effect> {
    Reduction::applied(book, vec![Effect::Commit])
}

fn missing(book: Book, id: &str) -> Reduction<Book, Effect> {
    Reduction::same(book, Disposition::Rejected(format!("No task {id}")))
}

impl Machine for M17 {
    type State = Book;
    type Event = Event;
    type Effect = Effect;

    fn reduce(mut book: Book, event: Event) -> Reduction<Book, Effect> {
        match event {
            Event::Add {
                id,
                project,
                title,
                ask,
                status,
                note,
                by,
                source,
                threads,
                parent,
                now,
            } => {
                let ask = ask.trim();
                if ask.is_empty() {
                    return Reduction::same(
                        book,
                        Disposition::Rejected("A task needs the user's ask".into()),
                    );
                }
                let title = one_line(&title);
                if title.is_empty() {
                    return Reduction::same(
                        book,
                        Disposition::Rejected(
                            "A task needs a title: a few words naming it (--title)".into(),
                        ),
                    );
                }
                let item = parent.as_deref().map(|p| {
                    book.tasks
                        .get(p)
                        .map(|t| (t.project_id.clone(), t.parent.clone()))
                });
                let project = match item {
                    None => project,
                    Some(None) => {
                        let parent = parent.unwrap_or_default();
                        return missing(book, &parent);
                    }
                    Some(Some((_, Some(above)))) => {
                        let reason = format!(
                            "{} is a sub-task; add to its work item {above}",
                            parent.unwrap_or_default()
                        );
                        return Reduction::same(book, Disposition::Rejected(reason));
                    }
                    Some(Some((project, None))) => project,
                };
                let status = match status.map(Status::stage) {
                    None => Stage::Queued,
                    Some(Ok(stage)) => stage,
                    Some(Err(reason)) => {
                        return Reduction::same(book, Disposition::Rejected(reason.into()));
                    }
                };
                let task = Record {
                    id: id.into(),
                    project_id: project,
                    parent,
                    title,
                    ask: ask.chars().take(500).collect(),
                    status,
                    note: note
                        .map(|n| n.trim().chars().take(300).collect())
                        .unwrap_or_default(),
                    source,
                    replaced_by: None,
                    threads,
                    builds: vec![],
                    created_at: now,
                    updated_at: now,
                    active_at: now,
                    placement: Placement::Active,
                    revision: 1,
                    observed: Observation::default(),
                    history: vec![Change {
                        at: now,
                        status: status.into(),
                        by,
                        note: String::new(),
                    }],
                    questions: vec![],
                    migrated: false,
                    undated: false,
                };
                let id = task.id.clone();
                book.tasks.insert(id.clone(), task);
                book.bubble(&id, true, by, now);
                changed(book)
            }
            Event::Edit {
                id,
                update,
                by,
                observed,
                now,
            } => {
                let Some(current) = book.tasks.get(&id) else {
                    return missing(book, &id);
                };
                let stage = match update.status.map(Status::stage).transpose() {
                    Ok(stage) => stage,
                    Err(reason) => {
                        return Reduction::same(book, Disposition::Rejected(reason.into()));
                    }
                };
                let (project, old_parent, before) = (
                    current.project_id.clone(),
                    current.parent.clone(),
                    current.status,
                );
                if let Some(target) = update.parent.as_deref().map(str::trim) {
                    let target = (!target.is_empty()).then(|| target.to_string());
                    if let Err(reason) = book.can_move(&id, target.as_deref()) {
                        return Reduction::same(book, Disposition::Rejected(reason));
                    }
                    if target != old_parent {
                        let task = book.tasks.get_mut(&id).expect("checked above");
                        task.parent = target.clone();
                        task.touch(now);
                        if let Some(old) = &old_parent {
                            book.rederive(old, by, now);
                        }
                        book.bubble(&id, true, by, now);
                    }
                }
                let replaced_by = update
                    .replaced_by
                    .as_deref()
                    .map(str::trim)
                    .filter(|r| !r.is_empty())
                    .map(str::to_string);
                if let Some(later) = &replaced_by {
                    let reason = match book.tasks.get(later) {
                        None => Some(format!("No task {later}")),
                        Some(_) if *later == id => Some("A task can't replace itself".into()),
                        Some(t) if t.project_id != project => {
                            Some(format!("{later} belongs to another app"))
                        }
                        Some(_) => None,
                    };
                    if let Some(reason) = reason {
                        return Reduction::same(book, Disposition::Rejected(reason));
                    }
                }
                let task = book.tasks.get_mut(&id).expect("checked above");
                if let Some(title) = update
                    .title
                    .as_deref()
                    .map(one_line)
                    .filter(|t| !t.is_empty())
                {
                    task.title = title;
                    task.touch(now);
                }
                if let Some(ask) = update
                    .ask
                    .as_deref()
                    .map(str::trim)
                    .filter(|a| !a.is_empty())
                {
                    task.ask = ask.chars().take(500).collect();
                    task.touch(now);
                }
                let (status, note) = match &replaced_by {
                    Some(_) => (
                        Some(Stage::Dropped),
                        update.note.as_deref().or(Some("Replaced by a later ask")),
                    ),
                    None => (stage, update.note.as_deref()),
                };
                if replaced_by.is_some() || status.is_some_and(Stage::open) {
                    task.replaced_by = replaced_by;
                }
                match status {
                    Some(status) => task.set(status, by, note, now),
                    None => {
                        if let Some(note) = update.note.as_deref() {
                            let status = task.status;
                            task.set(status, by, Some(note), now);
                        }
                    }
                }
                if status.is_some()
                    && let Some(observed) = observed
                {
                    task.hold(&observed);
                }
                let after = task.status;
                if status.is_some_and(|s| !s.open()) {
                    book.cascade(&id, after, by, now);
                }
                book.bubble(&id, after != before, by, now);
                changed(book)
            }
            Event::Link {
                id,
                thread,
                build,
                now,
            } => link(book, &id, thread, build, now, false),
            Event::Unlink {
                id,
                thread,
                build,
                now,
            } => link(book, &id, thread, build, now, true),
            Event::Attached { id, now } => {
                let Some(task) = book.tasks.get_mut(&id) else {
                    return missing(book, &id);
                };
                task.touch(now);
                book.bubble(&id, false, By::Auto, now);
                changed(book)
            }
            Event::Observe { reads, now } => {
                let mut any = false;
                // Sub-tasks first, then work items (which roll them up), then
                // the work items of sub-tasks that moved.
                let mut reads = reads;
                reads.sort_by_key(|(id, _, _)| {
                    book.tasks.get(id).is_none_or(|t| t.parent.is_none())
                });
                let mut moved = vec![];
                for (id, revision, signals) in &reads {
                    // Read before a change made meanwhile: older news, dropped (the next tick reads again).
                    if book.tasks.get(id).is_none_or(|t| t.revision != *revision) {
                        continue;
                    }
                    let subtasks = book.statuses(id);
                    let task = book.tasks.get_mut(id).expect("checked above");
                    let (before, turns, active, ran) =
                        (task.status, task.updated_at, task.active_at, task.live());
                    any |= task.follow(signals, &subtasks, now);
                    // A sub-task's work starting counts like a status change:
                    // it can reopen its closed work item.
                    let started = task.live() && !ran;
                    if task.status != before
                        || task.updated_at != turns
                        || task.active_at != active
                        || started
                    {
                        moved.push((id.clone(), task.status != before || started));
                    }
                }
                for (id, status_changed) in moved {
                    book.bubble(&id, status_changed, By::Auto, now);
                }
                if any {
                    changed(book)
                } else {
                    Reduction::same(book, Disposition::Unchanged)
                }
            }
            Event::Ask {
                id,
                question,
                text,
                options,
                media,
                thread,
                now,
            } => {
                let text = text.trim();
                if text.is_empty() {
                    return Reduction::same(
                        book,
                        Disposition::Rejected("A question needs its text".into()),
                    );
                }
                let Some(task) = book.tasks.get_mut(&id) else {
                    return missing(book, &id);
                };
                let before = task.status;
                task.questions.push(Question {
                    id: question,
                    text: text.chars().take(1000).collect(),
                    options: options
                        .iter()
                        .map(|o| o.trim().chars().take(120).collect::<String>())
                        .filter(|o| !o.is_empty())
                        .take(6)
                        .collect(),
                    media,
                    thread_id: thread,
                    asked_at: now,
                    state: QuestionState::Open,
                });
                task.touch(now);
                task.stir(now);
                if !task.status.open() {
                    task.replaced_by = None;
                    let rest = task.rest();
                    task.set(rest, By::Agent, None, now);
                }
                let after = task.status;
                book.bubble(&id, after != before, By::Agent, now);
                changed(book)
            }
            Event::Answer {
                question,
                text,
                now,
            } => {
                let text = text.trim();
                if text.is_empty() {
                    return Reduction::same(
                        book,
                        Disposition::Rejected("The answer is empty".into()),
                    );
                }
                let state = QuestionState::Answered {
                    text: text.chars().take(4000).collect(),
                    at: now,
                    owed: true,
                };
                close_question(book, &question, state, By::User, now)
            }
            Event::Withdraw { question, now } => close_question(
                book,
                &question,
                QuestionState::Withdrawn { at: now },
                By::Agent,
                now,
            ),
            Event::Delivered { question } => {
                let owed = book
                    .tasks
                    .values_mut()
                    .flat_map(|t| t.questions.iter_mut())
                    .find_map(|q| match &mut q.state {
                        QuestionState::Answered { owed, .. } if q.id == question && *owed => {
                            Some(owed)
                        }
                        _ => None,
                    });
                match owed {
                    Some(owed) => {
                        *owed = false;
                        changed(book)
                    }
                    None => Reduction::same(book, Disposition::Unchanged),
                }
            }
            Event::Migrate { now } => {
                // From before `active_at`: a work item was last active when
                // it or one of its sub-tasks was.
                let undated: Vec<String> = book
                    .tasks
                    .values_mut()
                    .filter(|t| t.undated)
                    .map(|t| {
                        t.undated = false;
                        t.revision += 1;
                        t.id.clone()
                    })
                    .collect();
                for id in &undated {
                    if let Some(active) = book.children(id).map(|t| t.active_at).max() {
                        book.tasks.get_mut(id).expect("listed above").stir(active);
                    }
                }
                let migrated: Vec<String> = book
                    .tasks
                    .values_mut()
                    .filter(|t| t.migrated)
                    .map(|t| {
                        t.migrated = false;
                        t.revision += 1;
                        t.parent.clone().unwrap_or_else(|| t.id.clone())
                    })
                    .collect();
                if migrated.is_empty() && undated.is_empty() {
                    return Reduction::same(book, Disposition::Unchanged);
                }
                // The work items among them or above them roll up again.
                for id in std::collections::BTreeSet::from_iter(migrated) {
                    if book.children(&id).next().is_some() {
                        book.rederive(&id, By::Auto, now);
                    }
                }
                changed(book)
            }
            Event::AgeDue { now } => {
                let mut any = false;
                for task in book.tasks.values_mut().filter(|t| t.ages(now)) {
                    task.placement = Placement::History { since: now };
                    task.revision += 1;
                    any = true;
                }
                if any {
                    changed(book)
                } else {
                    Reduction::same(book, Disposition::Unchanged)
                }
            }
        }
    }

    fn violations(book: &Book) -> Vec<Violation> {
        let mut found = vec![];
        for (key, task) in &book.tasks {
            if *key != task.id {
                found.push(Violation(format!("task {} kept under {key}", task.id)));
            }
            if task.observed.revision > task.revision {
                found.push(Violation(format!(
                    "task {} observed at revision {} past its own {}",
                    task.id, task.observed.revision, task.revision
                )));
            }
            if task
                .history
                .last()
                .is_some_and(|change| change.status != Status::from(task.status))
            {
                found.push(Violation(format!(
                    "task {} status differs from its last change",
                    task.id
                )));
            }
            if task.asking() && !task.status.open() {
                found.push(Violation(format!(
                    "task {} has an open question but is closed",
                    task.id
                )));
            }
            if let Some(parent) = &task.parent {
                match book.tasks.get(parent) {
                    Some(item) if item.parent.is_none() && item.project_id == task.project_id => {}
                    _ => found.push(Violation(format!(
                        "sub-task {} under {parent}, which is no work item of its app",
                        task.id
                    ))),
                }
            }
        }
        found
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const B: &str = "00000000-0000-4000-8000-00000000000b";
    const C: &str = "00000000-0000-4000-8000-00000000000c";

    fn step(book: Book, event: Event) -> Book {
        let reduction = M17::reduce(book, event);
        assert_eq!(M17::violations(&reduction.state), vec![]);
        reduction.state
    }

    /// A task linked to worker `w` and builds `b`, `c`; returns the book and its ID.
    fn book() -> (Book, String) {
        let id = TaskID::fresh();
        let book = step(
            Book::default(),
            Event::Add {
                id: id.clone(),
                project: "p".into(),
                title: "Stack the sims".into(),
                ask: " Stack the sims ".into(),
                status: None,
                note: None,
                by: By::Agent,
                source: None,
                threads: vec!["w".into()],
                parent: None,
                now: 0,
            },
        );
        let id = id.to_string();
        let book = [B, C].into_iter().fold(book, |book, build| {
            step(
                book,
                Event::Link {
                    id: id.clone(),
                    thread: None,
                    build: Some(BuildID::parse(build).unwrap()),
                    now: 0,
                },
            )
        });
        (book, id)
    }

    fn worker(turn: &str, phase: WorkerPhase) -> Signals {
        Signals {
            revision: None,
            workers: vec![WorkerSignal {
                thread: "w".into(),
                turn: Some(turn.into()),
                phase,
            }],
            builds: vec![],
        }
    }

    fn with_build(mut signals: Signals, build: &str, phase: BuildPhase) -> Signals {
        signals.builds.push(BuildSignal {
            build: build.into(),
            phase,
        });
        signals
    }

    /// Linked work as a tick reads it, against the task's current revision.
    fn observe(book: Book, id: &str, signals: Signals, now: u64) -> (Book, Disposition) {
        let revision = book.get(id).unwrap().revision;
        let reduction = M17::reduce(
            book,
            Event::Observe {
                reads: vec![(id.into(), revision, signals)],
                now,
            },
        );
        assert_eq!(M17::violations(&reduction.state), vec![]);
        (reduction.state, reduction.disposition)
    }

    fn set(
        book: Book,
        id: &str,
        status: Status,
        by: By,
        observed: Option<Signals>,
        now: u64,
    ) -> Book {
        let update = Update {
            status: Some(status),
            ..Default::default()
        };
        step(
            book,
            Event::Edit {
                id: id.into(),
                update,
                by,
                observed,
                now,
            },
        )
    }

    #[test]
    fn a_closed_task_ignores_old_work_finishing_but_reopens_for_the_next_turn() {
        let (book, id) = book();
        let (book, _) = observe(
            book,
            &id,
            with_build(worker("1", WorkerPhase::Working), B, BuildPhase::Running),
            10,
        );
        // The user calls it done while the worker and its build still run.
        let book = set(book, &id, Status::Done, By::User, None, 11);
        let (book, recorded) = observe(
            book,
            &id,
            with_build(worker("1", WorkerPhase::Done), B, BuildPhase::Succeeded),
            12,
        );
        assert_eq!(
            (book.get(&id).unwrap().status, recorded),
            (Status::Done, Disposition::Applied)
        );
        // The next turn starts (B-T01: this read as nothing new).
        let (book, _) = observe(
            book,
            &id,
            with_build(worker("2", WorkerPhase::Working), B, BuildPhase::Succeeded),
            13,
        );
        assert_eq!(book.get(&id).unwrap().status, Status::InProgress);
        // A whole turn between two reads still counts as new work.
        let book = set(book, &id, Status::Done, By::User, None, 14);
        let (book, _) = observe(
            book,
            &id,
            with_build(worker("2", WorkerPhase::Done), B, BuildPhase::Succeeded),
            15,
        );
        let (book, _) = observe(
            book,
            &id,
            with_build(worker("3", WorkerPhase::Done), B, BuildPhase::Succeeded),
            16,
        );
        assert_eq!(book.get(&id).unwrap().status, Status::ReadyToTry);
    }

    #[test]
    fn a_replaced_ask_stays_dropped_while_its_worker_goes_on() {
        let (book, id) = book();
        let later = TaskID::fresh();
        let book = step(
            book,
            Event::Add {
                id: later.clone(),
                project: "p".into(),
                title: "Stack the sims".into(),
                ask: "Stack them, fold only the tall ones".into(),
                status: None,
                note: None,
                by: By::Agent,
                source: None,
                threads: vec!["w".into()],
                parent: None,
                now: 1,
            },
        );
        let (book, _) = observe(book, &id, worker("1", WorkerPhase::Working), 2);
        let replace = Update {
            replaced_by: Some(later.to_string()),
            ..Default::default()
        };
        let book = step(
            book,
            Event::Edit {
                id: id.clone(),
                update: replace,
                by: By::Agent,
                observed: None,
                now: 3,
            },
        );
        // The same worker takes the next turn on the later ask: new work, but
        // not on the ask it replaced.
        let (book, _) = observe(book, &id, worker("2", WorkerPhase::Working), 4);
        let task = book.get(&id).unwrap();
        assert_eq!(
            (task.status, task.replaced_by.as_deref()),
            (Status::Dropped, Some(later.as_str()))
        );
        // Reopening it by hand undoes the replacement.
        let book = set(book, &id, Status::Queued, By::User, None, 5);
        assert_eq!(book.get(&id).unwrap().replaced_by, None);
    }

    #[test]
    fn a_question_holds_needs_you_against_linked_work_until_answered() {
        let (book, id) = book();
        let ask = |book: Book, question: &str, now: u64| {
            step(
                book,
                Event::Ask {
                    id: id.clone(),
                    question: question.into(),
                    text: "Top or bottom?".into(),
                    options: vec!["Top".into(), "Bottom".into()],
                    media: Vec::new(),
                    thread: "agent".into(),
                    now,
                },
            )
        };
        let book = ask(book, "q1", 1);
        assert_eq!(book.get(&id).unwrap().status, Status::NeedsYou);
        // The worker starting a new turn doesn't move it off needs you.
        let (book, _) = observe(book, &id, worker("2", WorkerPhase::Working), 2);
        assert_eq!(book.get(&id).unwrap().status, Status::NeedsYou);
        let answer = |book: Book, now: u64| {
            M17::reduce(
                book,
                Event::Answer {
                    question: "q1".into(),
                    text: "Bottom".into(),
                    now,
                },
            )
        };
        // Answered, it shows the worker still running.
        let reduction = answer(book, 3);
        let book = reduction.state;
        assert_eq!(book.get(&id).unwrap().status, Status::InProgress);
        // The same answer again (the phone retrying) is no new answer.
        let again = answer(book, 4);
        assert!(!matches!(again.disposition, Disposition::Rejected(_)));
        assert_eq!(again.state.get(&id).unwrap().status, Status::InProgress);
        // Closing the task withdraws a question still open.
        let book = set(
            ask(again.state, "q2", 5),
            &id,
            Status::Done,
            By::User,
            None,
            6,
        );
        let task = book.get(&id).unwrap();
        assert_eq!(task.status, Status::Done);
        assert!(matches!(
            task.questions[1].state,
            QuestionState::Withdrawn { .. }
        ));
    }

    #[test]
    fn needs_you_shows_only_while_something_waits_and_is_never_set() {
        let (book, id) = book();
        let refused = M17::reduce(
            book.clone(),
            Event::Edit {
                id: id.clone(),
                update: Update {
                    status: Some(Status::NeedsYou),
                    ..Default::default()
                },
                by: By::Agent,
                observed: None,
                now: 1,
            },
        );
        assert!(matches!(refused.disposition, Disposition::Rejected(_)));
        // A sub-task's question shows on it and its work item, and leaves with
        // the question.
        let sub = TaskID::fresh();
        let book = step(
            book,
            Event::Add {
                id: sub.clone(),
                project: "p".into(),
                title: "Stack the sims".into(),
                ask: "Fold from the bottom".into(),
                status: None,
                note: None,
                by: By::Agent,
                source: None,
                threads: vec![],
                parent: Some(id.clone()),
                now: 2,
            },
        );
        let book = step(
            book,
            Event::Ask {
                id: sub.to_string(),
                question: "q".into(),
                text: "Which edge?".into(),
                options: vec![],
                media: vec![],
                thread: "agent".into(),
                now: 3,
            },
        );
        assert_eq!(book.get(&id).unwrap().status, Status::NeedsYou);
        let book = step(
            book,
            Event::Withdraw {
                question: "q".into(),
                now: 4,
            },
        );
        assert_eq!(book.get(&id).unwrap().status, Status::Queued);
        // A linked worker waiting on its own question shows, then its finish.
        let (book, _) = observe(book, &id, worker("1", WorkerPhase::NeedsYou), 5);
        assert_eq!(book.get(&id).unwrap().status, Status::NeedsYou);
        let (book, _) = observe(book, &id, worker("1", WorkerPhase::Done), 6);
        assert_ne!(book.get(&id).unwrap().status, Status::NeedsYou);
    }

    #[test]
    fn a_kept_needs_you_reads_back_as_the_stage_before_it() {
        let json = serde_json::json!({"tasks": {"t": {
            "id": "t", "project_id": "p", "ask": "Stack the sims", "status": "needs_you",
            "note": "pick a layout", "threads": [], "builds": [], "order": 1.0,
            "created_at": 1, "updated_at": 2, "revision": 3,
            "history": [
                {"at": 1, "status": "ready_to_try", "by": "auto"},
                {"at": 2, "status": "needs_you", "by": "agent"}
            ]
        }}});
        let book: Book = serde_json::from_value(json).unwrap();
        assert!(book.migrated());
        assert_eq!(book.get("t").unwrap().status, Status::ReadyToTry);
        let book = step(book, Event::Migrate { now: 9 });
        assert!(!book.migrated());
        let saved: Book = serde_json::from_value(serde_json::to_value(&book).unwrap()).unwrap();
        assert!(!saved.migrated());
    }
    #[test]
    fn in_progress_shows_only_while_linked_work_runs_and_is_never_set() {
        let (book, id) = book();
        let refused = M17::reduce(
            book.clone(),
            Event::Edit {
                id: id.clone(),
                update: Update {
                    status: Some(Status::InProgress),
                    ..Default::default()
                },
                by: By::Agent,
                observed: None,
                now: 1,
            },
        );
        assert!(matches!(refused.disposition, Disposition::Rejected(_)));
        // No work yet: queued. A worker running: in progress over queued.
        assert_eq!(book.get(&id).unwrap().status, Status::Queued);
        let (book, _) = observe(book, &id, worker("1", WorkerPhase::Working), 2);
        assert_eq!(book.get(&id).unwrap().status, Status::InProgress);
        // It stops: ready to try, as work has happened.
        let (book, _) = observe(book, &id, worker("1", WorkerPhase::Done), 3);
        assert_eq!(book.get(&id).unwrap().status, Status::ReadyToTry);
        // A build queued and running shows; its failing leaves it resting.
        let (book, _) = observe(
            book,
            &id,
            with_build(worker("1", WorkerPhase::Done), B, BuildPhase::Queued),
            4,
        );
        assert_eq!(book.get(&id).unwrap().status, Status::InProgress);
        let (book, _) = observe(
            book,
            &id,
            with_build(worker("1", WorkerPhase::Done), B, BuildPhase::Failed),
            5,
        );
        assert_eq!(book.get(&id).unwrap().status, Status::ReadyToTry);
        // A worker archived mid-turn no longer runs.
        let (book, _) = observe(book, &id, worker("2", WorkerPhase::Working), 6);
        assert_eq!(book.get(&id).unwrap().status, Status::InProgress);
        let (book, _) = observe(book, &id, worker("2", WorkerPhase::Gone), 7);
        assert_eq!(book.get(&id).unwrap().status, Status::ReadyToTry);
        // A stale "unknown" read keeps what was last seen.
        let (book, _) = observe(book, &id, worker("2", WorkerPhase::Missing), 8);
        assert_eq!(book.get(&id).unwrap().status, Status::ReadyToTry);
    }

    #[test]
    fn a_work_item_shows_its_sub_tasks_running_and_rests_by_their_stages() {
        let (book, id) = book();
        let add = |book: Book, sub: &TaskID, now: u64| {
            step(
                book,
                Event::Add {
                    id: sub.clone(),
                    project: "p".into(),
                    title: "Fold".into(),
                    ask: "Fold from the bottom".into(),
                    status: None,
                    note: None,
                    by: By::Agent,
                    source: None,
                    threads: vec!["s".into()],
                    parent: Some(id.clone()),
                    now,
                },
            )
        };
        let (first, second) = (TaskID::fresh(), TaskID::fresh());
        let book = add(add(book, &first, 1), &second, 1);
        assert_eq!(book.get(&id).unwrap().status, Status::Queued);
        let sub = |phase| Signals {
            revision: None,
            workers: vec![WorkerSignal {
                thread: "s".into(),
                turn: Some("1".into()),
                phase,
            }],
            builds: vec![],
        };
        let (book, _) = observe(book, first.as_str(), sub(WorkerPhase::Working), 2);
        let item = book.get(&id).unwrap();
        assert_eq!(
            (
                item.status,
                item.subtasks.iter().map(|t| t.status).collect()
            ),
            (Status::InProgress, vec![Status::InProgress, Status::Queued])
        );
        // One finished, one still queued: the item rests at ready to try.
        let (book, _) = observe(book, first.as_str(), sub(WorkerPhase::Done), 3);
        assert_eq!(book.get(&id).unwrap().status, Status::ReadyToTry);
        // Closed by the user, then a sub-task's worker runs again: it reopens.
        let book = set(book, &id, Status::Done, By::User, None, 4);
        let (book, _) = observe(book, first.as_str(), sub(WorkerPhase::Done), 5);
        assert_eq!(book.get(&id).unwrap().status, Status::Done);
        let next = Signals {
            workers: vec![WorkerSignal {
                thread: "s".into(),
                turn: Some("2".into()),
                phase: WorkerPhase::Working,
            }],
            ..Default::default()
        };
        let (book, _) = observe(book, first.as_str(), next, 6);
        assert_eq!(book.get(&id).unwrap().status, Status::InProgress);
    }

    #[test]
    fn a_kept_in_progress_reads_back_as_where_it_rests() {
        let record = |id: &str, parent: Option<&str>, status: &str, history: &[&str]| {
            serde_json::json!({
                "id": id, "project_id": "p", "parent": parent, "ask": "Stack the sims",
                "status": status, "note": "Merged; build coming", "threads": [], "builds": [],
                "order": 1.0, "created_at": 1, "updated_at": 2, "revision": 3,
                "history": history.iter().map(|s| serde_json::json!({"at": 1, "status": s, "by": "agent"})).collect::<Vec<_>>()
            })
        };
        let json = serde_json::json!({"tasks": {
            "item": record("item", None, "in_progress", &["queued", "in_progress"]),
            "a": record("a", Some("item"), "in_progress", &["queued", "in_progress"]),
            "b": record("b", Some("item"), "in_progress", &["ready_to_try", "in_progress"]),
        }});
        let book: Book = serde_json::from_value(json).unwrap();
        assert!(book.migrated());
        let status = |book: &Book, id: &str| book.get(id).unwrap().status;
        // Never worked on: queued; with a result before: ready to try.
        assert_eq!(status(&book, "a"), Status::Queued);
        assert_eq!(status(&book, "b"), Status::ReadyToTry);
        let book = step(book, Event::Migrate { now: 9 });
        assert_eq!(status(&book, "item"), Status::ReadyToTry);
        let saved: Book = serde_json::from_value(serde_json::to_value(&book).unwrap()).unwrap();
        assert!(!saved.migrated());
    }
}
