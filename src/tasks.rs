//! Tasks: what the user asked an app's agent for, in their words, and where
//! each ask stands. The agent keeps them (`squircle task`), the user sees and
//! edits them on the phone, and linked workers and builds move their status
//! on by themselves. Kept per app (T3 project) in `<data>/tasks.json`;
//! screenshots and clips attached to a task live in `<data>/tasks/<id>/media`.
//!
//! This is the task owner: it validates requests, gathers what linked work
//! is doing, feeds both to the M17 reducer (`crate::fsm::tasks`) and saves
//! each result through the commit gate before anyone can read it.

use crate::actor::{Owner, Saved, Snapshot};
use crate::fsm::core::commit::{Gate, JsonFile};
use crate::fsm::core::{BuildID, Disposition, Machine, Revision, TaskID, ThreadID};
use crate::fsm::tasks::{Book, Effect, Event, M17};
use crate::media::{self, Media};
use anyhow::{Context, Result, anyhow, bail, ensure};
use std::{
    convert::Infallible,
    path::{Path, PathBuf},
};

pub use crate::fsm::tasks::{
    BuildPhase, BuildSignal, By, Change, Question, QuestionState, Signals, Source, Status, Task,
    Update, WorkerPhase, WorkerSignal,
};

/// The book as saved, for reading without the service (`squircle history`).
pub fn read(root: &Path) -> Result<Book> {
    Ok(JsonFile::new(root.join("tasks.json"))
        .read()?
        .map(|(book, _)| book)
        .unwrap_or_default())
}

/// The task owner's state: the book behind its commit gate, published once
/// a change is saved.
struct State {
    book: Saved<Book, Infallible, JsonFile>,
}

impl State {
    /// Reduces `events` in order and saves the result once, then publishes
    /// it: readers only ever see what is on disk. A blocked earlier save is
    /// settled first; a rejection or failed save leaves everything as it was.
    fn apply(&mut self, events: Vec<Event>) -> Result<()> {
        self.book.resolve()?;
        let mut book = self.book.committed().clone();
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
            self.book.commit(book, vec![])?;
        }
        Ok(())
    }

    fn apply_get(&mut self, events: Vec<Event>, id: &str) -> Result<Task> {
        self.apply(events)?;
        task(self.book.committed(), id)
    }
}

fn task(book: &Book, id: &str) -> Result<Task> {
    book.get(id).ok_or_else(|| anyhow!("No task {id}"))
}

/// What linked work said, read for each watched task at the revision it had.
pub struct Reads(Vec<(String, u64, Signals)>);

pub struct Tasks {
    root: PathBuf,
    owner: Owner<State>,
    book: Snapshot<Book>,
}

impl Tasks {
    pub fn open(root: &Path) -> Result<Self> {
        let file = JsonFile::new(root.join("tasks.json"));
        let (book, revision) = file
            .read()?
            .unwrap_or((Book::default(), Revision::default()));
        let migrated = book.migrated();
        let (book, snapshot) = Saved::new(Gate::restore(book, revision, file));
        let mut state = State { book };
        // Needs you kept as a status, from before it was derived: saved
        // once as the stage underneath (2026-10-31).
        if migrated {
            state.apply(vec![Event::Migrate {
                now: crate::model::now(),
            }])?;
        }
        let owner = Owner::spawn("tasks", state);
        Ok(Self {
            root: root.to_path_buf(),
            owner,
            book: snapshot,
        })
    }

    pub fn media_dir(&self, id: &str) -> Result<PathBuf> {
        TaskID::parse(id).context("Task ID must be a UUID")?;
        Ok(self.root.join("tasks").join(id).join("media"))
    }

    pub fn get(&self, id: &str) -> Result<Task> {
        task(&self.book.get(), id)
    }

    /// The app's work items, active and in History, each with its sub-tasks.
    pub fn list(&self, project: &str) -> Vec<Task> {
        self.book.get().list(project)
    }

    pub fn all(&self) -> Vec<Task> {
        self.book.get().all()
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn add(
        &self,
        project: &str,
        ask: &str,
        status: Option<Status>,
        note: Option<&str>,
        by: By,
        source: Option<Source>,
        threads: Vec<String>,
        parent: Option<&str>,
    ) -> Result<Task> {
        let id = TaskID::fresh();
        let event = Event::Add {
            id: id.clone(),
            project: project.into(),
            ask: ask.into(),
            status,
            note: note.map(str::to_string),
            by,
            source,
            threads,
            parent: parent.map(str::to_string),
            now: crate::model::now(),
        };
        self.owner
            .ask(move |s| s.apply_get(vec![event], id.as_str()))
            .await
    }

    /// An explicit change from the agent or the user. A status set this way
    /// holds until a linked worker or build changes after `observed`, what
    /// they were doing when it was chosen.
    pub async fn update(
        &self,
        id: &str,
        update: Update,
        by: By,
        observed: Option<Signals>,
    ) -> Result<Task> {
        let (id, now) = (id.to_string(), crate::model::now());
        self.owner
            .ask(move |s| {
                s.apply_get(
                    vec![Event::Edit {
                        id: id.clone(),
                        update,
                        by,
                        observed,
                        now,
                    }],
                    &id,
                )
            })
            .await
    }

    pub async fn link(
        &self,
        id: &str,
        thread: Option<&str>,
        build: Option<&str>,
        remove: bool,
    ) -> Result<Task> {
        ensure!(
            thread.is_some() || build.is_some(),
            "Pass a thread or a build to link"
        );
        let thread = thread
            .map(ThreadID::parse)
            .transpose()
            .context("Thread and build IDs are UUIDs")?;
        let build = build
            .map(BuildID::parse)
            .transpose()
            .context("Thread and build IDs are UUIDs")?;
        let (id, now) = (id.to_string(), crate::model::now());
        let event = if remove {
            Event::Unlink {
                id: id.clone(),
                thread,
                build,
                now,
            }
        } else {
            Event::Link {
                id: id.clone(),
                thread,
                build,
                now,
            }
        };
        self.owner.ask(move |s| s.apply_get(vec![event], &id)).await
    }

    /// Puts a question to the user on task `id` for `thread`, which gets the
    /// answer, with `files` (screenshots, clips, documents) copied into the
    /// task's media for it. The task shows as needs you until it is answered
    /// or withdrawn.
    pub async fn ask(
        &self,
        id: &str,
        text: &str,
        options: Vec<String>,
        files: &[PathBuf],
        thread: &str,
    ) -> Result<(Task, Question)> {
        ensure!(
            files.iter().all(|f| f.is_absolute()),
            "Pass absolute file paths"
        );
        self.get(id)?;
        let dir = self.media_dir(id)?;
        let mut media = Vec::new();
        for file in files {
            match media::add_in(&dir, id, file, None) {
                Ok(m) => media.push(m),
                Err(e) => {
                    media.iter().for_each(media::remove);
                    return Err(e);
                }
            }
        }
        let question = uuid::Uuid::new_v4().to_string();
        let event = Event::Ask {
            id: id.into(),
            question: question.clone(),
            text: text.into(),
            options,
            media: media.iter().map(|m| m.id.clone()).collect(),
            thread: thread.into(),
            now: crate::model::now(),
        };
        let asked = self
            .owner
            .ask(move |s| {
                s.apply(vec![event])?;
                s.book
                    .committed()
                    .question(&question)
                    .ok_or_else(|| anyhow!("No question {question}"))
            })
            .await;
        if asked.is_err() {
            media.iter().for_each(media::remove);
        }
        asked
    }

    /// The user's answer, or with `None` the asker withdrawing it.
    pub async fn close_question(
        &self,
        question: &str,
        answer: Option<&str>,
    ) -> Result<(Task, Question)> {
        let now = crate::model::now();
        let event = match answer {
            Some(text) => Event::Answer {
                question: question.into(),
                text: text.into(),
                now,
            },
            None => Event::Withdraw {
                question: question.into(),
                now,
            },
        };
        let question = question.to_string();
        self.owner
            .ask(move |s| {
                s.apply(vec![event])?;
                s.book
                    .committed()
                    .question(&question)
                    .ok_or_else(|| anyhow!("No question {question}"))
            })
            .await
    }

    /// Open questions, each with the task holding it.
    pub fn asking(&self) -> Vec<(Task, Question)> {
        self.book.get().asking()
    }

    /// Answered questions whose answer has not reached its asker yet.
    pub fn owed(&self) -> Vec<(Task, Question)> {
        self.book.get().owed()
    }

    /// Settles an answer's delivery once the notification owner has it.
    pub async fn delivered(&self, question: &str) -> Result<()> {
        let event = Event::Delivered {
            question: question.into(),
        };
        self.owner.ask(move |s| s.apply(vec![event])).await
    }

    /// The task holding question `id`, and the question.
    pub fn question(&self, id: &str) -> Result<(Task, Question)> {
        self.book
            .get()
            .question(id)
            .ok_or_else(|| anyhow!("No question {id}"))
    }

    pub async fn attach(&self, id: &str, file: &Path, caption: Option<&str>) -> Result<Media> {
        if !file.is_absolute() {
            bail!("Pass an absolute file path");
        }
        self.get(id)?;
        let media = media::add_in(&self.media_dir(id)?, id, file, caption)?;
        let event = Event::Attached {
            id: id.into(),
            now: crate::model::now(),
        };
        self.owner.ask(move |s| s.apply(vec![event])).await?;
        Ok(media)
    }

    pub fn media(&self, id: &str) -> Vec<Media> {
        self.media_dir(id)
            .ok()
            .and_then(|dir| media::list_in(&dir).ok())
            .unwrap_or_default()
    }

    /// One item each time the book is saved.
    pub fn changes(&self) -> futures_util::stream::BoxStream<'static, ()> {
        use futures_util::StreamExt;
        self.book.changes().boxed()
    }

    /// When the next task ages into History if nothing touches it (seconds
    /// since 1970).
    pub fn next_age(&self) -> Option<u64> {
        self.book.get().next_age()
    }

    /// Applies what linked workers and builds say, History tasks included,
    /// and ages tasks into History.
    pub async fn tick(&self, signals: impl Fn(&Task) -> Signals) -> Result<()> {
        self.observe(self.read(signals)).await
    }

    /// What linked work says of each watched task, read from the published
    /// book without the owner.
    pub fn read(&self, signals: impl Fn(&Task) -> Signals) -> Reads {
        Reads(
            self.book
                .get()
                .watched()
                .into_iter()
                .map(|task| {
                    let s = signals(&task);
                    (task.id, task.revision, s)
                })
                .collect(),
        )
    }

    /// Applies `reads` only to tasks still at the revision each was read at,
    /// so a change made meanwhile is never overwritten by older news (the
    /// next tick reads again), and ages tasks into History.
    pub async fn observe(&self, reads: Reads) -> Result<()> {
        let now = crate::model::now();
        self.owner
            .ask(move |s| {
                s.apply(vec![
                    Event::Observe {
                        reads: reads.0,
                        now,
                    },
                    Event::AgeDue { now },
                ])
            })
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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

    #[tokio::test]
    async fn an_explicit_status_still_holds_after_a_restart() {
        let dir = tempfile::tempdir().unwrap();
        let tasks = Tasks::open(dir.path()).unwrap();
        let id = tasks
            .add(
                "p",
                "Stack the sims",
                None,
                None,
                By::Agent,
                None,
                vec!["w".into()],
                None,
            )
            .await
            .unwrap()
            .id;
        tasks
            .tick(|_| worker("1", WorkerPhase::Working))
            .await
            .unwrap();
        let ready = Update {
            status: Some(Status::ReadyToTry),
            ..Default::default()
        };
        tasks
            .update(
                &id,
                ready,
                By::Agent,
                Some(worker("1", WorkerPhase::Working)),
            )
            .await
            .unwrap();
        let tasks = Tasks::open(dir.path()).unwrap();
        tasks
            .tick(|_| worker("1", WorkerPhase::Working))
            .await
            .unwrap();
        assert_eq!(tasks.get(&id).unwrap().status, Status::ReadyToTry);
    }

    #[tokio::test]
    async fn a_tick_read_before_an_explicit_change_does_not_overwrite_it() {
        let dir = tempfile::tempdir().unwrap();
        let tasks = Tasks::open(dir.path()).unwrap();
        let id = tasks
            .add(
                "p",
                "Stack the sims",
                None,
                None,
                By::Agent,
                None,
                vec!["w".into()],
                None,
            )
            .await
            .unwrap()
            .id;
        tasks
            .tick(|_| worker("1", WorkerPhase::Working))
            .await
            .unwrap();
        // While the tick reads the worker, the agent says the task is ready to try,
        // having seen the worker finish.
        let reads = tasks.read(|_| worker("1", WorkerPhase::Working));
        let finished = Signals {
            revision: Some(tasks.get(&id).unwrap().revision),
            ..worker("1", WorkerPhase::Done)
        };
        tasks
            .update(
                &id,
                Update {
                    status: Some(Status::ReadyToTry),
                    ..Default::default()
                },
                By::Agent,
                Some(finished),
            )
            .await
            .unwrap();
        tasks.observe(reads).await.unwrap();
        assert_eq!(tasks.get(&id).unwrap().status, Status::ReadyToTry);
        // The finish it saw is no news afterwards either.
        tasks
            .tick(|_| worker("1", WorkerPhase::Done))
            .await
            .unwrap();
        assert_eq!(tasks.get(&id).unwrap().status, Status::ReadyToTry);
    }

    #[tokio::test]
    async fn a_change_that_cannot_be_saved_is_not_seen() {
        let dir = tempfile::tempdir().unwrap();
        let tasks = Tasks::open(dir.path()).unwrap();
        let id = tasks
            .add(
                "p",
                "Stack the sims",
                None,
                None,
                By::Agent,
                None,
                vec![],
                None,
            )
            .await
            .unwrap()
            .id;
        std::fs::remove_file(dir.path().join("tasks.json")).unwrap();
        std::fs::create_dir(dir.path().join("tasks.json")).unwrap();
        let done = || Update {
            status: Some(Status::Done),
            ..Default::default()
        };
        assert!(tasks.update(&id, done(), By::User, None).await.is_err());
        let task = tasks.get(&id).unwrap();
        assert_eq!(
            (task.status, task.revision, task.history.len()),
            (Status::Queued, 1, 1)
        );
        // Once storage works again, the next change saves the change it couldn't
        // confirm first, then its own; nothing was published in between.
        std::fs::remove_dir(dir.path().join("tasks.json")).unwrap();
        let note = Update {
            note: Some("Waiting on Xcode".into()),
            ..Default::default()
        };
        let task = tasks.update(&id, note, By::User, None).await.unwrap();
        assert_eq!(
            (task.status, task.note.as_str(), task.history.len()),
            (Status::Done, "Waiting on Xcode", 3)
        );
        assert_eq!(
            Tasks::open(dir.path()).unwrap().get(&id).unwrap().note,
            "Waiting on Xcode"
        );
    }
}
