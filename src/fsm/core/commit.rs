//! C00, the durable commit gate: a candidate aggregate is saved before
//! anyone can read it, and effects that depend on it run only after that
//! save. It wraps the aggregate's existing private file; it is not a
//! database or a transaction coordinator.

use super::{Disposition, Failure, FailureKind, Machine, Reduction, Revision, TransactionID, Violation};
use crate::store::{atomic_json, read_json};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use std::{marker::PhantomData, path::PathBuf};

/// Where the aggregate stands. `Saving` and `Blocked` keep the committed
/// value as `previous`: that is what readers see until the candidate is saved.
#[derive(Debug)]
pub enum Phase<R, A> {
    Clean { committed: R, revision: Revision },
    Saving { previous: R, revision: Revision, candidate: R, transaction: TransactionID, after: Vec<A> },
    Blocked { previous: R, revision: Revision, candidate: R, transaction: TransactionID, after: Vec<A>, failure: Failure },
}

#[derive(Debug)]
pub struct Commit<R, A> {
    pub phase: Phase<R, A>,
    /// The owner is closing: no new proposals.
    pub closing: bool,
}

impl<R, A> Commit<R, A> {
    /// The aggregate as read from its file at startup.
    pub fn restore(committed: R, revision: Revision) -> Self {
        Self { phase: Phase::Clean { committed, revision }, closing: false }
    }

    /// What readers see: only ever a saved value.
    pub fn committed(&self) -> &R {
        match &self.phase {
            Phase::Clean { committed, .. } => committed,
            Phase::Saving { previous, .. } | Phase::Blocked { previous, .. } => previous,
        }
    }

    pub fn revision(&self) -> Revision {
        match &self.phase {
            Phase::Clean { revision, .. } | Phase::Saving { revision, .. } | Phase::Blocked { revision, .. } => *revision,
        }
    }

    pub fn candidate(&self) -> Option<(&TransactionID, &R)> {
        match &self.phase {
            Phase::Clean { .. } => None,
            Phase::Saving { transaction, candidate, .. } | Phase::Blocked { transaction, candidate, .. } => Some((transaction, candidate)),
        }
    }
}

#[derive(Debug)]
pub enum Event<R, A> {
    Propose { expected: Revision, transaction: TransactionID, candidate: R, after: Vec<A> },
    Saved(TransactionID),
    SaveFailed(TransactionID, Failure),
    Retry,
    CancelProposal,
    OwnerClose,
}

#[derive(Debug, PartialEq)]
pub enum Effect<A> {
    /// Write the candidate atomically, stamped with its transaction and the
    /// revision it will have; answer with `Saved` or `SaveFailed`.
    WriteCandidate { transaction: TransactionID, revision: Revision },
    /// An after-effect, released once, after the commit.
    Release(A),
}

pub struct C00<R, A>(PhantomData<(R, A)>);

impl<R, A> Machine for C00<R, A> {
    type State = Commit<R, A>;
    type Event = Event<R, A>;
    type Effect = Effect<A>;

    fn reduce(state: Commit<R, A>, event: Event<R, A>) -> Reduction<Commit<R, A>, Effect<A>> {
        use Disposition::*;
        let closing = state.closing;
        let keep = |phase| Commit { phase, closing };
        let write = |transaction: &TransactionID, revision: Revision| Effect::WriteCandidate { transaction: transaction.clone(), revision: revision.next() };
        match (state.phase, event) {
            (phase, Event::Propose { .. }) if closing => Reduction::same(keep(phase), NotApplicable),
            (Phase::Clean { committed, revision }, Event::Propose { expected, .. }) if expected != revision =>
                Reduction::same(keep(Phase::Clean { committed, revision }), Conflict(revision)),
            (Phase::Clean { committed, revision }, Event::Propose { transaction, candidate, after, .. }) => {
                let effects = vec![write(&transaction, revision)];
                Reduction::applied(keep(Phase::Saving { previous: committed, revision, candidate, transaction, after }), effects)
            }
            (phase @ (Phase::Saving { .. } | Phase::Blocked { .. }), Event::Propose { .. }) =>
                Reduction::same(keep(phase), Busy),

            (Phase::Saving { revision, candidate, transaction, after, .. }, Event::Saved(saved)) if saved == transaction => {
                let effects = after.into_iter().map(Effect::Release).collect();
                Reduction::applied(keep(Phase::Clean { committed: candidate, revision: revision.next() }), effects)
            }
            (Phase::Saving { previous, revision, candidate, transaction, after }, Event::SaveFailed(failed, failure)) if failed == transaction =>
                Reduction::applied(keep(Phase::Blocked { previous, revision, candidate, transaction, after, failure }), vec![]),
            (phase @ Phase::Clean { .. }, Event::Saved(_)) => Reduction::same(keep(phase), Duplicate),
            (phase @ Phase::Blocked { .. }, Event::Saved(saved)) if phase_transaction(&phase) == Some(&saved) =>
                Reduction::same(keep(phase), ProtocolFault("Saved while blocked: no write was in flight".into())),
            (phase, Event::Saved(_) | Event::SaveFailed(..)) => Reduction::same(keep(phase), Stale),

            (Phase::Blocked { previous, revision, candidate, transaction, after, .. }, Event::Retry) => {
                let effects = vec![write(&transaction, revision)];
                Reduction::applied(keep(Phase::Saving { previous, revision, candidate, transaction, after }), effects)
            }
            (phase @ (Phase::Clean { .. } | Phase::Saving { .. }), Event::Retry) => Reduction::same(keep(phase), NotApplicable),

            // Only a write known not to have happened can be given up.
            (Phase::Blocked { previous, revision, failure, .. }, Event::CancelProposal) if failure.kind == FailureKind::RefusedBeforeEffect =>
                Reduction::applied(keep(Phase::Clean { committed: previous, revision }), vec![]),
            (phase, Event::CancelProposal) => Reduction::same(keep(phase), NotApplicable),

            // An in-flight or blocked candidate stays an obligation.
            (phase, Event::OwnerClose) => Reduction::applied(Commit { phase, closing: true }, vec![]),
        }
    }

    fn violations(state: &Commit<R, A>) -> Vec<Violation> {
        // The phases make the gate's invariants structural: a candidate exists
        // only with its transaction and previous value, after-effects only
        // with a candidate.
        let _ = state;
        vec![]
    }
}

fn phase_transaction<R, A>(phase: &Phase<R, A>) -> Option<&TransactionID> {
    match phase {
        Phase::Clean { .. } => None,
        Phase::Saving { transaction, .. } | Phase::Blocked { transaction, .. } => Some(transaction),
    }
}

/// Writes a candidate durably and classifies a failure: `RefusedBeforeEffect`
/// only when the committed file provably still holds the previous value.
pub trait Storage<R> {
    fn write(&self, transaction: &TransactionID, revision: Revision, candidate: &R) -> Result<(), Failure>;
}

/// Why a proposal was not committed.
#[derive(Debug)]
pub enum Refusal {
    /// The reducer's decision (conflict, busy, closing).
    Declined(Disposition),
    /// The save failed; the candidate is not visible.
    Failed(Failure),
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Declined(Disposition::Conflict(revision)) => write!(f, "Changed meanwhile (now at revision {})", revision.0),
            Self::Declined(Disposition::Busy) => f.write_str("An earlier save has not finished"),
            Self::Declined(Disposition::NotApplicable) => f.write_str("Closing; no new changes"),
            Self::Declined(other) => write!(f, "Not committed: {other:?}"),
            Self::Failed(failure) => failure.fmt(f),
        }
    }
}

impl std::error::Error for Refusal {}

/// Runs the gate synchronously for an owner that saves in its own turn:
/// each `WriteCandidate` goes to `storage` and its result straight back in.
pub struct Gate<R, A, S> {
    state: Option<Commit<R, A>>,
    storage: S,
}

impl<R, A, S: Storage<R>> Gate<R, A, S> {
    pub fn restore(committed: R, revision: Revision, storage: S) -> Self {
        Self { state: Some(Commit::restore(committed, revision)), storage }
    }

    fn commit_state(&self) -> &Commit<R, A> {
        self.state.as_ref().expect("gate state is only taken inside feed")
    }

    pub fn committed(&self) -> &R {
        self.commit_state().committed()
    }

    pub fn revision(&self) -> Revision {
        self.commit_state().revision()
    }

    /// Reduces `event` and every storage result it leads to. Returns the
    /// first decision and the after-effects released.
    fn feed(&mut self, event: Event<R, A>) -> (Disposition, Vec<A>) {
        let mut released = vec![];
        let reduction = C00::reduce(self.state.take().expect("gate state is only taken inside feed"), event);
        let disposition = reduction.disposition;
        let mut pending = reduction.effects;
        let mut state = reduction.state;
        while !pending.is_empty() {
            let mut next = vec![];
            for effect in pending {
                match effect {
                    Effect::Release(after) => released.push(after),
                    Effect::WriteCandidate { transaction, revision } => {
                        let (_, candidate) = state.candidate().expect("a write is requested only with a candidate");
                        let result = match self.storage.write(&transaction, revision, candidate) {
                            Ok(()) => Event::Saved(transaction),
                            Err(failure) => Event::SaveFailed(transaction, failure),
                        };
                        let reduction = C00::reduce(state, result);
                        state = reduction.state;
                        next.extend(reduction.effects);
                    }
                }
            }
            pending = next;
        }
        self.state = Some(state);
        (disposition, released)
    }

    /// Brings a blocked gate back to clean by writing its candidate again.
    /// Owners call this before deriving a new candidate from `committed()`.
    pub fn resolve(&mut self) -> Result<(), Refusal> {
        if matches!(self.commit_state().phase, Phase::Blocked { .. }) {
            self.feed(Event::Retry);
            self.settle_failure()?;
        }
        Ok(())
    }

    /// Saves `candidate` as the next revision, then makes it what readers
    /// see. On failure nothing is published: a write known not to have
    /// happened is given up; an uncertain one stays blocked until `resolve`.
    pub fn commit(&mut self, candidate: R, after: Vec<A>) -> Result<Vec<A>, Refusal> {
        let expected = self.revision();
        let (disposition, released) = self.feed(Event::Propose { expected, transaction: TransactionID::fresh(), candidate, after });
        if disposition != Disposition::Applied {
            return Err(Refusal::Declined(disposition));
        }
        self.settle_failure()?;
        Ok(released)
    }

    fn settle_failure(&mut self) -> Result<(), Refusal> {
        let Phase::Blocked { failure, .. } = &self.commit_state().phase else { return Ok(()) };
        let failure = failure.clone();
        if failure.kind == FailureKind::RefusedBeforeEffect {
            self.feed(Event::CancelProposal);
        }
        Err(Refusal::Failed(failure))
    }
}

/// The aggregate's own JSON file, stamped with the transaction and revision
/// of its last save. Stamps are additive fields; readers without them ignore
/// them, and files without them read as revision 0.
pub struct JsonFile {
    path: PathBuf,
}

#[derive(Serialize)]
struct Stamped<'a, R> {
    transaction: &'a TransactionID,
    revision: Revision,
    #[serde(flatten)]
    state: &'a R,
}

#[derive(Deserialize)]
struct Stored<R> {
    #[serde(default)]
    revision: Revision,
    #[serde(flatten)]
    state: R,
}

#[derive(Deserialize)]
struct Stamp {
    #[serde(default)]
    transaction: Option<String>,
}

impl JsonFile {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    /// The committed value and its revision, or `None` with no file yet.
    pub fn read<R: DeserializeOwned>(&self) -> anyhow::Result<Option<(R, Revision)>> {
        if !self.path.try_exists()? {
            return Ok(None);
        }
        let stored: Stored<R> = read_json(&self.path)?;
        Ok(Some((stored.state, stored.revision)))
    }

    /// After a failed write: the file provably still holds another save
    /// (or there is none) only if it can be read and isn't this transaction.
    fn classify(&self, transaction: &TransactionID) -> FailureKind {
        match std::fs::symlink_metadata(&self.path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return FailureKind::RefusedBeforeEffect,
            _ => {}
        }
        match read_json::<Stamp>(&self.path) {
            Ok(stamp) if stamp.transaction.as_deref() != Some(transaction.as_str()) => FailureKind::RefusedBeforeEffect,
            Ok(_) | Err(_) => FailureKind::OutcomeUnknown,
        }
    }
}

impl<R: Serialize> Storage<R> for JsonFile {
    fn write(&self, transaction: &TransactionID, revision: Revision, candidate: &R) -> Result<(), Failure> {
        atomic_json(&self.path, &Stamped { transaction, revision, state: candidate })
            .map_err(|error| Failure::new(self.classify(transaction), format!("{error:#}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    /// Answers each write with the next scripted result and records what it was asked to save.
    struct Script {
        results: RefCell<Vec<Result<(), FailureKind>>>,
        writes: RefCell<Vec<(Revision, &'static str)>>,
    }

    impl Script {
        fn new(mut results: Vec<Result<(), FailureKind>>) -> Self {
            results.reverse();
            Self { results: RefCell::new(results), writes: RefCell::default() }
        }
    }

    impl Storage<&'static str> for &Script {
        fn write(&self, _: &TransactionID, revision: Revision, candidate: &&'static str) -> Result<(), Failure> {
            self.writes.borrow_mut().push((revision, candidate));
            self.results.borrow_mut().pop().expect("an unexpected write").map_err(|kind| Failure::new(kind, "disk"))
        }
    }

    #[test]
    fn a_candidate_is_hidden_and_its_after_effects_held_until_saved() {
        let state = Commit::restore("a", Revision(3));
        let tx = TransactionID::fresh();
        let saving = C00::reduce(state, Event::Propose { expected: Revision(3), transaction: tx.clone(), candidate: "b", after: vec!["alert"] });
        assert_eq!(saving.effects, vec![Effect::WriteCandidate { transaction: tx.clone(), revision: Revision(4) }]);
        assert_eq!((*saving.state.committed(), saving.state.revision()), ("a", Revision(3)));
        // A failed save publishes nothing and releases nothing.
        let blocked = C00::reduce(saving.state, Event::SaveFailed(tx.clone(), Failure::new(FailureKind::OutcomeUnknown, "fsync")));
        assert!(blocked.effects.is_empty());
        assert_eq!(*blocked.state.committed(), "a");
        // Dependent proposals wait; an uncertain write can't be given up.
        let busy = C00::reduce(blocked.state, Event::Propose { expected: Revision(3), transaction: TransactionID::fresh(), candidate: "c", after: vec![] });
        assert_eq!(busy.disposition, Disposition::Busy);
        let kept = C00::reduce(busy.state, Event::CancelProposal);
        assert_eq!(kept.disposition, Disposition::NotApplicable);
        // Retrying writes the same transaction; its save publishes and releases once.
        let retry = C00::reduce(kept.state, Event::Retry);
        assert_eq!(retry.effects, vec![Effect::WriteCandidate { transaction: tx.clone(), revision: Revision(4) }]);
        let saved = C00::reduce(retry.state, Event::Saved(tx.clone()));
        assert_eq!(saved.effects, vec![Effect::Release("alert")]);
        assert_eq!((*saved.state.committed(), saved.state.revision()), ("b", Revision(4)));
        let again = C00::reduce(saved.state, Event::Saved(tx));
        assert_eq!((again.disposition, again.effects), (Disposition::Duplicate, vec![]));
    }

    #[test]
    fn old_revisions_and_old_save_results_change_nothing() {
        let state = Commit::<_, ()>::restore("a", Revision(3));
        let conflict = C00::reduce(state, Event::Propose { expected: Revision(2), transaction: TransactionID::fresh(), candidate: "b", after: vec![] });
        assert_eq!((conflict.disposition, conflict.effects.len()), (Disposition::Conflict(Revision(3)), 0));
        let tx = TransactionID::fresh();
        let saving = C00::reduce(conflict.state, Event::Propose { expected: Revision(3), transaction: tx, candidate: "b", after: vec![] });
        let stale = C00::reduce(saving.state, Event::Saved(TransactionID::fresh()));
        assert_eq!(stale.disposition, Disposition::Stale);
        assert_eq!(*stale.state.committed(), "a");
    }

    #[test]
    fn the_driver_gives_up_refused_writes_and_retries_uncertain_ones_before_new_work() {
        let script = Script::new(vec![Err(FailureKind::RefusedBeforeEffect), Err(FailureKind::OutcomeUnknown), Ok(()), Ok(())]);
        let mut gate: Gate<&'static str, &'static str, _> = Gate::restore("a", Revision(1), &script);
        // Refused: nothing was written, nothing is published, and the gate is clean again.
        assert!(matches!(gate.commit("b", vec!["x"]), Err(Refusal::Failed(f)) if f.kind == FailureKind::RefusedBeforeEffect));
        assert_eq!((*gate.committed(), gate.revision()), ("a", Revision(1)));
        // Unknown: still hidden; the next owner call first settles it by writing it again.
        assert!(gate.commit("c", vec!["y"]).is_err());
        assert_eq!(*gate.committed(), "a");
        gate.resolve().unwrap();
        assert_eq!((*gate.committed(), gate.revision()), ("c", Revision(2)));
        assert_eq!(gate.commit("d", vec!["z"]).unwrap(), vec!["z"]);
        assert_eq!(*script.writes.borrow(), vec![(Revision(2), "b"), (Revision(2), "c"), (Revision(2), "c"), (Revision(3), "d")]);
    }

    #[test]
    fn a_failed_file_write_is_classified_by_what_the_file_still_holds() {
        let dir = tempfile::tempdir().unwrap();
        let file = JsonFile::new(dir.path().join("book.json"));
        let first = TransactionID::fresh();
        Storage::write(&file, &first, Revision(1), &serde_json::json!({"tasks": {}})).unwrap();
        assert_eq!(file.read::<serde_json::Value>().unwrap().unwrap().1, Revision(1));
        // The file holds the first save, so a later transaction provably didn't land…
        assert_eq!(file.classify(&TransactionID::fresh()), FailureKind::RefusedBeforeEffect);
        // …but if it holds this one, only durability is in question.
        assert_eq!(file.classify(&first), FailureKind::OutcomeUnknown);
    }
}
