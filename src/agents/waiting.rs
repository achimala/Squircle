use super::*;
use crate::tasks::QuestionState;

/// A thread of an app with an agent that T3 shows waiting on the user: a
/// question or an approval it asked for itself.
#[derive(Clone, Debug)]
pub struct WaitingThread {
    pub project_id: String,
    pub thread_id: String,
    pub title: String,
    /// The app agent it works for, when it is one of Squircle's workers.
    pub coordinator: Option<String>,
}

impl Agents {
    /// Every thread in an app with an agent that T3 shows waiting on the
    /// user, the agent's own and the user's own threads included.
    pub fn waiting_threads(&self) -> Vec<WaitingThread> {
        let View {
            registry, shell, ..
        } = &*self.view.get();
        shell
            .threads
            .iter()
            .filter_map(|(id, row)| {
                let project = row["projectId"].as_str()?;
                registry.agents.get(project)?;
                if ThreadObservation::decode(row).phase() != Phase::NeedsYou {
                    return None;
                }
                let worker = registry.workers.get(id);
                Some(WaitingThread {
                    project_id: project.to_string(),
                    thread_id: id.clone(),
                    title: worker
                        .map(|w| w.title.clone())
                        .or_else(|| row["title"].as_str().map(str::to_string))
                        .unwrap_or_default(),
                    coordinator: worker.map(|w| w.coordinator.clone()),
                })
            })
            .collect()
    }

    /// An app's name as T3 shows it.
    pub fn app_title(&self, project: &str) -> Option<String> {
        self.shell()
            .project(project)
            .and_then(|p| p["title"].as_str())
            .map(str::to_string)
    }

    /// The thread's open request and the turn item that says what it asks.
    pub async fn pending(&self, thread: &str) -> Result<Option<(String, Value)>> {
        let client = self.ready().await?;
        let detail = self.thread_detail(&*client, thread).await?;
        Ok(pending_item(&detail))
    }

    /// Answers a thread's open request from the phone: a decision for an
    /// approval, answers for questions (keyed by question ID). Returns what
    /// was asked and answered, in a line or two, for the app agent.
    pub async fn respond(
        &self,
        thread: &str,
        request: &str,
        decision: Option<String>,
        answers: Option<Value>,
    ) -> Result<String> {
        let client = self.ready().await?;
        let detail = self.thread_detail(&*client, thread).await?;
        let (open, item) =
            pending_item(&detail).context("That thread is no longer waiting on you")?;
        ensure!(open == request, "That request was already answered");
        let mut command =
            json!({"type": "runtime-request.respond", "threadId": thread, "requestId": request});
        let said = match (&decision, &answers) {
            (_, Some(answers)) => {
                command["answers"] = answers.clone();
                summary(&item, Some(answers), None)
            }
            (Some(decision), None) => {
                command["decision"] = json!(decision);
                summary(&item, None, Some(decision))
            }
            (None, None) => bail!("Pass a decision or answers"),
        };
        let purpose = format!("respond {thread} {request}\n{command}");
        self.dispatch_intent(&*client, purpose, move |identity| {
            Command::new(identity, command)
        })
        .await?;
        Ok(said)
    }
}

impl Agents {
    /// Hands every answered tracker question still owed to its asker to the
    /// outbox, then settles it with the task owner. The answer and the
    /// obligation were saved together, so a crash or a failure on the way
    /// leaves it owed and the next relay hands it over again; the outbox
    /// takes a message ID it already has as no change. Runs only from the
    /// service's task loop, so two relays never overlap.
    pub async fn relay_answers(self: &Arc<Self>) -> Result<()> {
        for (task, question) in self.tasks.owed() {
            let QuestionState::Answered { text, .. } = &question.state else {
                continue;
            };
            let ask = task.name().replace('\n', " ");
            let message = format!(
                "[answer] The user answered your question on “{ask}” in the tracker:\nQ: {}\nA: {text}\n\
                 Go on with it; record any new demand in the answer as a sub-task first.",
                question.text,
            );
            let payload = json!({"task": task.id, "question": question.id});
            self.notify(
                &question.thread_id,
                &question.id,
                message,
                Note::Answer,
                payload.clone(),
            )
            .await?;
            if let Some(coordinator) = self.coordinator_of(&question.thread_id) {
                let title = self.worker_title(&question.thread_id).unwrap_or_default();
                let told = format!(
                    "[answer] The user answered “{title}”'s question on “{ask}” directly; it has the answer, nothing to relay:\n“{}” → “{text}”",
                    question.text,
                );
                self.notify(
                    &coordinator,
                    &format!("{}.told", question.id),
                    told,
                    Note::Answer,
                    payload,
                )
                .await?;
            }
            self.tasks.delivered(&question.id).await?;
        }
        Ok(())
    }
}

/// The newest open request in a thread's projection that can still be
/// answered, and its `user_input_request` or `approval_request` turn item.
pub(super) fn pending_item(projection: &Value) -> Option<(String, Value)> {
    let items = projection["turnItems"].as_array();
    projection["runtimeRequests"]
        .as_array()?
        .iter()
        .rev()
        .filter(|r| r["status"] == "pending" && r["responseCapability"]["type"] != "not_resumable")
        .find_map(|r| {
            let id = r["id"].as_str()?;
            let item = items?.iter().rev().find(|i| {
                i["requestId"] == id
                    && matches!(
                        i["type"].as_str(),
                        Some("user_input_request" | "approval_request")
                    )
            })?;
            Some((id.to_string(), item.clone()))
        })
}

/// What a request asked and what the user said, for the agent's note.
fn summary(item: &Value, answers: Option<&Value>, decision: Option<&str>) -> String {
    if let Some(decision) = decision {
        let label = item["options"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|o| o["decision"] == decision)
            .and_then(|o| o["label"].as_str())
            .unwrap_or(decision);
        let asked = item["title"].as_str().unwrap_or("an approval");
        return format!("“{asked}”: {label}");
    }
    item["questions"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|q| {
            let key = q["id"]
                .as_str()
                .or(q["header"].as_str())
                .unwrap_or("answer");
            let answer = answers
                .and_then(|a| a.get(key))
                .map(|a| a.as_str().map_or_else(|| a.to_string(), str::to_string))
                .unwrap_or_default();
            format!("“{}” → “{answer}”", q["question"].as_str().unwrap_or(""))
        })
        .collect::<Vec<_>>()
        .join("\n")
}
