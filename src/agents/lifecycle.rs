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
            Some(agent) => {
                if self.wait_thread(&agent.thread_id).await?.is_some() {
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
            heard: None,
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
                    m14::Effect::Commit => {}
                    m14::Effect::SendCreate(command) => {
                        next = Some(m14::Event::Sent {
                            outcome: self.dispatch_creation(client, thread, &command).await,
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

    pub(super) fn agent_for_thread(&self, thread_id: &str) -> Option<Agent> {
        self.registry()
            .agents
            .values()
            .find(|a| a.thread_id == thread_id)
            .cloned()
    }

    // MARK: Restart

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

    /// Restarts an app's agent on its thread: now if it is between turns,
    /// otherwise once no turn is running. The request is saved first and
    /// cleared only once it succeeds; a failure is retried and shows as the
    /// agent's restart `error`.
    pub async fn restart(
        self: &Arc<Self>,
        project_id: Option<&str>,
        thread_id: Option<&str>,
    ) -> Result<Value> {
        self.ready().await?;
        let project = self.find_agent(project_id, thread_id)?.project_id;
        self.ops
            .run(project.clone(), async {
                let agent = self.find_agent(Some(&project), None)?;
                self.thread(&agent.thread_id)
                    .context("The app agent's thread is gone")?;
                for effect in self.reduce_agent(&project, m14::Event::Restart).await? {
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

    /// Starts the queued restarts whose agent has no turn running.
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
                            && matches!(
                                agent.lifecycle,
                                Lifecycle::RestartQueued { .. } | Lifecycle::Restarting { .. }
                            )
                            && s.shell
                                .observe(&agent.thread_id)
                                .current()
                                .flatten()
                                .is_some_and(|o| !o.busy())
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
            crate::clock::after(delay).await;
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

    /// What T3 shows now of the agent's thread: what a restart decides on.
    pub(super) async fn look(&self, client: &dyn Peer, agent: &Agent) -> m14::Event {
        m14::Event::Look {
            agent: self.seen_live(client, &agent.thread_id).await,
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
                        Ok(Some(session)) => {
                            json!({"type": "provider-session.detach", "threadId": thread,
                                            "providerSessionId": session, "reason": "Stopped by Squircle"})
                        }
                        Ok(None) => {
                            return Dispatched::Accepted(json!({"stopped": "nothing to stop"}));
                        }
                        Err(error) => return Dispatched::NotSent(error),
                    }
                }
            },
        };
        client.dispatch(&Command::new(identity, body)).await
    }

    /// Carries out the project's queued or interrupted restart (M14), its
    /// stop saved before it is sent. Call in its operation lane. Nothing is
    /// stopped while a turn may be running, the agent's or a newer one:
    /// that defers the restart until it ends.
    pub(super) async fn perform(&self, project: &str) -> Result<Value> {
        let client = self.ready().await?;
        let start = self.find_agent(Some(project), None)?;
        if matches!(
            start.lifecycle,
            Lifecycle::Creating { .. } | Lifecycle::Ready { .. }
        ) {
            return Ok(
                json!({"project_id": project, "thread_id": start.thread_id, "when": "done"}),
            );
        }
        let thread = start.thread_id.clone();
        let mut event = self.look(&*client, &start).await;
        loop {
            let mut next = None;
            for effect in self.reduce_agent(project, event).await? {
                match effect {
                    m14::Effect::Commit => {}
                    m14::Effect::Stop(identity) => {
                        let outcome = self.stop(&*client, &thread, &identity).await;
                        next = Some(m14::Event::Sent {
                            outcome,
                            next: self::identity(),
                        });
                    }
                    m14::Effect::Deferred => {
                        return Ok(json!({
                        "project_id": project, "thread_id": thread, "action": "restart", "when": "after-turn",
                        "next": "Happens when the agent's current turn ends. If that is you: end your turn now, telling the user in a sentence."}));
                    }
                    m14::Effect::Done => {
                        return Ok(json!({
                        "project_id": project, "thread_id": thread, "action": "restart", "when": "now",
                        "next": "The agent's next message starts a new session with the same history and gets the current instructions."}));
                    }
                    m14::Effect::Failed(detail) => bail!(detail),
                    m14::Effect::SendCreate(_) => bail!("Unexpected creation during a restart"),
                }
            }
            event = next.context("The restart stopped without an answer")?;
        }
    }
}
