use super::*;

impl Sims {
    pub fn open(root: &Path, agents: Arc<Agents>, pool: Arc<Pool>) -> Result<Arc<Self>> {
        let sims = Self::with_host(root, Arc::new(AgentsHost(agents, pool.clone())))?;
        let holds: Arc<dyn Holds> = sims.clone();
        pool.attach(Arc::downgrade(&holds));
        Ok(sims)
    }

    pub fn with_host(root: &Path, host: Arc<dyn Host>) -> Result<Arc<Self>> {
        let path = root.join("sims.json");
        let file = JsonFile::new(path.clone());
        let (ledger, revision) = file.read::<Ledger>()?.unwrap_or((
            Ledger {
                schema: SCHEMA,
                ..Ledger::default()
            },
            Default::default(),
        ));
        let legacy = ledger.schema < SCHEMA;
        let mut gate = Gate::restore(ledger, revision, file);
        // An earlier ledger: keep the original beside it, then save it once
        // in this format before anything is admitted.
        if legacy {
            let backup = root.join(format!(
                "sims.schema{}.json",
                gate.committed().schema.max(1)
            ));
            if !backup.try_exists()? {
                std::fs::copy(&path, &backup).with_context(|| {
                    format!(
                        "Cannot keep the earlier simulator ledger as {}",
                        backup.display()
                    )
                })?;
            }
            let candidate = Ledger {
                schema: SCHEMA,
                ..gate.committed().clone()
            };
            save(&mut gate, candidate)?;
        }
        // A recorder a previous run left is taken over only if it is provably
        // this session's; one from before start times were saved gets its own now.
        let mut recorders = HashMap::new();
        let mut adopted = vec![];
        for s in gate
            .committed()
            .sessions
            .iter()
            .filter(|s| s.holds_device())
        {
            let Some(recorder) = s.recorder().filter(|r| is_recorder(*r, &s.id)) else {
                continue;
            };
            let recorder = RecorderID {
                start: recorder.start.or_else(|| process_start(recorder.pid)),
                ..recorder
            };
            if s.active() && s.recorder() != Some(recorder) {
                adopted.push((s.id.clone(), recorder));
            }
            recorders.insert(s.id.clone(), Recorder::Recovered(recorder));
        }
        if !adopted.is_empty() {
            let mut candidate = gate.committed().clone();
            for (id, recorder) in adopted {
                if let Some(s) = candidate.sessions.iter_mut().find(|s| s.id == id) {
                    *s = session::reduce(s.clone(), Event::RecorderAdopted(recorder)).state;
                }
            }
            save(&mut gate, candidate)?;
        }
        // A recording handed over with its recorder still running carries on,
        // watched like any other; the rest a previous run left are finished.
        let orphans = gate
            .committed()
            .sessions
            .iter()
            .filter(|s| !s.ended() && !(s.active() && recorders.contains_key(&s.id)))
            .map(|s| s.id.clone())
            .collect();
        let watched: Vec<(String, u32)> = recorders
            .iter()
            .filter_map(|(id, recorder)| match recorder {
                Recorder::Recovered(r) => Some((id.clone(), r.pid)),
                Recorder::Owned(_) => None,
            })
            .collect();
        let (ledger, snapshot) = Saved::new(gate);
        let saved = Arc::new(Notify::new());
        let state = State {
            ledger,
            saved: saved.clone(),
            recorders,
            clocks: HashMap::new(),
            running: HashMap::new(),
            starts: HashSet::new(),
            orphans,
            excluded: HashMap::new(),
            draining: false,
        };
        let sims = Arc::new(Self {
            root: root.to_path_buf(),
            host,
            owner: Owner::spawn("simulator sessions", state),
            ledger: snapshot,
            starts: Lane::new(Rank::SimStart),
            draining: tokio::sync::watch::channel(false).0,
            saved,
            poke: Arc::new(Notify::new()),
        });
        for (id, pid) in watched {
            watch_exit(pid, &sims.poke);
            // Checked again now that it is watched: had it exited and its
            // pid been reused just before, the session's end is not missed.
            if !is_recorder(RecorderID { pid, start: None }, &id) {
                sims.poke.notify_one();
            }
        }
        sims.announce_waiting();
        Ok(sims)
    }

    /// The ledger as last saved.
    pub(super) fn ledger(&self) -> Arc<Ledger> {
        self.ledger.get()
    }

    /// One item each time the ledger is saved.
    pub fn changes(&self) -> futures_util::stream::BoxStream<'static, ()> {
        use futures_util::StreamExt;
        self.ledger.changes().boxed()
    }

    /// Reduces one event for one session and saves the result.
    pub(super) async fn step(
        &self,
        id: &str,
        event: Event,
    ) -> Result<(Disposition, Vec<session::Effect>)> {
        let id = id.to_string();
        self.owner.ask(move |s| s.step(&id, event)).await
    }

    pub(super) async fn claim(&self, id: &str, work: Work) -> Option<Claim> {
        let claim = Claim {
            owner: self.owner.clone(),
            key: (id.to_string(), work),
            token: token(),
        };
        let (key, token) = (claim.key.clone(), claim.token);
        let claimed = self
            .owner
            .ask(move |s| match s.running.entry(key) {
                Entry::Vacant(free) => {
                    free.insert(token);
                    true
                }
                Entry::Occupied(_) => false,
            })
            .await;
        claimed.then_some(claim)
    }

    /// Every simulator a session has used, with when it was last used.
    pub fn used(&self) -> Vec<(String, f64)> {
        self.ledger()
            .sessions
            .iter()
            .map(|s| (s.device_id.clone(), s.ended_at().unwrap_or(s.started_at)))
            .collect()
    }

    /// The simulators sessions reserve now: in use, or their cleanup unsettled.
    pub fn leases(&self) -> Vec<Lease> {
        self.ledger()
            .reservations()
            .into_iter()
            .map(|r| Lease {
                device_id: r.device,
                thread_id: r.thread,
            })
            .collect()
    }

    /// Sessions still recording, and recent ones (newest first), optionally for one thread.
    pub fn list(&self, thread: Option<&str>) -> Value {
        let ledger = self.ledger();
        let mine = |s: &&Session| thread.is_none_or(|t| s.thread_id == t);
        let active: Vec<Served> = ledger
            .sessions
            .iter()
            .filter(mine)
            .filter(|s| s.active())
            .map(Served::from)
            .collect();
        let recent: Vec<Served> = ledger
            .sessions
            .iter()
            .rev()
            .filter(mine)
            .filter(|s| !s.active())
            .take(50)
            .map(Served::from)
            .collect();
        let queue: Vec<Value> = ledger.queue.iter().enumerate().map(|(i, w)| json!({
            "position": i + 1, "thread_id": w.thread_id, "title": self.host.title(&w.thread_id), "queued_at": w.queued_at,
            "state": if w.grant.is_some() { "held for it" } else { "waiting" },
        })).collect();
        json!({"active": active, "recent": recent, "queue": queue, "limit": self.host.max_leases()})
    }
}
