//! Tasks: what the user asked an app's agent for, in their words, and where
//! each ask stands. The agent keeps them (`squircle task`), the user sees and
//! edits them on the phone, and linked workers and builds move their status
//! on by themselves. Kept per app (T3 project) in `<data>/tasks.json`;
//! screenshots and clips attached to a task live in `<data>/tasks/<id>/media`.
//!
//! This is the task owner: it validates requests, gathers what linked work
//! is doing, feeds both to the M17 reducer (`crate::fsm::tasks`) and saves
//! each result through the commit gate before anyone can read it.

use crate::fsm::core::commit::{Gate, JsonFile};
use crate::fsm::core::{BuildID, Disposition, Machine, Revision, TaskID, ThreadID};
use crate::fsm::tasks::{Book, Effect, Event, M17};
use crate::media::{self, Media};
use anyhow::{Context, Result, anyhow, bail, ensure};
use std::{
    convert::Infallible,
    path::{Path, PathBuf},
    sync::Mutex,
};

pub use crate::fsm::tasks::{
    BuildPhase, BuildSignal, By, Change, Signals, Source, Status, Task, Update, WorkerPhase, WorkerSignal,
};

pub struct Tasks {
    root: PathBuf,
    book: Mutex<Gate<Book, Infallible, JsonFile>>,
}

impl Tasks {
    pub fn open(root: &Path) -> Result<Self> {
        let file = JsonFile::new(root.join("tasks.json"));
        let (book, revision) = file.read()?.unwrap_or((Book::default(), Revision::default()));
        Ok(Self { root: root.to_path_buf(), book: Mutex::new(Gate::restore(book, revision, file)) })
    }

    /// Reduces `events` in order and saves the result once, then makes it
    /// current: readers only ever see what is on disk. A blocked earlier save
    /// is settled first; a rejection or failed save leaves everything as it was.
    fn apply(&self, events: impl IntoIterator<Item = Event>) -> Result<std::sync::MutexGuard<'_, Gate<Book, Infallible, JsonFile>>> {
        let mut gate = self.book.lock().unwrap();
        gate.resolve()?;
        let mut book = gate.committed().clone();
        let mut commit = false;
        for event in events {
            let reduction = M17::reduce(book, event);
            if let Disposition::Rejected(reason) = reduction.disposition {
                bail!(reason);
            }
            book = reduction.state;
            commit |= reduction.effects.contains(&Effect::Commit);
        }
        #[cfg(debug_assertions)]
        for violation in M17::violations(&book) {
            eprintln!("Task invariant broken: {}", violation.0);
        }
        if commit {
            gate.commit(book, vec![])?;
        }
        Ok(gate)
    }

    fn task(gate: &Gate<Book, Infallible, JsonFile>, id: &str) -> Result<Task> {
        gate.committed().get(id).ok_or_else(|| anyhow!("No task {id}"))
    }

    pub fn media_dir(&self, id: &str) -> Result<PathBuf> {
        TaskID::parse(id).context("Task ID must be a UUID")?;
        Ok(self.root.join("tasks").join(id).join("media"))
    }

    pub fn get(&self, id: &str) -> Result<Task> {
        Self::task(&self.book.lock().unwrap(), id)
    }

    /// The app's tasks, active and in History.
    pub fn list(&self, project: &str) -> Vec<Task> {
        self.book.lock().unwrap().committed().list(project)
    }

    pub fn all(&self) -> Vec<Task> {
        self.book.lock().unwrap().committed().all()
    }

    pub fn add(&self, project: &str, ask: &str, status: Option<Status>, note: Option<&str>, by: By,
               source: Option<Source>, threads: Vec<String>) -> Result<Task> {
        let id = TaskID::fresh();
        let gate = self.apply([Event::Add {
            id: id.clone(), project: project.into(), ask: ask.into(), status, note: note.map(str::to_string), by, source, threads,
            now: crate::model::now(),
        }])?;
        Self::task(&gate, id.as_str())
    }

    /// An explicit change from the agent or the user. A status set this way
    /// holds until a linked worker or build changes after `observed`, what
    /// they were doing when it was chosen.
    pub fn update(&self, id: &str, update: Update, by: By, observed: Option<Signals>) -> Result<Task> {
        let gate = self.apply([Event::Edit { id: id.into(), update, by, observed, now: crate::model::now() }])?;
        Self::task(&gate, id)
    }

    pub fn link(&self, id: &str, thread: Option<&str>, build: Option<&str>, remove: bool) -> Result<Task> {
        ensure!(thread.is_some() || build.is_some(), "Pass a thread or a build to link");
        let thread = thread.map(ThreadID::parse).transpose().context("Thread and build IDs are UUIDs")?;
        let build = build.map(BuildID::parse).transpose().context("Thread and build IDs are UUIDs")?;
        let (id, now) = (id.to_string(), crate::model::now());
        let event = if remove { Event::Unlink { id: id.clone(), thread, build, now } } else { Event::Link { id: id.clone(), thread, build, now } };
        let gate = self.apply([event])?;
        Self::task(&gate, &id)
    }

    pub fn attach(&self, id: &str, file: &Path, caption: Option<&str>) -> Result<Media> {
        if !file.is_absolute() {
            bail!("Pass an absolute file path");
        }
        self.get(id)?;
        let media = media::add_in(&self.media_dir(id)?, id, file, caption)?;
        self.apply([Event::Attached { id: id.into(), now: crate::model::now() }]).map(drop)?;
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
    pub fn tick(&self, signals: impl Fn(&Task) -> Signals) -> Result<()> {
        let now = crate::model::now();
        let watched = self.book.lock().unwrap().committed().watched();
        let reads = watched.into_iter().map(|task| { let s = signals(&task); (task.id, task.revision, s) }).collect();
        self.apply([Event::Observe { reads, now }, Event::AgeDue { now }]).map(drop)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn worker(turn: &str, phase: WorkerPhase) -> Signals {
        Signals { revision: None, workers: vec![WorkerSignal { thread: "w".into(), turn: Some(turn.into()), phase }], builds: vec![] }
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
        tasks.tick(|_| Signals::legacy("w:done")).unwrap();
        assert_eq!(tasks.get("t").unwrap().archived_at, Some(5));
        tasks.tick(|_| worker("2", WorkerPhase::Working)).unwrap();
        let task = tasks.get("t").unwrap();
        assert_eq!((task.status, task.archived_at), (Status::InProgress, None));
        assert_eq!(Tasks::open(dir.path()).unwrap().get("t").unwrap().status, Status::InProgress);
    }

    #[test]
    fn an_explicit_status_still_holds_after_a_restart() {
        let dir = tempfile::tempdir().unwrap();
        let tasks = Tasks::open(dir.path()).unwrap();
        let id = tasks.add("p", "Stack the sims", None, None, By::Agent, None, vec!["w".into()]).unwrap().id;
        tasks.tick(|_| worker("1", WorkerPhase::Working)).unwrap();
        let needs_you = Update { status: Some(Status::NeedsYou), ..Default::default() };
        tasks.update(&id, needs_you, By::Agent, Some(worker("1", WorkerPhase::Working))).unwrap();
        let tasks = Tasks::open(dir.path()).unwrap();
        tasks.tick(|_| worker("1", WorkerPhase::Working)).unwrap();
        assert_eq!(tasks.get(&id).unwrap().status, Status::NeedsYou);
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
        let done = || Update { status: Some(Status::Done), ..Default::default() };
        assert!(tasks.update(&id, done(), By::User, None).is_err());
        let task = tasks.get(&id).unwrap();
        assert_eq!((task.status, task.revision, task.history.len()), (Status::Queued, 1, 1));
        // Once storage works again, the next change saves the change it couldn't
        // confirm first, then its own; nothing was published in between.
        std::fs::remove_dir(dir.path().join("tasks.json")).unwrap();
        let note = Update { note: Some("Waiting on Xcode".into()), ..Default::default() };
        let task = tasks.update(&id, note, By::User, None).unwrap();
        assert_eq!((task.status, task.note.as_str(), task.history.len()), (Status::Done, "Waiting on Xcode", 3));
        assert_eq!(Tasks::open(dir.path()).unwrap().get(&id).unwrap().note, "Waiting on Xcode");
    }
}
