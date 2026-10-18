use super::*;

impl Agents {
    // MARK: Builds

    /// The app agent a build belongs to: the agent that started it, the
    /// coordinator of the worker that did, or the agent of the app whose
    /// task links it.
    pub fn build_owner(&self, thread: Option<&str>, build: &str) -> Option<Agent> {
        let tasks = self.tasks.all();
        owner(&self.registry(), &tasks, thread, build).cloned()
    }

    /// Each build's app agent thread, for the phone, in order.
    pub fn build_owners<'a>(
        &self,
        builds: impl IntoIterator<Item = (Option<&'a str>, &'a str)>,
    ) -> Vec<Option<String>> {
        let tasks = self.tasks.all();
        let registry = self.registry();
        builds
            .into_iter()
            .map(|(thread, build)| {
                owner(&registry, &tasks, thread, build).map(|a| a.thread_id.clone())
            })
            .collect()
    }

    /// The live worker whose worktree holds `path`, for a build started
    /// there without naming its thread.
    pub fn worker_at(&self, path: &Path) -> Option<String> {
        let View {
            registry, shell, ..
        } = &*self.view.get();
        registry
            .workers
            .iter()
            .filter(|(_, w)| w.stage.live())
            .find(|(id, _)| {
                shell
                    .threads
                    .get(*id)
                    .and_then(|t| t["worktreePath"].as_str())
                    .is_some_and(|tree| path.starts_with(tree))
            })
            .map(|(id, _)| id.clone())
    }

    /// Remembers the turn an app agent started a build in.
    pub async fn build_started(&self, build: &str, thread: Option<&str>) -> Result<()> {
        let (build, thread) = (build.to_string(), thread.map(str::to_string));
        self.owner
            .ask(move |s| {
                s.change_if(|registry, shell| {
                    let thread =
                        thread.filter(|t| registry.agents.values().any(|a| a.thread_id == *t))?;
                    let turn = shell
                        .threads
                        .get(&thread)
                        .map(|t| ThreadObservation::decode(t))
                        .filter(ThreadObservation::busy)
                        .and_then(|o| o.turn);
                    let now = crate::model::now();
                    registry
                        .builds
                        .retain(|_, w| now.saturating_sub(w.at()) < BUILD_WATCH_SECS);
                    registry
                        .builds
                        .insert(build, BuildWatch::Started { turn, at: now });
                    Some(())
                })
            })
            .await
            .map(drop)
    }

    /// A failed build queues one update to its app agent, which wakes it to
    /// act and shows the failure in its conversation. A build that succeeded
    /// wakes nobody: the app shows its card where it finished, and a reply
    /// to it would only repeat the card.
    pub async fn build_finished(self: &Arc<Self>, build: &FinishedBuild) -> Result<()> {
        let tasks = self.tasks.all();
        let build = FinishedBuild {
            id: build.id.clone(),
            thread: build.thread.clone(),
            app: build.app.clone(),
            succeeded: build.succeeded,
            reason: build.reason.clone(),
        };
        let queued = self.owner.ask(move |s| s.change_if(|registry, shell| {
            let agent = owner(registry, &tasks, build.thread.as_deref(), &build.id).cloned()?;
            let now = crate::model::now();
            match registry.builds.get(&build.id) {
                Some(BuildWatch::Told { .. }) => return None,
                Some(BuildWatch::Started { turn: Some(turn), .. }) if build.thread.as_deref() == Some(agent.thread_id.as_str()) => {
                    let same = shell.threads.get(&agent.thread_id).map(|t| ThreadObservation::decode(t))
                        .is_some_and(|o| o.busy() && o.turn.as_ref() == Some(turn));
                    if same {
                        registry.builds.insert(build.id.clone(), BuildWatch::Told { at: now });
                        return Some(false);
                    }
                }
                _ => {}
            }
            registry.builds.retain(|_, w| now.saturating_sub(w.at()) < BUILD_WATCH_SECS);
            registry.builds.insert(build.id.clone(), BuildWatch::Told { at: now });
            if build.succeeded {
                return Some(false);
            }
            let reason = build.reason.as_ref().map(|r| format!(": {r}")).unwrap_or_default();
            registry.outbox.push(Wake {
                coordinator: agent.thread_id.clone(),
                message_id: uuid::Uuid::new_v4().to_string(),
                workers: vec![],
                text: format!("[build update]\n- The {} build ({}) failed{reason}.\nThe user sees the failure in this chat. \
                               If it is yours to fix, fix it (`squircle build log ID` has the details); \
                               otherwise end your turn without a reply.", build.app, build.id),
                record: Note::BuildUpdate.record(json!({
                    "build": build.id, "app": build.app, "state": "failed", "reason": build.reason, "thread": build.thread
                })),
                outbound: Outbound::default(),
                build: Some(build.id.clone()),
            });
            Some(true)
        })).await?;
        if queued == Some(true) {
            self.schedule_flush();
        }
        Ok(())
    }
}
