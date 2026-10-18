use super::*;

/// Effects running now, by session, so the stop path and the watchdog never
/// run the same one twice.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub(super) enum Work {
    /// Stopping, cleaning up and filing a session, start to end.
    Finish,
    Close,
    Release,
}

/// The session owner's state, reached only by its letters.
pub(super) struct State {
    pub(super) ledger: Saved<Ledger, Infallible, JsonFile>,
    pub(super) saved: Arc<Notify>,
    pub(super) recorders: HashMap<String, Recorder>,
    pub(super) clocks: HashMap<String, IdleClock>,
    /// Effects running now, each with the token of the claim that holds it.
    pub(super) running: HashMap<(String, Work), u64>,
    /// Sessions a start in this run is opening: any other `starting` one was
    /// left by a start that couldn't save its end, and is finished.
    pub(super) starts: HashSet<String>,
    /// Sessions a previous run left unfinished, finished first by `run`.
    pub(super) orphans: Vec<String>,
    /// Simulators the pool is cleaning up, each with its exclusion's token:
    /// no start takes them meanwhile.
    pub(super) excluded: HashMap<String, u64>,
    /// Set by `shutdown` in the same letter that collects the sessions it ends.
    pub(super) draining: bool,
}

/// Saves `candidate` through the gate before the owner starts: nothing is
/// published unless saved.
pub(super) fn save(gate: &mut Gate<Ledger, Infallible, JsonFile>, candidate: Ledger) -> Result<()> {
    gate.commit(candidate, vec![])
        .map(|_| ())
        .map_err(|e| anyhow!("Cannot save the simulator session ledger: {e}"))
}

/// A token telling one holder of a claim or exclusion from the next.
pub(super) fn token() -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

/// One effect this run is running for a session, so the stop path and the
/// watchdog never run the same one twice. Made before its owner is asked,
/// so a cancelled ask still ends it; dropping it tells the owner.
pub(super) struct Claim {
    pub(super) owner: Owner<State>,
    pub(super) key: (String, Work),
    pub(super) token: u64,
}

impl Drop for Claim {
    fn drop(&mut self) {
        let (key, token) = (self.key.clone(), self.token);
        self.owner.tell(move |s| {
            if s.running.get(&key) == Some(&token) {
                s.running.remove(&key);
            }
        });
    }
}

impl State {
    pub(super) fn ledger(&self) -> &Ledger {
        self.ledger.committed()
    }

    pub(super) fn resolve(&mut self) -> Result<()> {
        self.ledger
            .resolve()
            .map_err(|e| anyhow!("Cannot save the simulator session ledger: {e}"))
    }

    /// Changes a copy of the saved ledger and saves it; the change is seen,
    /// and effects after it run, only once it is saved. An earlier save
    /// whose outcome is unknown is written again first.
    pub(super) fn change<T>(&mut self, change: impl FnOnce(&mut Ledger) -> Result<T>) -> Result<T> {
        self.resolve()?;
        let mut candidate = self.ledger().clone();
        let out = change(&mut candidate)?;
        self.ledger
            .commit(candidate, vec![])
            .map_err(|e| anyhow!("Cannot save the simulator session ledger: {e}"))?;
        self.saved.notify_waiters();
        Ok(out)
    }

    /// Reduces one event for one session and saves the result. Returns the
    /// decision and the effects to run now that it is saved.
    pub(super) fn step(
        &mut self,
        id: &str,
        event: Event,
    ) -> Result<(Disposition, Vec<session::Effect>)> {
        let current = self
            .ledger()
            .session(id)
            .cloned()
            .context("No such simulator session")?;
        let reduction = session::reduce(current, event);
        if let Disposition::ProtocolFault(why) = &reduction.disposition {
            bail!("Simulator session {id}: {why}");
        }
        debug_assert!(
            session::violations(&reduction.state).is_empty(),
            "{:?}",
            session::violations(&reduction.state)
        );
        let mut effects = reduction.effects;
        if effects.first() == Some(&session::Effect::Commit) {
            effects.remove(0);
            let next = reduction.state;
            self.change(|ledger| {
                let slot = ledger
                    .sessions
                    .iter_mut()
                    .find(|s| s.id == id)
                    .context("No such simulator session")?;
                *slot = next;
                Ok(())
            })?;
        }
        Ok((reduction.disposition, effects))
    }

    /// A start that failed or was cancelled before it committed: its
    /// partial movie goes, and the session ends owing the close and release
    /// of whatever it may have acquired. Nothing if the start committed (or
    /// never reserved anything).
    pub(super) fn abandon_start(&mut self, root: &Path, id: &str, error: String) {
        if !self.starts.remove(id) {
            return;
        }
        let Some(thread) = self.ledger().session(id).map(|s| s.thread_id.clone()) else {
            return;
        };
        if let Ok(path) = media::recording_path(root, &thread, id) {
            let _ = std::fs::remove_file(path.with_extension("log"));
            let _ = std::fs::remove_file(path);
        }
        // If this can't be saved, the watchdog finds the session stranded and finishes it.
        if let Err(error) = self.step(id, Event::StartFailed { error, now: now() }) {
            eprintln!("{error:#}");
        }
    }
}

/// Drops the oldest settled sessions over `KEEP`; anything still owed stays.
pub(super) fn trim(ledger: &mut Ledger) {
    let mut excess = ledger.sessions.len().saturating_sub(KEEP);
    ledger.sessions.retain(|s| {
        let gone = excess > 0 && s.settled();
        excess -= gone as usize;
        !gone
    });
}
