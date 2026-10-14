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
    /// A restart or fresh start asked for mid-turn, done when the turn ends
    /// (an agent cannot stop its own session while it runs).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending: Option<Reset>,
    /// After a restart: the next turn's note carries the current instructions,
    /// because Claude restores a resumed session's original system prompt.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub refresh: bool,
}

/// `restart` relaunches the agent's Claude session on the same thread, so the
/// next message starts with the current plugin instructions and the same
/// history. `fresh` replaces the thread with a new one seeded by a handoff.
#[derive(Clone, Serialize, Deserialize, PartialEq, Debug)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Reset {
    Restart,
    Fresh { note: Option<String> },
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

/// A worker's branch and worktree as git sees them.
#[derive(Debug, Default)]
struct GitState {
    branch: Option<String>,
    branch_exists: bool,
    /// Commits on the branch whose change is not in its base (`git cherry`,
    /// so rebased or cherry-picked merges count as merged).
    unmerged: usize,
    /// The worktree, if it still exists, and its uncommitted files.
    worktree: Option<PathBuf>,
    dirty: usize,
}

impl GitState {
    fn blocker(&self) -> Option<String> {
        let mut reasons = vec![];
        if self.unmerged > 0 {
            reasons.push(format!("{} commit{} not merged", self.unmerged, if self.unmerged == 1 { "" } else { "s" }));
        }
        if self.dirty > 0 {
            reasons.push(format!("{} uncommitted file{}", self.dirty, if self.dirty == 1 { "" } else { "s" }));
        }
        (!reasons.is_empty()).then(|| reasons.join(" and "))
    }
}

async fn inspect(root: &Path, worktree: Option<&Path>, branch: Option<&str>, base: Option<&str>) -> Result<GitState> {
    let mut state = GitState::default();
    if let Some(path) = worktree.filter(|p| p.exists()) {
        state.dirty = git(path, &["status", "--porcelain"]).await?.lines().count();
        state.worktree = Some(path.to_path_buf());
    }
    let Some(branch) = branch.filter(|b| !b.is_empty()) else { return Ok(state) };
    state.branch = Some(branch.into());
    state.branch_exists = git(root, &["rev-parse", "--verify", "--quiet", &format!("refs/heads/{branch}")]).await.is_ok();
    if state.branch_exists {
        let base = base.context("The worker has no base branch to compare with")?;
        ensure!(base != branch, "The worker's branch is its base");
        state.unmerged = git(root, &["cherry", base, branch]).await
            .with_context(|| format!("Cannot compare {branch} with {base}"))?
            .lines().filter(|l| l.starts_with('+')).count();
    }
    Ok(state)
}

#[derive(Default)]
struct Removed {
    worktree: Option<PathBuf>,
    branch: Option<String>,
}

/// Removes what `inspect` found. Without `discard`, git itself refuses to
/// drop uncommitted changes or a branch that is not fully merged.
async fn remove(root: &Path, state: &GitState, discard: bool) -> Result<Removed> {
    let mut removed = Removed::default();
    if let Some(path) = &state.worktree {
        let path = path.to_string_lossy();
        let mut args = vec!["worktree", "remove"];
        if discard { args.push("--force"); }
        args.push(&path);
        git(root, &args).await?;
        removed.worktree = state.worktree.clone();
    }
    git(root, &["worktree", "prune"]).await?;
    if let Some(branch) = state.branch.as_deref().filter(|_| state.branch_exists) {
        // Callers checked it is merged (`cherry`, which `branch -d` doesn't
        // understand for rebased merges) or chose to discard it.
        git(root, &["branch", "-D", branch]).await?;
        removed.branch = Some(branch.into());
    }
    Ok(removed)
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
                    self.run_due_resets();
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

    /// A thread's row in T3's shell, if T3 has sent it.
    pub fn thread_row(&self, id: &str) -> Option<Value> {
        self.thread(id)
    }

    /// The live T3 connection once its thread list has arrived.
    pub async fn connection(&self) -> Result<Arc<T3>> {
        self.ready().await
    }

    /// The squircle invocation agents are told to use.
    pub fn cli(&self) -> &str {
        &self.cli
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
        let agent = Agent { project_id: project_id.into(), thread_id, created_at: crate::model::now(), pending: None, refresh: false };
        let mut registry = self.registry.lock().unwrap();
        registry.agents.insert(project_id.into(), agent.clone());
        self.save(&registry)?;
        Ok(agent)
    }

    fn agent_for_thread(&self, thread_id: &str) -> Option<Agent> {
        self.registry.lock().unwrap().agents.values().find(|a| a.thread_id == thread_id).cloned()
    }

    // MARK: Restart and fresh start

    /// The agent named by its project or its thread.
    fn find_agent(&self, project_id: Option<&str>, thread_id: Option<&str>) -> Result<Agent> {
        let registry = self.registry.lock().unwrap();
        match (project_id, thread_id) {
            (Some(project), _) => registry.agents.get(project).cloned()
                .with_context(|| format!("The app {project} has no agent yet")),
            (None, Some(thread)) => registry.agents.values().find(|a| a.thread_id == thread).cloned()
                .with_context(|| format!("{thread} is not an app agent's thread")),
            (None, None) => bail!("Name the app (--project) or the agent's thread (--thread)"),
        }
    }

    /// Restarts or replaces an app's agent: now if it is between turns,
    /// otherwise as soon as its turn ends.
    pub async fn reset(self: &Arc<Self>, project_id: Option<&str>, thread_id: Option<&str>, reset: Reset) -> Result<Value> {
        self.ready().await?;
        let agent = self.find_agent(project_id, thread_id)?;
        let row = self.thread(&agent.thread_id).context("The app agent's thread is gone")?;
        let kind = match reset { Reset::Restart => "restart", Reset::Fresh { .. } => "fresh" };
        if worker_state(&row) == "working" {
            let mut registry = self.registry.lock().unwrap();
            if let Some(agent) = registry.agents.get_mut(&agent.project_id) {
                agent.pending = Some(reset);
            }
            self.save(&registry)?;
            return Ok(json!({"project_id": agent.project_id, "thread_id": agent.thread_id, "action": kind, "when": "after-turn",
                             "next": "Happens when the agent's current turn ends. If that is you: end your turn now, telling the user in a sentence."}));
        }
        self.perform(&agent, reset).await
    }

    /// Starts the resets whose agent turn has ended.
    fn run_due_resets(self: &Arc<Self>) {
        let due: Vec<(Agent, Reset)> = {
            let mut registry = self.registry.lock().unwrap();
            let shell = self.shell.lock().unwrap();
            if !shell.ready { return }
            let due: Vec<(Agent, Reset)> = registry.agents.values_mut().filter_map(|agent| {
                let row = shell.threads.get(&agent.thread_id)?;
                if agent.pending.is_none() || worker_state(row) == "working" { return None }
                let reset = agent.pending.take()?;
                Some((agent.clone(), reset))
            }).collect();
            if !due.is_empty() && let Err(error) = self.save(&registry) {
                eprintln!("Agent reset not saved: {error:#}");
            }
            due
        };
        for (agent, reset) in due {
            let this = self.clone();
            tokio::spawn(async move {
                if let Err(error) = this.perform(&agent, reset).await {
                    eprintln!("Agent reset failed: {error:#}");
                }
            });
        }
    }

    async fn perform(&self, agent: &Agent, reset: Reset) -> Result<Value> {
        let client = self.ready().await?;
        let row = self.thread(&agent.thread_id).context("The app agent's thread is gone")?;
        let stop = || client.dispatch(json!({"type": "thread.session.stop", "threadId": agent.thread_id}));
        let live = !row["session"].is_null() && row["session"]["status"] != "stopped";
        match reset {
            Reset::Restart => {
                if live { stop().await?; }
                {
                    let mut registry = self.registry.lock().unwrap();
                    if let Some(agent) = registry.agents.get_mut(&agent.project_id) { agent.refresh = true; }
                    self.save(&registry)?;
                }
                Ok(json!({"project_id": agent.project_id, "thread_id": agent.thread_id, "action": "restart", "when": "now",
                          "next": "The agent's next message starts a new session with the same history and gets the current instructions."}))
            }
            Reset::Fresh { note } => {
                let handoff = self.handoff(&client, agent, note.as_deref()).await?;
                if live { stop().await?; }
                let app = self.shell.lock().unwrap().projects.get(&agent.project_id)
                    .and_then(|p| p["title"].as_str().map(str::to_string)).unwrap_or_else(|| "App".into());
                let day = Command::new("date").arg("+%b %-d").output().await
                    .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default();
                client.dispatch(json!({"type": "thread.meta.update", "threadId": agent.thread_id,
                                       "title": format!("{app} agent (until {day})")})).await?;
                let model = row["modelSelection"]["model"].as_str().map(str::to_string);
                let new = self.create(&client, &agent.project_id, model.as_deref()).await?;
                {
                    let mut registry = self.registry.lock().unwrap();
                    for worker in registry.workers.values_mut().filter(|w| w.coordinator == agent.thread_id) {
                        worker.coordinator = new.thread_id.clone();
                    }
                    self.save(&registry)?;
                }
                let record = json!({"version": 1, "contextId": uuid::Uuid::new_v4().to_string(), "label": "Handoff",
                                    "kind": "squircle-handoff", "payload": {"previous": agent.thread_id}});
                self.wait_thread(&new.thread_id).await?;
                client.dispatch(json!({
                    "type": "thread.turn.start", "threadId": new.thread_id,
                    "message": {"messageId": uuid::Uuid::new_v4().to_string(), "role": "user", "text": handoff, "attachments": [],
                                "context": {"version": 1, "records": [record]}},
                    "runtimeMode": "full-access", "interactionMode": "default",
                })).await?;
                Ok(json!({"project_id": agent.project_id, "thread_id": new.thread_id, "previous_thread_id": agent.thread_id,
                          "action": "fresh", "when": "now",
                          "next": "The new agent has the handoff and is replying; the old conversation stays readable in the app's Threads."}))
            }
        }
    }

    /// What a new agent needs from the old one, gathered without a model:
    /// the app, recent commits, open workers, what the user said lately, the
    /// old agent's last reply and its own note.
    async fn handoff(&self, client: &T3, agent: &Agent, note: Option<&str>) -> Result<String> {
        let project = self.shell.lock().unwrap().projects.get(&agent.project_id).cloned().context("The app's T3 project is gone")?;
        let app = project["title"].as_str().unwrap_or("this app");
        let root = project["workspaceRoot"].as_str().map(PathBuf::from);
        let commits = match &root {
            Some(root) => git(root, &["log", "--oneline", "--no-decorate", "-8"]).await.unwrap_or_default(),
            None => String::new(),
        };
        let workers = self.workers(Some(&agent.thread_id));
        let workers = if workers.is_empty() { "none".to_string() } else {
            workers.iter().map(|w| format!("\n- {} ({})", w["title"].as_str().unwrap_or(""), w["state"].as_str().unwrap_or(""))).collect()
        };
        let old = self.thread_detail(client, &agent.thread_id).await?;
        let said: Vec<String> = old["messages"].as_array().into_iter().flatten()
            .filter(|m| m["role"] == "user" && m["context"]["records"].as_array().is_none_or(|r| r.is_empty()))
            .filter_map(|m| m["text"].as_str())
            .map(|t| t.split("\n\n---\n").next().unwrap_or(t).trim())
            .filter(|t| !t.is_empty() && !t.starts_with('['))
            .map(|t| if t.chars().count() > 300 { format!("{}…", t.chars().take(300).collect::<String>()) } else { t.to_string() })
            .collect();
        let said = said[said.len().saturating_sub(8)..].iter().map(|t| format!("\n- {}", t.replace('\n', " "))).collect::<String>();
        let mut text = format!(
            "[handoff] You are taking over as {app}'s app agent; the user started a fresh conversation. \
             The previous one stays readable in the app's Threads; `{cli} thread read {old}` gives its last reply.\n\n\
             Recent commits:\n{commits}\n\nYour workers: {workers}\n\nWhat the user said lately, oldest first:{said}",
            cli = self.cli, old = agent.thread_id,
            commits = if commits.is_empty() { "none".into() } else { commits },
            said = if said.is_empty() { "\nnothing".into() } else { said },
        );
        let last = old["messages"].as_array().into_iter().flatten().rev()
            .find(|m| m["role"] == "assistant").and_then(|m| m["text"].as_str()).unwrap_or("").trim();
        if !last.is_empty() {
            let last = if last.chars().count() > 1500 { format!("{}…", last.chars().take(1500).collect::<String>()) } else { last.to_string() };
            text += &format!("\n\nThe previous agent's last reply:\n{last}");
        }
        if let Some(note) = note.map(str::trim).filter(|n| !n.is_empty()) {
            text += &format!("\n\nThe previous agent's note:\n{note}");
        }
        text += "\n\nReply to the user in a sentence or two: you're ready, and what is open. Don't start work until they ask.";
        Ok(text)
    }

    /// The note at the start of each agent turn and after compaction: its
    /// role and reply style in brief (the system prompt has the rest), its
    /// thread ID (needed to spawn workers) and its workers right now.
    pub fn context(&self, cwd: &Path) -> String {
        let agents = self.list();
        let shell = self.shell.lock().unwrap();
        let found = agents.into_iter().find_map(|a| {
            let project = shell.projects.get(&a.project_id)?;
            let root = project["workspaceRoot"].as_str()?;
            (same_path(Path::new(root), cwd) || cwd.starts_with(root))
                .then(|| (a, project["title"].as_str().unwrap_or("this app").to_string()))
        });
        drop(shell);
        let Some((agent, app)) = found else {
            return "[squircle] No app agent works in this folder.".into();
        };
        // Claude keeps a resumed session's first system prompt; a restarted
        // agent gets the current one here, once.
        let refreshed = if agent.refresh {
            let mut registry = self.registry.lock().unwrap();
            if let Some(agent) = registry.agents.get_mut(&agent.project_id) { agent.refresh = false; }
            let _ = self.save(&registry);
            std::fs::read_to_string(self.root.join("plugin/squircle/agents/app-agent.md")).ok()
                .and_then(|t| t.splitn(3, "---\n").nth(2).map(|body| format!(
                    "\n[squircle] You were restarted. Your instructions are now the following; they replace any earlier version:\n{}", body.trim())))
                .unwrap_or_default()
        } else { String::new() };
        let workers = self.workers(Some(&agent.thread_id));
        let board = if workers.is_empty() {
            "none".to_string()
        } else {
            workers.iter().map(|w| format!("\n- {} [{}] {} ({})", w["title"].as_str().unwrap_or(""), w["branch"].as_str().unwrap_or(""),
                w["state"].as_str().unwrap_or(""), w["id"].as_str().unwrap_or(""))).collect()
        };
        format!(
            "[squircle] You are {app}'s app agent: you coordinate, and worker threads do the implementation \
             (`{cli} thread --help`), unless the user says otherwise; archive a worker once its work is merged or abandoned, \
             so no branches or worktrees are left behind. Your thread id: {id}. Your workers: {board}\n\
             Reply for a phone: short and conversational. Show pictures as ![..](/absolute/path) and clips as [..](/absolute/path), \
             copied out of /tmp into ~/.t3/userdata/attachments; a build you start or check this turn shows as an Install card. \
             No bare paths, IDs, branch names, commit hashes or Squircle internals unless asked.{refreshed}",
            cli = self.cli, id = agent.thread_id,
        )
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
            "{prompt}\n\n---\nYou are a worker for this app's agent, on branch {branch} in your own worktree. When done, commit on this branch and reply with a short summary. Remove anything else you create (scratch simulators, temp services or files) before you finish. \
             To run, check or demo the app in a simulator, first run {cli} sim start --thread {id} (see sim --help): Squircle records it, the user watches it live, and the recording appears in your turn. Drive it with the agent-device command it returns; run {cli} sim stop --thread {id} when done. Don't run agent-device record or device_open. \
             For signed builds: {cli} build start --help. \
             The user also reads your replies on their phone: keep them short and plain, show pictures as ![..](/absolute/path) and clips as [..](/absolute/path) \
             (copied out of /tmp into ~/.t3/userdata/attachments), and don't present bare paths or IDs as information.",
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

    /// Archives a worker: removes its worktree and deletes its branch. Refuses
    /// while the branch has commits not in its base or the worktree has
    /// uncommitted changes, unless `discard` drops them.
    pub async fn archive(&self, id: &str, discard: bool) -> Result<Value> {
        let client = self.ready().await?;
        let is_agent = self.registry.lock().unwrap().agents.values().any(|a| a.thread_id == id);
        ensure!(!is_agent, "That is an app agent's thread, not a worker");
        let thread = self.thread(id);
        let worker = self.registry.lock().unwrap().workers.get(id).cloned();
        ensure!(thread.is_some() || worker.is_some(), "T3 has no thread {id}");
        let row = thread.clone().unwrap_or(Value::Null);
        ensure!(discard || row.is_null() || worker_state(&row) != "working",
            "That worker is still working; wait for it, or pass --discard to stop tracking it and drop its work");
        let branch = worker.as_ref().map(|w| w.branch.clone()).or_else(|| row["branch"].as_str().map(str::to_string));
        let base = worker.as_ref().map(|w| w.base.clone());
        let project = worker.as_ref().map(|w| w.project_id.clone()).or_else(|| row["projectId"].as_str().map(str::to_string));
        let root = project.and_then(|p| self.shell.lock().unwrap().projects.get(&p).and_then(|p| p["workspaceRoot"].as_str().map(PathBuf::from)));
        let worktree = row["worktreePath"].as_str().map(PathBuf::from);
        let mut result = json!({"archived": id, "title": worker.as_ref().map(|w| w.title.clone()).or_else(|| row["title"].as_str().map(str::to_string))});
        if let Some(root) = &root {
            let base = match base {
                Some(base) => base,
                None => git(root, &["symbolic-ref", "--short", "HEAD"]).await?,
            };
            let state = inspect(root, worktree.as_deref(), branch.as_deref(), Some(&base)).await?;
            if let Some(reason) = state.blocker().filter(|_| !discard) {
                bail!("Not archived: {reason}. Merge it first, or pass --discard to drop that work");
            }
            let cleaned = remove(root, &state, discard).await?;
            result["removed_worktree"] = json!(cleaned.worktree);
            result["deleted_branch"] = json!(cleaned.branch);
            result["discarded"] = json!(discard && state.blocker().is_some());
        }
        if thread.is_some_and(|t| t["archivedAt"].is_null()) {
            client.dispatch(json!({"type": "thread.archive", "threadId": id})).await?;
        }
        let mut registry = self.registry.lock().unwrap();
        if let Some(worker) = registry.workers.get_mut(id) {
            worker.archived = true;
        }
        self.save(&registry)?;
        Ok(result)
    }

    /// Archives the coordinator's finished workers whose work is merged,
    /// deletes merged branches of workers archived earlier, prunes stale
    /// worktree entries, and reports what it leaves and why.
    pub async fn cleanup(&self, coordinator: &str, dry_run: bool) -> Result<Value> {
        self.ready().await?;
        let agent = self.agent_for_thread(coordinator)
            .with_context(|| format!("{coordinator} is not an app agent's thread"))?;
        let root = self.shell.lock().unwrap().projects.get(&agent.project_id)
            .and_then(|p| p["workspaceRoot"].as_str().map(PathBuf::from)).context("The app's T3 project is gone")?;
        let workers: Vec<(String, Worker)> = self.registry.lock().unwrap().workers.iter()
            .filter(|(_, w)| w.coordinator == coordinator).map(|(id, w)| (id.clone(), w.clone())).collect();
        let (mut archived, mut deleted, mut left) = (vec![], vec![], vec![]);
        for (id, worker) in workers {
            let row = self.thread(&id);
            let state = row.as_ref().map_or("missing", worker_state);
            let worktree = row.as_ref().and_then(|t| t["worktreePath"].as_str().map(PathBuf::from));
            let entry = json!({"id": id, "title": worker.title, "branch": worker.branch});
            if !worker.archived && matches!(state, "working" | "needs-you") {
                left.push(json!({"worker": entry, "reason": format!("still {state}")}));
                continue;
            }
            let git = inspect(&root, worktree.as_deref(), Some(&worker.branch), Some(&worker.base)).await?;
            if let Some(reason) = git.blocker() {
                left.push(json!({"worker": entry, "reason": reason}));
                continue;
            }
            if worker.archived {
                if git.branch_exists || git.worktree.is_some() {
                    if !dry_run { remove(&root, &git, false).await?; }
                    deleted.push(entry);
                }
            } else {
                if !dry_run { self.archive(&id, false).await?; }
                archived.push(entry);
            }
        }
        let pruned = git(&root, &["worktree", "prune", "--dry-run", "-v"]).await?;
        if !dry_run { git(&root, &["worktree", "prune"]).await?; }
        Ok(json!({
            "dry_run": dry_run, "archived": archived, "branches_deleted": deleted,
            "stale_worktrees_pruned": pruned.lines().filter(|l| !l.is_empty()).collect::<Vec<_>>(),
            "left": left,
        }))
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

    async fn run(dir: &Path, args: &[&str]) {
        git(dir, args).await.unwrap();
    }

    async fn commit(dir: &Path, file: &str) {
        std::fs::write(dir.join(file), file).unwrap();
        run(dir, &["add", file]).await;
        run(dir, &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", file]).await;
    }

    #[tokio::test]
    async fn archives_only_merged_clean_work() {
        let temp = tempfile::tempdir().unwrap();
        let root = &temp.path().join("repo");
        std::fs::create_dir(root).unwrap();
        run(root, &["init", "-q", "-b", "main"]).await;
        commit(root, "a").await;
        let tree = |name: &str| temp.path().join(name);
        for name in ["merged", "rebased", "open", "dirty"] {
            run(root, &["worktree", "add", "-q", "-b", name, tree(name).to_str().unwrap()]).await;
            commit(&tree(name), name).await;
        }
        // Fast-forward merge, and a rebase-style merge (same change, new commit).
        run(root, &["merge", "-q", "--ff-only", "merged"]).await;
        run(root, &["-c", "user.name=t", "-c", "user.email=t@t", "cherry-pick", "rebased"]).await;
        std::fs::write(tree("dirty").join("scratch"), "x").unwrap();

        let state = |name: &'static str| { let t = tree(name); async move { inspect(root, Some(&t), Some(name), Some("main")).await.unwrap() } };
        for name in ["merged", "rebased"] {
            let s = state(name).await;
            assert_eq!(s.blocker(), None, "{name}");
            remove(root, &s, false).await.unwrap();
            assert!(!tree(name).exists() && !state(name).await.branch_exists, "{name}");
        }
        assert_eq!(state("open").await.blocker().as_deref(), Some("1 commit not merged"));
        assert_eq!(state("dirty").await.blocker().as_deref(), Some("1 commit not merged and 1 uncommitted file"));
        // Discarding drops unmerged commits and uncommitted changes.
        remove(root, &state("dirty").await, true).await.unwrap();
        assert!(!tree("dirty").exists() && !state("dirty").await.branch_exists);
        // A branch already gone with no worktree leaves nothing to do.
        let gone = inspect(root, None, Some("merged"), Some("main")).await.unwrap();
        assert!(gone.blocker().is_none() && !gone.branch_exists && gone.worktree.is_none());
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
