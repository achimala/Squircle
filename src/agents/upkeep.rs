use super::*;

impl Agents {
    // MARK: Upkeep

    /// Every five minutes, compacts or starts fresh the idle agents whose
    /// context grew large (`crate::upkeep`). Never touches a running turn.
    pub async fn upkeep(self: Arc<Self>) {
        let config = match crate::upkeep::Upkeep::from_env() {
            Ok(config) => config,
            Err(error) => return eprintln!("Agent upkeep is off: {error:#}"),
        };
        let mut tick = tokio::time::interval(Duration::from_secs(300));
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tick.tick().await;
            for agent in self.list() {
                if let Err(error) = self.upkeep_agent(&config, &agent).await {
                    eprintln!("Agent upkeep of {}: {error:#}", agent.project_id);
                }
            }
        }
    }

    /// Why upkeep leaves an agent alone right now, if it does: only what T3
    /// shows now counts, with no turn that may be running and no worker working.
    pub(super) fn upkeep_blocker(&self, agent: &Agent) -> Option<&'static str> {
        if !matches!(agent.lifecycle, Lifecycle::Ready { .. }) {
            return Some("being created or reset");
        }
        if !matches!(self.observe(&agent.thread_id), Observed::Current { value: Some(ref o), .. } if !o.busy())
        {
            return Some("busy or not current");
        }
        if self.workers(Some(&agent.thread_id)).iter().any(|w| {
            matches!(
                w["state"].as_str(),
                Some("working" | "starting" | "archiving")
            )
        }) {
            return Some("a worker is working");
        }
        None
    }

    pub(super) async fn upkeep_agent(
        self: &Arc<Self>,
        config: &crate::upkeep::Upkeep,
        agent: &Agent,
    ) -> Result<()> {
        use crate::upkeep::tokens;
        let thread = &agent.thread_id;
        if !crate::t3steps::valid(thread, &[]) || self.upkeep_blocker(agent).is_some() {
            return Ok(());
        }
        let rows = crate::t3db::query(
            crate::t3db::sql::CONTEXT_READING,
            crate::t3db::params![thread],
            crate::t3db::DETAIL_READ,
        )
        .await?;
        let row = rows.first().context("no reading")?;
        let (Some(reading), Some(used), Some(last)) = (
            row["reading_at"].as_str(),
            row["used"].as_u64(),
            row["last_at"].as_str().and_then(crate::t3::iso_parse),
        ) else {
            return Ok(());
        };
        let idle = (crate::model::now() as f64 - last).max(0.0) as u64;
        let wanted = config
            .decide(used, idle, crate::upkeep::local_hour())
            .map(|decision| Reading {
                origin: Origin::Automatic,
                decision,
                at: Some(reading.into()),
                tokens: used,
            });
        // The read took a while: decide only on what T3 shows now.
        let Some(agent) = self
            .registry()
            .agents
            .get(&agent.project_id)
            .filter(|a| a.thread_id == *thread)
            .cloned()
        else {
            return Ok(());
        };
        if self.upkeep_blocker(&agent).is_some() {
            return Ok(());
        }
        let compact = self.compact_command(
            thread,
            &format!("Compacted while idle ({} tokens)", tokens(used)),
            used,
        )?;
        let event = m26::Event::Checked {
            thread: thread.clone(),
            reading: wanted.clone(),
            compact,
        };
        match self.run_upkeep(&agent.project_id, event).await? {
            Some(Dispatched::Accepted(_)) => eprintln!(
                "Agent upkeep: compacting {thread} at {} tokens, idle {} min",
                tokens(used),
                idle / 60
            ),
            Some(
                Dispatched::Refused(detail)
                | Dispatched::NotSent(detail)
                | Dispatched::Unknown(detail),
            ) => eprintln!("Agent upkeep: compaction of {thread} not confirmed: {detail}"),
            None => {}
        }
        Ok(())
    }

    /// Feeds one event to the app's upkeep (M26) and carries out what it
    /// decides, each decision saved before its effect runs. A fresh start is
    /// saved as the agent's queued reset in the same change, then left to
    /// the reset runner. Returns what the last compaction sent got.
    pub(super) async fn run_upkeep(
        self: &Arc<Self>,
        project: &str,
        event: m26::Event,
    ) -> Result<Option<Dispatched>> {
        let mut event = Some(event);
        let mut outcome = None;
        while let Some(current) = event.take() {
            let reducing = project.to_string();
            for effect in self
                .owner
                .ask(move |s| s.reduce_upkeep(&reducing, current))
                .await?
            {
                match effect {
                    m26::Effect::Commit => {}
                    m26::Effect::StartFresh(reading) => {
                        eprintln!(
                            "Agent upkeep: fresh start of the {project} agent at {} tokens",
                            crate::upkeep::tokens(reading.tokens)
                        );
                        self.run_due_resets().await;
                    }
                    m26::Effect::Send(command) => {
                        let sent = self.client().await?.dispatch(&command).await;
                        outcome = Some(sent.clone());
                        event = Some(m26::Event::Sent(sent));
                    }
                }
            }
        }
        Ok(outcome)
    }

    /// `agent compact`: the same compaction upkeep sends, now, if the
    /// agent has no turn running. An earlier compaction still unanswered is
    /// sent again instead of a second one.
    pub async fn compact(
        self: &Arc<Self>,
        project_id: Option<&str>,
        thread_id: Option<&str>,
    ) -> Result<Value> {
        self.ready().await?;
        let agent = self.find_agent(project_id, thread_id)?;
        ensure!(
            matches!(agent.lifecycle, Lifecycle::Ready { .. }),
            "The app's agent is being created or reset"
        );
        ensure!(
            !self.observe_now(&agent.thread_id)?.busy(),
            "The agent is working; compact it once its turn ends"
        );
        let compact = self.compact_command(&agent.thread_id, "Compacted", 0)?;
        match self
            .run_upkeep(
                &agent.project_id,
                m26::Event::Manual {
                    thread: agent.thread_id.clone(),
                    compact,
                },
            )
            .await?
        {
            Some(Dispatched::Accepted(_)) => {}
            Some(Dispatched::Unknown(detail) | Dispatched::NotSent(detail)) => bail!(
                "T3 has not confirmed the compaction ({detail}); the same one is sent again when the agent is next idle"
            ),
            Some(Dispatched::Refused(detail)) => bail!(detail),
            None => bail!("The compaction was not sent"),
        }
        Ok(
            json!({"project_id": agent.project_id, "thread_id": agent.thread_id, "action": "compact",
                  "next": "The agent's context is being compacted; T3 shows the sizes before and after."}),
        )
    }

    /// The command that asks Claude to compact the agent's context, keeping
    /// what the agent needs, with its identity; `line` is what the
    /// conversation shows for it.
    pub(super) fn compact_command(&self, thread: &str, line: &str, tokens: u64) -> Result<Command> {
        let row = self
            .thread(thread)
            .context("The app agent's thread is gone")?;
        let mode = thread_mode(&row)?;
        let text = "/compact Keep: the user's open tasks and where each stands, decisions and preferences they stated, \
            workers still running or waiting and their branches, and the last few exchanges. Drop tool output and finished detail.";
        let record = Note::Upkeep.labeled(line, json!({"action": "compact", "tokens": tokens}));
        Ok(Command::new(
            &identity(),
            json!({
                "type": "thread.turn.start", "threadId": thread,
                "message": Note::with_record(&uuid::Uuid::new_v4().to_string(), text, record),
                "runtimeMode": mode,
                "interactionMode": row["interactionMode"].as_str().unwrap_or("default"),
            }),
        ))
    }
}
