use super::*;

impl Agents {
    // MARK: Agents

    pub fn list(&self) -> Vec<Agent> {
        self.registry().agents.values().cloned().collect()
    }

    /// The app agent for a T3 project, created on first use: a thread on
    /// Squircle's instance in the project's folder, in `runtime_mode` (the
    /// mode of an existing agent is the phone's to change on its thread).
    pub async fn ensure(
        &self,
        project_id: &str,
        message: Option<&str>,
        model: Option<&str>,
        runtime_mode: Option<&str>,
    ) -> Result<Agent> {
        let mode = self::runtime_mode(runtime_mode)?;
        let client = self.ready().await?;
        let agent = self
            .ops
            .run(
                project_id.to_string(),
                self.existing_or_create(&*client, project_id, model, &mode),
            )
            .await?;
        if let Some(text) = message.filter(|t| !t.trim().is_empty()) {
            self.send(&agent.thread_id, text).await?;
        }
        Ok(agent)
    }

    /// Call in the project's operation lane.
    pub(super) async fn existing_or_create(
        &self,
        client: &dyn Peer,
        project_id: &str,
        model: Option<&str>,
        mode: &str,
    ) -> Result<Agent> {
        let saved = self.registry().agents.get(project_id).cloned();
        let agent = match saved {
            Some(
                agent @ Agent {
                    lifecycle: Lifecycle::Creating { .. },
                    ..
                },
            ) => agent,
            Some(
                agent @ Agent {
                    lifecycle: Lifecycle::Replacing { .. },
                    ..
                },
            ) => return Ok(agent),
            Some(agent) => {
                // A thread T3 has not sent yet may just be new: wait for it a moment.
                let row = match self.thread(&agent.thread_id) {
                    None => self.wait_thread(&agent.thread_id).await.ok(),
                    row => row,
                };
                if row.is_some_and(|row| row["archivedAt"].is_null()) {
                    return Ok(agent);
                }
                // Archived or deleted in T3: start a new agent.
                self.reserve(client, project_id).await?
            }
            None => self.reserve(client, project_id).await?,
        };
        self.create(client, &agent, model, mode).await
    }

    /// Reserves a new agent in the registry before T3 hears of it, so a
    /// retry or a restart finishes that thread instead of making another.
    pub(super) async fn reserve(&self, client: &dyn Peer, project_id: &str) -> Result<Agent> {
        let config = client.call("server.getConfig", json!({})).await?;
        let ready = config["providers"]
            .as_array()
            .into_iter()
            .flatten()
            .any(|p| p["instanceId"] == INSTANCE && p["status"] == "ready");
        ensure!(
            ready,
            "T3 has no ready \"{INSTANCE}\" agent instance. Run: squircle agent setup"
        );
        let agent = Agent {
            project_id: project_id.into(),
            thread_id: uuid::Uuid::new_v4().to_string(),
            created_at: crate::model::now(),
            lifecycle: Lifecycle::Creating { command: None },
        };
        let reserved = agent.clone();
        self.change(move |registry| {
            registry
                .agents
                .insert(reserved.project_id.clone(), reserved)
        })
        .await?;
        Ok(agent)
    }

    /// Has T3 create a reserved agent's thread (M14): the creation is saved
    /// before it is sent, and one T3 left unanswered is sent again as itself.
    pub(super) async fn create(
        &self,
        client: &dyn Peer,
        agent: &Agent,
        model: Option<&str>,
        mode: &str,
    ) -> Result<Agent> {
        let (project, thread) = (agent.project_id.as_str(), agent.thread_id.as_str());
        let create = self.create_command(project, thread, model, mode, &identity())?;
        let mut event = m14::Event::Create {
            exists: self.seen(thread, |o| o.is_some()),
            create,
        };
        loop {
            let mut next = None;
            for effect in self.reduce_agent(project, event).await? {
                match effect {
                    m14::Effect::Commit | m14::Effect::Rebind => {}
                    m14::Effect::SendCreate(command) => {
                        next = Some(m14::Event::Sent {
                            outcome: client.dispatch(&command).await,
                            next: identity(),
                        });
                    }
                    m14::Effect::Done => {
                        // T3 has it; it shows in the shell a moment later.
                        let _ = self.wait_thread(thread).await;
                        return self
                            .registry()
                            .agents
                            .get(project)
                            .cloned()
                            .context("The app's agent is gone");
                    }
                    m14::Effect::Failed(detail) => bail!(detail),
                    other => bail!("Unexpected step while creating the app's agent: {other:?}"),
                }
            }
            event = next.context("The app agent's creation stopped without an answer")?;
        }
    }

    pub(super) fn create_command(
        &self,
        project_id: &str,
        thread_id: &str,
        model: Option<&str>,
        mode: &str,
        identity: &Identity,
    ) -> Result<Command> {
        let shell = self.shell();
        let project = shell
            .project(project_id)
            .with_context(|| format!("T3 has no project {project_id}"))?;
        let model = model
            .map(str::to_string)
            .or_else(|| {
                project["defaultModelSelection"]["model"]
                    .as_str()
                    .filter(|_| project["defaultModelSelection"]["instanceId"] == "claudeAgent")
                    .map(str::to_string)
            })
            .unwrap_or_else(|| DEFAULT_MODEL.into());
        let name = project["title"].as_str().unwrap_or("App");
        Ok(Command::new(
            identity,
            json!({
                "type": "thread.create", "threadId": thread_id, "projectId": project_id,
                "createdBy": "user", "creationSource": "server",
                "title": format!("{name} agent"),
                "modelSelection": {"instanceId": INSTANCE, "model": model},
                "runtimeMode": mode, "interactionMode": "default",
                "branch": null, "worktreePath": null,
            }),
        ))
    }

    /// Reduces `event` for the app's agent (M14) and saves what it decided
    /// before any effect it asks for runs (see `State::reduce_agent`).
    pub(super) async fn reduce_agent(
        &self,
        project: &str,
        event: m14::Event,
    ) -> Result<Vec<m14::Effect>> {
        let project = project.to_string();
        self.owner
            .ask(move |s| s.reduce_agent(&project, event))
            .await
    }

    /// The agent, its workers and its updates not sent yet follow the new
    /// thread. One that may have reached the old thread is settled there
    /// (M16), never resent.
    pub(super) fn rebind(registry: &mut Registry, project: &str, previous: &str, thread: &str) {
        for worker in registry
            .workers
            .values_mut()
            .filter(|w| w.coordinator == previous)
        {
            worker.coordinator = thread.into();
        }
        for wake in registry
            .outbox
            .iter_mut()
            .filter(|w| w.coordinator == previous && w.outbound.delivery == Delivery::Queued)
        {
            wake.coordinator = thread.into();
        }
        if let Some(agent) = registry.agents.get_mut(project) {
            agent.thread_id = thread.into();
        }
    }

    pub(super) fn agent_for_thread(&self, thread_id: &str) -> Option<Agent> {
        self.registry()
            .agents
            .values()
            .find(|a| a.thread_id == thread_id)
            .cloned()
    }

    // MARK: Restart and fresh start

    /// The agent named by its project or its thread.
    pub(super) fn find_agent(
        &self,
        project_id: Option<&str>,
        thread_id: Option<&str>,
    ) -> Result<Agent> {
        let registry = self.registry();
        match (project_id, thread_id) {
            (Some(project), _) => registry
                .agents
                .get(project)
                .cloned()
                .with_context(|| format!("The app {project} has no agent yet")),
            (None, Some(thread)) => registry
                .agents
                .values()
                .find(|a| a.thread_id == thread)
                .cloned()
                .with_context(|| format!("{thread} is not an app agent's thread")),
            (None, None) => bail!("Name the app (--project) or the agent's thread (--thread)"),
        }
    }

    /// Restarts or replaces an app's agent: now if it is between turns,
    /// otherwise once no turn is running. The request is saved first and
    /// cleared only once it succeeds; a failure is retried and shows as the
    /// agent's reset `error`.
    pub async fn reset(
        self: &Arc<Self>,
        project_id: Option<&str>,
        thread_id: Option<&str>,
        reset: Reset,
    ) -> Result<Value> {
        self.ready().await?;
        let project = self.find_agent(project_id, thread_id)?.project_id;
        self.ops
            .run(project.clone(), async {
                let agent = self.find_agent(Some(&project), None)?;
                self.thread(&agent.thread_id)
                    .context("The app agent's thread is gone")?;
                for effect in self
                    .reduce_agent(&project, m14::Event::Request(reset))
                    .await?
                {
                    if let m14::Effect::Failed(detail) = effect {
                        bail!(detail)
                    }
                }
                let running = project.clone();
                self.owner
                    .ask(move |s| {
                        s.resets.insert(running);
                    })
                    .await;
                let result = self.perform(&project).await;
                self.reset_finished(&project, &result).await;
                result
            })
            .await
    }

    /// Starts the queued resets whose agent has no turn running, and resumes
    /// interrupted fresh starts.
    pub(super) async fn run_due_resets(self: &Arc<Self>) {
        let due: Vec<String> = self
            .owner
            .ask(|s| {
                let due: Vec<String> = s
                    .registry()
                    .agents
                    .values()
                    .filter(|agent| {
                        !s.resets.contains(&agent.project_id)
                            && match agent.lifecycle {
                                Lifecycle::Replacing { .. } => s.shell.current(),
                                Lifecycle::ResetQueued { .. } | Lifecycle::Restarting { .. } => s
                                    .shell
                                    .observe(&agent.thread_id)
                                    .current()
                                    .flatten()
                                    .is_some_and(|o| !o.busy()),
                                _ => false,
                            }
                    })
                    .map(|a| a.project_id.clone())
                    .collect();
                s.resets.extend(due.iter().cloned());
                due
            })
            .await;
        for project in due {
            self.clone().spawn_reset(project, Duration::ZERO);
        }
    }

    pub(super) fn spawn_reset(self: Arc<Self>, project: String, delay: Duration) {
        tokio::spawn(async move {
            tokio::time::sleep(delay).await;
            let result = self.ops.run(project.clone(), self.perform(&project)).await;
            if let Err(error) = &result {
                eprintln!("Agent reset failed: {error:#}");
            }
            self.reset_finished(&project, &result).await;
        });
    }

    /// Records the outcome in the reset's own state; a failure retries it
    /// with backoff, without waiting for T3 to send anything. A deferred one
    /// waits for the shell to show its agent between turns.
    pub(super) async fn reset_finished(self: &Arc<Self>, project: &str, result: &Result<Value>) {
        let (finished, failure) = (
            project.to_string(),
            result.as_ref().err().map(|e| format!("{e:#}")),
        );
        let retry = self
            .change(move |registry| {
                registry
                    .agents
                    .get_mut(&finished)
                    .and_then(|agent| agent.lifecycle.attempted(failure))
            })
            .await;
        // Unsaved, the reset is still queued in the saved lifecycle: the next
        // look at due resets starts it again.
        let retry = retry.unwrap_or_else(|error| {
            eprintln!("Agent state not saved: {error:#}");
            None
        });
        match retry {
            Some(delay) => self.clone().spawn_reset(project.into(), delay),
            None => {
                let done = project.to_string();
                self.owner
                    .ask(move |s| {
                        s.resets.remove(&done);
                    })
                    .await;
            }
        }
    }

    /// The agent thread as T3 shows it now; nothing older is acted on.
    pub(super) fn observe_now(&self, thread: &str) -> Result<ThreadObservation> {
        match self.observe(thread) {
            Observed::Current {
                value: Some(observation),
                ..
            } => Ok(observation),
            Observed::Current { value: None, .. } => bail!("The app agent's thread is gone"),
            _ => bail!("T3's thread list is not current; try again"),
        }
    }

    /// What T3 shows now of the agent's thread and, during a replacement,
    /// of the new one: what a reset step decides on.
    pub(super) async fn look(&self, client: &dyn Peer, agent: &Agent) -> m14::Event {
        let successor = match &agent.lifecycle {
            Lifecycle::Replacing { replacement, .. } => {
                self.seen(&replacement.thread_id, |o| o.is_some())
            }
            _ => core::Observed::Unavailable("no replacement".into()),
        };
        m14::Event::Look {
            agent: self.seen_live(client, &agent.thread_id).await,
            successor,
            next: identity(),
        }
    }

    /// What T3 shows of a thread, with whether a provider session is still
    /// attached to it when no run is in progress: the shell does not say,
    /// the thread's projection does. A restart is that session's end.
    pub(super) async fn seen_live(
        &self,
        client: &dyn Peer,
        thread: &str,
    ) -> core::Observed<Option<ThreadObservation>> {
        match self.seen(thread, |o| o) {
            core::Observed::Current {
                epoch,
                revision,
                value: Some(o),
            } if o.execution == Execution::Stopped => {
                match self.thread_detail(client, thread).await {
                    Ok(projection) => core::Observed::Current {
                        epoch,
                        revision,
                        value: Some(o.with_sessions(&projection)),
                    },
                    Err(error) => core::Observed::Unavailable(format!("{error:#}")),
                }
            }
            seen => seen,
        }
    }

    /// Stops a thread's work in T3 under `identity`: interrupts its run in
    /// progress, else detaches the provider session still attached to it.
    /// T3 (protocol 2) has no single "stop the session" command; with
    /// neither, there is nothing to stop.
    pub(super) async fn stop(
        &self,
        client: &dyn Peer,
        thread: &str,
        identity: &Identity,
    ) -> Dispatched {
        let row = self.thread(thread);
        let run = row
            .as_ref()
            .filter(|row| ThreadObservation::decode(row).busy())
            .and_then(|row| row["activeRunId"].as_str().or(row["latestRunId"].as_str()));
        let body = match run {
            Some(run) => json!({"type": "run.interrupt", "threadId": thread, "runId": run,
                                "reason": "Stopped by Squircle"}),
            None => match self.thread_detail(client, thread).await {
                Err(error) => return Dispatched::NotSent(format!("{error:#}")),
                Ok(projection) => {
                    match crate::fsm::coordinator::thread::live_session(&projection) {
                        Some(session) => {
                            json!({"type": "provider-session.detach", "threadId": thread,
                                            "providerSessionId": session, "reason": "Stopped by Squircle"})
                        }
                        None => return Dispatched::Accepted(json!({"stopped": "nothing to stop"})),
                    }
                }
            },
        };
        client.dispatch(&Command::new(identity, body)).await
    }

    /// Carries out the project's queued or interrupted reset (M14), each
    /// step saved before its command is sent. Call in its operation lane.
    /// Nothing is stopped while a turn may be running, the agent's or a
    /// newer one: that defers the reset until it ends.
    pub(super) async fn perform(&self, project: &str) -> Result<Value> {
        let client = self.ready().await?;
        let start = self.find_agent(Some(project), None)?;
        let (action, mut previous) = match &start.lifecycle {
            Lifecycle::ResetQueued {
                reset: Reset::Restart,
                ..
            }
            | Lifecycle::Restarting { .. } => ("restart", start.thread_id.clone()),
            Lifecycle::ResetQueued {
                reset: Reset::Fresh { .. },
                ..
            } => ("fresh", start.thread_id.clone()),
            Lifecycle::Replacing { replacement, .. } => ("fresh", replacement.previous.clone()),
            Lifecycle::Creating { .. } | Lifecycle::Ready { .. } => {
                return Ok(
                    json!({"project_id": project, "thread_id": start.thread_id, "when": "done"}),
                );
            }
        };
        let mut event = self.look(&*client, &start).await;
        loop {
            let mut next = None;
            for effect in self.reduce_agent(project, event).await? {
                let agent = self.find_agent(Some(project), None)?;
                match effect {
                    m14::Effect::Commit | m14::Effect::Rebind => {}
                    m14::Effect::Send(Order::Stop, identity) => {
                        let thread = match &agent.lifecycle {
                            Lifecycle::Replacing { replacement, .. } => {
                                replacement.previous.clone()
                            }
                            _ => agent.thread_id.clone(),
                        };
                        let outcome = self.stop(&*client, &thread, &identity).await;
                        next = Some(m14::Event::Sent {
                            outcome,
                            next: self::identity(),
                        });
                    }
                    m14::Effect::Send(order, identity) => {
                        let command = self.order(&agent, order, &identity)?;
                        let outcome = client.dispatch(&command).await;
                        next = Some(m14::Event::Sent {
                            outcome,
                            next: self::identity(),
                        });
                    }
                    m14::Effect::Gather => {
                        let plan = self
                            .plan(&*client, &agent)
                            .await
                            .map_err(|e| format!("{e:#}"));
                        if let Ok(plan) = &plan {
                            previous = plan.previous.clone();
                        }
                        // Gathering took a while: what counts is the agent right after.
                        next = Some(m14::Event::Gathered {
                            plan,
                            agent: self.seen_live(&*client, &agent.thread_id).await,
                            next: identity(),
                        });
                    }
                    m14::Effect::LookUp => {
                        let Lifecycle::Replacing { replacement, .. } = &agent.lifecycle else {
                            bail!("A handoff looked for outside a fresh start")
                        };
                        let found = self
                            .has_message(&*client, &replacement.thread_id, &replacement.message_id)
                            .await
                            .map_err(|e| format!("{e:#}"));
                        next = Some(m14::Event::LookedUp {
                            found,
                            next: identity(),
                        });
                    }
                    m14::Effect::Deferred => {
                        return Ok(json!({
                        "project_id": project, "thread_id": agent.thread_id, "action": action, "when": "after-turn",
                        "next": "Happens when the agent's current turn ends. If that is you: end your turn now, telling the user in a sentence."}));
                    }
                    m14::Effect::Done if action == "restart" => {
                        return Ok(json!({
                        "project_id": project, "thread_id": agent.thread_id, "action": "restart", "when": "now",
                        "next": "The agent's next message starts a new session with the same history and gets the current instructions."}));
                    }
                    m14::Effect::Done => {
                        return Ok(json!({
                        "project_id": project, "thread_id": agent.thread_id, "previous_thread_id": previous,
                        "action": "fresh", "when": "now",
                        "next": "The new agent has the handoff and is replying; the old conversation stays readable in the app's Threads."}));
                    }
                    m14::Effect::Failed(detail) => bail!(detail),
                    m14::Effect::SendCreate(_) => bail!("Unexpected creation during a reset"),
                }
            }
            event = next.context("The reset stopped without an answer")?;
        }
    }

    /// The command for a reset step, from the saved lifecycle.
    pub(super) fn order(
        &self,
        agent: &Agent,
        order: Order,
        identity: &Identity,
    ) -> Result<Command> {
        let body = match (order, &agent.lifecycle) {
            (Order::Rename, Lifecycle::Replacing { replacement, .. }) => json!({
                "type": "thread.metadata.update", "threadId": replacement.previous,
                "title": replacement.title.as_deref().context("The fresh start has no title for the old thread")?}),
            (Order::Create, Lifecycle::Replacing { replacement, .. }) => {
                return self.create_command(
                    &agent.project_id,
                    &replacement.thread_id,
                    Some(&replacement.model),
                    &replacement.runtime_mode,
                    identity,
                );
            }
            (Order::Handoff, Lifecycle::Replacing { replacement, .. }) => deliver(
                &replacement.thread_id,
                Note::Handoff.message(
                    &replacement.message_id,
                    &replacement.handoff,
                    json!({"previous": replacement.previous}),
                ),
            ),
            (order, lifecycle) => bail!("No {order:?} command for an agent that is {lifecycle:?}"),
        };
        Ok(Command::new(identity, body))
    }

    /// A fresh start's plan: the handoff, the new thread's identities and
    /// the old thread's new title. The new agent keeps the old one's model
    /// and runtime mode; a mode T3 doesn't report holds the fresh start.
    pub(super) async fn plan(&self, client: &dyn Peer, agent: &Agent) -> Result<Replacement> {
        let Lifecycle::ResetQueued {
            reset: Reset::Fresh { note },
            ..
        } = &agent.lifecycle
        else {
            bail!("No fresh start is queued")
        };
        let handoff = self.handoff(client, agent, note.as_deref()).await?;
        let row = self
            .thread(&agent.thread_id)
            .context("The app agent's thread is gone")?;
        let mode = row["runtimeMode"].as_str().filter(|mode| RUNTIME_MODES.contains(mode)).with_context(|| format!(
            "T3 doesn't report a runtime mode this service knows for the app agent ({}), so the fresh start waits",
            row["runtimeMode"].as_str().unwrap_or("none")))?;
        let app = self
            .shell()
            .project(&agent.project_id)
            .and_then(|p| p["title"].as_str().map(str::to_string))
            .unwrap_or_else(|| "App".into());
        let day = Process::new("date")
            .arg("+%b %-d")
            .output()
            .await
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_default();
        Ok(Replacement {
            previous: agent.thread_id.clone(),
            thread_id: uuid::Uuid::new_v4().to_string(),
            model: row["modelSelection"]["model"]
                .as_str()
                .unwrap_or(DEFAULT_MODEL)
                .into(),
            runtime_mode: mode.into(),
            handoff,
            message_id: uuid::Uuid::new_v4().to_string(),
            title: Some(format!("{app} agent (until {day})")),
            note: None,
            step: None,
            delivery: Delivery::Queued,
        })
    }
}
