//! The user's demands reach the tracker and every worker (2026-10-24, after
//! "fold from bottom" was passed on once, never recorded, and dropped from
//! a later re-brief). An app agent can't hand work to a worker while one of
//! the user's messages is neither in the tracker (a task records it as its
//! source) nor marked as asking nothing (`task heard`), and every brief to a
//! linked worker carries its work item's asks in the user's words.

use super::*;

/// What the user wrote in a message, without the attachments T3 appends;
/// None for an empty one or a bracketed relay (`[worker update]` and the like).
pub(super) fn said(message: &Value) -> Option<&str> {
    let text = message["text"].as_str()?;
    let text = text.split("\n\n---\n").next().unwrap_or(text).trim();
    (!text.is_empty() && !text.starts_with('[')).then_some(text)
}

fn message_id(message: &Value) -> Option<&str> {
    message["id"].as_str().or(message["messageId"].as_str())
}

/// The user's messages after the last one `accounted` names, oldest first.
pub(super) fn unheard(messages: &[Value], accounted: impl Fn(&str) -> bool) -> Vec<&str> {
    let start = messages
        .iter()
        .rposition(|m| message_id(m).is_some_and(&accounted))
        .map_or(0, |i| i + 1);
    messages[start..]
        .iter()
        .filter(|m| users_own(m))
        .filter_map(said)
        .collect()
}

impl Agents {
    /// The user's messages to this app agent that came after the last one
    /// the tracker records as a task's source or the agent marked heard.
    pub async fn unheard(&self, thread: &str) -> Result<Vec<String>> {
        let agent = self
            .agent_for_thread(thread)
            .with_context(|| format!("{thread} is not an app agent's thread"))?;
        let client = self.ready().await?;
        let detail = self.thread_detail(&*client, thread).await?;
        let sources: Vec<String> = self
            .tasks
            .list(&agent.project_id)
            .iter()
            .flat_map(|t| std::iter::once(t).chain(&t.subtasks))
            .filter_map(|t| t.source.as_ref())
            .filter(|s| s.thread_id == thread)
            .map(|s| s.message_id.clone())
            .chain(agent.heard)
            .collect();
        let messages = detail["messages"].as_array().cloned().unwrap_or_default();
        Ok(unheard(&messages, |id| sources.iter().any(|s| s == id))
            .into_iter()
            .map(str::to_string)
            .collect())
    }
}

/// The user's unheard messages as the agent is shown them, or None.
pub(super) fn listed(unheard: &[String]) -> Option<String> {
    const SHOWN: usize = 6;
    if unheard.is_empty() {
        return None;
    }
    let skipped = unheard.len().saturating_sub(SHOWN);
    let mut text: String = unheard[skipped..]
        .iter()
        .map(|t| {
            let t = t.replace('\n', " ");
            if t.chars().count() > 800 {
                format!("\n- \"{}…\"", t.chars().take(800).collect::<String>())
            } else {
                format!("\n- \"{t}\"")
            }
        })
        .collect();
    if skipped > 0 {
        text = format!("\n- ({skipped} earlier ones){text}");
    }
    Some(text)
}

impl Agents {
    /// Refuses to hand work on (spawn, send, answer) while the coordinator
    /// has unheard messages from the user. Not an app agent: nothing to check.
    pub async fn ensure_heard(&self, coordinator: &str) -> Result<()> {
        if self.agent_for_thread(coordinator).is_none() {
            return Ok(());
        }
        let unheard = self.unheard(coordinator).await?;
        let Some(list) = listed(&unheard) else {
            return Ok(());
        };
        bail!(
            "Not sent: these messages from the user aren't in the tracker yet:{list}\n\
             Record each demand in them first, in the user's words, corrections and details included: \
             `{cli} task sub add ITEM --thread {coordinator} --ask \"...\"` under the work item it belongs to, \
             or `{cli} task add --thread {coordinator} --ask \"...\"` for a new one. If they ask for nothing to track \
             (a thanks, a question you answered), run `{cli} task heard --thread {coordinator}`. Then run this again; \
             the worker's brief will carry every ask of its work item.",
            cli = self.cli,
        )
    }

    /// The app agent a worker reports to.
    pub fn coordinator_of(&self, worker: &str) -> Option<String> {
        self.registry()
            .workers
            .get(worker)
            .map(|w| w.coordinator.clone())
    }

    /// `task heard`: the user's messages so far ask for nothing to track.
    pub async fn mark_heard(&self, thread: &str) -> Result<Value> {
        let agent = self
            .agent_for_thread(thread)
            .with_context(|| format!("{thread} is not an app agent's thread"))?;
        let client = self.ready().await?;
        let detail = self.thread_detail(&*client, thread).await?;
        let latest = detail["messages"]
            .as_array()
            .into_iter()
            .flatten()
            .rev()
            .find(|m| users_own(m))
            .and_then(message_id)
            .map(str::to_string);
        let heard = latest.clone();
        self.change(move |registry| {
            if let Some(agent) = registry.agents.get_mut(&agent.project_id) {
                agent.heard = heard;
            }
        })
        .await?;
        Ok(json!({"heard": latest.is_some(),
                  "next": "Anything the user asks from now on still goes in the tracker before you act on it."}))
    }

    /// The asks of the work items `task` belongs to, and those any task
    /// linked to `worker` belongs to, in the user's words: the block a
    /// worker's brief ends with, so a re-brief can't drop one. Empty when
    /// none apply.
    pub fn asks_for(&self, task: Option<&str>, worker: Option<&str>) -> String {
        let all = self.tasks.all();
        let relevant = |t: &crate::tasks::Task| {
            task.is_some_and(|id| t.id == id)
                || worker.is_some_and(|w| t.threads.iter().any(|x| x == w))
        };
        let items: Vec<&crate::tasks::Task> = all
            .iter()
            .filter(|i| i.parent_id.is_none())
            .filter(|i| relevant(i) || i.subtasks.iter().any(relevant))
            .collect();
        if items.is_empty() {
            return String::new();
        }
        let line = |t: &crate::tasks::Task| {
            let state = match t.status {
                Status::Done => " (done; still holds)",
                _ => "",
            };
            format!("{}{state}", t.ask.replace('\n', " "))
        };
        let body: String = items
            .iter()
            .map(|item| {
                let subtasks: String = item
                    .subtasks
                    .iter()
                    .filter(|s| s.status != Status::Dropped)
                    .map(|s| format!("\n  - {}", line(s)))
                    .collect();
                format!("\n- {}{subtasks}", line(item))
            })
            .collect();
        format!(
            "\n\n---\nThe user's asks for this work, from the tracker, in their words. Every one holds unless the user changes it, \
             whatever this message says. Before you report anything done, look at it (screenshots or a recording) and check it against each:{body}"
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn user(id: &str, text: &str) -> Value {
        json!({"id": id, "role": "user", "text": text})
    }

    #[test]
    fn unheard_starts_after_the_last_recorded_message() {
        let messages = vec![
            user("1", "Make the letters stack"),
            json!({"id": "2", "role": "assistant", "text": "On it"}),
            user("3", "Fold from bottom same as the folder."),
            Note::WorkerUpdate.message("4", "[worker update] done", json!({})),
            user("5", "[squircle] relay"),
            user("6", "Stack them up and fold to fit\n\n---\nattachment"),
        ];
        assert_eq!(
            unheard(&messages, |id| id == "1"),
            [
                "Fold from bottom same as the folder.",
                "Stack them up and fold to fit"
            ]
        );
        assert!(unheard(&messages, |id| id == "6").is_empty());
        // Nothing recorded yet: every message of the user's counts.
        assert_eq!(unheard(&messages, |_| false).len(), 3);
    }
}
