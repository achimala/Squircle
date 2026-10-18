use super::*;

impl Agents {
    pub fn open(root: &Path, server: &str, tasks: Arc<Tasks>) -> Result<Arc<Self>> {
        let file = JsonFile::new(root.join("agents.json"));
        let (registry, revision) = file.read()?.unwrap_or_default();
        let gate: RegistryGate = Gate::restore(registry, revision, file);
        let registry = Arc::new(gate.committed().clone());
        let status: Arc<str> = "Not connected to T3".into();
        let shell = Arc::new(Shell::default());
        let (view, snapshot) = Published::new(View {
            registry: registry.clone(),
            shell: shell.clone(),
            status: status.clone(),
            t3: None,
        });
        let state = State {
            gate,
            shell,
            status,
            t3: None,
            published: (registry, revision),
            view,
            flush_scheduled: false,
            flush_failures: 0,
            sim_waiting: Default::default(),
            resets: Default::default(),
        };
        Ok(Arc::new(Self {
            root: root.to_path_buf(),
            cli: cli_invocation(root, server),
            owner: Owner::spawn("agents", state),
            view: snapshot,
            fake: std::sync::OnceLock::new(),
            ops: Lanes::new("agent operations", Rank::AgentOp),
            spawning: Lanes::new("worker spawns", Rank::AgentSpawn),
            flushing: Lane::new(Rank::AgentFlush),
            push: std::sync::OnceLock::new(),
            tasks,
        }))
    }

    /// The registry as last saved.
    pub(super) fn registry(&self) -> Arc<Registry> {
        self.view.get().registry.clone()
    }

    /// T3's shell as last received.
    pub(super) fn shell(&self) -> Arc<Shell> {
        self.view.get().shell.clone()
    }

    /// Changes the registry and saves it before anyone can read the change.
    /// A failed save leaves everything as it was; one whose outcome is
    /// unknown is written again before the next change.
    pub(super) async fn change<T: Send + 'static>(
        &self,
        f: impl FnOnce(&mut Registry) -> T + Send + 'static,
    ) -> Result<T> {
        self.change_if(|registry| Some(f(registry)))
            .await
            .map(|changed| changed.expect("always changed"))
    }

    /// `change` for a closure that may find nothing to change (`None`, and
    /// then it must not have changed anything): nothing is saved.
    pub(super) async fn change_if<T: Send + 'static>(
        &self,
        f: impl FnOnce(&mut Registry) -> Option<T> + Send + 'static,
    ) -> Result<Option<T>> {
        self.owner
            .ask(move |s| s.change_if(|registry, _| f(registry)))
            .await
    }

    pub(super) async fn client(&self) -> Result<Arc<dyn Peer>> {
        if let Some(fake) = self.fake.get() {
            return Ok(fake.clone());
        }
        let view = self.view.get();
        match &view.t3 {
            Some(client) => Ok(client.clone()),
            None => bail!("{}", view.status),
        }
    }

    /// Keeps a live copy of T3's shell and delivers wake-ups. Reconnects with
    /// backoff that doubles while connections keep failing and starts over
    /// after one that stayed up; a missing pairing is reported, not fatal to
    /// the service.
    pub async fn run(self: Arc<Self>) {
        const STABLE: Duration = Duration::from_secs(60);
        let mut delay = 1;
        loop {
            let started = std::time::Instant::now();
            let error = self.clone().session().await.unwrap_err();
            eprintln!("T3: {error:#}");
            let status: Arc<str> = format!("{error:#}").into();
            let synced = self
                .owner
                .ask(move |s| {
                    s.status = status;
                    s.t3 = None;
                    let shell = s.shell_mut();
                    let synced = shell.current();
                    shell.link = Link::Offline {
                        epoch: shell.link.epoch(),
                    };
                    s.publish();
                    synced
                })
                .await;
            if synced && started.elapsed() >= STABLE {
                delay = 1;
            }
            tokio::time::sleep(Duration::from_secs(delay)).await;
            delay = (delay * 2).min(30);
        }
    }

    /// One connection, until it fails or closes.
    pub(super) async fn session(self: Arc<Self>) -> Result<std::convert::Infallible> {
        let config = T3Config::load(&self.root)?;
        let client = T3::connect(config).await?;
        let (_, mut shell) = client.subscribe("orchestration.subscribeShell", json!({}))?;
        let connected = client.clone();
        self.owner
            .ask(move |s| {
                let shell = s.shell_mut();
                shell.link = Link::Syncing {
                    epoch: shell.link.epoch() + 1,
                };
                s.t3 = Some(connected);
                s.status = "Connected".into();
                s.publish();
            })
            .await;
        loop {
            tokio::select! {
                item = shell.recv() => {
                    let Some(item) = item else { break };
                    self.owner.ask(move |s| { s.consume_shell(&item); s.observe_workers(); }).await;
                    if let Some(push) = self.push.get() { push.apps_changed(self.app_views()).await; }
                    self.schedule_flush();
                    self.run_due_resets().await;
                }
                _ = client.closed() => break,
            }
        }
        bail!("T3 connection closed")
    }

    /// Applies one item of T3's shell subscription.
    #[cfg(test)]
    pub(super) async fn consume_shell(&self, item: &Value) {
        let item = item.clone();
        self.owner.ask(move |s| s.consume_shell(&item)).await
    }

    pub(super) fn thread(&self, id: &str) -> Option<Value> {
        self.shell().thread(id)
    }

    /// What T3 says a thread is doing, and how fresh that is. Views may show
    /// a stale observation; tasks, simulators and notifications must not
    /// stop or remove anything on one.
    pub fn observe(&self, id: &str) -> Observed<Option<ThreadObservation>> {
        self.shell().observe(id)
    }

    /// Notifications and Live Activities follow the agents from here on.
    pub fn attach_push(self: &Arc<Self>, push: Arc<crate::push::Push>) {
        push.set_threads(self.clone());
        let _ = self.push.set(push);
    }

    /// Each app's agent and live workers, for notifications.
    pub(super) fn app_views(&self) -> Vec<crate::push::AppView> {
        let View {
            registry, shell, ..
        } = &*self.view.get();
        registry
            .agents
            .values()
            .map(|agent| crate::push::AppView {
                project_id: agent.project_id.clone(),
                app: shell
                    .project(&agent.project_id)
                    .and_then(|p| p["title"].as_str())
                    .unwrap_or("App")
                    .to_string(),
                agent: shell
                    .thread(&agent.thread_id)
                    .map(|row| (agent.thread_id.clone(), row)),
                workers: registry
                    .workers
                    .iter()
                    .filter(|(_, w)| w.stage.live() && w.coordinator == agent.thread_id)
                    .filter_map(|(id, w)| Some((id.clone(), w.title.clone(), shell.thread(id)?)))
                    .collect(),
            })
            .collect()
    }

    /// A thread's row in T3's shell, if T3 has sent it.
    pub fn thread_row(&self, id: &str) -> Option<Value> {
        self.thread(id)
    }

    /// The T3 project a thread belongs to: an app agent's, a worker's, or
    /// any thread T3 has sent.
    pub fn project_of(&self, thread: &str) -> Option<String> {
        let View {
            registry, shell, ..
        } = &*self.view.get();
        if let Some(agent) = registry.agents.values().find(|a| a.thread_id == thread) {
            return Some(agent.project_id.clone());
        }
        if let Some(worker) = registry.workers.get(thread) {
            return Some(worker.project_id.clone());
        }
        shell
            .threads
            .get(thread)
            .and_then(|t| t["projectId"].as_str().map(str::to_string))
    }

    /// An app agent's or worker's thread (not one the user started in T3).
    pub fn is_squircle_thread(&self, id: &str) -> bool {
        let registry = self.registry();
        registry.workers.contains_key(id) || registry.agents.values().any(|a| a.thread_id == id)
    }

    /// A worker's title, even once T3 has archived its thread.
    pub fn worker_title(&self, id: &str) -> Option<String> {
        self.registry().workers.get(id).map(|w| w.title.clone())
    }

    /// The user's latest message to an app agent: where a task it adds now
    /// came from.
    pub async fn source_message(&self, thread: &str) -> Option<Source> {
        self.agent_for_thread(thread)?;
        let client = self.ready().await.ok()?;
        let detail = self.thread_detail(&*client, thread).await.ok()?;
        detail["messages"]
            .as_array()?
            .iter()
            .rev()
            .find(|m| users_own(m) && !m["text"].as_str().unwrap_or("").starts_with('['))
            .and_then(|m| m["id"].as_str().or(m["messageId"].as_str()))
            .map(|id| Source {
                thread_id: thread.into(),
                message_id: id.into(),
            })
    }

    /// The live T3 connection once its thread list has arrived.
    pub async fn connection(&self) -> Result<Arc<T3>> {
        self.ready().await?;
        self.view.get().t3.clone().with_context(|| self.status())
    }

    /// The squircle invocation agents are told to use.
    pub fn cli(&self) -> &str {
        &self.cli
    }

    pub(super) async fn ready(&self) -> Result<Arc<dyn Peer>> {
        let client = self.client().await?;
        self.view_when(Duration::from_secs(5), |v| v.shell.current())
            .await
            .context("T3 has not sent its thread list yet; try again")?;
        Ok(client)
    }

    /// The first view, within `limit`, for which `ready` holds.
    pub(super) async fn view_when(
        &self,
        limit: Duration,
        ready: impl FnMut(&View) -> bool,
    ) -> Option<Arc<View>> {
        tokio::time::timeout(limit, self.view.wait_for(ready))
            .await
            .ok()
            .flatten()
    }
}
