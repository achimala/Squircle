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

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Task {
    pub id: String,
    /// The T3 project of the app.
    pub project_id: String,
    /// The ask in the user's own words.
    pub ask: String,
    pub status: Status,
    /// What it waits on or what happened, in a few words.
    #[serde(default)]
    pub note: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<Source>,
    #[serde(default)]
    pub threads: Vec<String>,
    #[serde(default)]
    pub builds: Vec<String>,
    /// Position within its status group; lower first.
    pub order: f64,
    pub created_at: u64,
    pub updated_at: u64,
    /// When it moved out of the active list into History.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub archived_at: Option<u64>,
    /// Linked workers' and builds' states when the status was last decided,
    /// so an explicit status holds until one of them changes.
    #[serde(default)]
    pub seen: String,
    #[serde(default)]
    pub history: Vec<Change>,
}

/// What linked workers and builds say a task's status is, if anything.
/// Worker states are `agents::worker_state`'s; build states `BuildState`'s.
pub fn derive(threads: &[&str], builds: &[&str]) -> Option<Status> {
    if threads.contains(&"needs-you") {
        Some(Status::NeedsYou)
    } else if threads.contains(&"working") || builds.iter().any(|b| matches!(*b, "queued" | "running")) {
        Some(Status::InProgress)
    } else if builds.last() == Some(&"succeeded") {
        Some(Status::ReadyToTry)
    } else {
        None
    }
}

/// Done or dropped tasks leave the active list after a day; open ones that
/// nothing has touched for three days, too. Both stay in History.
const DONE_AGE: u64 = 24 * 3600;
const STALE_AGE: u64 = 3 * 24 * 3600;

impl Task {
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

    fn touch(&mut self, now: u64) {
        self.updated_at = now;
        self.archived_at = None;
    }

    /// Follows linked workers and builds: when one of them has news since
    /// the status was last decided, the status they imply replaces the
    /// current one. A link going missing (an archived worker) is no news.
    /// A done or dropped task reopens only for new work: a new link, or a
    /// linked worker working or asking again, not old work finishing.
    /// Returns whether anything changed.
    pub fn follow(&mut self, signature: &str, derived: Option<Status>, now: u64) -> bool {
        if self.seen == signature {
            return false;
        }
        let seen: Vec<&str> = self.seen.split(' ').collect();
        let news: Vec<(&str, &str)> = signature.split(' ')
            .filter(|entry| !entry.is_empty() && !seen.contains(entry))
            .filter_map(|entry| entry.rsplit_once(':'))
            .filter(|(_, state)| *state != "missing")
            .collect();
        let linked = |id: &str| seen.iter().any(|entry| entry.rsplit_once(':').is_some_and(|(seen, _)| seen == id));
        let new_work = news.iter().any(|(id, state)| !linked(id) || matches!(*state, "working" | "needs-you"));
        if news.is_empty() || (!self.status.open() && !new_work) {
            return false;
        }
        self.seen = signature.to_string();
        if let Some(status) = derived.filter(|s| *s != self.status) {
            self.set(status, By::Auto, None, now);
        }
        true
    }

    /// Moves a task into History once it has aged out.
    pub fn age(&mut self, now: u64) -> bool {
        let limit = if self.status.open() { STALE_AGE } else { DONE_AGE };
        if self.archived_at.is_none() && now.saturating_sub(self.updated_at) >= limit {
            self.archived_at = Some(now);
            return true;
        }
        false
    }
}

#[derive(Default, Serialize, Deserialize)]
struct Book {
    #[serde(default)]
    tasks: BTreeMap<String, Task>,
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

    fn save(&self, book: &Book) -> Result<()> {
        atomic_json(&self.root.join("tasks.json"), book)
    }

    pub fn media_dir(&self, id: &str) -> Result<PathBuf> {
        uuid::Uuid::parse_str(id).context("Task ID must be a UUID")?;
        Ok(self.root.join("tasks").join(id).join("media"))
    }

    pub fn get(&self, id: &str) -> Result<Task> {
        self.book.lock().unwrap().tasks.get(id).cloned().with_context(|| format!("No task {id}"))
    }

    /// The app's tasks, active and in History.
    pub fn list(&self, project: &str) -> Vec<Task> {
        self.book.lock().unwrap().tasks.values().filter(|t| t.project_id == project).cloned().collect()
    }

    pub fn all(&self) -> Vec<Task> {
        self.book.lock().unwrap().tasks.values().cloned().collect()
    }

    pub fn add(&self, project: &str, ask: &str, status: Option<Status>, note: Option<&str>, by: By,
               source: Option<Source>, threads: Vec<String>) -> Result<Task> {
        let ask = ask.trim();
        ensure!(!ask.is_empty(), "A task needs the user's ask");
        let now = crate::model::now();
        let mut book = self.book.lock().unwrap();
        let order = book.tasks.values().filter(|t| t.project_id == project).map(|t| t.order).fold(0.0, f64::max) + 1.0;
        let status = status.unwrap_or(Status::Queued);
        let mut task = Task {
            id: uuid::Uuid::new_v4().to_string(), project_id: project.into(), ask: ask.chars().take(500).collect(),
            status, note: String::new(), source, threads, builds: vec![], order, created_at: now, updated_at: now,
            archived_at: None, seen: String::new(), history: vec![],
        };
        task.history.push(Change { at: now, status, by, note: String::new() });
        if let Some(note) = note { task.note = note.trim().chars().take(300).collect(); }
        book.tasks.insert(task.id.clone(), task.clone());
        self.save(&book)?;
        Ok(task)
    }

    /// An explicit change from the agent or the user. A status set this way
    /// holds until a linked worker or build changes (`signature`).
    pub fn update(&self, id: &str, update: Update, by: By, signature: Option<String>) -> Result<Task> {
        let now = crate::model::now();
        let mut book = self.book.lock().unwrap();
        let top = book.tasks.get(id).map(|t| t.project_id.clone()).map(|project| {
            book.tasks.values().filter(|t| t.project_id == project).map(|t| t.order).fold(f64::INFINITY, f64::min) - 1.0
        });
        let task = book.tasks.get_mut(id).with_context(|| format!("No task {id}"))?;
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
        if update.status.is_some() && let Some(signature) = signature {
            task.seen = signature;
        }
        if update.to_top && let Some(top) = top {
            task.order = top;
            task.touch(now);
        }
        let task = task.clone();
        self.save(&book)?;
        Ok(task)
    }

    pub fn link(&self, id: &str, thread: Option<&str>, build: Option<&str>, remove: bool) -> Result<Task> {
        ensure!(thread.is_some() || build.is_some(), "Pass a thread or a build to link");
        for value in [thread, build].into_iter().flatten() {
            uuid::Uuid::parse_str(value).context("Thread and build IDs are UUIDs")?;
        }
        let now = crate::model::now();
        let mut book = self.book.lock().unwrap();
        let task = book.tasks.get_mut(id).with_context(|| format!("No task {id}"))?;
        for (list, value) in [(&mut task.threads, thread), (&mut task.builds, build)] {
            let Some(value) = value else { continue };
            list.retain(|v| v != value);
            if !remove { list.push(value.to_string()); }
        }
        task.touch(now);
        let task = task.clone();
        self.save(&book)?;
        Ok(task)
    }

    pub fn attach(&self, id: &str, file: &Path, caption: Option<&str>) -> Result<Media> {
        if !file.is_absolute() {
            bail!("Pass an absolute file path");
        }
        self.get(id)?;
        let media = media::add_in(&self.media_dir(id)?, id, file, caption)?;
        let mut book = self.book.lock().unwrap();
        if let Some(task) = book.tasks.get_mut(id) {
            task.touch(crate::model::now());
        }
        self.save(&book)?;
        Ok(media)
    }

    pub fn media(&self, id: &str) -> Vec<Media> {
        self.media_dir(id).ok().and_then(|dir| media::list_in(&dir).ok()).unwrap_or_default()
    }

    /// Applies what linked workers and builds say and ages tasks into
    /// History. `signals` gives a task's signature and derived status.
    pub fn tick(&self, signals: impl Fn(&Task) -> (String, Option<Status>)) -> Result<()> {
        let now = crate::model::now();
        let current: Vec<Task> = self.all();
        let decided: BTreeMap<String, (String, Option<Status>)> = current.iter()
            .filter(|t| t.archived_at.is_none())
            .map(|t| (t.id.clone(), signals(t))).collect();
        let mut book = self.book.lock().unwrap();
        let mut changed = false;
        for task in book.tasks.values_mut() {
            if let Some((signature, derived)) = decided.get(&task.id) {
                changed |= task.follow(signature, *derived, now);
            }
            changed |= task.age(now);
        }
        if changed {
            self.save(&book)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn task() -> Task {
        Task {
            id: "t".into(), project_id: "p".into(), ask: "Stack the sims".into(), status: Status::Queued, note: String::new(),
            source: None, threads: vec![], builds: vec![], order: 1.0, created_at: 0, updated_at: 0, archived_at: None,
            seen: String::new(), history: vec![],
        }
    }

    #[test]
    fn linked_work_moves_status_but_an_explicit_one_holds_until_something_new() {
        let mut task = task();
        assert!(task.follow("w:working", derive(&["working"], &[]), 10));
        assert_eq!(task.status, Status::InProgress);
        // The agent says it's waiting on the user; the worker is still working.
        task.set(Status::NeedsYou, By::Agent, Some("Pick a layout"), 11);
        task.seen = "w:working".into();
        assert!(!task.follow("w:working", derive(&["working"], &[]), 12));
        assert_eq!(task.status, Status::NeedsYou);
        // Something new: a build is ready.
        task.follow("w:done b:succeeded", derive(&["done"], &["succeeded"]), 13);
        assert_eq!(task.status, Status::ReadyToTry);
        assert_eq!(task.history.last().unwrap().by, By::Auto);
        // A finished worker alone says nothing; the status stays.
        task.set(Status::Done, By::User, None, 14);
        task.follow("w:done", derive(&["done"], &[]), 15);
        assert_eq!(task.status, Status::Done);
    }

    #[test]
    fn a_closed_task_reopens_only_for_new_work() {
        let mut task = task();
        task.follow("w:working b:running", derive(&["working"], &["running"]), 10);
        // The user calls it done while the worker and its build still run.
        task.set(Status::Done, By::User, None, 11);
        task.seen = "w:working b:running".into();
        // Old work finishing, or the worker being archived, leaves it done.
        assert!(!task.follow("w:done b:succeeded", derive(&["done"], &["succeeded"]), 12));
        assert!(!task.follow("w:missing b:succeeded", derive(&["missing"], &["succeeded"]), 13));
        assert_eq!(task.status, Status::Done);
        // A new build is new work.
        assert!(task.follow("w:missing b:succeeded c:running", derive(&["missing"], &["succeeded", "running"]), 14));
        assert_eq!(task.status, Status::InProgress);
        // An open status ignores a worker going missing too.
        task.set(Status::NeedsYou, By::Agent, None, 15);
        task.seen = "w:done b:succeeded c:succeeded".into();
        assert!(!task.follow("w:missing b:succeeded c:succeeded", derive(&["missing"], &["succeeded", "succeeded"]), 16));
        assert_eq!(task.status, Status::NeedsYou);
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
        let mut task = task();
        task.status = Status::Done;
        assert!(!task.age(DONE_AGE - 1));
        assert!(task.age(DONE_AGE));
        task.set(Status::Queued, By::User, None, DONE_AGE + 5);
        assert_eq!(task.archived_at, None);
        assert!(!task.age(DONE_AGE + 5 + STALE_AGE - 1));
        assert!(task.age(DONE_AGE + 5 + STALE_AGE));
    }
}
