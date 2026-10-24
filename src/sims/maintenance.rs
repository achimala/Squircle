use super::*;

impl Sims {
    // MARK: Watching

    /// Ends sessions whose turn has stopped, whose recorder died, or that ran
    /// too long, and runs owed cleanup and saves. Sessions a previous run
    /// left unfinished are finished first. Returns once `shutdown` begins.
    ///
    /// It looks again when something it reads changes: T3's thread states,
    /// a recorder exiting, the ledger being saved. The only clock is the
    /// policy's: the next idle grace, recording limit or cleanup retry due.
    pub async fn run(self: Arc<Self>) {
        use futures_util::StreamExt;
        let mut draining = self.draining.subscribe();
        let orphans = self.owner.ask(|s| std::mem::take(&mut s.orphans)).await;
        for id in orphans {
            if *draining.borrow() {
                return;
            }
            self.resume(&id, "service restarted").await;
        }
        let mut threads = self.host.changes();
        loop {
            // Listening before looking, so a save during the tick isn't missed.
            let saved = self.saved.notified();
            tokio::pin!(saved);
            saved.as_mut().enable();
            self.tick().await;
            let due = self.next_due().await;
            tokio::select! {
                _ = draining.wait_for(|d| *d) => return,
                _ = &mut saved => {}
                _ = self.poke.notified() => {}
                Some(()) = threads.next() => {}
                _ = until(due) => {}
            }
            if *draining.borrow() {
                return;
            }
        }
    }

    /// When the policy next asks for something without any event: an idle
    /// grace or the recording limit running out, or an owed cleanup's retry.
    pub(super) async fn next_due(&self) -> Option<f64> {
        self.owner
            .ask(|s| {
                s.ledger()
                    .sessions
                    .iter()
                    .flat_map(|session| {
                        let clock = s.clocks.get(&session.id).copied().unwrap_or_default();
                        session::due_at(session, clock)
                    })
                    .min_by(f64::total_cmp)
            })
            .await
    }

    /// One look at every session: what is due now runs.
    pub(super) async fn tick(self: &Arc<Self>) {
        if let Err(error) = self.owner.ask(|s| s.ledger.resolve()).await {
            eprintln!("Simulator session ledger still not saved: {error}");
        }
        for (id, reason) in self.due().await {
            // Filing can take minutes; it never holds up other sessions.
            let sims = self.clone();
            tokio::spawn(async move {
                if let Err(error) = sims.finish(&id, reason).await {
                    eprintln!("Simulator session {id} not ended: {error:#}");
                }
            });
        }
        // Sessions a step's failed save left part-way: finished from where they stand.
        for id in self.stranded().await {
            let sims = self.clone();
            tokio::spawn(async move { sims.resume(&id, "interrupted").await });
        }
        let time = now();
        let owed: Vec<String> = self
            .ledger()
            .sessions
            .iter()
            .filter(|s| s.close_due(time) || s.release_due(time))
            .map(|s| s.id.clone())
            .collect();
        for id in owed {
            self.cleanup(&id, false).await;
        }
        // Not while a start is deciding whether it may take a slot.
        self.starts.try_run(self.advance()).await;
    }

    /// Sessions nothing in this run is working on that are stuck before
    /// their end: a start that couldn't save its failure, a stop or filing
    /// whose save failed.
    pub(super) async fn stranded(&self) -> Vec<String> {
        self.owner
            .ask(|s| {
                let orphans: HashSet<&String> = s.orphans.iter().collect();
                s.ledger()
                    .sessions
                    .iter()
                    .filter(|session| match session.phase {
                        Phase::Starting { .. } => !s.starts.contains(&session.id),
                        Phase::Stopping { .. } | Phase::Filing { .. } => true,
                        _ => false,
                    })
                    .filter(|session| {
                        !orphans.contains(&session.id)
                            && !s.running.contains_key(&(session.id.clone(), Work::Finish))
                    })
                    .map(|session| session.id.clone())
                    .collect()
            })
            .await
    }

    /// Sessions to stop now, and why: the recorder died, the time limit
    /// passed, or T3 confirmed the turn over for the grace.
    pub(super) async fn due(&self) -> Vec<(String, &'static str)> {
        let time = now();
        // What T3 says of each recording session's thread, read before the owner decides.
        let seen: HashMap<String, Seen> = self
            .ledger()
            .sessions
            .iter()
            .filter(|s| s.active())
            .map(|s| (s.thread_id.clone(), self.host.seen(&s.thread_id)))
            .collect();
        self.owner
            .ask(move |s| {
                let active: Vec<Session> = s
                    .ledger()
                    .sessions
                    .iter()
                    .filter(|s| s.active())
                    .cloned()
                    .collect();
                let mut due = Vec::new();
                for session in active {
                    let alive = match s.recorders.get_mut(&session.id) {
                        Some(Recorder::Owned(child)) => matches!(child.try_wait(), Ok(None)),
                        Some(Recorder::Recovered(recorder)) => is_recorder(*recorder, &session.id),
                        None => false,
                    };
                    let seen = seen
                        .get(&session.thread_id)
                        .cloned()
                        .unwrap_or(Seen::Unknown { turn: None });
                    let clock = s.clocks.get(&session.id).copied().unwrap_or_default();
                    let (clock, reason) = session::watch(&session, clock, alive, &seen, time);
                    s.clocks.insert(session.id.clone(), clock);
                    if let Some(reason) = reason {
                        due.push((session.id, reason));
                    }
                }
                due
            })
            .await
    }

    /// For the service's graceful exit: refuses new starts and stops the
    /// watchdog. A stop ends every recording (filed uncompressed, to be
    /// quick); a handover leaves them recording for the next run. Either way
    /// owed closes and releases are run. Anything it can't finish stays owed
    /// in the ledger for the next run.
    pub async fn shutdown(&self, exit: Exit) {
        // Not in the start lane: a start booting a simulator could hold it
        // for minutes. One past its commit check is rolled back instead.
        self.draining.send_replace(true);
        let live: Vec<String> = self
            .owner
            .ask(move |s| {
                s.draining = true;
                s.ledger()
                    .sessions
                    .iter()
                    .filter(|s| s.active() && exit == Exit::Stop)
                    .map(|s| s.id.clone())
                    .collect()
            })
            .await;
        futures_util::future::join_all(live.iter().map(|id| async move {
            let Some(_finish) = self.claim(id, Work::Finish).await else {
                return;
            };
            match self.halt(id, "service stopped", false).await {
                Ok(Some(_)) => {
                    self.cleanup(id, true).await;
                    let _ = self.file(id, false).await;
                }
                Ok(None) => {}
                Err(error) => eprintln!("Simulator session {id} not stopped: {error:#}"),
            }
        }))
        .await;
        let owed: Vec<String> = self
            .ledger()
            .sessions
            .iter()
            .filter(|s| s.close_due(f64::INFINITY) || s.release_owed())
            .map(|s| s.id.clone())
            .collect();
        futures_util::future::join_all(owed.iter().map(|id| self.cleanup(id, true))).await;
        if let Err(error) = self.owner.ask(|s| s.ledger.resolve()).await {
            eprintln!("Simulator session ledger not saved: {error}");
        }
    }
}

/// Resolves at wall-clock time `at` (Unix seconds); never without one.
async fn until(at: Option<f64>) {
    match at {
        Some(at) => {
            let wait = (at - now()).max(0.0);
            tokio::time::sleep(std::time::Duration::from_secs_f64(wait)).await
        }
        None => std::future::pending().await,
    }
}

impl Sims {
    /// Records `note` in the session holding `device`, if one does; returns
    /// that session's thread.
    pub async fn note(&self, device: &str, note: String) -> Option<String> {
        let device = device.to_string();
        self.owner
            .ask(move |s| {
                let session = s
                    .ledger()
                    .sessions
                    .iter()
                    .find(|s| s.holds_device() && s.device_id.eq_ignore_ascii_case(&device))?;
                let (id, thread) = (session.id.clone(), session.thread_id.clone());
                if let Err(error) = s.step(&id, Event::Noted(note)) {
                    eprintln!("{error:#}");
                }
                Some(thread)
            })
            .await
    }
}

impl Holds for Sims {
    fn leases(&self) -> Vec<Lease> {
        Sims::leases(self)
    }

    fn boots(&self) -> Vec<(String, BootReceipt)> {
        self.ledger()
            .sessions
            .iter()
            .filter_map(|s| match s.boot {
                Boot::BootedHere { at } => Some((
                    s.device_id.to_ascii_uppercase(),
                    BootReceipt {
                        at,
                        thread: None,
                        session: Some(s.id.clone()),
                    },
                )),
                _ => None,
            })
            .collect()
    }

    fn exclude<'a>(&'a self, udid: &'a str) -> Pending<'a, Option<Exclusion>> {
        Box::pin(async move {
            let (udid, token) = (udid.to_ascii_uppercase(), token());
            let (owner, released) = (self.owner.clone(), udid.clone());
            // Made before the owner is asked, so even a cancelled ask is released.
            let exclusion = Exclusion::new(move || {
                owner.tell(move |s| {
                    if s.excluded.get(&released) == Some(&token) {
                        s.excluded.remove(&released);
                    }
                })
            });
            // In the owner's turn, as a start's reservation is: the two can't interleave.
            let excluded = self
                .owner
                .ask(move |s| {
                    let reserved = s
                        .ledger()
                        .sessions
                        .iter()
                        .any(|s| s.reserves() && s.device_id.eq_ignore_ascii_case(&udid));
                    if reserved || s.excluded.contains_key(&udid) {
                        return false;
                    }
                    s.excluded.insert(udid, token);
                    true
                })
                .await;
            excluded.then_some(exclusion)
        })
    }
}

/// How the service is exiting.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Exit {
    /// A restart (SIGTERM): live sessions carry on into the next run.
    Handover,
    /// A real stop (SIGINT, `squircle service stop`): live sessions end.
    Stop,
}
