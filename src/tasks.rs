//! Tasks: what the user asked an app's agent for, in their words, and where
//! each ask stands. The agent keeps them (`squircle task`), the user sees and
//! edits them on the phone, and linked workers and builds move their status
//! on by themselves. Kept per app (T3 project) in `<data>/tasks.json`;
//! screenshots and clips attached to a task live in `<data>/tasks/<id>/media`.

use crate::media::{self, Media};
use crate::store::{atomic_json, read_json};
use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::Mutex,
};

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

/// The earlier `id:state id:state` signature (worker states are
/// `agents::worker_state`'s, build states `queued|running|succeeded|failed`),
/// read from old `tasks.json` files and from callers not yet passing `Signals`.
impl From<String> for Signals {
    fn from(signature: String) -> Self {
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

impl From<(String, Option<Status>)> for Signals {
    fn from((signature, _): (String, Option<Status>)) -> Self {
        signature.into()
    }
}

/// What linked workers and builds say a task's status is, if anything.
/// Worker states are `agents::worker_state`'s; build states `BuildState`'s.
pub fn derive(threads: &[&str], builds: &[&str]) -> Option<Status> {
    let pairs = threads.iter().chain(builds).map(|state| format!("x:{state}")).collect::<Vec<_>>().join(" ");
    Signals::from(pairs).implied()
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
            Observation::default().next(&s.threads, &s.builds, &Signals::from(s.seen)).0
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

#[derive(Clone, Default, Serialize, Deserialize)]
struct Book {
    #[serde(default)]
    tasks: BTreeMap<String, Record>,
}

/// A change to a task. Fields left out are kept.
#[derive(Default, Deserialize)]
pub struct Update {
    pub ask: Option<String>,
    pub status: Option<Status>,
    pub note: Option<String>,
    /// Put it first in its group.
    #[serde(default)]
    pub to_top: bool,
}

pub struct Tasks {
    root: PathBuf,
    book: Mutex<Book>,
}

impl Tasks {
    pub fn open(root: &Path) -> Result<Self> {
        let path = root.join("tasks.json");
        let book = if path.try_exists()? { read_json(&path)? } else { Book::default() };
        Ok(Self { root: root.to_path_buf(), book: Mutex::new(book) })
    }

    /// Saves the book with `staged` records in place, then makes it current:
    /// readers only ever see what is on disk.
    fn commit(&self, book: &mut Book, staged: impl IntoIterator<Item = Record>) -> Result<()> {
        let mut next = book.clone();
        for record in staged {
            next.tasks.insert(record.id.clone(), record);
        }
        atomic_json(&self.root.join("tasks.json"), &next)?;
        *book = next;
        Ok(())
    }

    pub fn media_dir(&self, id: &str) -> Result<PathBuf> {
        uuid::Uuid::parse_str(id).context("Task ID must be a UUID")?;
        Ok(self.root.join("tasks").join(id).join("media"))
    }

    pub fn get(&self, id: &str) -> Result<Task> {
        self.book.lock().unwrap().tasks.get(id).map(Record::publish).with_context(|| format!("No task {id}"))
    }

    /// The app's tasks, active and in History.
    pub fn list(&self, project: &str) -> Vec<Task> {
        self.book.lock().unwrap().tasks.values().filter(|t| t.project_id == project).map(Record::publish).collect()
    }

    pub fn all(&self) -> Vec<Task> {
        self.book.lock().unwrap().tasks.values().map(Record::publish).collect()
    }

    pub fn add(&self, project: &str, ask: &str, status: Option<Status>, note: Option<&str>, by: By,
               source: Option<Source>, threads: Vec<String>) -> Result<Task> {
        let ask = ask.trim();
        ensure!(!ask.is_empty(), "A task needs the user's ask");
        let now = crate::model::now();
        let mut book = self.book.lock().unwrap();
        let order = book.tasks.values().filter(|t| t.project_id == project).map(|t| t.order).fold(0.0, f64::max) + 1.0;
        let status = status.unwrap_or(Status::Queued);
        let task = Record {
            id: uuid::Uuid::new_v4().to_string(), project_id: project.into(), ask: ask.chars().take(500).collect(),
            status, note: note.map(|n| n.trim().chars().take(300).collect()).unwrap_or_default(), source, threads,
            builds: vec![], order, created_at: now, updated_at: now, placement: Placement::Active, revision: 1,
            observed: Observation::default(), history: vec![Change { at: now, status, by, note: String::new() }],
        };
        let published = task.publish();
        self.commit(&mut book, [task])?;
        Ok(published)
    }

    /// An explicit change from the agent or the user. A status set this way
    /// holds until a linked worker or build changes after `observed`, what
    /// they were doing when it was chosen.
    pub fn update<S: Into<Signals>>(&self, id: &str, update: Update, by: By, observed: Option<S>) -> Result<Task> {
        let now = crate::model::now();
        let mut book = self.book.lock().unwrap();
        let mut task = book.tasks.get(id).cloned().with_context(|| format!("No task {id}"))?;
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
            task.hold(&observed.into());
        }
        if update.to_top {
            task.order = book.tasks.values().filter(|t| t.project_id == task.project_id).map(|t| t.order).fold(f64::INFINITY, f64::min) - 1.0;
            task.touch(now);
        }
        let published = task.publish();
        self.commit(&mut book, [task])?;
        Ok(published)
    }

    pub fn link(&self, id: &str, thread: Option<&str>, build: Option<&str>, remove: bool) -> Result<Task> {
        ensure!(thread.is_some() || build.is_some(), "Pass a thread or a build to link");
        for value in [thread, build].into_iter().flatten() {
            uuid::Uuid::parse_str(value).context("Thread and build IDs are UUIDs")?;
        }
        let now = crate::model::now();
        let mut book = self.book.lock().unwrap();
        let mut task = book.tasks.get(id).cloned().with_context(|| format!("No task {id}"))?;
        for (list, value) in [(&mut task.threads, thread), (&mut task.builds, build)] {
            let Some(value) = value else { continue };
            list.retain(|v| v != value);
            if !remove { list.push(value.to_string()); }
        }
        task.touch(now);
        let published = task.publish();
        self.commit(&mut book, [task])?;
        Ok(published)
    }

    pub fn attach(&self, id: &str, file: &Path, caption: Option<&str>) -> Result<Media> {
        if !file.is_absolute() {
            bail!("Pass an absolute file path");
        }
        self.get(id)?;
        let media = media::add_in(&self.media_dir(id)?, id, file, caption)?;
        let mut book = self.book.lock().unwrap();
        if let Some(mut task) = book.tasks.get(id).cloned() {
            task.touch(crate::model::now());
            self.commit(&mut book, [task])?;
        }
        Ok(media)
    }

    pub fn media(&self, id: &str) -> Vec<Media> {
        self.media_dir(id).ok().and_then(|dir| media::list_in(&dir).ok()).unwrap_or_default()
    }

    /// Applies what linked workers and builds say, History tasks included,
    /// and ages tasks into History. `signals` runs outside the book's lock;
    /// what it says applies only to a task still at the revision it read,
    /// so a change made meanwhile is never overwritten by older news (the
    /// next tick reads again).
    pub fn tick<S: Into<Signals>>(&self, signals: impl Fn(&Task) -> S) -> Result<()> {
        let now = crate::model::now();
        let watched: Vec<Task> = self.book.lock().unwrap().tasks.values().filter(|t| t.watched()).map(Record::publish).collect();
        let read: Vec<(Task, Signals)> = watched.into_iter().map(|task| { let s = signals(&task).into(); (task, s) }).collect();
        let mut book = self.book.lock().unwrap();
        let mut staged: BTreeMap<String, Record> = BTreeMap::new();
        for (task, signals) in &read {
            let Some(current) = book.tasks.get(&task.id).filter(|t| t.revision == task.revision) else { continue };
            let mut record = current.clone();
            if record.follow(signals, now) {
                staged.insert(record.id.clone(), record);
            }
        }
        for current in book.tasks.values() {
            let record = staged.get(&current.id).unwrap_or(current);
            if record.ages(now) {
                let mut record = record.clone();
                record.placement = Placement::History { since: now };
                record.revision += 1;
                staged.insert(record.id.clone(), record);
            }
        }
        if staged.is_empty() {
            return Ok(());
        }
        self.commit(&mut book, staged.into_values())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record() -> Record {
        Record {
            id: "t".into(), project_id: "p".into(), ask: "Stack the sims".into(), status: Status::Queued, note: String::new(),
            source: None, threads: vec!["w".into()], builds: vec!["b".into(), "c".into()], order: 1.0, created_at: 0, updated_at: 0,
            placement: Placement::Active, revision: 1, observed: Observation::default(), history: vec![],
        }
    }

    fn worker(turn: &str, phase: WorkerPhase) -> Signals {
        Signals { revision: None, workers: vec![WorkerSignal { thread: "w".into(), turn: Some(turn.into()), phase }], builds: vec![] }
    }

    fn with_build(mut signals: Signals, build: &str, phase: BuildPhase) -> Signals {
        signals.builds.push(BuildSignal { build: build.into(), phase });
        signals
    }

    #[test]
    fn linked_work_moves_status_but_an_explicit_one_holds_until_something_new() {
        let mut task = record();
        assert!(task.follow(&worker("1", WorkerPhase::Working), 10));
        assert_eq!(task.status, Status::InProgress);
        // The agent says it's waiting on the user; the worker is still working.
        task.set(Status::NeedsYou, By::Agent, Some("Pick a layout"), 11);
        task.hold(&worker("1", WorkerPhase::Working));
        assert!(!task.follow(&worker("1", WorkerPhase::Working), 12));
        assert_eq!(task.status, Status::NeedsYou);
        // Something new: a build is ready.
        task.follow(&with_build(worker("1", WorkerPhase::Done), "b", BuildPhase::Succeeded), 13);
        assert_eq!(task.status, Status::ReadyToTry);
        assert_eq!(task.history.last().unwrap().by, By::Auto);
        // A worker or link going missing is no news.
        assert!(!task.follow(&Signals::default(), 14));
        assert_eq!(task.status, Status::ReadyToTry);
    }

    #[test]
    fn a_closed_task_ignores_old_work_finishing_but_reopens_for_the_next_turn() {
        let mut task = record();
        task.follow(&with_build(worker("1", WorkerPhase::Working), "b", BuildPhase::Running), 10);
        // The user calls it done while the worker and its build still run.
        task.set(Status::Done, By::User, None, 11);
        assert!(task.follow(&with_build(worker("1", WorkerPhase::Done), "b", BuildPhase::Succeeded), 12));
        assert_eq!(task.status, Status::Done);
        // The next turn starts (B-T01: this read as nothing new).
        task.follow(&with_build(worker("2", WorkerPhase::Working), "b", BuildPhase::Succeeded), 13);
        assert_eq!(task.status, Status::InProgress);
        // A whole turn between two reads still counts as new work.
        task.set(Status::Done, By::User, None, 14);
        task.follow(&with_build(worker("2", WorkerPhase::Done), "b", BuildPhase::Succeeded), 15);
        assert!(task.follow(&with_build(worker("3", WorkerPhase::Done), "b", BuildPhase::Succeeded), 16));
        assert_eq!(task.status, Status::ReadyToTry);
    }

    #[test]
    fn history_tasks_come_back_for_new_work_including_ones_saved_before_revisions() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("tasks.json"), r#"{"tasks": {"t": {"id": "t", "project_id": "p", "ask": "Stack the sims",
            "status": "done", "note": "", "threads": ["w"], "builds": [], "order": 1.0, "created_at": 0, "updated_at": 0,
            "archived_at": 5, "seen": "w:done", "history": []}}}"#).unwrap();
        let tasks = Tasks::open(dir.path()).unwrap();
        assert_eq!(tasks.get("t").unwrap().archived_at, Some(5));
        // Unchanged work leaves it where it is.
        tasks.tick(|_| Signals::from("w:done".to_string())).unwrap();
        assert_eq!(tasks.get("t").unwrap().archived_at, Some(5));
        tasks.tick(|_| worker("2", WorkerPhase::Working)).unwrap();
        let task = tasks.get("t").unwrap();
        assert_eq!((task.status, task.archived_at), (Status::InProgress, None));
        assert_eq!(Tasks::open(dir.path()).unwrap().get("t").unwrap().status, Status::InProgress);
    }

    #[test]
    fn a_tick_read_before_an_explicit_change_does_not_overwrite_it() {
        let dir = tempfile::tempdir().unwrap();
        let tasks = Tasks::open(dir.path()).unwrap();
        let id = tasks.add("p", "Stack the sims", None, None, By::Agent, None, vec!["w".into()]).unwrap().id;
        tasks.tick(|_| worker("1", WorkerPhase::Working)).unwrap();
        // While the tick reads the worker, the agent says the task needs the user,
        // having seen the worker finish.
        tasks.tick(|task| {
            let finished = Signals { revision: Some(task.revision), ..worker("1", WorkerPhase::Done) };
            tasks.update(&id, Update { status: Some(Status::NeedsYou), ..Default::default() }, By::Agent, Some(finished)).unwrap();
            worker("1", WorkerPhase::Working)
        }).unwrap();
        assert_eq!(tasks.get(&id).unwrap().status, Status::NeedsYou);
        // The finish it saw is no news afterwards either.
        tasks.tick(|_| worker("1", WorkerPhase::Done)).unwrap();
        assert_eq!(tasks.get(&id).unwrap().status, Status::NeedsYou);
    }

    #[test]
    fn a_change_that_cannot_be_saved_is_not_seen() {
        let dir = tempfile::tempdir().unwrap();
        let tasks = Tasks::open(dir.path()).unwrap();
        let id = tasks.add("p", "Stack the sims", None, None, By::Agent, None, vec![]).unwrap().id;
        std::fs::remove_file(dir.path().join("tasks.json")).unwrap();
        std::fs::create_dir(dir.path().join("tasks.json")).unwrap();
        let done = Update { status: Some(Status::Done), ..Default::default() };
        assert!(tasks.update(&id, done, By::User, None::<Signals>).is_err());
        let task = tasks.get(&id).unwrap();
        assert_eq!((task.status, task.revision, task.history.len()), (Status::Queued, 1, 1));
    }

    #[test]
    fn derive_prefers_questions_then_work_then_the_newest_build() {
        assert_eq!(derive(&["working", "needs-you"], &["succeeded"]), Some(Status::NeedsYou));
        assert_eq!(derive(&["done"], &["succeeded", "running"]), Some(Status::InProgress));
        assert_eq!(derive(&[], &["failed", "succeeded"]), Some(Status::ReadyToTry));
        assert_eq!(derive(&[], &["succeeded", "failed"]), None);
    }

    #[test]
    fn tasks_age_into_history_and_come_back_when_touched() {
        let mut task = record();
        task.status = Status::Done;
        assert!(!task.ages(DONE_AGE - 1));
        assert!(task.ages(DONE_AGE));
        task.placement = Placement::History { since: DONE_AGE };
        task.set(Status::Queued, By::User, None, DONE_AGE + 5);
        assert_eq!(task.placement, Placement::Active);
        assert!(!task.ages(DONE_AGE + 5 + STALE_AGE - 1));
        assert!(task.ages(DONE_AGE + 5 + STALE_AGE));
    }
}
