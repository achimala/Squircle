use super::*;

impl Push {
    pub fn open(root: &Path) -> Result<Arc<Self>> {
        Self::build(root, None, Timing::default())
    }

    /// With a given transport and timing, for tests.
    pub fn with_transport(
        root: &Path,
        transport: Arc<dyn Transport>,
        timing: Timing,
    ) -> Result<Arc<Self>> {
        Self::build(root, Some(transport), timing)
    }

    pub(super) fn build(
        root: &Path,
        fixed: Option<Arc<dyn Transport>>,
        timing: Timing,
    ) -> Result<Arc<Self>> {
        private_dir(&root.join("push"))?;
        let path = root.join("push").join("devices.json");
        let devices = if path.try_exists()? {
            read_json(&path)?
        } else {
            BTreeMap::new()
        };
        let owner = Owner::spawn(
            "push",
            State {
                root: root.to_path_buf(),
                devices,
                ..State::default()
            },
        );
        Ok(Arc::new(Self {
            root: root.to_path_buf(),
            owner,
            fixed,
            timing,
            alerts_sent: AtomicU64::new(0),
            wake: Notify::new(),
        }))
    }

    pub fn set_threads(&self, threads: Arc<dyn Threads>) {
        self.owner.tell(move |s| s.threads = Some(threads));
    }

    /// The transport for the current key, reloaded when the key changes.
    pub(super) async fn transport(&self) -> Result<Option<Arc<dyn Transport>>> {
        if let Some(fixed) = &self.fixed {
            return Ok(Some(fixed.clone()));
        }
        let path = key_path(&self.root);
        let Ok(modified) = std::fs::metadata(&path).and_then(|m| m.modified()) else {
            self.owner.ask(|s| s.loaded = None).await;
            return Ok(None);
        };
        let loaded = self
            .owner
            .ask(move |s| {
                s.loaded
                    .as_ref()
                    .filter(|(at, _)| *at == modified)
                    .map(|(_, t)| t.clone())
            })
            .await;
        if let Some(transport) = loaded {
            return Ok(Some(transport));
        }
        let config = KeyConfig::load(&self.root)?.context("APNs key disappeared")?;
        let transport: Arc<dyn Transport> = Arc::new(Apns::new(&config)?);
        let made = transport.clone();
        self.owner
            .ask(move |s| s.loaded = Some((modified, made)))
            .await;
        Ok(Some(transport))
    }

    // MARK: Notifications

    /// Forgets a token Apple says is gone, wherever this device used it.
    pub(super) async fn forget(&self, device: &str, token: &str) {
        let (device, token) = (device.to_string(), token.to_string());
        self.owner.ask(move |s| s.forget(&device, &token)).await
    }

    /// Queues a notification; notes within the burst window go out together.
    pub fn notify(self: &Arc<Self>, note: Note) {
        let this = self.clone();
        self.owner.tell(move |s| {
            s.pending.push(note);
            if s.pending.len() > 1 {
                return;
            }
            tokio::spawn(async move {
                crate::clock::after(this.timing.coalesce).await;
                this.flush().await;
            });
        });
    }

    /// Sends the batch; each alert retries transient failures on its own,
    /// under one collapse ID so a retry of a delivered alert replaces it.
    pub(super) async fn flush(self: &Arc<Self>) {
        let deliveries = self
            .owner
            .ask(|s| {
                let notes = std::mem::take(&mut s.pending);
                s.alerts(&notes)
            })
            .await;
        for (device, mut delivery) in deliveries {
            let n = self.alerts_sent.fetch_add(1, Ordering::Relaxed);
            delivery.collapse_id = Some(format!("squircle-{}-{n}", crate::model::now()));
            let this = self.clone();
            tokio::spawn(async move { this.send_alert(device, delivery).await });
        }
    }

    pub(super) async fn send_alert(&self, device: String, delivery: Delivery) {
        for attempt in 1..=ALERT_ATTEMPTS {
            let transport = match self.transport().await {
                Ok(Some(t)) => t,
                Ok(None) => return,
                Err(error) => {
                    eprintln!("Push: {error:#}");
                    return;
                }
            };
            let outcome = transport.send(&delivery).await;
            if matches!(outcome, Ok(Outcome::Unregistered)) {
                self.forget(&device, &delivery.token).await;
            }
            if !matches!(outcome, Ok(Outcome::Sent)) {
                eprintln!(
                    "Push to device {device} (try {attempt}): {}",
                    describe(&outcome)
                );
            }
            if !transient(&outcome) {
                return;
            }
            if attempt < ALERT_ATTEMPTS {
                crate::clock::after(backoff(self.timing.retry, attempt)).await;
            }
        }
    }

    /// `squircle push test`: a notification, and optionally a Live Activity,
    /// now, once each, reporting what Apple said.
    pub async fn test(&self, live: bool) -> Value {
        let note = Note {
            app: "Squircle".into(),
            line: "Notifications from your Mac work.".into(),
            target: Target::default(),
        };
        let deliveries = self
            .owner
            .ask(move |s| {
                let mut deliveries = s.alerts(&[note]);
                if live {
                    let content = LiveState {
                        status: "Testing the Live Activity".into(),
                        workers: 1,
                        needs_you: false,
                        working: true,
                    };
                    for device in s.devices.values() {
                        let Some(token) = &device.start_token else {
                            continue;
                        };
                        deliveries.push((
                            device.id.clone(),
                            Delivery {
                                token: token.clone(),
                                environment: device.environment,
                                bundle_id: device.bundle_id.clone(),
                                push_type: PushType::LiveActivity,
                                priority: 10,
                                collapse_id: None,
                                payload: activity_payload(
                                    LiveEvent::Start,
                                    &content,
                                    "Squircle",
                                    "test",
                                    crate::model::now(),
                                ),
                            },
                        ));
                    }
                }
                deliveries
            })
            .await;
        if deliveries.is_empty() {
            return json!({"sent": [], "note": "No phone has registered yet. Open Squircle on the phone and allow notifications."});
        }
        let transport = match self.transport().await {
            Ok(Some(t)) => t,
            Ok(None) => {
                return json!({"sent": [{"error": "No APNs key. Run: squircle push setup --key-file PATH --key-id ID --team-id ID"}]});
            }
            Err(error) => return json!({"sent": [{"error": format!("{error:#}")}]}),
        };
        let mut results = vec![];
        for (device, delivery) in deliveries {
            let outcome = transport.send(&delivery).await;
            if matches!(outcome, Ok(Outcome::Unregistered)) {
                self.forget(&device, &delivery.token).await;
            }
            results.push(json!({"device": device, "result": describe(&outcome)}));
        }
        json!({"sent": results})
    }

    /// Keeps every phone's activities in line with what each app wants, until
    /// the service stops. Runs on each change (`written`: T3 writing its
    /// database, which may change a step) and when the policy next asks.
    pub async fn run(self: Arc<Self>, mut written: futures_util::stream::BoxStream<'static, ()>) {
        use futures_util::StreamExt;
        loop {
            let next = self.reconcile().await;
            tokio::select! {
                _ = self.wake.notified() => {}
                Some(()) = written.next() => self.owner.ask(|s| s.written += 1).await,
                _ = crate::clock::reach(next) => {}
            }
        }
    }

    /// One pass: decides the sends and step lookups due now, starts them, and
    /// returns when the next pass is due.
    pub(super) async fn reconcile(self: &Arc<Self>) -> Option<Instant> {
        let transport = match self.transport().await {
            Ok(Some(t)) => t,
            Ok(None) => return None, // nobody to tell: no sends, no lookups
            Err(error) => {
                eprintln!("Push: {error:#}");
                return None;
            }
        };
        let timing = self.timing;
        let (sends, lookups, next) = self.owner.ask(move |s| s.reconcile(timing)).await;
        for (failures, send) in sends {
            let (this, transport) = (self.clone(), transport.clone());
            tokio::spawn(async move {
                let outcome = transport.send(&send.delivery).await;
                this.settle(send, failures, outcome).await;
            });
        }
        for (project, key) in lookups {
            let this = self.clone();
            tokio::spawn(async move { this.look_up(project, key).await });
        }
        next
    }

    /// Applies a send's result, if the link still waits for that send.
    pub(super) async fn settle(&self, send: Outgoing, failures: u32, outcome: Result<Outcome>) {
        if !matches!(outcome, Ok(Outcome::Sent)) {
            eprintln!(
                "Live Activity push to device {} ({}): {}",
                send.device,
                send.project,
                describe(&outcome)
            );
        }
        let retry = self.timing.retry;
        self.owner
            .ask(move |s| s.settle(send, failures, outcome, retry))
            .await;
        self.wake.notify_one();
    }

    /// Reads the agent's current step for one turn; the text is kept only if
    /// that turn is still the one the activity shows.
    pub(super) async fn look_up(&self, project: String, key: StepKey) {
        let threads = self.owner.ask(|s| s.threads.clone()).await;
        let text = match threads {
            Some(t) => t.current_step(&key.thread).await,
            None => None,
        };
        self.owner
            .ask(move |s| {
                let Some(step) = s
                    .apps
                    .get_mut(&project)
                    .and_then(|a| a.step.as_mut())
                    .filter(|s| s.key == key)
                else {
                    return;
                };
                step.looking = false;
                step.checked = Some(Instant::now());
                if text.is_some() {
                    step.text = text;
                }
            })
            .await;
        self.wake.notify_one();
    }
}
