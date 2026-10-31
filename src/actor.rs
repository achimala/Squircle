//! Single owners: the only way the service shares state, built so that a
//! deadlock can't be written (docs/fsm-architecture.md §4, "Owners and who
//! may wait for whom").
//!
//! 1. **Owners never wait.** An owner's state lives inside one tokio task.
//!    The only way to it is a letter: a synchronous closure the owner runs in
//!    turn ([`Owner::ask`], [`Owner::tell`]). A letter can't `.await`, and the
//!    blocking calls are banned (`clippy.toml`, `tests/ownership.rs`), so it
//!    can't wait for anything, another owner included: every ask is answered.
//!    Nothing can be locked twice, or in two orders, because nothing is locked.
//! 2. **Readers read a published value.** What other components read without
//!    changing it, an owner publishes after each change ([`Published`]); a
//!    [`Snapshot`] hands out the current value and is never held.
//! 3. **Long async work waits only downhill.** Work with I/O that must not
//!    overlap (one creation per app, one cleanup pass) runs in a [`Lane`].
//!    Lanes have ranks ([`Rank`]): a task may enter a lane only above every
//!    lane it is in, which is checked on entry, so no two tasks can each hold
//!    a lane the other waits for.
//! 4. **Drop never locks or waits.** A guard that ends something (a claim,
//!    an exclusion, an abandoned start) tells its owner; the owner does the
//!    cleanup as its next letter.
//!
//! Mailboxes are unbounded: sending never waits, so a letter or a `Drop` may
//! tell any owner. Their senders are request handlers and service loops,
//! each bounded by the work it does.

use crate::fsm::core::Revision;
use crate::fsm::core::commit::{Gate, Refusal, Storage};
use std::{collections::HashMap, future::Future, hash::Hash, sync::Arc};
use tokio::sync::{mpsc, oneshot, watch};

type Letter<S> = Box<dyn FnOnce(&mut S) + Send>;

/// The handle to one owner's state. Cloning it shares the same owner.
pub struct Owner<S> {
    name: &'static str,
    mail: mpsc::UnboundedSender<Letter<S>>,
}

impl<S> Clone for Owner<S> {
    fn clone(&self) -> Self {
        Self {
            name: self.name,
            mail: self.mail.clone(),
        }
    }
}

impl<S: Send + 'static> Owner<S> {
    /// Moves `state` into its own task, which runs letters one at a time
    /// until every handle is gone. Call inside the runtime.
    pub fn spawn(name: &'static str, mut state: S) -> Self {
        let (mail, mut letters) = mpsc::unbounded_channel::<Letter<S>>();
        tokio::spawn(async move {
            while let Some(letter) = letters.recv().await {
                letter(&mut state);
            }
        });
        Self { name, mail }
    }

    /// Runs `letter` on the state, after every letter sent before it, and
    /// returns its answer. A letter that panics stops the owner, as a
    /// poisoned lock did: later asks panic too.
    pub async fn ask<R: Send + 'static>(
        &self,
        letter: impl FnOnce(&mut S) -> R + Send + 'static,
    ) -> R {
        let (reply, answer) = oneshot::channel();
        self.tell(move |state| {
            let _ = reply.send(letter(state));
        });
        match answer.await {
            Ok(answer) => answer,
            Err(_) => panic!("the {} owner has stopped", self.name),
        }
    }

    /// Queues `letter` and returns at once. What it does is seen by every
    /// letter sent after it, from anywhere.
    pub fn tell(&self, letter: impl FnOnce(&mut S) + Send + 'static) {
        // Only fails once the owner has stopped, when nothing it does matters.
        let _ = self.mail.send(Box::new(letter));
    }
}

/// An owner's side of a published value.
pub struct Published<T>(watch::Sender<Arc<T>>);

impl<T> Published<T> {
    pub fn new(value: T) -> (Self, Snapshot<T>) {
        let (sender, receiver) = watch::channel(Arc::new(value));
        (Self(sender), Snapshot(receiver))
    }

    pub fn set(&self, value: T) {
        self.0.send_replace(Arc::new(value));
    }

    pub fn get(&self) -> Arc<T> {
        self.0.borrow().clone()
    }
}

/// The latest published value, for any reader on any task.
pub struct Snapshot<T>(watch::Receiver<Arc<T>>);

impl<T> Clone for Snapshot<T> {
    fn clone(&self) -> Self {
        Self(self.0.clone())
    }
}

impl<T> Snapshot<T> {
    pub fn get(&self) -> Arc<T> {
        self.0.borrow().clone()
    }

    /// One item for each publication after this call (several published
    /// between two reads are one item); ends when the owner has stopped.
    pub fn changes(&self) -> impl futures_util::Stream<Item = ()> + Send + 'static
    where
        T: Send + Sync + 'static,
    {
        let mut receiver = self.0.clone();
        receiver.mark_unchanged();
        futures_util::stream::unfold(receiver, |mut receiver| async move {
            receiver.changed().await.ok()?;
            Some(((), receiver))
        })
    }

    /// The first published value, the current one included, for which
    /// `ready` holds; `None` once the owner has stopped without one.
    pub async fn wait_for(&self, mut ready: impl FnMut(&T) -> bool) -> Option<Arc<T>> {
        let mut receiver = self.0.clone();
        receiver
            .wait_for(|value| ready(value))
            .await
            .ok()
            .map(|value| value.clone())
    }
}

/// An owner's commit gate (C00) with its saved value published: readers
/// see a change only once it is on disk, and from then on.
pub struct Saved<R, A, S> {
    gate: Gate<R, A, S>,
    published: Published<R>,
    revision: Revision,
}

impl<R: Clone, A, S: Storage<R>> Saved<R, A, S> {
    pub fn new(gate: Gate<R, A, S>) -> (Self, Snapshot<R>) {
        let (published, snapshot) = Published::new(gate.committed().clone());
        let revision = gate.revision();
        (
            Self {
                gate,
                published,
                revision,
            },
            snapshot,
        )
    }

    pub fn committed(&self) -> &R {
        self.gate.committed()
    }

    /// Writes a blocked earlier candidate again (see `Gate::resolve`).
    pub fn resolve(&mut self) -> Result<(), Refusal> {
        let resolved = self.gate.resolve();
        self.publish();
        resolved
    }

    /// Saves `candidate`, then publishes it (see `Gate::commit`).
    pub fn commit(&mut self, candidate: R, after: Vec<A>) -> Result<Vec<A>, Refusal> {
        let committed = self.gate.commit(candidate, after);
        self.publish();
        committed
    }

    fn publish(&mut self) {
        if self.gate.revision() != self.revision {
            self.revision = self.gate.revision();
            self.published.set(self.gate.committed().clone());
        }
    }
}

/// Every lane, in the one order a task may hold them: a task in a lane may
/// enter only lanes listed after it. Owners (letters) are not here: they
/// never wait, so anyone may ask any owner at any time.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub enum Rank {
    /// One build or preview at a time.
    Build,
    /// `thread spawn` asked again for the same agent and branch.
    AgentSpawn,
    /// An app's agent (create, reset) or one worker (bootstrap, archive).
    AgentOp,
    /// Delivering queued wake-ups.
    AgentFlush,
    /// One compaction per app, from its decision to T3's answer.
    Compaction,
    /// Admitting simulator starts.
    SimStart,
    /// One simulator pool plan-and-apply.
    PoolApply,
    /// One read/modify/write of the app catalog.
    Catalog,
    /// One append to, or read of, a build's diagnostics.
    Diagnostics,
    /// One overlay framework build into the data directory's cache.
    OverlayCache,
}

tokio::task_local! {
    /// The lanes this task is in, lowest first.
    static HELD: Vec<Rank>;
}

/// The lanes held once `rank` is entered. Panics if `rank` isn't above
/// every lane this task is already in: that order is what makes waiting
/// for a lane deadlock-free, so breaking it is a bug, not a wait.
fn entering(rank: Rank) -> Vec<Rank> {
    let mut held = HELD.try_with(Vec::clone).unwrap_or_default();
    if let Some(top) = held.last() {
        assert!(
            *top < rank,
            "lane order broken: entering {rank:?} while in {held:?} (see crate::actor::Rank)"
        );
    }
    held.push(rank);
    held
}

// The one place an async lock exists: a lane's turn. It is only ever
// entered in rank order (`entering`), and a task never holds two turns of
// the same rank, so waiting for one can't close a cycle.
#[allow(clippy::disallowed_types)]
type Turn = tokio::sync::Mutex<()>;

/// Async work that runs one at a time.
pub struct Lane {
    rank: Rank,
    turn: Turn,
}

impl Lane {
    pub const fn new(rank: Rank) -> Self {
        Self {
            rank,
            turn: Turn::const_new(()),
        }
    }

    /// Waits for the lane, then runs `work` in it.
    pub async fn run<F: Future>(&self, work: F) -> F::Output {
        let held = entering(self.rank);
        let _turn = self.turn.lock().await;
        HELD.scope(held, work).await
    }

    /// Runs `work` in the lane if it is free now; None if it is busy.
    pub async fn try_run<F: Future>(&self, work: F) -> Option<F::Output> {
        let held = entering(self.rank);
        let _turn = self.turn.try_lock().ok()?;
        Some(HELD.scope(held, work).await)
    }
}

/// A lane per key, all of one rank.
pub struct Lanes<K> {
    rank: Rank,
    turns: Owner<HashMap<K, Arc<Turn>>>,
}

impl<K: Eq + Hash + Send + 'static> Lanes<K> {
    pub fn new(name: &'static str, rank: Rank) -> Self {
        Self {
            rank,
            turns: Owner::spawn(name, HashMap::new()),
        }
    }

    /// Waits for `key`'s lane, then runs `work` in it.
    pub async fn run<F: Future>(&self, key: K, work: F) -> F::Output {
        let held = entering(self.rank);
        let turn = self
            .turns
            .ask(move |turns| turns.entry(key).or_default().clone())
            .await;
        let _turn = turn.lock().await;
        HELD.scope(held, work).await
    }
}
