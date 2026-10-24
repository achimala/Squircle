use super::*;

impl Agents {
    // MARK: Workers

    pub fn workers(&self, coordinator: Option<&str>) -> Vec<Value> {
        let View {
            registry, shell, ..
        } = &*self.view.get();
        registry.workers.iter()
            .filter(|(_, w)| w.stage != Stage::Archived && coordinator.is_none_or(|c| w.coordinator == c))
            .map(|(id, w)| {
                let thread = shell.threads.get(id);
                let state = match (&w.stage, thread) {
                    (Stage::FilesRemoved | Stage::Archiving(_), _) => "archiving",
                    (_, Some(row)) => worker_state(row),
                    (Stage::Bootstrapping { .. }, None) => "starting",
                    (_, None) => "missing",
                };
                json!({
                    "id": id, "title": w.title, "branch": w.branch, "base": w.base, "coordinator": w.coordinator,
                    "project_id": w.project_id, "created_at": w.created_at,
                    "state": state,
                    "worktree": thread.and_then(|t| t["worktreePath"].as_str()),
                })
            }).collect()
    }

    /// Every worker Squircle started, archived ones too, so a conversation
    /// can name the workers its agent talked to.
    pub fn all_workers(&self) -> Vec<Value> {
        let View {
            registry, shell, ..
        } = &*self.view.get();
        registry
            .workers
            .iter()
            .map(|(id, w)| {
                let state = if w.stage == Stage::Archived {
                    "archived"
                } else {
                    shell.threads.get(id).map_or("missing", |t| worker_state(t))
                };
                json!({"id": id, "title": w.title, "branch": w.branch, "state": state})
            })
            .collect()
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn spawn(
        &self,
        coordinator: &str,
        title: &str,
        branch: &str,
        base: Option<&str>,
        prompt: &str,
        provider: Option<&str>,
        model: Option<&str>,
        effort: Option<&str>,
        runtime_mode: Option<&str>,
    ) -> Result<Value> {
        let client = self.ready().await?;
        let agent = self
            .agent_for_thread(coordinator)
            .with_context(|| format!("{coordinator} is not an app agent's thread"))?;
        ensure!(
            !title.trim().is_empty() && !prompt.trim().is_empty(),
            "A worker needs a title and a prompt"
        );
        ensure!(
            !branch.is_empty() && !branch.contains(char::is_whitespace) && !branch.contains(".."),
            "Invalid branch name"
        );
        // The same worker asked for again (after T3 left the first request
        // unconfirmed) is finished, not started twice.
        self.spawning.run(format!("spawn {coordinator} {branch}"), async {
            let existing = self.registry().workers.iter()
                .find(|(_, w)| w.coordinator == coordinator && w.branch == branch && w.stage.live())
                .map(|(id, w)| (id.clone(), w.clone()));
            if let Some((id, worker)) = existing {
                self.ops.run(id.clone(), self.bootstrap(&*client, &id, true)).await?;
                return Ok(json!({"id": id, "title": worker.title, "branch": worker.branch, "base": worker.base, "existing": true,
                                 "next": "A worker on this branch already exists and is running; this did not start another. End your turn; a [worker update] arrives when it finishes."}));
            }
            let project = self.shell().project(&agent.project_id).cloned().context("The app's T3 project is gone")?;
            let coordinator_thread = self.thread(coordinator).context("The app agent's thread is gone")?;
            let config = client.call("server.getConfig", json!({})).await?;
            let selection = worker_selection(&config, provider, model, effort,
                                             coordinator_thread["modelSelection"]["model"].as_str())?;
            let (instance, model) = (selection["instanceId"].clone(), selection["model"].clone());
            let driver = config["providers"].as_array().into_iter().flatten()
                .find(|p| p["instanceId"] == instance).and_then(|p| p["driver"].as_str()).unwrap_or(instance.as_str().unwrap_or_default());
            let (mode, permissions) = worker_mode(driver, coordinator_thread["runtimeMode"].as_str(), runtime_mode)?;
            let checkout = PathBuf::from(project["workspaceRoot"].as_str().context("The project has no folder")?);
            let current = git(&checkout, &["symbolic-ref", "--short", "HEAD"]).await.unwrap_or_else(|_| "HEAD".into());
            let base = base.unwrap_or(&current);
            let id = uuid::Uuid::new_v4().to_string();
            let text = format!(
                "{prompt}\n\n---\nYou are a worker for this app's agent, on branch {branch} in your own worktree. When done, commit on this branch and reply with a short summary. Remove anything else you create (scratch simulators, temp services or files) before you finish. \
                 If the user asks you for something directly, put it in the tracker before working on it ({cli} task --help): a sub-task of the work item it belongs to, otherwise a new work item. \
                 To run, check or demo the app in a simulator, first run {cli} sim start --thread {id} (see sim --help): Squircle records it, the user watches it live, and the recording appears in your turn. Then call T3's device_open with the deviceId it returns and drive it with the agent-device command that gives; run {cli} sim stop --thread {id} when done (it shuts the simulator down). If it says you're queued, end your turn: a [simulator ready] message wakes you when one is held for you; run sim start again then. Use sim start for every simulator: don't boot or create simulators with simctl or xcodebuild, and don't run agent-device record or device_open on any other simulator. \
                 For signed builds: {cli} build start --thread {id} ... (see build start --help); the user gets it in their chat when it finishes. \
                 A performance recording the user sends from the phone is a linked .perf.json: {cli} perf show PATH summarizes it (hitches with symbolicated main-thread stacks, timeline). \
                 The user also reads your replies on their phone: keep them short and plain, show pictures as ![..](/absolute/path) and clips as [..](/absolute/path) \
                 (copied out of /tmp into ~/.t3/userdata/attachments), and don't present bare paths or IDs as information.",
                cli = self.cli
            );
            let message_id = uuid::Uuid::new_v4().to_string();
            let message = Note::Task.message(&message_id, &text, json!({"from": coordinator}));
            // T3 creates the thread, its worktree (running the project's
            // setup) and its first run in one launch.
            let command = json!({
                "type": crate::fsm::coordinator::LAUNCH, "threadId": id,
                "projectId": agent.project_id, "title": title, "creationSource": "server",
                "modelSelection": selection, "runtimeMode": mode, "interactionMode": "default",
                "workspaceStrategy": {"type": "worktree", "baseRef": base, "branch": branch},
                "initialMessage": {"messageId": message_id, "text": message["text"],
                                   "attachments": [], "context": message["context"]},
            });
            // Reserved before T3 is asked, so wake-ups follow it from its first
            // turn and a lost acknowledgement or a restart finishes this worker.
            let worker = Worker {
                coordinator: coordinator.into(), project_id: agent.project_id.clone(), title: title.into(),
                branch: branch.into(), base: base.into(), created_at: crate::model::now(), notified: None,
                stage: Stage::Bootstrapping { message_id, command },
            };
            self.ops.run(id.clone(), async {
                let reserved = id.clone();
                self.change(move |registry| registry.workers.insert(reserved, worker)).await?;
                self.bootstrap(&*client, &id, false).await
            }).await?;
            Ok(json!({"id": id, "title": title, "branch": branch, "base": base, "provider": instance, "model": model, "effort": effort,
                      "runtime_mode": mode, "permissions": permissions,
                      "next": "The worker is running. End your turn; a [worker update] arrives when it finishes."}))
        }).await
    }

    /// Sends a reserved worker's bootstrap (M15) and confirms it: an
    /// acknowledgement, the thread in the shell or its first message counts.
    /// `again`: spawn was asked again for it, so T3's shell is looked at
    /// first and the bootstrap is sent again (with the same thread and
    /// message IDs) only if T3 doesn't show it. T3 keeps a rejected receipt
    /// per command ID and a launch fails part way (its thread made, its
    /// workspace not), so each attempt is its own command. Call in the
    /// worker's operation lane.
    pub(super) async fn bootstrap(&self, client: &dyn Peer, id: &str, again: bool) -> Result<()> {
        let mut effects = match again {
            true => {
                self.reduce_boot(
                    id,
                    BootEvent::Look {
                        thread: self.seen(id, |o| o.is_some()),
                    },
                )
                .await?
            }
            false => vec![BootEffect::Send],
        };
        loop {
            let Some(Stage::Bootstrapping {
                message_id,
                command,
            }) = self.registry().workers.get(id).map(|w| w.stage.clone())
            else {
                return Ok(());
            };
            let mut next = None;
            for effect in effects {
                match effect {
                    BootEffect::Commit => {}
                    BootEffect::Send => {
                        next = Some(BootEvent::Sent(
                            client
                                .dispatch(&Command::new(&identity(), command.clone()))
                                .await,
                        ))
                    }
                    BootEffect::Confirm(detail) => {
                        let found = match self.thread(id) {
                            Some(_) => Ok(true),
                            None => self
                                .has_message(client, id, &message_id)
                                .await
                                .map_err(|e| format!("{e:#}")),
                        };
                        next = Some(BootEvent::Confirmed { found, detail });
                    }
                    BootEffect::Done => return Ok(()),
                    BootEffect::Failed(detail) => bail!(detail),
                }
            }
            effects = self
                .reduce_boot(
                    id,
                    next.context("The worker's bootstrap stopped without an answer")?,
                )
                .await?;
        }
    }

    pub(super) async fn reduce_boot(&self, id: &str, event: BootEvent) -> Result<Vec<BootEffect>> {
        let id = id.to_string();
        self.owner.ask(move |s| s.reduce_boot(&id, event)).await
    }

    /// A thread from the live shell; one just created arrives with T3's
    /// next shell event.
    pub(super) async fn wait_thread(&self, id: &str) -> Result<Value> {
        let view = self.view_when(|v| v.shell.threads.contains_key(id)).await;
        view.and_then(|v| v.shell.thread(id))
            .with_context(|| format!("T3 has no thread {id}"))
    }

    /// Archives a worker (M15): stops its session (one whose turn may still
    /// be running only with `discard`), removes its worktree and deletes its
    /// branch, then archives its thread. Refuses while the branch has commits
    /// not in its base or the worktree has uncommitted changes, unless
    /// `discard` drops them. Nothing is removed until T3 reports the session
    /// stopped. Each step is saved before it acts, so after a failure or a
    /// crash running it again resumes where it stood.
    pub async fn archive(&self, id: &str, discard: bool) -> Result<Value> {
        let client = self.ready().await?;
        self.ops
            .run(id.to_string(), self.archive_in_lane(&*client, id, discard))
            .await
    }

    pub(super) async fn archive_in_lane(
        &self,
        client: &dyn Peer,
        id: &str,
        discard: bool,
    ) -> Result<Value> {
        let is_agent = self.registry().agents.values().any(|a| a.thread_id == id);
        ensure!(!is_agent, "That is an app agent's thread, not a worker");
        let worker = self.registry().workers.get(id).cloned();
        let observed = self
            .observe(id)
            .current()
            .context("T3's thread list is not current; try again")?;
        ensure!(
            observed.is_some() || worker.is_some(),
            "T3 has no thread {id}"
        );
        let title = worker.as_ref().map(|w| w.title.clone()).or_else(|| {
            self.thread(id)
                .and_then(|r| r["title"].as_str().map(str::to_string))
        });
        // A thread Squircle didn't start goes through the same steps, unsaved.
        let mut stage = worker.as_ref().map_or(Stage::Active, |w| w.stage.clone());
        let mut result = json!({"archived": id, "stopped": false, "title": title});
        let mut inspected = None;
        let look = || m15::ArchiveEvent::Look {
            thread: self.seen(id, |o| o),
            discard,
            next: identity(),
        };
        let mut event = look();
        loop {
            let mut next = None;
            let (archiving, registered) = (id.to_string(), worker.is_some());
            let (decided, effects) = self
                .owner
                .ask(move |s| s.reduce_archive(&archiving, registered, stage, event))
                .await?;
            stage = decided;
            for effect in effects {
                match effect {
                    m15::ArchiveEffect::Commit => {}
                    m15::ArchiveEffect::Send(order, identity) => {
                        let outcome = match order {
                            ArchiveOrder::Stop => self.stop(client, id, &identity).await,
                            ArchiveOrder::Archive => {
                                client
                                    .dispatch(&Command::new(
                                        &identity,
                                        json!({"type": "thread.archive", "threadId": id}),
                                    ))
                                    .await
                            }
                        };
                        if order == ArchiveOrder::Stop && matches!(outcome, Dispatched::Accepted(_))
                        {
                            result["stopped"] = json!(true);
                        }
                        next = Some(m15::ArchiveEvent::Sent {
                            outcome,
                            next: self::identity(),
                        });
                    }
                    m15::ArchiveEffect::AwaitStopped => {
                        next = Some(m15::ArchiveEvent::Stopped(
                            self.wait_stopped(id).await.is_ok(),
                        ))
                    }
                    m15::ArchiveEffect::Inspect => {
                        let found = self.inspect_worker(id, worker.as_ref()).await;
                        let blocker = found
                            .as_ref()
                            .map(|f| f.as_ref().and_then(|(_, state)| state.blocker()))
                            .map_err(|e| format!("{e:#}"));
                        inspected = found.ok().flatten();
                        next = Some(m15::ArchiveEvent::Inspected { blocker, discard });
                    }
                    m15::ArchiveEffect::Remove => {
                        // Stopped right now, not just when it was inspected.
                        let removed = match (&inspected, self.stopped(id)) {
                            (_, None) => {
                                Err("Its session is live again, so nothing more was removed"
                                    .to_string())
                            }
                            (None, Some(_)) => Ok(()),
                            (Some((root, state)), Some(receipt)) => {
                                match remove(root, state, discard, &receipt).await {
                                    Ok(cleaned) => {
                                        result["removed_worktree"] = json!(cleaned.worktree);
                                        result["deleted_branch"] = json!(cleaned.branch);
                                        result["discarded"] =
                                            json!(discard && state.blocker().is_some());
                                        Ok(())
                                    }
                                    Err(error) => Err(format!("{error:#}")),
                                }
                            }
                        };
                        next = Some(m15::ArchiveEvent::Removed(removed));
                    }
                    m15::ArchiveEffect::Look => next = Some(look()),
                    m15::ArchiveEffect::Refused(why) | m15::ArchiveEffect::Failed(why) => {
                        bail!(why)
                    }
                    m15::ArchiveEffect::Done => return Ok(result),
                    m15::ArchiveEffect::NeverStarted => {
                        return Ok(
                            json!({"archived": id, "stopped": false, "title": title, "never_started": true}),
                        );
                    }
                }
            }
            event = next.context("The archive stopped without an answer")?;
        }
    }

    /// The worker's checkout and its Git state, if its project has a folder.
    pub(super) async fn inspect_worker(
        &self,
        id: &str,
        worker: Option<&Worker>,
    ) -> Result<Option<(PathBuf, GitState)>> {
        let row = self.thread(id).unwrap_or(Value::Null);
        let branch = worker
            .map(|w| w.branch.clone())
            .or_else(|| row["branch"].as_str().map(str::to_string));
        let project = worker
            .map(|w| w.project_id.clone())
            .or_else(|| row["projectId"].as_str().map(str::to_string));
        let root = project.and_then(|p| {
            self.shell()
                .project(&p)
                .and_then(|p| p["workspaceRoot"].as_str().map(PathBuf::from))
        });
        let Some(root) = root else { return Ok(None) };
        let base = match worker {
            Some(worker) => worker.base.clone(),
            None => git(&root, &["symbolic-ref", "--short", "HEAD"]).await?,
        };
        let worktree = row["worktreePath"].as_str().map(PathBuf::from);
        let state = inspect(&root, worktree.as_deref(), branch.as_deref(), Some(&base)).await?;
        Ok(Some((root, state)))
    }

    /// A receipt if the live shell shows the thread's session stopped, or
    /// no such thread.
    pub(super) fn stopped(&self, id: &str) -> Option<StopReceipt> {
        stopped_in(&self.shell(), id)
    }

    /// Waits for T3 to report a stopped worker's session stopped. A thread
    /// still waiting on the user, or a disconnected shell, does not count:
    /// a connection that goes down first ends the wait.
    pub(super) async fn wait_stopped(&self, id: &str) -> Result<StopReceipt> {
        let view = self.view_when(|v| stopped_in(&v.shell, id).is_some()).await;
        view.and_then(|v| stopped_in(&v.shell, id))
            .context("T3 disconnected before the worker stopped; nothing was removed")
    }

    /// Archives the coordinator's finished workers whose work is merged,
    /// deletes merged branches of workers archived earlier, prunes stale
    /// worktree entries, and reports what it leaves and why.
    pub async fn cleanup(&self, coordinator: &str, dry_run: bool) -> Result<Value> {
        self.ready().await?;
        let agent = self
            .agent_for_thread(coordinator)
            .with_context(|| format!("{coordinator} is not an app agent's thread"))?;
        let root = self
            .shell()
            .project(&agent.project_id)
            .and_then(|p| p["workspaceRoot"].as_str().map(PathBuf::from))
            .context("The app's T3 project is gone")?;
        let workers: Vec<(String, Worker)> = self
            .registry()
            .workers
            .iter()
            .filter(|(_, w)| w.coordinator == coordinator)
            .map(|(id, w)| (id.clone(), w.clone()))
            .collect();
        let (mut archived, mut deleted, mut left) = (vec![], vec![], vec![]);
        for (id, worker) in workers {
            let row = self.thread(&id);
            let observed = self
                .observe(&id)
                .current()
                .context("T3's thread list is not current; try again")?;
            let worktree = row
                .as_ref()
                .and_then(|t| t["worktreePath"].as_str().map(PathBuf::from));
            let entry = json!({"id": id, "title": worker.title, "branch": worker.branch});
            let reason = match (&worker.stage, &observed) {
                (Stage::Bootstrapping { .. }, _) => Some("still starting".to_string()),
                (Stage::Active, Some(now))
                    if matches!(now.phase(), Phase::Working | Phase::NeedsYou) =>
                {
                    Some(format!("still {}", now.phase().label()))
                }
                (Stage::Archived, Some(now)) if now.execution != Execution::Stopped => {
                    Some("its session is still live".into())
                }
                _ => None,
            };
            if let Some(reason) = reason {
                left.push(json!({"worker": entry, "reason": reason}));
                continue;
            }
            if matches!(worker.stage, Stage::FilesRemoved | Stage::Archiving(_)) {
                if !dry_run {
                    self.archive(&id, false).await?;
                }
                archived.push(entry);
                continue;
            }
            let git = inspect(
                &root,
                worktree.as_deref(),
                Some(&worker.branch),
                Some(&worker.base),
            )
            .await?;
            if let Some(reason) = git.blocker() {
                left.push(json!({"worker": entry, "reason": reason}));
                continue;
            }
            if worker.stage == Stage::Archived {
                if git.branch_exists || git.worktree.is_some() {
                    if !dry_run {
                        self.ops
                            .run(id.clone(), async {
                                let receipt = self
                                    .stopped(&id)
                                    .context("Its session is still live; nothing was removed")?;
                                remove(&root, &git, false, &receipt).await
                            })
                            .await?;
                    }
                    deleted.push(entry);
                }
            } else {
                if !dry_run {
                    self.archive(&id, false).await?;
                }
                archived.push(entry);
            }
        }
        let pruned = git(&root, &["worktree", "prune", "--dry-run", "-v"]).await?;
        if !dry_run {
            git(&root, &["worktree", "prune"]).await?;
        }
        Ok(json!({
            "dry_run": dry_run, "archived": archived, "branches_deleted": deleted,
            "stale_worktrees_pruned": pruned.lines().filter(|l| !l.is_empty()).collect::<Vec<_>>(),
            "left": left,
        }))
    }
}
