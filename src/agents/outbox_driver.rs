use super::*;

impl Agents {
    // MARK: Wake-ups

    /// Wake-ups wait a few seconds so workers finishing together arrive as one note.
    pub(super) fn schedule_flush(self: &Arc<Self>) {
        self.schedule_flush_in(Duration::from_secs(4));
    }

    /// A failed flush retries with backoff even if T3 sends nothing new.
    pub(super) fn schedule_flush_in(self: &Arc<Self>, delay: Duration) {
        let this = self.clone();
        tokio::spawn(async move {
            let scheduled = this
                .owner
                .ask(|s| {
                    if s.flush_scheduled || !s.has_due_wakes() {
                        return false;
                    }
                    s.flush_scheduled = true;
                    true
                })
                .await;
            if !scheduled {
                return;
            }
            tokio::time::sleep(delay).await;
            this.owner.ask(|s| s.flush_scheduled = false).await;
            match this.flush().await {
                Ok(()) => {
                    this.owner.ask(|s| s.flush_failures = 0).await;
                    // An update whose attempt failed is due again at its own
                    // saved time, even if T3 sends nothing new meanwhile.
                    if let Some(at) = this.next_retry() {
                        this.schedule_flush_in(Duration::from_secs(
                            at.saturating_sub(crate::model::now()).max(1),
                        ));
                    }
                }
                Err(error) => {
                    eprintln!("Wake-up not delivered: {error:#}");
                    let failures = this
                        .owner
                        .ask(|s| {
                            s.flush_failures = (s.flush_failures + 1).min(6);
                            s.flush_failures
                        })
                        .await;
                    this.schedule_flush_in(Duration::from_secs(outbox::backoff(failures)));
                }
            }
        });
    }

    /// Follows workers in T3's shell (see `State::observe_workers`).
    #[cfg(test)]
    pub(super) async fn observe_workers(&self) {
        self.owner.ask(|s| s.observe_workers()).await
    }

    /// Workers whose state calls for a wake-up their coordinator has not had
    /// and that is not already queued. Only from a current shell.
    pub(super) async fn due_wakes(&self) -> Vec<(String, Worker, WorkerEvent)> {
        self.owner.ask(|s| s.due_wakes()).await
    }

    #[cfg(test)]
    pub(super) async fn has_due_wakes(&self) -> bool {
        self.owner.ask(|s| s.has_due_wakes()).await
    }

    /// When the soonest queued update that failed is due again.
    pub(super) fn next_retry(&self) -> Option<u64> {
        self.registry()
            .outbox
            .iter()
            .filter_map(|w| w.outbound.retry_at)
            .min()
    }

    /// Queues the due wake-ups, then delivers the queue in order. Each queued
    /// update keeps its message ID, and each attempt its saved command
    /// identity: an unanswered one is sent again as the same command, which
    /// T3 answers from its receipt if it already has it.
    pub(super) async fn flush(&self) -> Result<()> {
        self.flushing
            .run(async {
                let client = self.client().await?;
                let mut due = vec![];
                for (id, worker, mut event) in self.due_wakes().await {
                    // A question's request tells this one from an earlier one in the turn.
                    if event.kind == EventKind::NeedsYou {
                        event.request = pending_request(&self.thread_detail(&*client, &id).await?);
                    }
                    if worker.notified.as_ref() != Some(&event) {
                        due.push((id, worker, event));
                    }
                }
                self.queue(due).await?;
                let queued: Vec<String> = self
                    .registry()
                    .outbox
                    .iter()
                    .map(|w| w.message_id.clone())
                    .collect();
                for id in queued {
                    self.deliver(&*client, &id).await?;
                }
                Ok(())
            })
            .await
    }

    /// Takes one queued update as far as it goes now: M16 decides, each of
    /// its decisions is saved before what it asks for runs.
    pub(super) async fn deliver(&self, client: &dyn Peer, id: &str) -> Result<()> {
        let Some(coordinator) = self
            .registry()
            .outbox
            .iter()
            .find(|w| w.message_id == id)
            .map(|w| w.coordinator.clone())
        else {
            return Ok(());
        };
        let mut event = outbox::Event::Due {
            now: crate::model::now(),
            recipient: self.recipient(&coordinator),
            next: identity(),
        };
        loop {
            let reducing = id.to_string();
            let Some((wake, effects)) = self
                .owner
                .ask(move |s| s.reduce_wake(&reducing, event))
                .await?
            else {
                return Ok(());
            };
            let mut next = None;
            for effect in effects {
                match effect {
                    outbox::Effect::Commit | outbox::Effect::Settle(_) => {}
                    outbox::Effect::Send(identity) => {
                        let outcome = match self.wake_command(&wake, &identity) {
                            Ok(command) => client.dispatch(&command).await,
                            Err(why) => Dispatched::NotSent(why),
                        };
                        if let Dispatched::Refused(detail)
                        | Dispatched::NotSent(detail)
                        | Dispatched::Unknown(detail) = &outcome
                        {
                            eprintln!("Wake-up {id} not delivered yet: {detail}");
                        }
                        next = Some(outbox::Event::Sent {
                            outcome,
                            now: crate::model::now(),
                            next: self::identity(),
                        });
                    }
                    outbox::Effect::LookUp => {
                        let found = self
                            .has_message(client, &wake.coordinator, &wake.message_id)
                            .await
                            .map_err(|e| format!("{e:#}"));
                        next = Some(outbox::Event::LookedUp {
                            found,
                            now: crate::model::now(),
                            next: identity(),
                        });
                    }
                }
            }
            match next {
                Some(following) => event = following,
                None => return Ok(()),
            }
        }
    }

    /// What the live shell says of a thread, as the machines read it.
    pub(super) fn seen<T>(
        &self,
        thread: &str,
        f: impl Fn(Option<ThreadObservation>) -> T,
    ) -> core::Observed<T> {
        match self.observe(thread) {
            Observed::Current { epoch, value } => core::Observed::Current {
                epoch: Epoch(epoch),
                revision: Revision::default(),
                value: f(value),
            },
            Observed::Stale { epoch, value } => core::Observed::Stale {
                epoch: Epoch(epoch),
                revision: Revision::default(),
                last: Some(f(value)),
            },
            Observed::Unavailable => {
                core::Observed::Unavailable("T3's thread list is not current".into())
            }
        }
    }

    /// Whether the live shell has a thread, as M16 sees it.
    pub(super) fn recipient(&self, thread: &str) -> core::Observed<bool> {
        self.seen(thread, |o| o.is_some())
    }

    /// The update as T3 is sent it, under `identity`. T3 dedupes by command
    /// ID alone.
    pub(super) fn wake_command(
        &self,
        wake: &Wake,
        identity: &Identity,
    ) -> std::result::Result<Command, String> {
        self.thread(&wake.coordinator)
            .ok_or("T3's shell no longer has the agent's thread")?;
        Ok(Command::new(
            identity,
            deliver(
                &wake.coordinator,
                json!({"messageId": wake.message_id, "text": wake.text, "attachments": [],
                       "context": {"version": 1, "records": [wake.record]}}),
            ),
        ))
    }

    /// Records one update per coordinator for the given wake-ups.
    pub(super) async fn queue(&self, due: Vec<(String, Worker, WorkerEvent)>) -> Result<()> {
        if due.is_empty() {
            return Ok(());
        }
        let mut by_coordinator: BTreeMap<String, Vec<(String, Worker, WorkerEvent)>> =
            BTreeMap::new();
        for due in due {
            by_coordinator
                .entry(due.1.coordinator.clone())
                .or_default()
                .push(due);
        }
        let label = |kind: EventKind| {
            match kind {
                EventKind::NeedsYou => Phase::NeedsYou,
                EventKind::Error => Phase::Error,
                EventKind::Done => Phase::Done,
                EventKind::Working => Phase::Working,
            }
            .label()
        };
        let wakes: Vec<Wake> = by_coordinator.into_iter().map(|(coordinator, notes)| {
            let lines: Vec<String> = notes.iter().map(|(id, w, event)| {
                let what = match event.kind {
                    EventKind::NeedsYou => "is waiting on a question or approval",
                    EventKind::Error => "stopped with an error",
                    _ => "finished its turn",
                };
                format!("- \"{}\" ({id}, {}) {what}.", w.title, w.branch)
            }).collect();
            Wake {
                coordinator,
                message_id: uuid::Uuid::new_v4().to_string(),
                workers: notes.iter().map(|(id, _, event)| (id.clone(), event.clone())).collect(),
                text: format!("[worker update]\n{}\nRun `squircle thread read ID` for details, then decide what to do next.", lines.join("\n")),
                record: Note::WorkerUpdate.record(json!({
                    "workers": notes.iter().map(|(id, w, event)| json!({"id": id, "title": w.title, "branch": w.branch, "state": label(event.kind)})).collect::<Vec<_>>()
                })),
                outbound: Outbound::default(),
                build: None,
            }
        }).collect();
        self.change(|registry| registry.outbox.extend(wakes)).await
    }

    /// Queues a service message that starts a turn in `thread`; `id` is its
    /// message ID, so queuing it again changes nothing.
    pub async fn notify(
        self: &Arc<Self>,
        thread: &str,
        id: &str,
        text: String,
        note: Note,
        payload: Value,
    ) -> Result<()> {
        let (thread, id) = (thread.to_string(), id.to_string());
        let queued = self
            .change_if(move |registry| {
                if registry.outbox.iter().any(|w| w.message_id == id) {
                    return None;
                }
                registry.outbox.push(Wake {
                    coordinator: thread,
                    message_id: id,
                    workers: vec![],
                    text,
                    record: note.record(payload),
                    outbound: Outbound::default(),
                    build: None,
                });
                Some(())
            })
            .await?;
        if queued.is_some() {
            self.schedule_flush();
        }
        Ok(())
    }

    /// The threads now waiting in line for a simulator.
    pub fn set_sim_waiting(&self, threads: Vec<String>) {
        self.owner
            .tell(move |s| s.sim_waiting = threads.into_iter().collect());
    }

    /// Whether T3 has a message with this ID in the thread.
    pub(super) async fn has_message(
        &self,
        client: &dyn Peer,
        thread: &str,
        message: &str,
    ) -> Result<bool> {
        let detail = self.thread_detail(client, thread).await?;
        Ok(detail["messages"]
            .as_array()
            .into_iter()
            .flatten()
            .any(|m| m["id"] == message || m["messageId"] == message))
    }
}
