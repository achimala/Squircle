use super::*;

impl Agents {
    pub async fn send(&self, thread_id: &str, text: &str) -> Result<()> {
        self.send_with(thread_id, text, None).await
    }

    /// `squircle thread send`: a message from an agent, marked as one so the
    /// app never shows it as something the user typed.
    pub async fn message(&self, thread_id: &str, text: &str) -> Result<()> {
        let from = self
            .registry()
            .workers
            .get(thread_id)
            .map(|w| w.coordinator.clone());
        self.send_with(
            thread_id,
            text,
            Some((Note::AgentMessage, json!({"from": from}))),
        )
        .await
    }

    pub(super) async fn send_with(
        &self,
        thread_id: &str,
        text: &str,
        note: Option<(Note, Value)>,
    ) -> Result<()> {
        let client = self.ready().await?;
        self.wait_thread(thread_id)
            .await?
            .with_context(|| format!("T3 has no thread {thread_id}"))?;
        let purpose = format!(
            "send {thread_id} {}\n{text}",
            note.as_ref().map_or("user", |(note, _)| note.kind())
        );
        let id = uuid::Uuid::new_v4().to_string();
        let message = match note {
            Some((note, payload)) => note.message(&id, text, payload),
            None => json!({"messageId": id, "text": text, "attachments": []}),
        };
        let thread_id = thread_id.to_string();
        self.dispatch_intent(&*client, purpose, move |identity| {
            Command::new(identity, deliver(&thread_id, message))
        })
        .await?;
        Ok(())
    }

    /// Sends a command a caller waits for under a saved identity. Asked
    /// again while T3 has left it unanswered, the same request sends that
    /// same command (T3 answers it from its receipt if it has it), never a
    /// second; only T3's answer settles it.
    pub(super) async fn dispatch_intent(
        &self,
        client: &dyn Peer,
        purpose: String,
        build: impl FnOnce(&Identity) -> Command + Send + 'static,
    ) -> Result<Value> {
        let command = self.owner.ask(move |s| s.intent(purpose, build)).await?;
        let outcome = client.dispatch(&command).await;
        let id = command.id().unwrap_or_default().to_string();
        let seen = outcome.clone();
        // Unsaved, the record stays as it was: the same request sends it again.
        if let Err(error) = self.owner.ask(move |s| s.attempted(&id, &seen)).await {
            eprintln!("Command outcome not saved: {error:#}");
        }
        match outcome {
            Dispatched::Accepted(value) => Ok(value),
            Dispatched::Unknown(detail) => bail!(
                "T3 has not confirmed it ({detail}). Ask again with the same text: the same one is sent again, never a second"
            ),
            Dispatched::Refused(detail) | Dispatched::NotSent(detail) => bail!(detail),
        }
    }

    /// A thread's projection (protocol 2: its `thread`, `runs`,
    /// `runtimeRequests`, `messages`, `turnItems`, `providerSessions`, …).
    /// T3 bounds it to the recent history, which is all this service reads.
    pub(super) async fn thread_detail(&self, client: &dyn Peer, id: &str) -> Result<Value> {
        client
            .call("orchestration.getThreadProjection", json!({"threadId": id}))
            .await
    }

    /// A pending question's request ID and questions, if the thread is
    /// waiting on one: a pending `user_input` runtime request, whose
    /// questions are on its `user_input_request` turn item.
    pub(super) fn pending_question(projection: &Value) -> Option<(String, Vec<Value>)> {
        let request = projection["runtimeRequests"]
            .as_array()?
            .iter()
            .rev()
            .find(|r| r["status"] == "pending" && r["kind"] == "user_input")?["id"]
            .as_str()?;
        let questions = projection["turnItems"]
            .as_array()
            .into_iter()
            .flatten()
            .rev()
            .find(|i| i["type"] == "user_input_request" && i["requestId"] == request)
            .and_then(|i| i["questions"].as_array().cloned())
            .unwrap_or_default();
        Some((request.to_string(), questions))
    }

    pub async fn read(&self, id: &str) -> Result<Value> {
        let client = self.ready().await?;
        let detail = self.thread_detail(&*client, id).await?;
        let thread = &detail["thread"];
        let worker = self.registry().workers.get(id).cloned();
        let last = detail["messages"]
            .as_array()
            .into_iter()
            .flatten()
            .rev()
            .find(|m| m["role"] == "assistant")
            .and_then(|m| m["text"].as_str())
            .map(str::to_string);
        let mut diff = Value::Null;
        let mut uncommitted = Value::Null;
        if let Some(path) = thread["worktreePath"].as_str().map(PathBuf::from) {
            let base = worker.as_ref().map_or("HEAD", |w| w.base.as_str());
            diff = git(&path, &["diff", "--shortstat", &format!("{base}...HEAD")])
                .await
                .map(Value::from)
                .unwrap_or(Value::Null);
            uncommitted = git(&path, &["status", "--porcelain"])
                .await
                .map(|s| json!(s.lines().count()))
                .unwrap_or(Value::Null);
        }
        let question = Self::pending_question(&detail).map(|(request, questions)| json!({"request_id": request,
            "questions": questions.iter().map(|q| json!({"question": q["question"], "options": q["options"].as_array().map(|o| o.iter().map(|o| o["label"].clone()).collect::<Vec<_>>())})).collect::<Vec<_>>()}));
        let shell = self.thread(id).unwrap_or(Value::Null);
        Ok(json!({
            "id": id, "title": thread["title"], "state": if shell.is_null() { "missing" } else { worker_state(&shell) },
            "branch": thread["branch"], "worktree": thread["worktreePath"], "base": worker.as_ref().map(|w| w.base.clone()),
            "committed_diff": diff, "uncommitted_files": uncommitted, "question": question, "last_reply": last,
        }))
    }

    /// Answers every question in the thread's pending request with `text`.
    pub async fn answer(&self, id: &str, text: &str) -> Result<()> {
        let client = self.ready().await?;
        let detail = self.thread_detail(&*client, id).await?;
        let (request, questions) = Self::pending_question(&detail).with_context(|| match pending_request(&detail) {
            Some(_) => "That thread is waiting on an approval; the user approves or declines it on the phone",
            None => "That thread is not waiting on a question",
        })?;
        let answers: serde_json::Map<String, Value> = questions
            .iter()
            .filter_map(|q| {
                q["id"]
                    .as_str()
                    .or(q["question"].as_str())
                    .map(|k| (k.to_string(), json!(text)))
            })
            .collect();
        let purpose = format!("answer {id} {request}\n{text}");
        let id = id.to_string();
        self.dispatch_intent(&*client, purpose, move |identity| Command::new(identity,
            json!({"type": "runtime-request.respond", "threadId": id, "requestId": request, "answers": answers}))).await?;
        Ok(())
    }

    pub fn status(&self) -> String {
        self.view.get().status.to_string()
    }

    /// T3's providers for the phone's model menus. T3's config also carries,
    /// per instance, the skill and command catalog of each of the last 16
    /// folders it ran a turn in (about 35 KB each, so about 1 MB with
    /// workers' worktrees), which the phone would otherwise carry over cellular.
    pub async fn providers(&self) -> Result<Value> {
        let config = self
            .client()
            .await?
            .call("server.getConfig", json!({}))
            .await?;
        Ok(Value::Array(
            config["providers"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|provider| {
                    let mut provider = provider.clone();
                    if let Some(fields) = provider.as_object_mut() {
                        for key in ["workspaceSnapshots", "skills", "slashCommands"] {
                            fields.remove(key);
                        }
                    }
                    provider
                })
                .collect(),
        ))
    }
}
