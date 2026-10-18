use super::*;

impl Sims {
    // MARK: Start

    pub async fn start(self: &Arc<Self>, thread: &str, device: Option<&str>) -> Result<Value> {
        ensure!(
            media::valid_thread(thread) && uuid::Uuid::parse_str(thread).is_ok(),
            "Thread ID must be a T3 thread UUID"
        );
        loop {
            // Listening before looking, so a save in between isn't missed.
            let saved = self.saved.notified();
            tokio::pin!(saved);
            saved.as_mut().enable();
            match self.starts.run(self.try_start(thread, device)).await? {
                Started::Done(value) => return Ok(value),
                // This thread's previous session on that simulator is still
                // being cleaned up: its release receipt frees it.
                Started::Wait => saved.await,
            }
        }
    }

    pub(super) async fn try_start(
        self: &Arc<Self>,
        thread: &str,
        device: Option<&str>,
    ) -> Result<Started> {
        ensure!(
            !*self.draining.borrow(),
            "Squircle is restarting or stopping; start the simulator again once it is back"
        );
        let inventory = inventory(&*self.host).await?;
        ensure!(
            self.host.seen(thread) != Seen::Gone,
            "T3 has no thread {thread}"
        );
        let simulators = local_simulators(&inventory);
        ensure!(!simulators.is_empty(), "{}", no_simulators(&inventory));

        // At most `max_leases` simulators at once; past that, the thread waits its turn.
        let max = self.host.max_leases();
        if let Some(queued) = self.admit(thread, max).await? {
            return Ok(Started::Done(queued));
        }

        let ledger = self.ledger();
        let reserved: Vec<&Session> = ledger.sessions.iter().filter(|s| s.reserves()).collect();
        let excluded: HashSet<String> = self
            .owner
            .ask(|s| s.excluded.keys().cloned().collect())
            .await;
        let id = |d: &Value| d["id"].as_str().unwrap_or("").to_ascii_uppercase();
        let mine = |d: &Value| {
            reserved.iter().any(|s| {
                s.device_id.eq_ignore_ascii_case(&id(d)) && s.thread_id == thread && s.active()
            })
        };
        let chosen = match device {
            Some(wanted) => simulators
                .iter()
                .find(|d| {
                    d["id"]
                        .as_str()
                        .is_some_and(|id| id.eq_ignore_ascii_case(wanted))
                        || d["name"]
                            .as_str()
                            .is_some_and(|n| n.eq_ignore_ascii_case(wanted))
                })
                .with_context(|| {
                    format!("No iOS simulator {wanted} on this Mac; run squircle sim devices")
                })?,
            None => {
                let last = ledger
                    .sessions
                    .iter()
                    .rev()
                    .find(|s| s.thread_id == thread)
                    .map(|s| s.device_id.to_ascii_uppercase());
                let used: HashSet<String> = ledger
                    .sessions
                    .iter()
                    .map(|s| s.device_id.to_ascii_uppercase())
                    .collect();
                let free = self.host.free(&self.leases()).await;
                // Reserved by a session (another thread's, or this thread's
                // still being cleaned up) or being cleaned up by the pool.
                let taken = |d: &Value| {
                    (reserved
                        .iter()
                        .any(|s| s.device_id.eq_ignore_ascii_case(&id(d)))
                        && !mine(d))
                        || excluded.contains(&id(d))
                };
                // A booted simulator is taken only when it is Squircle's and
                // free: never the user's own, nor another agent's.
                let takeable = |d: &Value| {
                    !taken(d) && (d["booted"] != true || free.contains(&id(d)) || mine(d))
                };
                simulators.iter().copied().find(|d| last.as_deref().is_some_and(|l| l.eq_ignore_ascii_case(&id(d))) && takeable(d))
                    .or_else(|| simulators.iter().copied().find(|d| d["booted"] == true && takeable(d)))
                    .or_else(|| simulators.iter().copied().find(|d| used.contains(&id(d)) && takeable(d)))
                    .or_else(|| simulators.iter().copied().find(|d| takeable(d)))
                    .context("No free simulator: the booted ones are the user's or other agents'; pass --device (squircle sim devices)")?
            }
        };
        let device_id = chosen["id"]
            .as_str()
            .context("Simulator without an ID")?
            .to_string();
        let device_name = chosen["name"].as_str().unwrap_or("Simulator").to_string();
        let booted = chosen["booted"] == true;

        // Already running here: the same session. On another simulator: end that one first.
        if let Some(existing) = reserved
            .iter()
            .find(|s| s.thread_id == thread && s.active())
        {
            if existing.device_id.eq_ignore_ascii_case(&device_id) {
                return Ok(Started::Done(self.started(
                    existing,
                    "This thread's simulator session is already running.",
                )));
            }
            let sims = self.clone();
            let old = existing.id.clone();
            tokio::spawn(async move {
                if let Err(error) = sims.finish(&old, "replaced").await {
                    eprintln!("Simulator session {old} not ended: {error:#}");
                }
            });
        }
        if let Some(other) = reserved
            .iter()
            .find(|s| s.device_id.eq_ignore_ascii_case(&device_id) && !s.active())
        {
            if other.thread_id != thread {
                bail!(
                    "{device_name} is in use by thread {}; pick another with --device (squircle sim devices)",
                    other.thread_id
                );
            }
            if let Some(error) = cleanup_error(other) {
                bail!(
                    "{device_name} is still held by this thread's previous session, whose cleanup is failing ({error}); \
                    Squircle keeps retrying. Pick another simulator with --device meanwhile."
                );
            }
            return Ok(Started::Wait);
        }
        if let Some(other) = reserved
            .iter()
            .find(|s| s.device_id.eq_ignore_ascii_case(&device_id) && s.thread_id != thread)
        {
            bail!(
                "{device_name} is in use by thread {}; pick another with --device (squircle sim devices)",
                other.thread_id
            );
        }

        // The reservation, saved (with its place in line given up) before T3
        // opens anything: whatever happens next, a close and a release are
        // owed. The startup exists first, so even a cancelled ask is rolled back.
        let id = uuid::Uuid::new_v4().to_string();
        let session = Session::reserve(
            id.clone(),
            thread.into(),
            device_id,
            device_name,
            booted,
            now(),
        );
        let mut startup = Startup {
            owner: self.owner.clone(),
            root: self.root.clone(),
            id: id.clone(),
            child: None,
            error: None,
        };
        let (reserving, claimant) = (session.clone(), thread.to_string());
        self.owner.ask(move |s| {
            ensure!(!s.excluded.contains_key(&reserving.device_id.to_ascii_uppercase()),
                "{} is being shut down by the simulator cleanup; start again, or pick another with --device", reserving.device_name);
            s.starts.insert(reserving.id.clone());
            let reserved = s.change(|ledger| {
                ensure!(!ledger.sessions.iter().any(|s| s.reserves() && s.device_id.eq_ignore_ascii_case(&reserving.device_id)),
                    "{} was taken meanwhile; start again", reserving.device_name);
                let reservations = ledger.reservations();
                let claim = admission::Event::Claim { thread: claimant };
                ledger.queue = admission::reduce(std::mem::take(&mut ledger.queue), &Capacity { limit: max, reservations: &reservations }, claim).state;
                ledger.sessions.push(reserving.clone());
                trim(ledger);
                Ok(())
            });
            if reserved.is_err() {
                // An unsaved reservation left in doubt is finished by the watchdog once it is saved.
                s.starts.remove(&reserving.id);
            }
            reserved
        }).await?;
        self.announce_waiting();
        match self.begin(&session, &mut startup).await {
            Ok(session) => Ok(Started::Done(self.started(
                &session,
                "Recording. The user watches it live on their phone.",
            ))),
            Err(error) => {
                startup.error = Some(format!("{error:#}"));
                drop(startup);
                self.cleanup(&id, false).await;
                Err(error)
            }
        }
    }

    /// Opens, boots and records, saving each step; `startup` ends the
    /// session if this fails or is cancelled.
    pub(super) async fn begin(&self, session: &Session, startup: &mut Startup) -> Result<Session> {
        let name = &session.device_name;
        self.host
            .device(
                "device.open",
                json!({"threadId": session.thread_id, "hostId": session.host_id,
            "deviceId": session.device_id, "platform": "ios", "boot": true}),
            )
            .await
            .context("T3 could not open the simulator")?;
        self.step(&session.id, Event::Opened).await?;
        self.host
            .boot(&session.device_id)
            .await
            .with_context(|| format!("{name} did not finish booting"))?;
        self.step(&session.id, Event::Booted { at: now() }).await?;

        let path = media::recording_path(&self.root, &session.thread_id, &session.id)?;
        let log = std::fs::File::create(path.with_extension("log"))?;
        let recorder = startup
            .child
            .insert(self.host.record(&session.device_id, &path, log)?);
        let pid = recorder.id().context("The recorder exited at once")?;
        self.step(
            &session.id,
            Event::RecorderStarted(RecorderID {
                pid,
                start: process_start(pid),
            }),
        )
        .await?;
        tokio::time::sleep(Duration::from_millis(1200)).await;
        if let Some(status) = startup
            .child
            .as_mut()
            .and_then(|c| c.try_wait().transpose())
            .transpose()?
        {
            let detail = std::fs::read_to_string(path.with_extension("log")).unwrap_or_default();
            bail!("Recording {name} failed ({status}): {}", detail.trim());
        }
        // In one letter with shutdown's collection of the sessions it ends:
        // either shutdown sees this recording, or this sees shutdown.
        let (id, child) = (session.id.clone(), startup.child.take());
        self.owner
            .ask(move |s| {
                let mut child = child;
                let recording = if s.draining {
                    Err(anyhow!("Squircle is shutting down"))
                } else {
                    s.step(&id, Event::Recording).map(drop)
                };
                if let Err(error) = recording {
                    // The partial movie is useless; tokio reaps the killed child.
                    if let Some(child) = &mut child {
                        let _ = child.start_kill();
                    }
                    return Err(error);
                }
                if let Some(child) = child {
                    s.recorders.insert(id.clone(), Recorder::Owned(child));
                }
                s.starts.remove(&id);
                s.ledger()
                    .session(&id)
                    .cloned()
                    .context("No such simulator session")
            })
            .await
    }

    /// Admission: None if `thread` may reserve a simulator now; otherwise it
    /// keeps (or takes) its place in line, saved, and this tells the agent.
    pub(super) async fn admit(&self, thread: &str, max: usize) -> Result<Option<Value>> {
        let (asking, waiter) = (thread.to_string(), uuid::Uuid::new_v4().to_string());
        let position = self
            .owner
            .ask(move |s| -> Result<Option<usize>> {
                s.resolve()?;
                let ledger = s.ledger();
                let reservations = ledger.reservations();
                let ask = admission::Event::Ask {
                    thread: asking,
                    now: now(),
                    waiter,
                };
                let reduction = admission::reduce(
                    ledger.queue.clone(),
                    &Capacity {
                        limit: max,
                        reservations: &reservations,
                    },
                    ask,
                );
                let position = match reduction.effects.iter().find_map(|e| match e {
                    admission::Effect::Answer(a) => Some(a.clone()),
                    _ => None,
                }) {
                    Some(Answer::Admitted) | None => return Ok(None),
                    Some(Answer::Queued { position }) => position,
                };
                if reduction.effects.contains(&admission::Effect::Commit) {
                    let queue = reduction.state;
                    s.change(|ledger| {
                        ledger.queue = queue;
                        Ok(())
                    })?;
                }
                Ok(Some(position))
            })
            .await?;
        let Some(position) = position else {
            return Ok(None);
        };
        let holders: Vec<String> = self
            .ledger()
            .sessions
            .iter()
            .filter(|s| s.reserves())
            .map(|s| {
                format!(
                    "{} ({})",
                    s.device_name,
                    self.host
                        .title(&s.thread_id)
                        .unwrap_or_else(|| s.thread_id.clone())
                )
            })
            .collect();
        self.announce_waiting();
        let cli = self.host.cli();
        Ok(Some(json!({
            "status": "queued",
            "position": position,
            "in_use": holders,
            "limit": max,
            "next": format!("All {max} simulators are in use; this thread is number {position} in line and keeps its place. \
                End your turn now. When a simulator is free, Squircle holds it for this thread and wakes it with a \
                [simulator ready] message; then run {cli} sim start --thread {thread} again. \
                To leave the line: {cli} sim stop --thread {thread}."),
        })))
    }

    /// Whether `thread` has a session recording.
    pub fn running(&self, thread: &str) -> bool {
        self.ledger()
            .sessions
            .iter()
            .any(|s| s.thread_id == thread && s.active())
    }

    /// Takes `thread` out of the line (a held slot frees for the next).
    pub async fn leave(&self, thread: &str) -> Result<bool> {
        let (max, leaving) = (self.host.max_leases(), thread.to_string());
        let left = self
            .owner
            .ask(move |s| -> Result<bool> {
                s.resolve()?;
                let reservations = s.ledger().reservations();
                let queue = s.ledger().queue.clone();
                let reduction = admission::reduce(
                    queue,
                    &Capacity {
                        limit: max,
                        reservations: &reservations,
                    },
                    admission::Event::Leave { thread: leaving },
                );
                if reduction.disposition != Disposition::Applied {
                    return Ok(false);
                }
                let queue = reduction.state;
                s.change(|ledger| {
                    ledger.queue = queue;
                    Ok(())
                })?;
                Ok(true)
            })
            .await?;
        if left {
            self.announce_waiting();
        }
        Ok(left)
    }

    pub(super) fn announce_waiting(&self) {
        let threads = self
            .ledger()
            .queue
            .iter()
            .map(|w| w.thread_id.clone())
            .collect();
        self.host.waiting(threads);
    }

    /// One coherent look at the line: gives up the places of threads T3 no
    /// longer has and grants left unclaimed, grants free slots to the head,
    /// saves that, and only then queues the wakes it owes.
    pub(super) async fn advance(&self) {
        let max = self.host.max_leases();
        // What T3 says of each thread in line, read before the owner decides;
        // one that joined meanwhile is unknown, which keeps its place.
        let seen: HashMap<String, Seen> = self
            .ledger()
            .queue
            .iter()
            .map(|w| (w.thread_id.clone(), self.host.seen(&w.thread_id)))
            .collect();
        let decided = self
            .owner
            .ask(move |s| -> Option<(Vec<Waiter>, bool)> {
                s.resolve().ok()?;
                let ledger = s.ledger();
                let reservations = ledger.reservations();
                let seen = ledger
                    .queue
                    .iter()
                    .map(|w| {
                        (
                            w.thread_id.clone(),
                            seen.get(&w.thread_id)
                                .cloned()
                                .unwrap_or(Seen::Unknown { turn: None }),
                        )
                    })
                    .collect();
                let reduction = admission::reduce(
                    ledger.queue.clone(),
                    &Capacity {
                        limit: max,
                        reservations: &reservations,
                    },
                    admission::Event::Advance { now: now(), seen },
                );
                if reduction.effects.contains(&admission::Effect::Commit) {
                    let queue = reduction.state;
                    if let Err(error) = s.change(|ledger| {
                        ledger.queue = queue;
                        Ok(())
                    }) {
                        // Nothing was granted, so nobody is woken.
                        eprintln!("Simulator queue not advanced: {error:#}");
                        return None;
                    }
                }
                let wakes = reduction
                    .effects
                    .iter()
                    .filter_map(|e| match e {
                        admission::Effect::Wake(w) => Some(w.clone()),
                        _ => None,
                    })
                    .collect();
                Some((
                    wakes,
                    reduction.effects.contains(&admission::Effect::Announce),
                ))
            })
            .await;
        let Some((wakes, announce)) = decided else {
            return;
        };
        if announce {
            self.announce_waiting();
        }
        let cli = self.host.cli();
        for waiter in wakes {
            let thread = &waiter.thread_id;
            let text = format!(
                "[simulator ready]\nA simulator is free and held for this thread. Run {cli} sim start --thread {thread} \
                now to take it, then carry on. If you no longer need it, run {cli} sim stop --thread {thread} to give it up."
            );
            if let Err(error) = self.host.wake(thread, &waiter.id, text).await {
                eprintln!("Simulator wake for {thread} not queued: {error:#}");
                continue;
            }
            let (thread, woken) = (thread.clone(), waiter.id.clone());
            self.owner
                .ask(move |s| {
                    let reservations = s.ledger().reservations();
                    let queue = s.ledger().queue.clone();
                    let reduction = admission::reduce(
                        queue,
                        &Capacity {
                            limit: max,
                            reservations: &reservations,
                        },
                        admission::Event::WakeQueued { waiter: woken },
                    );
                    if reduction.disposition == Disposition::Applied {
                        let queue = reduction.state;
                        if let Err(error) = s.change(|ledger| {
                            ledger.queue = queue;
                            Ok(())
                        }) {
                            // The outbox dedupes by the waiter's ID; the wake is asked for again.
                            eprintln!(
                                "Simulator wake for {thread} queued but not recorded: {error:#}"
                            );
                        }
                    }
                })
                .await;
        }
    }

    pub(super) fn started(&self, session: &Session, status: &str) -> Value {
        let cli = self.host.cli();
        json!({
            "session": Served::from(session),
            "status": status,
            "agent_device": agent_device(&session.thread_id, &session.host_id, &session.device_id),
            "next": format!("Drive it with agent_device.command plus agent_device.target_args (or T3's device_screenshot to look). \
                When you are done with the simulator, run {cli} sim stop --thread {}; the recording then appears in this turn \
                and the simulator shuts down. If you forget, that happens when your turn ends. Don't boot or create simulators yourself.", session.thread_id),
        })
    }
}

/// How a start ended up.
pub(super) enum Started {
    Done(Value),
    /// Wait for a save, then look again.
    Wait,
}

/// Owns a starting session's provisional resources: unless the start
/// commits, dropping it (an error or a cancelled request) kills the
/// recorder and tells the owner to end the session, which then owes the
/// close and release of whatever it may have acquired.
pub(super) struct Startup {
    pub(super) owner: Owner<State>,
    pub(super) root: PathBuf,
    pub(super) id: String,
    pub(super) child: Option<Child>,
    pub(super) error: Option<String>,
}

impl Drop for Startup {
    fn drop(&mut self) {
        if let Some(child) = &mut self.child {
            // The partial movie is useless; tokio reaps the killed child.
            let _ = child.start_kill();
        }
        let (root, id) = (self.root.clone(), self.id.clone());
        let error = self
            .error
            .take()
            .unwrap_or_else(|| "The start was cancelled".into());
        self.owner.tell(move |s| s.abandon_start(&root, &id, error));
    }
}
