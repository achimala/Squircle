use super::*;

/// The push owner's state, reached only by its letters.
#[derive(Default)]
pub(super) struct State {
    pub(super) root: PathBuf,
    pub(super) devices: BTreeMap<String, Device>,
    pub(super) presence: HashMap<String, Presence>,
    pub(super) apps: BTreeMap<String, AppLive>,
    pub(super) generation: u64,
    /// The key file's modification time and the transport made from it.
    pub(super) loaded: Option<(SystemTime, Arc<dyn Transport>)>,
    /// Notes waiting for the burst window to close.
    pub(super) pending: Vec<Note>,
    /// Each thread's last turn and phase, once the first shell is seen.
    pub(super) seen: Option<HashMap<String, (Option<String>, Phase)>>,
    pub(super) threads: Option<Arc<dyn Threads>>,
}

pub(super) type DeliveryPlan = (
    Vec<(u32, Outgoing)>,
    Vec<(String, StepKey)>,
    Option<Instant>,
);

impl State {
    /// A phone that could show this app's activity: one running or starting,
    /// or a start token while Squircle isn't open on it.
    pub(super) fn has_recipient(&self, project: &str) -> bool {
        self.devices
            .values()
            .any(|d| match d.links.get(project).map(|l| &l.stage) {
                Some(Stage::Running { .. } | Stage::Starting { .. }) => true,
                _ => d.start_token.is_some() && shown(&self.presence, &d.id) == Shown::Background,
            })
    }

    pub(super) fn save(&self) {
        if let Err(error) = atomic_json(&self.root.join("push").join("devices.json"), &self.devices)
        {
            eprintln!("Push: cannot save devices: {error:#}");
        }
    }

    /// Forgets a token Apple says is gone, wherever this device used it.
    pub(super) fn forget(&mut self, device: &str, token: &str) {
        let Some(d) = self.devices.get_mut(device) else {
            return;
        };
        if d.token.as_deref() == Some(token) {
            d.token = None;
        }
        if d.start_token.as_deref() == Some(token) {
            d.start_token = None;
        }
        d.links.retain(
            |_, l| !matches!(&l.stage, Stage::Running { activity, .. } if activity.token == token),
        );
        self.save();
    }

    /// One alert per device and app, leaving out what the phone is looking at.
    pub(super) fn alerts(&self, notes: &[Note]) -> Vec<(String, Delivery)> {
        let mut out = vec![];
        for device in self.devices.values() {
            let Some(token) = &device.token else { continue };
            let here = shown(&self.presence, &device.id);
            let mut by_app: BTreeMap<&str, Vec<&Note>> = BTreeMap::new();
            for note in notes {
                if let (
                    Some(t),
                    Shown::Foreground {
                        thread: Some(viewed),
                    },
                ) = (&note.target.thread, &here)
                    && t == viewed
                {
                    continue;
                }
                by_app.entry(note.app.as_str()).or_default().push(note);
            }
            for group in by_app.values() {
                out.push((
                    device.id.clone(),
                    Delivery {
                        token: token.clone(),
                        environment: device.environment,
                        bundle_id: device.bundle_id.clone(),
                        push_type: PushType::Alert,
                        priority: 10,
                        collapse_id: None,
                        payload: alert_payload(group),
                    },
                ));
            }
        }
        out
    }

    /// Notes for finished turns and questions since the last shell.
    pub(super) fn changes(
        &mut self,
        apps: &[AppView],
    ) -> Vec<(String, String, String, Option<String>, Change)> {
        let mut changes = vec![];
        let first = self.seen.is_none();
        let seen = self.seen.get_or_insert_with(HashMap::new);
        for app in apps {
            let agent = app.agent.iter().map(|(id, row)| (id, None, row));
            let workers = app
                .workers
                .iter()
                .map(|(id, title, row)| (id, Some(title), row));
            for (id, title, row) in agent.chain(workers) {
                let turn = row["latestRunId"].as_str().map(str::to_string);
                let now = phase(row);
                if !first && let Some(change) = change(seen.get(id), turn.clone(), now) {
                    changes.push((
                        app.app.clone(),
                        app.project_id.clone(),
                        id.clone(),
                        title.cloned(),
                        change,
                    ));
                }
                seen.insert(id.clone(), (turn, now));
            }
        }
        changes
    }

    /// Moves each app's wanted activity to what the shell now says.
    pub(super) fn observe(&mut self, apps: &[AppView]) {
        let now = Instant::now();
        for app in apps {
            let (observed, stepping) = observe(app);
            let active = observed.working || observed.needs_you;
            let entry = self
                .apps
                .entry(app.project_id.clone())
                .or_insert_with(|| AppLive {
                    name: app.app.clone(),
                    want: Want::Hide(observed.clone()),
                    stepping: None,
                    step: None,
                });
            entry.name = app.app.clone();
            entry.want = match (&entry.want, active) {
                (_, true) => Want::Show(observed),
                (Want::Show(_), false) => Want::Pausing {
                    since: now,
                    last: observed,
                },
                (Want::Pausing { since, .. }, false) => Want::Pausing {
                    since: *since,
                    last: observed,
                },
                (Want::Hide(_), false) => Want::Hide(observed),
            };
            if entry.step.as_ref().map(|s| &s.key) != stepping.as_ref() {
                entry.step = stepping.clone().map(|key| Step {
                    key,
                    text: None,
                    checked: None,
                    looking: false,
                });
            }
            entry.stepping = stepping;
        }
    }

    /// One pass of the reconciler: the sends and step lookups due now, and
    /// when the next pass is due.
    pub(super) fn reconcile(&mut self, timing: Timing) -> DeliveryPlan {
        let now = Instant::now();
        let mut next: Option<Instant> = None;
        let mut due = |at: Instant| next = Some(next.map_or(at, |n: Instant| n.min(at)));
        let mut sends = vec![];
        let mut lookups = vec![];
        // The step is read only while it can reach someone.
        let recipients: Vec<String> = self
            .apps
            .keys()
            .filter(|p| self.has_recipient(p))
            .cloned()
            .collect();
        let State {
            devices,
            presence,
            apps,
            generation,
            ..
        } = self;
        for app in apps.values_mut() {
            if let Want::Pausing { since, last } = &app.want {
                if now.duration_since(*since) >= timing.pause {
                    app.want = Want::Hide(last.clone());
                } else {
                    due(*since + timing.pause);
                }
            }
        }
        for (project, app) in apps.iter_mut() {
            for device in devices.values_mut() {
                let here = shown(presence, &device.id);
                let link = device.links.get(project).cloned();
                if let Some(Link { flight, .. }) = &link {
                    match flight {
                        Flight::Sending(_) => continue,
                        Flight::Waiting { until, .. } if *until > now => {
                            due(*until);
                            continue;
                        }
                        _ => {}
                    }
                }
                let stage = link.as_ref().map(|l| &l.stage);
                let (message, token, priority) = match (&app.want, stage) {
                    (Want::Pausing { .. }, _) => continue,
                    (Want::Show(shown), Some(Stage::Running { activity, acked })) => {
                        let content = app.stepped(shown);
                        let important = acked.as_ref().is_none_or(|(s, _)| {
                            s.working != content.working
                                || s.needs_you != content.needs_you
                                || s.workers != content.workers
                        });
                        match acked {
                            Some((s, _)) if *s == content => continue,
                            Some((_, at))
                                if !important && now.duration_since(*at) < timing.throttle =>
                            {
                                due(*at + timing.throttle);
                                continue;
                            }
                            _ => {}
                        }
                        (
                            Message::Update(content),
                            activity.token.clone(),
                            if important { 10 } else { 5 },
                        )
                    }
                    (Want::Show(_), Some(Stage::Starting { at }))
                        if now.duration_since(*at) < START_WAIT =>
                    {
                        continue;
                    }
                    (Want::Show(shown), _) => {
                        let Some(token) = &device.start_token else {
                            continue;
                        };
                        if here != Shown::Background {
                            continue;
                        }
                        (Message::Start(app.stepped(shown)), token.clone(), 10)
                    }
                    (Want::Hide(last), Some(Stage::Running { activity, .. })) => {
                        (Message::End(last.clone()), activity.token.clone(), 10)
                    }
                    (Want::Hide(_), Some(Stage::Starting { .. } | Stage::Absent)) => {
                        // Nothing to end; the phone reports a late start's token, which then ends.
                        device.links.remove(project);
                        continue;
                    }
                    (Want::Hide(_), None) => continue,
                };
                *generation += 1;
                let (event, body) = match &message {
                    Message::Start(s) => (LiveEvent::Start, s.clone()),
                    Message::Update(s) => (LiveEvent::Update, s.clone()),
                    Message::End(s) => (LiveEvent::End, s.clone()),
                };
                let failures = match link.as_ref().map(|l| l.flight) {
                    Some(Flight::Waiting { failures, .. }) => failures,
                    _ => 0,
                };
                let entry = device
                    .links
                    .entry(project.clone())
                    .or_insert_with(|| Link::new(Stage::Absent));
                entry.flight = Flight::Sending(*generation);
                sends.push((
                    failures,
                    Outgoing {
                        device: device.id.clone(),
                        project: project.clone(),
                        generation: *generation,
                        message,
                        delivery: Delivery {
                            token,
                            environment: device.environment,
                            bundle_id: device.bundle_id.clone(),
                            push_type: PushType::LiveActivity,
                            priority,
                            collapse_id: None,
                            payload: activity_payload(
                                event,
                                &body,
                                &app.name,
                                project,
                                crate::model::now(),
                            ),
                        },
                    },
                ));
            }
        }
        // One lookup per turn at a time.
        for (project, app) in apps.iter_mut() {
            let (Want::Show(_), Some(step)) = (&app.want, app.step.as_mut()) else {
                continue;
            };
            if step.looking || !recipients.contains(project) {
                continue;
            }
            match step.checked {
                Some(at) if now.duration_since(at) < STEP_EVERY => due(at + STEP_EVERY),
                _ => {
                    step.looking = true;
                    lookups.push((project.clone(), step.key.clone()));
                }
            }
        }
        (sends, lookups, next)
    }

    /// Applies a send's result, if the link still waits for that send.
    pub(super) fn settle(
        &mut self,
        send: Outgoing,
        failures: u32,
        outcome: Result<Outcome>,
        retry: Duration,
    ) {
        let now = Instant::now();
        let Some(device) = self.devices.get_mut(&send.device) else {
            return;
        };
        let Some(link) = device.links.get_mut(&send.project) else {
            return;
        };
        if link.flight != Flight::Sending(send.generation) {
            return; // superseded: a new activity token, or the link went away
        }
        link.flight = Flight::Idle;
        let mut save = false;
        match (&outcome, &send.message) {
            (Ok(Outcome::Sent | Outcome::Rejected(_)), Message::Start(_)) => {
                link.stage = Stage::Starting { at: now }
            }
            (Ok(Outcome::Sent | Outcome::Rejected(_)), Message::Update(content)) => {
                // A rejected update is not retried: the next change sends anew.
                if let Stage::Running { acked, .. } = &mut link.stage {
                    *acked = Some((content.clone(), now));
                }
            }
            (Ok(Outcome::Sent | Outcome::Rejected(_)), Message::End(_)) => {
                device.links.remove(&send.project);
                save = true;
            }
            (Ok(Outcome::Unregistered), message) => {
                device.links.remove(&send.project);
                if matches!(message, Message::Start(_))
                    && device.start_token.as_deref() == Some(&send.delivery.token)
                {
                    device.start_token = None;
                }
                save = true;
            }
            (Ok(Outcome::Retry(_)) | Err(_), _) => {
                link.flight = Flight::Waiting {
                    until: now + backoff(retry, failures + 1),
                    failures: failures + 1,
                };
            }
        }
        if save {
            self.save();
        }
    }
}

/// A send the reconciler decided on, with the generation its result must match.
pub(super) struct Outgoing {
    pub(super) device: String,
    pub(super) project: String,
    pub(super) generation: u64,
    pub(super) message: Message,
    pub(super) delivery: Delivery,
}
