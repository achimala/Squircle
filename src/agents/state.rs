use super::*;

/// What the agents owner publishes: the registry as saved, T3's shell as
/// last received, and the connection. Every reader reads one of these.
#[derive(Clone)]
pub(super) struct View {
    pub(super) registry: Arc<Registry>,
    pub(super) shell: Arc<Shell>,
    pub(super) status: Arc<str>,
    pub(super) t3: Option<Arc<T3>>,
}

/// The agents owner's state, reached only by its letters.
pub(super) struct State {
    /// `agents.json` behind the commit gate: changes are saved before anyone reads them.
    pub(super) gate: RegistryGate,
    pub(super) shell: Arc<Shell>,
    pub(super) status: Arc<str>,
    pub(super) t3: Option<Arc<T3>>,
    /// The registry as last published, and its revision.
    pub(super) published: (Arc<Registry>, Revision),
    pub(super) view: Published<View>,
    pub(super) flush_scheduled: bool,
    pub(super) flush_failures: u32,
    /// Threads in line for a simulator: a worker that ends its turn to wait
    /// wakes nobody; the service wakes it when its simulator is held.
    pub(super) sim_waiting: std::collections::HashSet<String>,
    /// Projects whose reset task is running or waiting to retry; the
    /// attempt count and error belong to the agent's `Lifecycle`.
    pub(super) resets: std::collections::HashSet<String>,
}

impl State {
    pub(super) fn registry(&self) -> &Registry {
        self.gate.committed()
    }

    /// Publishes what readers see: the saved registry (cloned only when a
    /// save changed it), the shell and the connection.
    pub(super) fn publish(&mut self) {
        if self.gate.revision() != self.published.1 {
            self.published = (
                Arc::new(self.gate.committed().clone()),
                self.gate.revision(),
            );
        }
        self.view.set(View {
            registry: self.published.0.clone(),
            shell: self.shell.clone(),
            status: self.status.clone(),
            t3: self.t3.clone(),
        });
    }

    /// Writes a blocked earlier candidate again before anything new is decided.
    pub(super) fn resolve(&mut self) -> Result<()> {
        let resolved = self.gate.resolve();
        self.publish();
        Ok(resolved?)
    }

    /// Saves `next` as the registry; readers see it only once it is saved.
    pub(super) fn commit(&mut self, next: Registry) -> Result<()> {
        let committed = self.gate.commit(next, vec![]);
        self.publish();
        committed?;
        Ok(())
    }

    /// Changes the registry and saves it before anyone can read the change.
    /// A failed save leaves everything as it was; one whose outcome is
    /// unknown is written again before the next change. `f` may find nothing
    /// to change (`None`, and then it must not have changed anything):
    /// nothing is saved.
    pub(super) fn change_if<T>(
        &mut self,
        f: impl FnOnce(&mut Registry, &Shell) -> Option<T>,
    ) -> Result<Option<T>> {
        self.resolve()?;
        let mut next = self.registry().clone();
        let Some(out) = f(&mut next, &self.shell) else {
            return Ok(None);
        };
        self.commit(next)?;
        Ok(Some(out))
    }

    pub(super) fn shell_mut(&mut self) -> &mut Shell {
        Arc::make_mut(&mut self.shell)
    }

    /// Applies one item of T3's (protocol 2) shell subscription. The active
    /// shell holds every thread that is neither archived nor deleted: an
    /// archived thread leaves it (`thread.removed`), so to this service it is
    /// gone. A snapshot that names `resolvedRepositoryIdentityRoots` is only
    /// a refresh of those projects' metadata, with no threads. An item that
    /// isn't what protocol 2 says is refused unapplied: the connection ends
    /// and the shell stays unknown until a new one sends its snapshot.
    pub(super) fn consume_shell(&mut self, item: &Value) -> Result<()> {
        let malformed = || format!("T3 sent a malformed shell item: {}", item["kind"]);
        let shell = self.shell_mut();
        match item["kind"].as_str() {
            Some("snapshot") if item.get("resolvedRepositoryIdentityRoots").is_some() => {
                let projects = keyed(&item["snapshot"]["projects"]).with_context(malformed)?;
                shell.projects.extend(projects);
            }
            Some("snapshot") => {
                let snapshot = &item["snapshot"];
                let (Some(threads), Some(projects), Some(sequence)) = (
                    keyed(&snapshot["threads"]).filter(|t| t.values().all(|t| shell_row(t))),
                    keyed(&snapshot["projects"]),
                    snapshot["snapshotSequence"].as_u64(),
                ) else {
                    bail!(malformed());
                };
                shell.threads = threads;
                shell.projects = projects;
                shell.sequence = sequence;
                shell.link = Link::Current {
                    epoch: shell.link.epoch(),
                };
            }
            Some(
                kind
                @ ("thread.updated" | "thread.removed" | "project.updated" | "project.removed"),
            ) => {
                let sequence = item["sequence"].as_u64().with_context(malformed)?;
                match kind {
                    "thread.updated" => {
                        let thread = &item["thread"];
                        let id = thread["id"]
                            .as_str()
                            .filter(|_| shell_row(thread))
                            .with_context(malformed)?;
                        if item["location"] == "archive" {
                            shell.threads.remove(id);
                        } else {
                            shell
                                .threads
                                .insert(id.to_string(), Arc::new(thread.clone()));
                        }
                    }
                    "thread.removed" => {
                        let id = item["threadId"].as_str().with_context(malformed)?;
                        if item["location"] != "archive" {
                            shell.threads.remove(id);
                        }
                    }
                    "project.updated" => {
                        let project = &item["project"];
                        let id = project["id"].as_str().with_context(malformed)?;
                        shell
                            .projects
                            .insert(id.to_string(), Arc::new(project.clone()));
                    }
                    _ => {
                        let id = item["projectId"].as_str().with_context(malformed)?;
                        shell.projects.remove(id);
                    }
                }
                shell.sequence = shell.sequence.max(sequence);
            }
            _ => {}
        }
        let sequence = shell.sequence;
        shell.created.retain(|_, at| *at > sequence);
        self.publish();
        Ok(())
    }

    /// Follows workers in T3's shell: a reserved worker whose thread has
    /// appeared is running (T3 accepted its bootstrap), and one that waited
    /// on a question and is working again has had it answered.
    pub(super) fn observe_workers(&mut self) {
        let changes =
            |registry: &Registry, shell: &Shell| -> (Vec<String>, Vec<(String, WorkerEvent)>) {
                let adopted = registry
                    .workers
                    .iter()
                    .filter(|(id, w)| {
                        matches!(w.stage, Stage::Bootstrapping { .. })
                            && shell.threads.contains_key(*id)
                    })
                    .map(|(id, _)| id.clone())
                    .collect();
                let progressed = registry
                    .workers
                    .iter()
                    .filter(|(_, w)| w.stage.live())
                    .filter_map(|(id, w)| {
                        let event = ThreadObservation::decode(shell.threads.get(id)?)
                            .progressed(w.notified.as_ref())?;
                        Some((id.clone(), event))
                    })
                    .collect();
                (adopted, progressed)
            };
        // Most shell events change nothing here; only then is a change made.
        let (a, p) = changes(self.registry(), &self.shell);
        if a.is_empty() && p.is_empty() {
            return;
        }
        let saved = self.change_if(|registry, shell| {
            let (adopted, progressed) = changes(registry, shell);
            if adopted.is_empty() && progressed.is_empty() {
                return None;
            }
            let shown = core::Observed::Current {
                epoch: Epoch::default(),
                revision: Revision::default(),
                value: true,
            };
            for id in adopted {
                if let Some(worker) = registry.workers.get_mut(&id) {
                    worker.stage = m15::bootstrap(
                        worker.stage.clone(),
                        BootEvent::Look {
                            thread: shown.clone(),
                        },
                    )
                    .state;
                }
            }
            for (id, event) in progressed {
                if let Some(worker) = registry.workers.get_mut(&id) {
                    worker.notified = Some(event);
                }
            }
            Some(())
        });
        if let Err(error) = saved {
            eprintln!("Worker state not saved: {error:#}");
        }
    }

    /// Workers whose state calls for a wake-up their coordinator has not had
    /// and that is not already queued. Only from a current shell.
    pub(super) fn due_wakes(&self) -> Vec<(String, Worker, WorkerEvent)> {
        let (registry, shell) = (self.registry(), &self.shell);
        if !shell.current() {
            return vec![];
        }
        registry
            .workers
            .iter()
            .filter(|(_, w)| w.stage.live())
            .filter_map(|(id, worker)| {
                let event = ThreadObservation::decode(shell.threads.get(id)?).wake()?;
                if event.kind == EventKind::Done && self.sim_waiting.contains(id) {
                    return None;
                }
                // A worker's own question or approval waits on the user's
                // phone with everything else; the user answers it there, and
                // the app agent hears once they have (no proxying).
                if event.kind == EventKind::NeedsYou {
                    return None;
                }
                let queued = registry
                    .outbox
                    .iter()
                    .any(|w| w.workers.iter().any(|(queued, _)| queued == id));
                (!queued && !worker.notified.as_ref().is_some_and(|n| n.covers(&event)))
                    .then(|| (id.clone(), worker.clone(), event))
            })
            .collect()
    }

    pub(super) fn has_due_wakes(&self) -> bool {
        !self.registry().outbox.is_empty() || !self.due_wakes().is_empty()
    }

    /// Reduces `event` for the queued update `id` and saves what it decided:
    /// its new delivery state, or its removal together with what settling it
    /// implies. Returns the update as decided and the effects to run next;
    /// `None` if it is no longer queued.
    pub(super) fn reduce_wake(
        &mut self,
        id: &str,
        event: outbox::Event,
    ) -> Result<Option<(Wake, Vec<outbox::Effect>)>> {
        self.resolve()?;
        let Some(index) = self
            .registry()
            .outbox
            .iter()
            .position(|w| w.message_id == id)
        else {
            return Ok(None);
        };
        let wake = self.registry().outbox[index].clone();
        let reduction = outbox::reduce(wake.outbound.clone(), event);
        if let Disposition::ProtocolFault(fault) = &reduction.disposition {
            debug_assert!(false, "{fault}");
            eprintln!("Outbox fault for {id}: {fault}");
        }
        #[cfg(debug_assertions)]
        for violation in outbox::violations(&reduction.state) {
            eprintln!("Outbox invariant broken for {id}: {}", violation.0);
        }
        let settled = reduction.effects.iter().find_map(|e| match e {
            outbox::Effect::Settle(s) => Some(s.clone()),
            _ => None,
        });
        if settled.is_some() || reduction.effects.contains(&outbox::Effect::Commit) {
            let mut next = self.registry().clone();
            match &settled {
                None => next.outbox[index].outbound = reduction.state.clone(),
                Some(settled) => {
                    next.outbox.remove(index);
                    // Delivered, or nobody left to tell: either way that event is settled.
                    for (worker, told) in &wake.workers {
                        if let Some(worker) = next.workers.get_mut(worker) {
                            worker.notified = Some(told.clone());
                        }
                    }
                    if let Settled::Undelivered(reason) = settled {
                        next.undelivered.push(Undelivered {
                            message_id: wake.message_id.clone(),
                            coordinator: wake.coordinator.clone(),
                            reason: (*reason).into(),
                            at: crate::model::now(),
                        });
                        let excess = next.undelivered.len().saturating_sub(UNDELIVERED_KEPT);
                        next.undelivered.drain(..excess);
                    }
                }
            }
            self.commit(next)?;
        }
        Ok(Some((
            Wake {
                outbound: reduction.state,
                ..wake
            },
            reduction.effects,
        )))
    }

    /// Reduces `event` for the app's agent (M14) and saves what it decided
    /// before any effect it asks for runs.
    pub(super) fn reduce_agent(
        &mut self,
        project: &str,
        event: m14::Event,
    ) -> Result<Vec<m14::Effect>> {
        self.resolve()?;
        let agent = self
            .registry()
            .agents
            .get(project)
            .cloned()
            .context("The app has no agent")?;
        let reduction = m14::reduce(agent.lifecycle, event);
        if let Disposition::ProtocolFault(fault) = &reduction.disposition {
            debug_assert!(false, "{fault}");
            eprintln!("Agent lifecycle fault for {project}: {fault}");
        }
        #[cfg(debug_assertions)]
        for violation in m14::violations(&reduction.state) {
            eprintln!(
                "Agent lifecycle invariant broken for {project}: {}",
                violation.0
            );
        }
        if reduction.effects.contains(&m14::Effect::Commit) {
            let mut next = self.registry().clone();
            if let Some(agent) = next.agents.get_mut(project) {
                agent.lifecycle = reduction.state;
            }
            self.commit(next)?;
        }
        Ok(reduction.effects)
    }

    /// Reduces `event` for the app's upkeep record and saves the result
    /// before the compaction it may call for is sent.
    pub(super) fn reduce_upkeep(
        &mut self,
        project: &str,
        event: m26::Event,
    ) -> Result<Vec<m26::Effect>> {
        self.resolve()?;
        let reduction = m26::reduce(self.registry().upkeep.get(project).cloned(), event);
        if let Disposition::ProtocolFault(fault) = &reduction.disposition {
            debug_assert!(false, "{fault}");
            eprintln!("Upkeep fault for {project}: {fault}");
        }
        if !reduction.effects.contains(&m26::Effect::Commit) {
            return Ok(reduction.effects);
        }
        let mut next = self.registry().clone();
        match reduction.state {
            Some(record) => next.upkeep.insert(project.into(), record),
            None => next.upkeep.remove(project),
        };
        self.commit(next)?;
        Ok(reduction.effects)
    }

    pub(super) fn reduce_boot(&mut self, id: &str, event: BootEvent) -> Result<Vec<BootEffect>> {
        self.resolve()?;
        let Some(worker) = self.registry().workers.get(id) else {
            return Ok(vec![BootEffect::Done]);
        };
        let reduction = m15::bootstrap(worker.stage.clone(), event);
        if reduction.effects.contains(&BootEffect::Commit) {
            let mut next = self.registry().clone();
            if let Some(worker) = next.workers.get_mut(id) {
                worker.stage = reduction.state;
            }
            self.commit(next)?;
        }
        Ok(reduction.effects)
    }

    /// Reduces `event` for a worker's archive and, for a registered worker,
    /// saves the new stage before any effect it asks for runs. Returns the
    /// stage it decided and the effects.
    pub(super) fn reduce_archive(
        &mut self,
        id: &str,
        registered: bool,
        stage: Stage,
        event: m15::ArchiveEvent,
    ) -> Result<(Stage, Vec<m15::ArchiveEffect>)> {
        let mut stage = stage;
        if registered {
            self.resolve()?;
            stage = self
                .registry()
                .workers
                .get(id)
                .context("The worker is gone from the registry")?
                .stage
                .clone();
        }
        let reduction = m15::archive(stage, event);
        if let Disposition::ProtocolFault(fault) = &reduction.disposition {
            debug_assert!(false, "{fault}");
            eprintln!("Archive fault for {id}: {fault}");
        }
        if registered && reduction.effects.contains(&m15::ArchiveEffect::Commit) {
            let mut next = self.registry().clone();
            if let Some(worker) = next.workers.get_mut(id) {
                worker.stage = reduction.state.clone();
            }
            self.commit(next)?;
        }
        Ok((reduction.state, reduction.effects))
    }

    /// The command for `purpose` a caller waits for: the one saved for it
    /// while T3 left it unanswered, or a new one, saved before it is sent.
    pub(super) fn intent(
        &mut self,
        purpose: String,
        build: impl FnOnce(&Identity) -> Command,
    ) -> Result<Command> {
        self.resolve()?;
        if let Some(pending) = self
            .registry()
            .intents
            .iter()
            .find(|p| p.purpose == purpose)
        {
            return Ok(pending.command.clone());
        }
        let command = build(&identity());
        let mut next = self.registry().clone();
        next.intents.push(Pending {
            purpose,
            command: command.clone(),
            at: crate::model::now(),
        });
        let excess = next.intents.len().saturating_sub(INTENTS_KEPT);
        next.intents.drain(..excess);
        self.commit(next)?;
        Ok(command)
    }
}

/// A list of shell rows by ID; `None` unless every one has a string ID.
fn keyed(list: &Value) -> Option<HashMap<String, Arc<Value>>> {
    list.as_array()?
        .iter()
        .map(|v| Some((v["id"].as_str()?.to_string(), Arc::new(v.clone()))))
        .collect()
}

/// Whether a thread row says what its run is doing: a row without its
/// status would read as stopped.
fn shell_row(row: &Value) -> bool {
    row["id"].is_string() && row["status"].is_string()
}
