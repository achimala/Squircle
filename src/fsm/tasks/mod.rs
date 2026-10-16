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

use crate::fsm::core::{BuildID, Disposition, Machine, Reduction, TaskID, ThreadID, Violation};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, clap::ValueEnum)]
#[serde(rename_all = "snake_case")]
#[value(rename_all = "snake_case")]
pub enum Status {
    Queued,
    InProgress,
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
}

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

/// A task as readers see it: a copy of one saved revision. Changes go
/// through `Tasks`, which saves them before anyone can read them.
#[derive(Clone, Debug, Serialize)]
pub struct Task {
    pub id: String,
    /// The T3 project of the app.
    pub project_id: String,
    /// The ask in the user's own words.
    pub ask: String,
    pub status: Status,
    /// What it waits on or what happened, in a few words.
    pub note: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<Source>,
    pub threads: Vec<String>,
    pub builds: Vec<String>,
    /// Position within its status group; lower first.
    pub order: f64,
    pub created_at: u64,
    pub updated_at: u64,
    /// When it moved out of the active list into History.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub archived_at: Option<u64>,
    /// Rises with every saved change, including what linked work was seen doing.
    pub revision: u64,
    pub history: Vec<Change>,
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
    /// T3's `latestTurn.turnId`: a new turn is new work even when the state reads the same.
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

impl Signals {
    /// The status linked work implies, if any: a question, then work, then
    /// the newest linked build having succeeded.
    fn implied(&self) -> Option<Status> {
        if self.workers.iter().any(|w| w.phase == WorkerPhase::NeedsYou) {
            Some(Status::NeedsYou)
        } else if self.workers.iter().any(|w| w.phase == WorkerPhase::Working)
            || self.builds.iter().any(|b| matches!(b.phase, BuildPhase::Queued | BuildPhase::Running)) {
            Some(Status::InProgress)
        } else if self.builds.last().is_some_and(|b| b.phase == BuildPhase::Succeeded) {
            Some(Status::ReadyToTry)
        } else {
            None
        }
    }
}

impl Signals {
    /// The `id:state id:state` signature old `tasks.json` files kept as
    /// `seen` (worker states `working|needs-you|done|error`, build states
    /// `queued|running|succeeded|failed`).
    pub(crate) fn legacy(signature: &str) -> Self {
        let mut signals = Signals::default();
        for (id, state) in signature.split(' ').filter_map(|entry| entry.rsplit_once(':')) {
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
                signals.workers.push(WorkerSignal { thread: id.into(), turn: None, phase });
            } else if let Some(phase) = build {
                signals.builds.push(BuildSignal { build: id.into(), phase });
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
    fn next(&self, threads: &[String], builds: &[String], signals: &Signals) -> (Observation, News) {
        let mut next = Observation { revision: self.revision, ..Default::default() };
        let mut news = News::None;
        for id in threads {
            let old = self.workers.get(id);
            let fact = signals.workers.iter().find(|w| &w.thread == id && w.phase != WorkerPhase::Missing);
            let Some(fact) = fact else {
                if let Some(old) = old { next.workers.insert(id.clone(), old.clone()); }
                continue;
            };
            news = news.max(match old {
                None => News::NewWork,
                Some(WorkerSeen { turn: Some(turn), .. }) if fact.turn.as_ref().is_some_and(|t| t != turn) => News::NewWork,
                Some(old) if old.phase == fact.phase => News::None,
                Some(_) if matches!(fact.phase, WorkerPhase::Working | WorkerPhase::NeedsYou) => News::NewWork,
                Some(_) => News::Changed,
            });
            let turn = fact.turn.clone().or_else(|| old.and_then(|o| o.turn.clone()));
            next.workers.insert(id.clone(), WorkerSeen { turn, phase: fact.phase });
        }
        for id in builds {
            let old = self.builds.get(id);
            let fact = signals.builds.iter().find(|b| &b.build == id && b.phase != BuildPhase::Missing);
            let Some(fact) = fact else {
                if let Some(old) = old { next.builds.insert(id.clone(), *old); }
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
}

/// A task as it is kept. Status and its history change together (`set`).
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(from = "StoredRecord")]
struct Record {
    id: String,
    project_id: String,
    ask: String,
    status: Status,
    note: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    source: Option<Source>,
    threads: Vec<String>,
    builds: Vec<String>,
    order: f64,
    created_at: u64,
    updated_at: u64,
    placement: Placement,
    revision: u64,
    observed: Observation,
    history: Vec<Change>,
}

/// A record as read from disk, including files from before revisions
/// (2026-10-15), which kept `archived_at` and a `seen` signature instead.
#[derive(Deserialize)]
struct StoredRecord {
    id: String,
    project_id: String,
    ask: String,
    status: Status,
    #[serde(default)]
    note: String,
    #[serde(default)]
    source: Option<Source>,
    #[serde(default)]
    threads: Vec<String>,
    #[serde(default)]
    builds: Vec<String>,
    order: f64,
    created_at: u64,
    updated_at: u64,
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
}

impl From<StoredRecord> for Record {
    fn from(s: StoredRecord) -> Self {
        let placement = s.placement
            .or(s.archived_at.map(|since| Placement::History { since }))
            .unwrap_or(Placement::Active);
        let observed = s.observed.unwrap_or_else(|| {
            Observation::default().next(&s.threads, &s.builds, &Signals::legacy(&s.seen)).0
        });
        Record {
            id: s.id, project_id: s.project_id, ask: s.ask, status: s.status, note: s.note, source: s.source,
            threads: s.threads, builds: s.builds, order: s.order, created_at: s.created_at, updated_at: s.updated_at,
            placement, revision: s.revision, observed, history: s.history,
        }
    }
}

impl Record {
    fn publish(&self) -> Task {
        Task {
            id: self.id.clone(), project_id: self.project_id.clone(), ask: self.ask.clone(), status: self.status,
            note: self.note.clone(), source: self.source.clone(), threads: self.threads.clone(), builds: self.builds.clone(),
            order: self.order, created_at: self.created_at, updated_at: self.updated_at,
            archived_at: match self.placement { Placement::Active => None, Placement::History { since } => Some(since) },
            revision: self.revision, history: self.history.clone(),
        }
    }

    /// Any change to the task itself: it counts as touched and leaves History.
    fn touch(&mut self, now: u64) {
        self.updated_at = now;
        self.placement = Placement::Active;
        self.revision += 1;
    }

    fn set(&mut self, status: Status, by: By, note: Option<&str>, now: u64) {
        let note = note.map(str::trim);
        if status == self.status && note.is_none_or(|n| n == self.note) {
            return;
        }
        if let Some(note) = note {
            self.note = note.chars().take(300).collect();
        }
        self.status = status;
        self.touch(now);
        self.history.push(Change { at: now, status, by, note: self.note.clone() });
    }

    fn record(&mut self, observed: Observation) {
        self.revision += 1;
        self.observed = Observation { revision: self.revision, ..observed };
    }

    /// Follows linked workers and builds: when one of them has news since it
    /// was last seen, the status they imply replaces the current one. A done
    /// or dropped task reopens only for new work (a new link, a new turn, a
    /// worker working or asking again), not old work finishing; new work also
    /// brings a task back from History. Returns whether anything changed.
    fn follow(&mut self, signals: &Signals, now: u64) -> bool {
        let (next, news) = self.observed.next(&self.threads, &self.builds, signals);
        if next == self.observed {
            return false;
        }
        self.record(next);
        if news == News::None || (!self.status.open() && news != News::NewWork) {
            return true;
        }
        if news == News::NewWork {
            self.touch(now);
        }
        if let Some(status) = signals.implied().filter(|s| *s != self.status) {
            self.set(status, By::Auto, None, now);
        }
        true
    }

    /// An explicit status holds from what linked work was doing when it was
    /// chosen: that becomes the last observation, unless a newer one was
    /// recorded after `signals` were read.
    fn hold(&mut self, signals: &Signals) {
        if signals.revision.is_some_and(|base| base < self.observed.revision) {
            return;
        }
        let (next, _) = self.observed.next(&self.threads, &self.builds, signals);
        self.record(next);
    }

    fn ages(&self, now: u64) -> bool {
        let limit = if self.status.open() { STALE_AGE } else { DONE_AGE };
        self.placement == Placement::Active && now.saturating_sub(self.updated_at) >= limit
    }

    /// Whether linked work can still say anything: History tasks are skipped
    /// only when all they link is builds that have finished.
    fn watched(&self) -> bool {
        self.placement == Placement::Active || !self.threads.is_empty()
            || self.builds.iter().any(|b| !matches!(self.observed.builds.get(b), Some(BuildPhase::Succeeded | BuildPhase::Failed)))
    }
}

/// Every app's tasks: the aggregate one file (`tasks.json`) keeps.
#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Book {
    #[serde(default)]
    tasks: BTreeMap<String, Record>,
}

impl Book {
    pub fn get(&self, id: &str) -> Option<Task> {
        self.tasks.get(id).map(Record::publish)
    }

    pub fn list(&self, project: &str) -> Vec<Task> {
        self.tasks.values().filter(|t| t.project_id == project).map(Record::publish).collect()
    }

    pub fn all(&self) -> Vec<Task> {
        self.tasks.values().map(Record::publish).collect()
    }

    /// Tasks whose linked work a tick should read.
    pub fn watched(&self) -> Vec<Task> {
        self.tasks.values().filter(|t| t.watched()).map(Record::publish).collect()
    }
}

/// A change to a task. Fields left out are kept.
#[derive(Debug, Default, Deserialize)]
pub struct Update {
    pub ask: Option<String>,
    pub status: Option<Status>,
    pub note: Option<String>,
    /// Put it first in its group.
    #[serde(default)]
    pub to_top: bool,
}


/// Everything that can happen to the task book. Time and new IDs come in
/// the event; the reducer never reads a clock or allocates.
#[derive(Debug)]
pub enum Event {
    /// The user's ask, through the agent or the phone.
    Add { id: TaskID, project: String, ask: String, status: Option<Status>, note: Option<String>, by: By,
          source: Option<Source>, threads: Vec<String>, now: u64 },
    /// An explicit change. A status set this way holds from `observed`, what
    /// linked work was doing when it was chosen.
    Edit { id: String, update: Update, by: By, observed: Option<Signals>, now: u64 },
    Link { id: String, thread: Option<ThreadID>, build: Option<BuildID>, now: u64 },
    Unlink { id: String, thread: Option<ThreadID>, build: Option<BuildID>, now: u64 },
    /// A screenshot or clip was stored for the task.
    Attached { id: String, now: u64 },
    /// What linked work said, each read against the task revision it names.
    Observe { reads: Vec<(String, u64, Signals)>, now: u64 },
    /// Untouched tasks move into History.
    AgeDue { now: u64 },
}

#[derive(Debug, PartialEq, Eq)]
pub enum Effect {
    /// Save the new book; only then may anyone see it.
    Commit,
}

pub struct M17;

/// Adds (to the end) or removes a linked worker and build.
fn link(mut book: Book, id: &str, thread: Option<ThreadID>, build: Option<BuildID>, now: u64, remove: bool) -> Reduction<Book, Effect> {
    let Some(task) = book.tasks.get_mut(id) else { return missing(book, id) };
    for (list, value) in [(&mut task.threads, thread.map(String::from)), (&mut task.builds, build.map(String::from))] {
        let Some(value) = value else { continue };
        list.retain(|v| *v != value);
        if !remove { list.push(value); }
    }
    task.touch(now);
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
            Event::Add { id, project, ask, status, note, by, source, threads, now } => {
                let ask = ask.trim();
                if ask.is_empty() {
                    return Reduction::same(book, Disposition::Rejected("A task needs the user's ask".into()));
                }
                let order = book.tasks.values().filter(|t| t.project_id == project).map(|t| t.order).fold(0.0, f64::max) + 1.0;
                let status = status.unwrap_or(Status::Queued);
                let task = Record {
                    id: id.into(), project_id: project, ask: ask.chars().take(500).collect(),
                    status, note: note.map(|n| n.trim().chars().take(300).collect()).unwrap_or_default(), source, threads,
                    builds: vec![], order, created_at: now, updated_at: now, placement: Placement::Active, revision: 1,
                    observed: Observation::default(), history: vec![Change { at: now, status, by, note: String::new() }],
                };
                book.tasks.insert(task.id.clone(), task);
                changed(book)
            }
            Event::Edit { id, update, by, observed, now } => {
                let Some(project) = book.tasks.get(&id).map(|t| t.project_id.clone()) else { return missing(book, &id) };
                let lowest = book.tasks.values().filter(|t| t.project_id == project).map(|t| t.order).fold(f64::INFINITY, f64::min);
                let task = book.tasks.get_mut(&id).expect("checked above");
                if let Some(ask) = update.ask.as_deref().map(str::trim).filter(|a| !a.is_empty()) {
                    task.ask = ask.chars().take(500).collect();
                    task.touch(now);
                }
                match update.status {
                    Some(status) => task.set(status, by, update.note.as_deref(), now),
                    None => if let Some(note) = update.note.as_deref() {
                        let status = task.status;
                        task.set(status, by, Some(note), now);
                    },
                }
                if update.status.is_some() && let Some(observed) = observed {
                    task.hold(&observed);
                }
                if update.to_top {
                    task.order = lowest - 1.0;
                    task.touch(now);
                }
                changed(book)
            }
            Event::Link { id, thread, build, now } => link(book, &id, thread, build, now, false),
            Event::Unlink { id, thread, build, now } => link(book, &id, thread, build, now, true),
            Event::Attached { id, now } => {
                let Some(task) = book.tasks.get_mut(&id) else { return missing(book, &id) };
                task.touch(now);
                changed(book)
            }
            Event::Observe { reads, now } => {
                let mut any = false;
                for (id, revision, signals) in &reads {
                    // Read before a change made meanwhile: older news, dropped (the next tick reads again).
                    let Some(task) = book.tasks.get_mut(id).filter(|t| t.revision == *revision) else { continue };
                    any |= task.follow(signals, now);
                }
                if any { changed(book) } else { Reduction::same(book, Disposition::Unchanged) }
            }
            Event::AgeDue { now } => {
                let mut any = false;
                for task in book.tasks.values_mut().filter(|t| t.ages(now)) {
                    task.placement = Placement::History { since: now };
                    task.revision += 1;
                    any = true;
                }
                if any { changed(book) } else { Reduction::same(book, Disposition::Unchanged) }
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
                found.push(Violation(format!("task {} observed at revision {} past its own {}", task.id, task.observed.revision, task.revision)));
            }
            if task.history.last().is_some_and(|change| change.status != task.status) {
                found.push(Violation(format!("task {} status differs from its last change", task.id)));
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
        let book = step(Book::default(), Event::Add {
            id: id.clone(), project: "p".into(), ask: " Stack the sims ".into(), status: None, note: None, by: By::Agent,
            source: None, threads: vec!["w".into()], now: 0,
        });
        let id = id.to_string();
        let book = [B, C].into_iter().fold(book, |book, build| step(book, Event::Link {
            id: id.clone(), thread: None, build: Some(BuildID::parse(build).unwrap()), now: 0,
        }));
        (book, id)
    }

    fn worker(turn: &str, phase: WorkerPhase) -> Signals {
        Signals { revision: None, workers: vec![WorkerSignal { thread: "w".into(), turn: Some(turn.into()), phase }], builds: vec![] }
    }

    fn with_build(mut signals: Signals, build: &str, phase: BuildPhase) -> Signals {
        signals.builds.push(BuildSignal { build: build.into(), phase });
        signals
    }

    /// Linked work as a tick reads it, against the task's current revision.
    fn observe(book: Book, id: &str, signals: Signals, now: u64) -> (Book, Disposition) {
        let revision = book.get(id).unwrap().revision;
        let reduction = M17::reduce(book, Event::Observe { reads: vec![(id.into(), revision, signals)], now });
        assert_eq!(M17::violations(&reduction.state), vec![]);
        (reduction.state, reduction.disposition)
    }

    fn set(book: Book, id: &str, status: Status, by: By, observed: Option<Signals>, now: u64) -> Book {
        let update = Update { status: Some(status), ..Default::default() };
        step(book, Event::Edit { id: id.into(), update, by, observed, now })
    }

    #[test]
    fn linked_work_moves_status_but_an_explicit_one_holds_until_something_new() {
        let (book, id) = book();
        let (book, _) = observe(book, &id, worker("1", WorkerPhase::Working), 10);
        assert_eq!(book.get(&id).unwrap().status, Status::InProgress);
        // The agent says it's waiting on the user; the worker is still working.
        let book = set(book, &id, Status::NeedsYou, By::Agent, Some(worker("1", WorkerPhase::Working)), 11);
        let (book, unchanged) = observe(book, &id, worker("1", WorkerPhase::Working), 12);
        assert_eq!((book.get(&id).unwrap().status, unchanged), (Status::NeedsYou, Disposition::Unchanged));
        // Something new: a build is ready.
        let (book, _) = observe(book, &id, with_build(worker("1", WorkerPhase::Done), B, BuildPhase::Succeeded), 13);
        let task = book.get(&id).unwrap();
        assert_eq!((task.status, task.history.last().unwrap().by), (Status::ReadyToTry, By::Auto));
        // A worker or link going missing is no news.
        let (book, unchanged) = observe(book, &id, Signals::default(), 14);
        assert_eq!((book.get(&id).unwrap().status, unchanged), (Status::ReadyToTry, Disposition::Unchanged));
    }

    #[test]
    fn a_closed_task_ignores_old_work_finishing_but_reopens_for_the_next_turn() {
        let (book, id) = book();
        let (book, _) = observe(book, &id, with_build(worker("1", WorkerPhase::Working), B, BuildPhase::Running), 10);
        // The user calls it done while the worker and its build still run.
        let book = set(book, &id, Status::Done, By::User, None, 11);
        let (book, recorded) = observe(book, &id, with_build(worker("1", WorkerPhase::Done), B, BuildPhase::Succeeded), 12);
        assert_eq!((book.get(&id).unwrap().status, recorded), (Status::Done, Disposition::Applied));
        // The next turn starts (B-T01: this read as nothing new).
        let (book, _) = observe(book, &id, with_build(worker("2", WorkerPhase::Working), B, BuildPhase::Succeeded), 13);
        assert_eq!(book.get(&id).unwrap().status, Status::InProgress);
        // A whole turn between two reads still counts as new work.
        let book = set(book, &id, Status::Done, By::User, None, 14);
        let (book, _) = observe(book, &id, with_build(worker("2", WorkerPhase::Done), B, BuildPhase::Succeeded), 15);
        let (book, _) = observe(book, &id, with_build(worker("3", WorkerPhase::Done), B, BuildPhase::Succeeded), 16);
        assert_eq!(book.get(&id).unwrap().status, Status::ReadyToTry);
    }

    #[test]
    fn signals_read_before_a_change_are_dropped() {
        let (book, id) = book();
        let read_at = book.get(&id).unwrap().revision;
        let book = set(book, &id, Status::NeedsYou, By::User, None, 5);
        let reduction = M17::reduce(book, Event::Observe { reads: vec![(id.clone(), read_at, worker("1", WorkerPhase::Working))], now: 6 });
        assert_eq!(reduction.disposition, Disposition::Unchanged);
        assert_eq!(reduction.state.get(&id).unwrap().status, Status::NeedsYou);
    }

    #[test]
    fn linked_work_implies_questions_then_work_then_the_newest_build() {
        let implied = |signature: &str| Signals::legacy(signature).implied();
        assert_eq!(implied("w:working v:needs-you b:succeeded"), Some(Status::NeedsYou));
        assert_eq!(implied("w:done b:succeeded c:running"), Some(Status::InProgress));
        assert_eq!(implied("b:failed c:succeeded"), Some(Status::ReadyToTry));
        assert_eq!(implied("b:succeeded c:failed"), None);
    }

    #[test]
    fn tasks_age_into_history_and_come_back_when_touched() {
        let (book, id) = book();
        let book = set(book, &id, Status::Done, By::User, None, 0);
        let early = M17::reduce(book, Event::AgeDue { now: DONE_AGE - 1 });
        assert_eq!(early.disposition, Disposition::Unchanged);
        let book = step(early.state, Event::AgeDue { now: DONE_AGE });
        assert_eq!(book.get(&id).unwrap().archived_at, Some(DONE_AGE));
        let book = set(book, &id, Status::Queued, By::User, None, DONE_AGE + 5);
        assert_eq!(book.get(&id).unwrap().archived_at, None);
        let book = step(book, Event::AgeDue { now: DONE_AGE + 5 + STALE_AGE - 1 });
        assert_eq!(book.get(&id).unwrap().archived_at, None);
        let book = step(book, Event::AgeDue { now: DONE_AGE + 5 + STALE_AGE });
        assert_eq!(book.get(&id).unwrap().archived_at, Some(DONE_AGE + 5 + STALE_AGE));
    }

    #[test]
    fn requests_about_no_task_or_without_an_ask_are_refused() {
        let (book, _) = book();
        let refused = M17::reduce(book, Event::Attached { id: "nope".into(), now: 1 });
        assert_eq!((refused.disposition, refused.effects), (Disposition::Rejected("No task nope".into()), vec![]));
        let empty = M17::reduce(refused.state, Event::Add {
            id: TaskID::fresh(), project: "p".into(), ask: "  ".into(), status: None, note: None, by: By::User, source: None, threads: vec![], now: 1,
        });
        assert_eq!(empty.disposition, Disposition::Rejected("A task needs the user's ask".into()));
    }
}
