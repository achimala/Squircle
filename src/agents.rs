//! One agent per app. The app agent is an ordinary T3 thread on Squircle's
//! own Claude instance (see `setup`), in the project's folder. It can run
//! ordinary T3 worker threads, each in its own worktree. Squircle adds only
//! what T3 lacks: who owns which worker, the agent's thread ID and workers at
//! the start of each turn, and a wake-up when a worker finishes or needs
//! input. How to work is up to the user and the agent. No model runs here.

use crate::store::{atomic_json, private_dir, read_json};
use crate::t3::{T3, T3Config};
use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::process::Command;
use tokio::sync::RwLock;

/// The T3 provider instance `squircle agent setup` creates.
pub const INSTANCE: &str = "squircle";
const DEFAULT_MODEL: &str = "claude-opus-5-5";

#[derive(Clone, Serialize, Deserialize)]
pub struct Agent {
    pub project_id: String,
    pub thread_id: String,
    pub created_at: u64,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Worker {
    pub coordinator: String,
    pub project_id: String,
    pub title: String,
    pub branch: String,
    pub base: String,
    pub created_at: u64,
    /// The last state its coordinator was told about (`turn:state`), so a
    /// restart neither repeats nor misses a wake-up.
    #[serde(default)]
    pub notified: Option<String>,
    #[serde(default)]
    pub archived: bool,
}

#[derive(Default, Serialize, Deserialize)]
pub struct Registry {
    #[serde(default)]
    pub agents: BTreeMap<String, Agent>,
    #[serde(default)]
    pub workers: BTreeMap<String, Worker>,
}

/// What a worker is doing, from T3's shell row.
pub fn worker_state(thread: &Value) -> &'static str {
    if thread["hasPendingApprovals"] == true || thread["hasPendingUserInput"] == true {
        "needs-you"
    } else if thread["session"]["status"] == "error" || thread["latestTurn"]["state"] == "error" {
        "error"
    } else if thread["latestTurn"]["state"] == "running"
        || matches!(thread["session"]["status"].as_str(), Some("starting" | "running"))
    {
        "working"
    } else {
        "done"
    }
}

/// The wake-up a worker's current state calls for, if any: a stopped turn
/// (done, error) or one waiting on its owner. Identified by turn and state so
/// each is delivered once.
pub fn wake_key(thread: &Value) -> Option<String> {
    let turn = thread["latestTurn"]["turnId"].as_str()?;
    match worker_state(thread) {
        "working" => None,
        state => Some(format!("{turn}:{state}")),
    }
}

#[derive(Default)]
struct Shell {
    threads: HashMap<String, Value>,
    projects: HashMap<String, Value>,
    ready: bool,
}

pub struct Agents {
    root: PathBuf,
    /// The squircle executable and its arguments, for instructions to agents.
    cli: String,
    registry: Mutex<Registry>,
    shell: Mutex<Shell>,
    t3: RwLock<Option<Arc<T3>>>,
    status: Mutex<String>,
    flush_scheduled: Mutex<bool>,
}

fn quote(path: &Path) -> String {
    let text = path.display().to_string();
    if text.chars().all(|c| c.is_ascii_alphanumeric() || "/._-~".contains(c)) {
        text
    } else {
        format!("'{}'", text.replace('\'', "'\\''"))
    }
}

/// How agents invoke this same CLI against this same service.
pub fn cli_invocation(root: &Path, server: &str) -> String {
    let exe = std::env::current_exe()
        .and_then(|p| p.canonicalize())
        .unwrap_or_else(|_| PathBuf::from("squircle"));
    format!("{} --data-dir {} --server {server}", quote(&exe), quote(root))
}

async fn git(dir: &Path, args: &[&str]) -> Result<String> {
    let output = Command::new("git").arg("-C").arg(dir).args(args).output().await?;
    if !output.status.success() {
        bail!("git {}: {}", args.join(" "), String::from_utf8_lossy(&output.stderr).trim());
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn same_path(a: &Path, b: &Path) -> bool {
    match (a.canonicalize(), b.canonicalize()) {
        (Ok(a), Ok(b)) => a == b,
        _ => a == b,
    }
}

impl Agents {
    pub fn open(root: &Path, server: &str) -> Result<Arc<Self>> {
        let path = root.join("agents.json");
        let registry = if path.try_exists()? { read_json(&path)? } else { Registry::default() };
        Ok(Arc::new(Self {
            root: root.to_path_buf(),
            cli: cli_invocation(root, server),
            registry: Mutex::new(registry),
            shell: Mutex::default(),
            t3: RwLock::new(None),
            status: Mutex::new("Not connected to T3".into()),
            flush_scheduled: Mutex::new(false),
        }))
    }

    fn save(&self, registry: &Registry) -> Result<()> {
        atomic_json(&self.root.join("agents.json"), registry)
    }

    async fn client(&self) -> Result<Arc<T3>> {
        if let Some(client) = self.t3.read().await.clone() {
            return Ok(client);
        }
        bail!("{}", self.status.lock().unwrap())
    }

    /// Keeps a live copy of T3's shell and delivers wake-ups. Reconnects with
    /// backoff; a missing pairing is reported, not fatal to the service.
    pub async fn run(self: Arc<Self>) {
        let mut delay = 1;
        loop {
            match self.clone().session().await {
                Ok(()) => delay = 1,
                Err(error) => {
                    *self.status.lock().unwrap() = format!("{error:#}");
                    eprintln!("T3: {error:#}");
                }
            }
            *self.t3.write().await = None;
            self.shell.lock().unwrap().ready = false;
            tokio::time::sleep(Duration::from_secs(delay)).await;
            delay = (delay * 2).min(30);
        }
    }

    async fn session(self: Arc<Self>) -> Result<()> {
        let config = T3Config::load(&self.root)?;
        let client = T3::connect(config).await?;
        let (_, mut shell) = client.subscribe("orchestration.subscribeShell", json!({}))?;
        *self.t3.write().await = Some(client.clone());
        *self.status.lock().unwrap() = "Connected".into();
        loop {
            tokio::select! {
                item = shell.recv() => {
                    let Some(item) = item else { break };
                    self.consume_shell(&item);
                    self.schedule_flush();
                }
                _ = client.closed() => break,
            }
        }
        bail!("T3 connection closed")
    }

    fn consume_shell(&self, item: &Value) {
        let mut shell = self.shell.lock().unwrap();
        match item["kind"].as_str() {
            Some("snapshot") => {
                let snapshot = &item["snapshot"];
                shell.threads = snapshot["threads"].as_array().into_iter().flatten()
                    .filter_map(|t| Some((t["id"].as_str()?.to_string(), t.clone()))).collect();
                shell.projects = snapshot["projects"].as_array().into_iter().flatten()
                    .filter_map(|p| Some((p["id"].as_str()?.to_string(), p.clone()))).collect();
                shell.ready = true;
            }
            Some("thread-upserted") => {
                if let Some(id) = item["thread"]["id"].as_str() {
                    shell.threads.insert(id.to_string(), item["thread"].clone());
                }
            }
            Some("project-upserted") => {
                if let Some(id) = item["project"]["id"].as_str() {
                    shell.projects.insert(id.to_string(), item["project"].clone());
                }
            }
            Some("thread-removed") => {
                if let Some(id) = item["threadId"].as_str() {
                    shell.threads.remove(id);
                }
            }
            Some("project-removed") => {
                if let Some(id) = item["projectId"].as_str() {
                    shell.projects.remove(id);
                }
            }
            _ => {}
        }
    }

    fn thread(&self, id: &str) -> Option<Value> {
        self.shell.lock().unwrap().threads.get(id).cloned()
    }

    async fn ready(&self) -> Result<Arc<T3>> {
        let client = self.client().await?;
        for _ in 0..50 {
            if self.shell.lock().unwrap().ready {
                return Ok(client);
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        bail!("T3 has not sent its thread list yet; try again")
    }

    // MARK: Wake-ups

    /// Wake-ups wait a few seconds so workers finishing together arrive as one note.
    fn schedule_flush(self: &Arc<Self>) {
        let mut scheduled = self.flush_scheduled.lock().unwrap();
        if *scheduled || !self.has_due_wakes() {
            return;
        }
        *scheduled = true;
        let this = self.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(4)).await;
            *this.flush_scheduled.lock().unwrap() = false;
            if let Err(error) = this.flush().await {
                eprintln!("Wake-up not delivered: {error:#}");
            }
        });
    }

    fn due_wakes(&self) -> Vec<(String, Worker, String, &'static str)> {
        let registry = self.registry.lock().unwrap();
        let shell = self.shell.lock().unwrap();
        if !shell.ready {
            return vec![];
        }
        registry.workers.iter().filter(|(_, w)| !w.archived).filter_map(|(id, worker)| {
            let thread = shell.threads.get(id)?;
            let key = wake_key(thread)?;
            (worker.notified.as_deref() != Some(key.as_str()))
                .then(|| (id.clone(), worker.clone(), key, worker_state(thread)))
        }).collect()
    }

    fn has_due_wakes(&self) -> bool {
        !self.due_wakes().is_empty()
    }

    async fn flush(&self) -> Result<()> {
        let client = self.client().await?;
        let mut by_coordinator: BTreeMap<String, Vec<(String, Worker, String, &'static str)>> = BTreeMap::new();
        for due in self.due_wakes() {
            by_coordinator.entry(due.1.coordinator.clone()).or_default().push(due);
        }
        for (coordinator, notes) in by_coordinator {
            let Some(agent) = self.thread(&coordinator) else {
                // Its agent is gone; nobody is left to tell.
                let mut registry = self.registry.lock().unwrap();
                for (id, _, key, _) in &notes {
                    if let Some(worker) = registry.workers.get_mut(id) { worker.notified = Some(key.clone()); }
                }
                self.save(&registry)?;
                continue;
            };
            let lines: Vec<String> = notes.iter().map(|(id, w, _, state)| {
                let what = match *state {
                    "needs-you" => "is waiting on a question or approval",
                    "error" => "stopped with an error",
                    _ => "finished its turn",
                };
                format!("- \"{}\" ({id}, {}) {what}.", w.title, w.branch)
            }).collect();
            let text = format!("[worker update]\n{}\nRun `squircle thread read ID` for details, then decide what to do next.", lines.join("\n"));
            let record = json!({
                "version": 1, "contextId": uuid::Uuid::new_v4().to_string(), "label": "Worker update",
                "kind": "squircle-worker-update",
                "payload": {"workers": notes.iter().map(|(id, w, _, state)| json!({"id": id, "title": w.title, "branch": w.branch, "state": state})).collect::<Vec<_>>()}
            });
            client.dispatch(json!({
                "type": "thread.turn.start", "threadId": coordinator,
                "message": {"messageId": uuid::Uuid::new_v4().to_string(), "role": "user", "text": text, "attachments": [],
                            "context": {"version": 1, "records": [record]}},
                "runtimeMode": agent["runtimeMode"].as_str().unwrap_or("full-access"),
                "interactionMode": "default",
            })).await?;
            let mut registry = self.registry.lock().unwrap();
            for (id, _, key, _) in &notes {
                if let Some(worker) = registry.workers.get_mut(id) {
                    worker.notified = Some(key.clone());
                }
            }
            self.save(&registry)?;
        }
        Ok(())
    }

    // MARK: Agents

    pub fn list(&self) -> Vec<Agent> {
        self.registry.lock().unwrap().agents.values().cloned().collect()
    }

    /// The app agent for a T3 project, created on first use: a thread on
    /// Squircle's instance in the project's folder.
    pub async fn ensure(&self, project_id: &str, message: Option<&str>, model: Option<&str>) -> Result<Agent> {
        let client = self.ready().await?;
        let existing = self.registry.lock().unwrap().agents.get(project_id).cloned();
        let agent = match existing.filter(|a| self.thread(&a.thread_id).is_some_and(|t| t["archivedAt"].is_null())) {
            Some(agent) => agent,
            None => self.create(&client, project_id, model).await?,
        };
        if let Some(text) = message.filter(|t| !t.trim().is_empty()) {
            self.send(&agent.thread_id, text).await?;
        }
        Ok(agent)
    }

    async fn create(&self, client: &T3, project_id: &str, model: Option<&str>) -> Result<Agent> {
        let project = self.shell.lock().unwrap().projects.get(project_id).cloned()
            .with_context(|| format!("T3 has no project {project_id}"))?;
        let config = client.call("server.getConfig", json!({})).await?;
        let ready = config["providers"].as_array().into_iter().flatten()
            .any(|p| p["instanceId"] == INSTANCE && p["status"] == "ready");
        ensure!(ready, "T3 has no ready \"{INSTANCE}\" agent instance. Run: squircle agent setup");

        let model = model.map(str::to_string)
            .or_else(|| project["defaultModelSelection"]["model"].as_str().filter(|_| project["defaultModelSelection"]["instanceId"] == "claudeAgent").map(str::to_string))
            .unwrap_or_else(|| DEFAULT_MODEL.into());
        let thread_id = uuid::Uuid::new_v4().to_string();
        let name = project["title"].as_str().unwrap_or("App");
        client.dispatch(json!({
            "type": "thread.create", "threadId": thread_id, "projectId": project_id,
            "title": format!("{name} agent"),
            "modelSelection": {"instanceId": INSTANCE, "model": model},
            "runtimeMode": "full-access", "interactionMode": "default",
            "branch": null, "worktreePath": null,
        })).await?;
        let agent = Agent { project_id: project_id.into(), thread_id, created_at: crate::model::now() };
        let mut registry = self.registry.lock().unwrap();
        registry.agents.insert(project_id.into(), agent.clone());
        self.save(&registry)?;
        Ok(agent)
    }

    fn agent_for_thread(&self, thread_id: &str) -> Option<Agent> {
        self.registry.lock().unwrap().agents.values().find(|a| a.thread_id == thread_id).cloned()
    }

    /// Facts at the start of each agent turn: its thread ID (needed to spawn
    /// workers) and its workers right now.
    pub fn context(&self, cwd: &Path) -> String {
        let agents = self.list();
        let shell = self.shell.lock().unwrap();
        let agent = agents.into_iter().find(|a| {
            shell.projects.get(&a.project_id).and_then(|p| p["workspaceRoot"].as_str())
                .is_some_and(|root| same_path(Path::new(root), cwd) || cwd.starts_with(root))
        });
        drop(shell);
        let Some(agent) = agent else {
            return "[squircle] No app agent works in this folder.".into();
        };
        let workers = self.workers(Some(&agent.thread_id));
        let board = if workers.is_empty() {
            "none".to_string()
        } else {
            workers.iter().map(|w| format!("\n- {} [{}] {} ({})", w["title"].as_str().unwrap_or(""), w["branch"].as_str().unwrap_or(""),
                w["state"].as_str().unwrap_or(""), w["id"].as_str().unwrap_or(""))).collect()
        };
        format!("[squircle] Your thread id: {}. Your workers: {board}", agent.thread_id)
    }

    // MARK: Workers

    pub fn workers(&self, coordinator: Option<&str>) -> Vec<Value> {
        let registry = self.registry.lock().unwrap();
        let shell = self.shell.lock().unwrap();
        registry.workers.iter()
            .filter(|(_, w)| !w.archived && coordinator.is_none_or(|c| w.coordinator == c))
            .map(|(id, w)| {
                let thread = shell.threads.get(id);
                json!({
                    "id": id, "title": w.title, "branch": w.branch, "base": w.base, "coordinator": w.coordinator,
                    "project_id": w.project_id, "created_at": w.created_at,
                    "state": thread.map_or("missing", worker_state),
                    "worktree": thread.and_then(|t| t["worktreePath"].as_str()),
                })
            }).collect()
    }

    pub async fn spawn(&self, coordinator: &str, title: &str, branch: &str, base: Option<&str>, prompt: &str, model: Option<&str>) -> Result<Value> {
        let client = self.ready().await?;
        let agent = self.agent_for_thread(coordinator)
            .with_context(|| format!("{coordinator} is not an app agent's thread"))?;
        ensure!(!title.trim().is_empty() && !prompt.trim().is_empty(), "A worker needs a title and a prompt");
        ensure!(!branch.is_empty() && !branch.contains(char::is_whitespace) && !branch.contains(".."), "Invalid branch name");
        let project = self.shell.lock().unwrap().projects.get(&agent.project_id).cloned().context("The app's T3 project is gone")?;
        let coordinator_thread = self.thread(coordinator).context("The app agent's thread is gone")?;
        let model = model.map(str::to_string)
            .or_else(|| coordinator_thread["modelSelection"]["model"].as_str().map(str::to_string))
            .unwrap_or_else(|| DEFAULT_MODEL.into());
        let selection = json!({"instanceId": "claudeAgent", "model": model});
        let checkout = PathBuf::from(project["workspaceRoot"].as_str().context("The project has no folder")?);
        let current = git(&checkout, &["symbolic-ref", "--short", "HEAD"]).await.unwrap_or_else(|_| "HEAD".into());
        let base = base.unwrap_or(&current);
        let id = uuid::Uuid::new_v4().to_string();
        let text = format!(
            "{prompt}\n\n---\nYou are a worker for this app's agent, on branch {branch} in your own worktree. When done, commit on this branch and reply with a short summary. \
             To show the app running, use T3's device tools (device_list, device_open) so the user can watch. To publish a recording or screenshot into this thread: {cli} media add --thread {id} --file PATH --caption TEXT. \
             For signed builds: {cli} build start --help.",
            cli = self.cli
        );
        let now = crate::t3::iso_now();
        client.dispatch(json!({
            "type": "thread.turn.start", "threadId": id,
            "message": {"messageId": uuid::Uuid::new_v4().to_string(), "role": "user", "text": text, "attachments": []},
            "modelSelection": selection, "runtimeMode": "full-access", "interactionMode": "default",
            "bootstrap": {
                "createThread": {"projectId": agent.project_id, "title": title, "modelSelection": selection,
                                 "runtimeMode": "full-access", "interactionMode": "default", "branch": null, "worktreePath": null, "createdAt": now},
                "prepareWorktree": {"projectCwd": project["workspaceRoot"], "baseBranch": base, "branch": branch},
                "runSetupScript": true,
            },
        })).await?;
        {
            let mut registry = self.registry.lock().unwrap();
            registry.workers.insert(id.clone(), Worker {
                coordinator: coordinator.into(), project_id: agent.project_id.clone(), title: title.into(),
                branch: branch.into(), base: base.into(), created_at: crate::model::now(), notified: None, archived: false,
            });
            self.save(&registry)?;
        }
        Ok(json!({"id": id, "title": title, "branch": branch, "base": base, "model": model,
                  "next": "The worker is running. End your turn; a [worker update] arrives when it finishes."}))
    }

    /// A thread from the live shell; one just created takes a moment to arrive.
    async fn wait_thread(&self, id: &str) -> Result<Value> {
        for _ in 0..100 {
            if let Some(thread) = self.thread(id) {
                return Ok(thread);
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        bail!("T3 has no thread {id}")
    }

    pub async fn send(&self, thread_id: &str, text: &str) -> Result<()> {
        let client = self.ready().await?;
        let thread = self.wait_thread(thread_id).await?;
        client.dispatch(json!({
            "type": "thread.turn.start", "threadId": thread_id,
            "message": {"messageId": uuid::Uuid::new_v4().to_string(), "role": "user", "text": text, "attachments": []},
            "runtimeMode": thread["runtimeMode"].as_str().unwrap_or("full-access"),
            "interactionMode": thread["interactionMode"].as_str().unwrap_or("default"),
        })).await?;
        Ok(())
    }

    async fn thread_detail(&self, client: &T3, id: &str) -> Result<Value> {
        let snapshot = client.snapshot("orchestration.subscribeThread", json!({"threadId": id})).await?;
        let thread = &snapshot["snapshot"];
        Ok(if thread["thread"].is_object() { thread["thread"].clone() } else { thread.clone() })
    }

    /// A pending question's request ID and question IDs, if the thread is waiting on one.
    fn pending_question(thread: &Value) -> Option<(String, Vec<Value>)> {
        let activities = thread["activities"].as_array()?;
        let resolved: Vec<&str> = activities.iter()
            .filter(|a| matches!(a["kind"].as_str(), Some("user-input.resolved" | "user-input.answer-submitted")))
            .filter_map(|a| a["payload"]["requestId"].as_str()).collect();
        activities.iter().rev().find(|a| a["kind"] == "user-input.requested"
            && a["payload"]["requestId"].as_str().is_some_and(|r| !resolved.contains(&r)))
            .map(|a| (a["payload"]["requestId"].as_str().unwrap().to_string(),
                      a["payload"]["questions"].as_array().cloned().unwrap_or_default()))
    }

    pub async fn read(&self, id: &str) -> Result<Value> {
        let client = self.ready().await?;
        let thread = self.thread_detail(&client, id).await?;
        let worker = self.registry.lock().unwrap().workers.get(id).cloned();
        let last = thread["messages"].as_array().into_iter().flatten().rev()
            .find(|m| m["role"] == "assistant").and_then(|m| m["text"].as_str()).map(str::to_string);
        let mut diff = Value::Null;
        let mut uncommitted = Value::Null;
        if let Some(path) = thread["worktreePath"].as_str().map(PathBuf::from) {
            let base = worker.as_ref().map_or("HEAD", |w| w.base.as_str());
            diff = git(&path, &["diff", "--shortstat", &format!("{base}...HEAD")]).await.map(Value::from).unwrap_or(Value::Null);
            uncommitted = git(&path, &["status", "--porcelain"]).await
                .map(|s| json!(s.lines().count())).unwrap_or(Value::Null);
        }
        let question = Self::pending_question(&thread).map(|(request, questions)| json!({"request_id": request,
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
        let thread = self.thread_detail(&client, id).await?;
        let (request, questions) = Self::pending_question(&thread).context("That thread is not waiting on a question")?;
        let answers: serde_json::Map<String, Value> = questions.iter()
            .filter_map(|q| q["id"].as_str().or(q["question"].as_str()).map(|k| (k.to_string(), json!(text)))).collect();
        client.dispatch(json!({"type": "thread.user-input.respond", "threadId": id, "requestId": request, "answers": answers})).await?;
        Ok(())
    }

    /// Archives a worker and removes its worktree; its branch stays.
    pub async fn archive(&self, id: &str, force: bool) -> Result<Value> {
        let client = self.ready().await?;
        let thread = self.thread(id).with_context(|| format!("T3 has no thread {id}"))?;
        let mut removed = Value::Null;
        if let (Some(path), Some(project)) = (thread["worktreePath"].as_str(), thread["projectId"].as_str()) {
            let is_agent = self.registry.lock().unwrap().agents.values().any(|a| a.thread_id == id);
            ensure!(!is_agent, "That is an app agent's thread, not a worker");
            let root = self.shell.lock().unwrap().projects.get(project).and_then(|p| p["workspaceRoot"].as_str().map(PathBuf::from));
            if let Some(root) = root && Path::new(path).exists() {
                let mut args = vec!["worktree", "remove"];
                if force { args.push("--force"); }
                args.push(path);
                git(&root, &args).await.context("The worktree has uncommitted changes; commit them or pass --force")?;
                removed = json!(path);
            }
        }
        client.dispatch(json!({"type": "thread.archive", "threadId": id})).await?;
        let mut registry = self.registry.lock().unwrap();
        if let Some(worker) = registry.workers.get_mut(id) {
            worker.archived = true;
        }
        self.save(&registry)?;
        Ok(json!({"archived": id, "removed_worktree": removed, "branch": thread["branch"]}))
    }

    pub fn status(&self) -> String {
        self.status.lock().unwrap().clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn thread(turn: Option<&str>, turn_state: &str, session: &str, needs: bool) -> Value {
        json!({
            "latestTurn": turn.map(|t| json!({"turnId": t, "state": turn_state})),
            "session": {"status": session}, "hasPendingApprovals": false, "hasPendingUserInput": needs,
        })
    }

    #[test]
    fn wakes_once_per_turn_outcome() {
        // Not started yet, and running, call for nothing.
        assert_eq!(wake_key(&thread(None, "", "starting", false)), None);
        assert_eq!(wake_key(&thread(Some("a"), "running", "running", false)), None);
        // A question mid-turn wakes; the same turn finishing wakes again.
        assert_eq!(wake_key(&thread(Some("a"), "running", "running", true)).as_deref(), Some("a:needs-you"));
        assert_eq!(wake_key(&thread(Some("a"), "completed", "ready", false)).as_deref(), Some("a:done"));
        // A session that stopped between turns is still the same outcome.
        assert_eq!(wake_key(&thread(Some("a"), "completed", "stopped", false)).as_deref(), Some("a:done"));
        assert_eq!(wake_key(&thread(Some("b"), "error", "error", false)).as_deref(), Some("b:error"));
    }
}

const PLUGIN_FILES: [(&str, &str); 3] = [
    (".claude-plugin/plugin.json", include_str!("../plugin/squircle/.claude-plugin/plugin.json")),
    ("agents/app-agent.md", include_str!("../plugin/squircle/agents/app-agent.md")),
    ("hooks/hooks.json", include_str!("../plugin/squircle/hooks/hooks.json")),
];

/// Installs the plugin (agent definition and hooks) into the data directory
/// and adds T3's "squircle" Claude instance that launches with it, on the
/// same Claude binary and login as T3's own Claude. `remove` takes the
/// instance out again. Returns what changed.
pub async fn setup(root: &Path, server: &str, remove: bool) -> Result<Value> {
    // T3 and hooks run elsewhere: every path they get must be absolute.
    let root = &root.canonicalize().context("Squircle data directory not found; run squircle init")?;
    let client = T3::connect(T3Config::load(root)?).await?;
    let settings = client.call("server.getSettings", json!({})).await?;
    let mut instances = settings["providerInstances"].as_object().cloned().unwrap_or_default();
    let plugin = root.join("plugin").join("squircle");
    if remove {
        let removed = instances.remove(INSTANCE).is_some();
        client.call("server.updateSettings", json!({"patch": {"providerInstances": instances}})).await?;
        return Ok(json!({"removed_instance": removed, "plugin_left_at": plugin}));
    }
    let cli = cli_invocation(root, server);
    let escaped = serde_json::to_string(&cli)?;
    let escaped = &escaped[1..escaped.len() - 1];
    for (path, template) in PLUGIN_FILES {
        let target = plugin.join(path);
        private_dir(target.parent().unwrap())?;
        let cli = if path.ends_with(".json") { escaped } else { cli.as_str() };
        std::fs::write(&target, template.replace("{{CLI}}", cli).replace("{{VERSION}}", env!("CARGO_PKG_VERSION")))?;
    }
    let claude = &settings["providers"]["claudeAgent"];
    let mut config = serde_json::Map::new();
    for key in ["binaryPath", "homePath"] {
        if let Some(value) = claude[key].as_str().filter(|v| !v.is_empty()) {
            config.insert(key.into(), json!(value));
        }
    }
    let launch = format!("--plugin-dir {} --agent squircle:app-agent", quote(&plugin));
    config.insert("launchArgs".into(), json!(launch));
    instances.insert(INSTANCE.into(), json!({"driver": "claudeAgent", "displayName": "Squircle agent", "config": config}));
    client.call("server.updateSettings", json!({"patch": {"providerInstances": instances}})).await?;
    Ok(json!({"plugin": plugin, "instance": INSTANCE, "launch_args": launch,
              "note": "T3 now offers a \"Squircle agent\" Claude instance on your existing Claude login. Run with --remove to take it out."}))
}
