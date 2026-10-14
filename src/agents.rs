//! One agent per app. The app agent is an ordinary T3 thread on Squircle's
//! own Claude instance (see `setup`), in the project's folder. It can run
//! ordinary T3 worker threads, each in its own worktree. Squircle adds only
//! what T3 lacks: who owns which worker, the agent's thread ID and workers at
//! the start of each turn, and a wake-up when a worker finishes or needs
//! input. How to work is up to the user and the agent. No model runs here.

use crate::store::{atomic_json, private_dir, read_json};
use crate::t3::{T3, T3Config};
use crate::tasks::{Source, Status, Tasks};
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
    /// Reserved before T3 is asked to create the thread, so a retry or a
    /// restart finishes that thread instead of creating a second agent.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub creating: bool,
    /// A restart or fresh start that has not finished yet: asked for
    /// mid-turn (an agent cannot stop its own session while it runs), or one
    /// that failed and is retried. Cleared only once it has succeeded.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending: Option<Reset>,
    /// A fresh start's progress, so a retry resumes with the same new thread.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replacing: Option<Replacement>,
    /// Why the pending reset last failed; it is retried.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reset_error: Option<String>,
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

/// A fresh start under way: the old thread has been stopped and renamed
/// once the handoff is gathered; the rest is retried with these identities.
#[derive(Clone, Serialize, Deserialize, PartialEq, Debug)]
pub struct Replacement {
    pub previous: String,
    pub thread_id: String,
    pub model: String,
    pub runtime_mode: String,
    pub handoff: String,
    pub message_id: String,
    /// The handoff was dispatched at least once; check before sending again.
    #[serde(default)]
    pub handoff_sent: bool,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Worker {
    pub coordinator: String,
    pub project_id: String,
    pub title: String,
    pub branch: String,
    pub base: String,
    pub created_at: u64,
    /// The last state its coordinator was told about (`turn:state`, plus the
    /// pending request for needs-you), so a restart neither repeats nor
    /// misses a wake-up.
    #[serde(default)]
    pub notified: Option<String>,
    #[serde(default)]
    pub archived: bool,
}

/// A worker update for one agent, recorded before it is sent so a lost
/// acknowledgement or a restart re-sends the same message, never a second.
#[derive(Clone, Serialize, Deserialize)]
pub struct Wake {
    pub coordinator: String,
    pub message_id: String,
    /// Worker ID and the wake key it delivers.
    pub workers: Vec<(String, String)>,
    pub text: String,
    pub record: Value,
    #[serde(default)]
    pub attempted: bool,
}

#[derive(Default, Serialize, Deserialize)]
pub struct Registry {
    #[serde(default)]
    pub agents: BTreeMap<String, Agent>,
    #[serde(default)]
    pub workers: BTreeMap<String, Worker>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub outbox: Vec<Wake>,
}

/// T3's runtime modes. A new app agent gets the one the user chose, or
/// `full-access`; a fresh start keeps its predecessor's.
const RUNTIME_MODES: [&str; 4] = ["approval-required", "auto-accept-edits", "auto", "full-access"];
const AGENT_MODE: &str = "full-access";

fn runtime_mode(mode: Option<&str>) -> Result<String> {
    let mode = mode.unwrap_or(AGENT_MODE);
    ensure!(RUNTIME_MODES.contains(&mode), "Unknown runtime mode \"{mode}\". Modes: {}", RUNTIME_MODES.join(", "));
    Ok(mode.into())
}

/// The part of T3 the agents use; a fake stands in for it in tests.
pub trait Peer: Send + Sync {
    fn call<'a>(&'a self, tag: &'a str, payload: Value) -> crate::push::BoxFuture<'a, Result<Value>>;
    fn dispatch<'a>(&'a self, command: Value) -> crate::push::BoxFuture<'a, Result<Value>>;
    fn snapshot<'a>(&'a self, tag: &'a str, payload: Value) -> crate::push::BoxFuture<'a, Result<Value>>;
}

impl Peer for T3 {
    fn call<'a>(&'a self, tag: &'a str, payload: Value) -> crate::push::BoxFuture<'a, Result<Value>> {
        Box::pin(T3::call(self, tag, payload))
    }
    fn dispatch<'a>(&'a self, command: Value) -> crate::push::BoxFuture<'a, Result<Value>> {
        Box::pin(T3::dispatch(self, command))
    }
    fn snapshot<'a>(&'a self, tag: &'a str, payload: Value) -> crate::push::BoxFuture<'a, Result<Value>> {
        Box::pin(T3::snapshot(self, tag, payload))
    }
}

/// Marks a message Squircle sends for an agent (`squircle-task`: a worker's
/// prompt; `squircle-agent-message`: `thread send`), with the agent's thread.
/// The app shows only unmarked user messages as the user's own.
fn agent_message(kind: &str, from: Option<&str>) -> Value {
    json!({"version": 1, "contextId": uuid::Uuid::new_v4().to_string(), "label": "Agent message",
           "kind": kind, "payload": {"from": from}})
}

/// A worker's runtime mode, and what T3 makes of it on the worker's provider
/// (its driver): the mode asked for, else its coordinator's. Claude, Codex,
/// Cursor and Grok each have an `auto` that runs unattended behind the
/// provider's own checks; Antigravity's would ask before everything, so an
/// inherited `auto` takes its auto-edit mode there. A worker that hits an
/// approval prompt waits as needs-you for the user.
fn worker_mode(driver: &str, coordinator: Option<&str>, requested: Option<&str>) -> Result<(String, &'static str)> {
    let mode = match requested {
        Some(mode) => runtime_mode(Some(mode))?,
        None => match runtime_mode(coordinator).unwrap_or_else(|_| AGENT_MODE.into()).as_str() {
            "auto" if driver == "antigravity" => "auto-accept-edits".into(),
            mode => mode.into(),
        },
    };
    let permissions = match (driver, mode.as_str()) {
        ("claudeAgent", "approval-required") => "Claude Code default: asks before edits and commands",
        ("claudeAgent", "auto-accept-edits") => "Claude Code acceptEdits: edits freely, asks before commands",
        ("claudeAgent", "auto") => "Claude Code auto: runs unattended; its safety checks block risky actions",
        ("codex", "approval-required") => "Codex read-only sandbox; asks before anything else",
        ("codex", "auto-accept-edits") => "Codex workspace-write sandbox; asks before leaving it",
        ("codex", "auto") => "Codex workspace-write sandbox; Codex's auto-reviewer decides on leaving it",
        ("codex", _) => "Codex without a sandbox; never asks",
        ("cursor", "auto") => "Cursor auto-review: runs unattended; its reviewer checks actions",
        ("grok", "auto") => "Grok auto: runs unattended behind its own checks",
        ("antigravity", "auto-accept-edits") => "Antigravity auto_edit: edits freely, asks before commands",
        ("opencode", "full-access") => "OpenCode: allows everything",
        ("opencode", _) => "OpenCode: asks before everything except reads",
        (_, "full-access") => "No checks; never asks",
        (_, "approval-required") => "Asks before edits and commands",
        _ => "Asks before some actions",
    };
    Ok((mode, permissions))
}

/// A worker's T3 model selection, checked against the providers T3 reports
/// ready. Claude by default, on the app agent's model; another provider
/// defaults to its own default model. Squircle's own instance carries the
/// app-agent plugin, so it is not offered to workers.
fn worker_selection(config: &Value, provider: Option<&str>, model: Option<&str>, effort: Option<&str>, agent_model: Option<&str>) -> Result<Value> {
    let ready: Vec<&Value> = config["providers"].as_array().into_iter().flatten()
        .filter(|p| p["status"] == "ready" && p["enabled"] != false && p["instanceId"] != INSTANCE)
        .collect();
    let names = |items: Vec<&str>| items.join(", ");
    let instance = provider.unwrap_or("claudeAgent");
    let provider = ready.iter().find(|p| p["instanceId"] == instance).with_context(|| format!(
        "T3 has no ready provider \"{instance}\". Ready: {}", names(ready.iter().filter_map(|p| p["instanceId"].as_str()).collect())))?;
    let models: Vec<&Value> = provider["models"].as_array().into_iter().flatten().collect();
    let model = model.map(str::to_string).or_else(|| match instance {
        "claudeAgent" => Some(agent_model.unwrap_or(DEFAULT_MODEL).to_string()),
        _ => models.iter().find(|m| m["isDefault"] == true).or(models.first()).and_then(|m| m["slug"].as_str()).map(str::to_string),
    }).with_context(|| format!("T3 lists no models for \"{instance}\""))?;
    let entry = models.iter().find(|m| m["slug"] == model.as_str()).with_context(|| format!(
        "\"{instance}\" has no model \"{model}\". Models: {}", names(models.iter().filter_map(|m| m["slug"].as_str()).collect())))?;
    let mut selection = json!({"instanceId": instance, "model": model});
    if let Some(effort) = effort {
        // Claude calls it "effort", Codex "reasoningEffort".
        let option = entry["capabilities"]["optionDescriptors"].as_array().into_iter().flatten()
            .find(|o| o["type"] == "select" && matches!(o["id"].as_str(), Some("effort" | "reasoningEffort")))
            .with_context(|| format!("{model} has no reasoning effort setting"))?;
        let levels: Vec<&str> = option["options"].as_array().into_iter().flatten().filter_map(|o| o["id"].as_str()).collect();
        ensure!(levels.contains(&effort), "{model} has no effort \"{effort}\". Levels: {}", names(levels));
        selection["options"] = json!([{"id": option["id"], "value": effort}]);
    }
    Ok(selection)
}

impl crate::push::Threads for Agents {
    fn last_reply<'a>(&'a self, thread: &'a str) -> crate::push::BoxFuture<'a, Option<String>> {
        Box::pin(async move {
            let client = self.client().await.ok()?;
            let detail = self.thread_detail(&*client, thread).await.ok()?;
            detail["messages"].as_array()?.iter().rev().find(|m| m["role"] == "assistant")
                .and_then(|m| m["text"].as_str()).map(str::to_string)
        })
    }
    fn question<'a>(&'a self, thread: &'a str) -> crate::push::BoxFuture<'a, Option<String>> {
        Box::pin(async move {
            let client = self.client().await.ok()?;
            let detail = self.thread_detail(&*client, thread).await.ok()?;
            let (_, questions) = Self::pending_question(&detail)?;
            questions.first()?["question"].as_str().map(str::to_string)
        })
    }
    fn current_step<'a>(&'a self, thread: &'a str) -> crate::push::BoxFuture<'a, Option<String>> {
        Box::pin(async move { crate::t3steps::current_step(thread).await.ok().flatten() })
    }
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

/// Whether the coordinator was already told about `key`. A needs-you key is
/// stored with its request (`turn:needs-you:request`), which T3's shell row
/// does not carry.
fn notified_of(notified: Option<&str>, key: &str) -> bool {
    notified.is_some_and(|n| n == key || n.strip_prefix(key).is_some_and(|rest| rest.starts_with(':')))
}

/// What to remember once a worker is working again: a question it was
/// waiting on has been answered, so the next one in the same turn is new.
fn progressed(notified: Option<&str>, thread: &Value) -> Option<String> {
    let turn = thread["latestTurn"]["turnId"].as_str()?;
    (worker_state(thread) == "working" && notified_of(notified, &format!("{turn}:needs-you")))
        .then(|| format!("{turn}:working"))
}

/// The newest unanswered question or approval request in a thread's detail.
fn pending_request(thread: &Value) -> Option<String> {
    let activities = thread["activities"].as_array()?;
    let resolved: Vec<&str> = activities.iter()
        .filter(|a| matches!(a["kind"].as_str(), Some("user-input.resolved" | "user-input.answer-submitted" | "approval.resolved")))
        .filter_map(|a| a["payload"]["requestId"].as_str()).collect();
    activities.iter().rev()
        .filter(|a| matches!(a["kind"].as_str(), Some("user-input.requested" | "approval.requested")))
        .filter_map(|a| a["payload"]["requestId"].as_str())
        .find(|r| !resolved.contains(r)).map(str::to_string)
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
    /// Stands in for T3 in tests.
    fake: std::sync::OnceLock<Arc<dyn Peer>>,
    flush_scheduled: Mutex<bool>,
    /// One flush at a time, so overlapping triggers cannot send twice.
    flush_lock: tokio::sync::Mutex<()>,
    flush_failures: Mutex<u32>,
    /// One operation at a time per project (create, reset) and per worker
    /// (archive), so concurrent requests see each other's result.
    ops: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
    /// Projects whose reset is running or waiting to retry.
    resets: Mutex<HashMap<String, u32>>,
    push: std::sync::OnceLock<Arc<crate::push::Push>>,
    tasks: Arc<Tasks>,
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

/// The project root that contains `cwd` most closely, comparing resolved
/// paths so symlinked aliases match. Two projects with the same root are
/// ambiguous: all of their indexes.
fn deepest_root(roots: &[&Path], cwd: &Path) -> std::result::Result<Option<usize>, Vec<usize>> {
    let resolve = |p: &Path| p.canonicalize().unwrap_or_else(|_| p.to_path_buf());
    let cwd = resolve(cwd);
    let mut matches: Vec<(usize, usize)> = roots.iter().enumerate()
        .map(|(index, root)| (index, resolve(root)))
        .filter(|(_, root)| cwd.starts_with(root))
        .map(|(index, root)| (index, root.components().count())).collect();
    matches.sort_by_key(|(_, depth)| std::cmp::Reverse(*depth));
    match matches.as_slice() {
        [] => Ok(None),
        [(index, depth), rest @ ..] if rest.first().is_none_or(|(_, d)| d < depth) => Ok(Some(*index)),
        [(_, depth), ..] => Err(matches.iter().filter(|(_, d)| d == depth).map(|(i, _)| *i).collect()),
    }
}

/// A worker's branch and worktree as git sees them.
#[derive(Debug, Default)]
struct GitState {
    branch: Option<String>,
    branch_exists: bool,
    /// The branch tip that was checked; deletion refuses a branch that moved.
    tip: Option<String>,
    /// Commits on the branch whose work is not known to be in its base:
    /// none if the base contains the tip; otherwise `git cherry`'s unmatched
    /// commits (so rebased or cherry-picked merges count as merged) plus
    /// every merge commit, whose resolution `cherry` cannot compare.
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
    state.tip = git(root, &["rev-parse", "--verify", "--quiet", &format!("refs/heads/{branch}^{{commit}}")]).await.ok();
    state.branch_exists = state.tip.is_some();
    if let Some(tip) = &state.tip {
        let base = base.context("The worker has no base branch to compare with")?;
        ensure!(base != branch, "The worker's branch is its base");
        let contained = Command::new("git").arg("-C").arg(root).args(["merge-base", "--is-ancestor", tip, base])
            .status().await?.success();
        if !contained {
            let compare = |args: Vec<String>| async move {
                git(root, &args.iter().map(String::as_str).collect::<Vec<_>>()).await
                    .with_context(|| format!("Cannot compare {branch} with {base}"))
            };
            let picked = compare(vec!["cherry".into(), base.into(), tip.clone()]).await?
                .lines().filter(|l| l.starts_with('+')).count();
            let merges = compare(vec!["rev-list".into(), "--merges".into(), "--count".into(), format!("{base}..{tip}")]).await?
                .parse::<usize>().unwrap_or(1);
            state.unmerged = picked + merges;
        }
    }
    Ok(state)
}

#[derive(Default)]
struct Removed {
    worktree: Option<PathBuf>,
    branch: Option<String>,
}

/// Removes what `inspect` found. Without `discard`, git itself refuses to
/// drop uncommitted changes, and the branch is deleted only at the tip that
/// was checked (`branch -D` also refuses one checked out elsewhere).
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
    if let (Some(branch), Some(tip)) = (state.branch.as_deref(), state.tip.as_deref()) {
        let now = git(root, &["rev-parse", "--verify", "--quiet", &format!("refs/heads/{branch}^{{commit}}")]).await.ok();
        if now.is_some() {
            ensure!(now.as_deref() == Some(tip), "{branch} moved while it was being archived; nothing more was deleted");
            // `inspect` checked it is merged (`branch -d` doesn't understand
            // rebased merges) or the caller chose to discard it.
            git(root, &["branch", "-D", branch]).await?;
            removed.branch = Some(branch.into());
        }
    }
    Ok(removed)
}

impl Agents {
    pub fn open(root: &Path, server: &str, tasks: Arc<Tasks>) -> Result<Arc<Self>> {
        let path = root.join("agents.json");
        let registry = if path.try_exists()? { read_json(&path)? } else { Registry::default() };
        Ok(Arc::new(Self {
            root: root.to_path_buf(),
            cli: cli_invocation(root, server),
            registry: Mutex::new(registry),
            shell: Mutex::default(),
            t3: RwLock::new(None),
            status: Mutex::new("Not connected to T3".into()),
            fake: std::sync::OnceLock::new(),
            flush_scheduled: Mutex::new(false),
            flush_lock: tokio::sync::Mutex::new(()),
            flush_failures: Mutex::new(0),
            ops: Mutex::default(),
            resets: Mutex::default(),
            push: std::sync::OnceLock::new(),
            tasks,
        }))
    }

    fn save(&self, registry: &Registry) -> Result<()> {
        atomic_json(&self.root.join("agents.json"), registry)
    }

    async fn client(&self) -> Result<Arc<dyn Peer>> {
        if let Some(fake) = self.fake.get() {
            return Ok(fake.clone());
        }
        if let Some(client) = self.t3.read().await.clone() {
            return Ok(client);
        }
        bail!("{}", self.status.lock().unwrap())
    }

    /// Holds the operation lock for a project or worker.
    async fn op(&self, key: &str) -> tokio::sync::OwnedMutexGuard<()> {
        let lock = self.ops.lock().unwrap().entry(key.into()).or_default().clone();
        lock.lock_owned().await
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
                    self.note_progress();
                    if let Some(push) = self.push.get() { push.apps_changed(self.app_views()); }
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

    /// Notifications and Live Activities follow the agents from here on.
    pub fn attach_push(self: &Arc<Self>, push: Arc<crate::push::Push>) {
        push.set_threads(self.clone());
        let _ = self.push.set(push);
    }

    /// Each app's agent and live workers, for notifications.
    fn app_views(&self) -> Vec<crate::push::AppView> {
        let registry = self.registry.lock().unwrap();
        let shell = self.shell.lock().unwrap();
        registry.agents.values().map(|agent| crate::push::AppView {
            project_id: agent.project_id.clone(),
            app: shell.projects.get(&agent.project_id).and_then(|p| p["title"].as_str()).unwrap_or("App").to_string(),
            agent: shell.threads.get(&agent.thread_id).map(|row| (agent.thread_id.clone(), row.clone())),
            workers: registry.workers.iter()
                .filter(|(_, w)| !w.archived && w.coordinator == agent.thread_id)
                .filter_map(|(id, w)| Some((id.clone(), w.title.clone(), shell.threads.get(id)?.clone())))
                .collect(),
        }).collect()
    }

    /// A thread's row in T3's shell, if T3 has sent it.
    pub fn thread_row(&self, id: &str) -> Option<Value> {
        self.thread(id)
    }

    /// The T3 project a thread belongs to: an app agent's, a worker's, or
    /// any thread T3 has sent.
    pub fn project_of(&self, thread: &str) -> Option<String> {
        {
            let registry = self.registry.lock().unwrap();
            if let Some(agent) = registry.agents.values().find(|a| a.thread_id == thread) {
                return Some(agent.project_id.clone());
            }
            if let Some(worker) = registry.workers.get(thread) {
                return Some(worker.project_id.clone());
            }
        }
        self.thread(thread).and_then(|t| t["projectId"].as_str().map(str::to_string))
    }

    /// A worker's title, even once T3 has archived its thread.
    pub fn worker_title(&self, id: &str) -> Option<String> {
        self.registry.lock().unwrap().workers.get(id).map(|w| w.title.clone())
    }

    /// The user's latest message to an app agent: where a task it adds now
    /// came from.
    pub async fn source_message(&self, thread: &str) -> Option<Source> {
        self.agent_for_thread(thread)?;
        let client = self.ready().await.ok()?;
        let detail = self.thread_detail(&*client, thread).await.ok()?;
        detail["messages"].as_array()?.iter().rev()
            .find(|m| m["role"] == "user" && m["context"]["records"].as_array().is_none_or(|r| r.is_empty())
                && !m["text"].as_str().unwrap_or("").starts_with('['))
            .and_then(|m| m["id"].as_str().or(m["messageId"].as_str()))
            .map(|id| Source { thread_id: thread.into(), message_id: id.into() })
    }

    /// The live T3 connection once its thread list has arrived.
    pub async fn connection(&self) -> Result<Arc<T3>> {
        self.ready().await?;
        self.t3.read().await.clone().with_context(|| self.status())
    }

    /// The squircle invocation agents are told to use.
    pub fn cli(&self) -> &str {
        &self.cli
    }

    async fn ready(&self) -> Result<Arc<dyn Peer>> {
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
        self.schedule_flush_in(Duration::from_secs(4));
    }

    /// A failed flush retries with backoff even if T3 sends nothing new.
    fn schedule_flush_in(self: &Arc<Self>, delay: Duration) {
        let mut scheduled = self.flush_scheduled.lock().unwrap();
        if *scheduled || !self.has_due_wakes() {
            return;
        }
        *scheduled = true;
        let this = self.clone();
        tokio::spawn(async move {
            tokio::time::sleep(delay).await;
            *this.flush_scheduled.lock().unwrap() = false;
            match this.flush().await {
                Ok(()) => *this.flush_failures.lock().unwrap() = 0,
                Err(error) => {
                    eprintln!("Wake-up not delivered: {error:#}");
                    let failures = {
                        let mut failures = this.flush_failures.lock().unwrap();
                        *failures = (*failures + 1).min(6);
                        *failures
                    };
                    this.schedule_flush_in(Duration::from_secs(4 << failures));
                }
            }
        });
    }

    /// Remembers that a worker which waited on a question is working again.
    fn note_progress(&self) {
        let mut registry = self.registry.lock().unwrap();
        let changed: Vec<(String, String)> = {
            let shell = self.shell.lock().unwrap();
            registry.workers.iter().filter(|(_, w)| !w.archived)
                .filter_map(|(id, w)| Some((id.clone(), progressed(w.notified.as_deref(), shell.threads.get(id)?)?)))
                .collect()
        };
        if changed.is_empty() { return }
        for (id, key) in changed {
            if let Some(worker) = registry.workers.get_mut(&id) { worker.notified = Some(key); }
        }
        if let Err(error) = self.save(&registry) {
            eprintln!("Worker state not saved: {error:#}");
        }
    }

    /// Workers whose state calls for a wake-up their coordinator has not had
    /// and that is not already queued.
    fn due_wakes(&self) -> Vec<(String, Worker, String, &'static str)> {
        let registry = self.registry.lock().unwrap();
        let shell = self.shell.lock().unwrap();
        if !shell.ready {
            return vec![];
        }
        registry.workers.iter().filter(|(_, w)| !w.archived).filter_map(|(id, worker)| {
            let thread = shell.threads.get(id)?;
            let key = wake_key(thread)?;
            let queued = registry.outbox.iter().any(|w| w.workers.iter().any(|(queued, _)| queued == id));
            (!queued && !notified_of(worker.notified.as_deref(), &key))
                .then(|| (id.clone(), worker.clone(), key, worker_state(thread)))
        }).collect()
    }

    fn has_due_wakes(&self) -> bool {
        !self.registry.lock().unwrap().outbox.is_empty() || !self.due_wakes().is_empty()
    }

    /// Queues the due wake-ups, then delivers the queue in order. Each queued
    /// update keeps its message ID: after an unanswered or failed dispatch,
    /// the agent's thread is checked for it before it is sent again.
    async fn flush(&self) -> Result<()> {
        let _flushing = self.flush_lock.lock().await;
        let client = self.client().await?;
        let mut due = vec![];
        for (id, worker, key, state) in self.due_wakes() {
            // A question's request tells this one from an earlier one in the turn.
            let key = if state == "needs-you" {
                let detail = self.thread_detail(&*client, &id).await?;
                match pending_request(&detail) { Some(request) => format!("{key}:{request}"), None => key }
            } else { key };
            if worker.notified.as_deref() != Some(key.as_str()) {
                due.push((id, worker, key, state));
            }
        }
        self.queue(due)?;
        let outbox = self.registry.lock().unwrap().outbox.clone();
        for wake in outbox {
            let Some(agent) = self.thread(&wake.coordinator) else {
                // Its agent is gone; nobody is left to tell.
                self.delivered(&wake)?;
                continue;
            };
            if wake.attempted && self.has_message(&*client, &wake.coordinator, &wake.message_id).await? {
                self.delivered(&wake)?;
                continue;
            }
            {
                let mut registry = self.registry.lock().unwrap();
                if let Some(queued) = registry.outbox.iter_mut().find(|w| w.message_id == wake.message_id) { queued.attempted = true; }
                self.save(&registry)?;
            }
            client.dispatch(json!({
                "type": "thread.turn.start", "threadId": wake.coordinator,
                "message": {"messageId": wake.message_id, "role": "user", "text": wake.text, "attachments": [],
                            "context": {"version": 1, "records": [wake.record]}},
                "runtimeMode": agent["runtimeMode"].as_str().unwrap_or(AGENT_MODE),
                "interactionMode": "default",
            })).await?;
            self.delivered(&wake)?;
        }
        Ok(())
    }

    /// Records one update per coordinator for the given wake-ups.
    fn queue(&self, due: Vec<(String, Worker, String, &'static str)>) -> Result<()> {
        if due.is_empty() { return Ok(()) }
        let mut by_coordinator: BTreeMap<String, Vec<(String, Worker, String, &'static str)>> = BTreeMap::new();
        for due in due {
            by_coordinator.entry(due.1.coordinator.clone()).or_default().push(due);
        }
        let mut registry = self.registry.lock().unwrap();
        for (coordinator, notes) in by_coordinator {
            let lines: Vec<String> = notes.iter().map(|(id, w, _, state)| {
                let what = match *state {
                    "needs-you" => "is waiting on a question or approval",
                    "error" => "stopped with an error",
                    _ => "finished its turn",
                };
                format!("- \"{}\" ({id}, {}) {what}.", w.title, w.branch)
            }).collect();
            registry.outbox.push(Wake {
                coordinator,
                message_id: uuid::Uuid::new_v4().to_string(),
                workers: notes.iter().map(|(id, _, key, _)| (id.clone(), key.clone())).collect(),
                text: format!("[worker update]\n{}\nRun `squircle thread read ID` for details, then decide what to do next.", lines.join("\n")),
                record: json!({
                    "version": 1, "contextId": uuid::Uuid::new_v4().to_string(), "label": "Worker update",
                    "kind": "squircle-worker-update",
                    "payload": {"workers": notes.iter().map(|(id, w, _, state)| json!({"id": id, "title": w.title, "branch": w.branch, "state": state})).collect::<Vec<_>>()}
                }),
                attempted: false,
            });
        }
        self.save(&registry)
    }

    fn delivered(&self, wake: &Wake) -> Result<()> {
        let mut registry = self.registry.lock().unwrap();
        for (id, key) in &wake.workers {
            if let Some(worker) = registry.workers.get_mut(id) { worker.notified = Some(key.clone()); }
        }
        registry.outbox.retain(|w| w.message_id != wake.message_id);
        self.save(&registry)
    }

    /// Whether T3 has a message with this ID in the thread.
    async fn has_message(&self, client: &dyn Peer, thread: &str, message: &str) -> Result<bool> {
        let detail = self.thread_detail(client, thread).await?;
        Ok(detail["messages"].as_array().into_iter().flatten()
            .any(|m| m["id"] == message || m["messageId"] == message))
    }

    // MARK: Agents

    pub fn list(&self) -> Vec<Agent> {
        self.registry.lock().unwrap().agents.values().cloned().collect()
    }

    /// The app agent for a T3 project, created on first use: a thread on
    /// Squircle's instance in the project's folder, in `runtime_mode` (the
    /// mode of an existing agent is the phone's to change on its thread).
    pub async fn ensure(&self, project_id: &str, message: Option<&str>, model: Option<&str>, runtime_mode: Option<&str>) -> Result<Agent> {
        let mode = self::runtime_mode(runtime_mode)?;
        let client = self.ready().await?;
        let agent = {
            let _op = self.op(project_id).await;
            self.existing_or_create(&*client, project_id, model, &mode).await?
        };
        if let Some(text) = message.filter(|t| !t.trim().is_empty()) {
            self.send(&agent.thread_id, text).await?;
        }
        Ok(agent)
    }

    /// Call with the project's operation lock held.
    async fn existing_or_create(&self, client: &dyn Peer, project_id: &str, model: Option<&str>, mode: &str) -> Result<Agent> {
        let Some(agent) = self.registry.lock().unwrap().agents.get(project_id).cloned() else {
            return self.create(client, project_id, model, mode).await;
        };
        if agent.replacing.is_some() {
            return Ok(agent);
        }
        // A thread T3 has not sent yet may just be new: wait for it a moment
        // (a reservation is finished below instead).
        let row = match self.thread(&agent.thread_id) {
            None if !agent.creating => self.wait_thread(&agent.thread_id).await.ok(),
            row => row,
        };
        match row {
            Some(row) if row["archivedAt"].is_null() => {
                if agent.creating { self.created(project_id)?; }
                Ok(agent)
            }
            // A reservation whose creation may not have reached T3: finish it
            // under the same thread ID rather than starting another agent.
            None if agent.creating => {
                let dispatched = self.create_thread(client, project_id, &agent.thread_id, model, mode).await;
                if self.wait_thread(&agent.thread_id).await.is_err() {
                    dispatched?;
                    bail!("T3 has not created the app agent's thread yet; try again");
                }
                self.created(project_id)?;
                Ok(agent)
            }
            // Archived or deleted in T3: start a new agent.
            _ => self.create(client, project_id, model, mode).await,
        }
    }

    /// Reserves the new agent in the registry, then has T3 create its thread.
    async fn create(&self, client: &dyn Peer, project_id: &str, model: Option<&str>, mode: &str) -> Result<Agent> {
        let config = client.call("server.getConfig", json!({})).await?;
        let ready = config["providers"].as_array().into_iter().flatten()
            .any(|p| p["instanceId"] == INSTANCE && p["status"] == "ready");
        ensure!(ready, "T3 has no ready \"{INSTANCE}\" agent instance. Run: squircle agent setup");
        let agent = Agent {
            project_id: project_id.into(), thread_id: uuid::Uuid::new_v4().to_string(), created_at: crate::model::now(),
            creating: true, pending: None, replacing: None, reset_error: None, refresh: false,
        };
        {
            let mut registry = self.registry.lock().unwrap();
            registry.agents.insert(project_id.into(), agent.clone());
            self.save(&registry)?;
        }
        self.create_thread(client, project_id, &agent.thread_id, model, mode).await?;
        self.wait_thread(&agent.thread_id).await?;
        self.created(project_id)?;
        Ok(Agent { creating: false, ..agent })
    }

    async fn create_thread(&self, client: &dyn Peer, project_id: &str, thread_id: &str, model: Option<&str>, mode: &str) -> Result<()> {
        let project = self.shell.lock().unwrap().projects.get(project_id).cloned()
            .with_context(|| format!("T3 has no project {project_id}"))?;
        let model = model.map(str::to_string)
            .or_else(|| project["defaultModelSelection"]["model"].as_str().filter(|_| project["defaultModelSelection"]["instanceId"] == "claudeAgent").map(str::to_string))
            .unwrap_or_else(|| DEFAULT_MODEL.into());
        let name = project["title"].as_str().unwrap_or("App");
        client.dispatch(json!({
            "type": "thread.create", "threadId": thread_id, "projectId": project_id,
            "title": format!("{name} agent"),
            "modelSelection": {"instanceId": INSTANCE, "model": model},
            "runtimeMode": mode, "interactionMode": "default",
            "branch": null, "worktreePath": null,
        })).await?;
        Ok(())
    }

    fn created(&self, project_id: &str) -> Result<()> {
        let mut registry = self.registry.lock().unwrap();
        if let Some(agent) = registry.agents.get_mut(project_id) { agent.creating = false; }
        self.save(&registry)
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
    /// otherwise as soon as its turn ends. The request is saved first and
    /// cleared only once it succeeds; a failure is retried and shows as the
    /// agent's `reset_error`.
    pub async fn reset(self: &Arc<Self>, project_id: Option<&str>, thread_id: Option<&str>, reset: Reset) -> Result<Value> {
        self.ready().await?;
        let project = self.find_agent(project_id, thread_id)?.project_id;
        let _op = self.op(&project).await;
        let agent = self.find_agent(Some(&project), None)?;
        ensure!(agent.replacing.is_none(), "A fresh start of this agent is already under way");
        let row = self.thread(&agent.thread_id).context("The app agent's thread is gone")?;
        let kind = match reset { Reset::Restart => "restart", Reset::Fresh { .. } => "fresh" };
        {
            let mut registry = self.registry.lock().unwrap();
            if let Some(agent) = registry.agents.get_mut(&project) {
                agent.pending = Some(reset);
                agent.reset_error = None;
            }
            self.save(&registry)?;
        }
        if worker_state(&row) == "working" {
            return Ok(json!({"project_id": agent.project_id, "thread_id": agent.thread_id, "action": kind, "when": "after-turn",
                             "next": "Happens when the agent's current turn ends. If that is you: end your turn now, telling the user in a sentence."}));
        }
        self.resets.lock().unwrap().insert(project.clone(), 0);
        let result = self.perform(&project).await;
        self.reset_finished(&project, &result);
        result
    }

    /// Starts the resets whose agent turn has ended, and resumes interrupted ones.
    fn run_due_resets(self: &Arc<Self>) {
        let due: Vec<String> = {
            let registry = self.registry.lock().unwrap();
            let shell = self.shell.lock().unwrap();
            if !shell.ready { return }
            let mut running = self.resets.lock().unwrap();
            let due: Vec<String> = registry.agents.values().filter(|agent| {
                agent.pending.is_some() && !running.contains_key(&agent.project_id)
                    && (agent.replacing.is_some() || shell.threads.get(&agent.thread_id).is_some_and(|row| worker_state(row) != "working"))
            }).map(|a| a.project_id.clone()).collect();
            for project in &due { running.insert(project.clone(), 0); }
            due
        };
        for project in due {
            self.clone().spawn_reset(project, Duration::ZERO);
        }
    }

    fn spawn_reset(self: Arc<Self>, project: String, delay: Duration) {
        tokio::spawn(async move {
            tokio::time::sleep(delay).await;
            let result = {
                let _op = self.op(&project).await;
                self.perform(&project).await
            };
            if let Err(error) = &result {
                eprintln!("Agent reset failed: {error:#}");
            }
            self.reset_finished(&project, &result);
        });
    }

    /// Records the outcome; a failure keeps the request and retries it with
    /// backoff, without waiting for T3 to send anything.
    fn reset_finished(self: &Arc<Self>, project: &str, result: &Result<Value>) {
        let mut registry = self.registry.lock().unwrap();
        let Some(agent) = registry.agents.get_mut(project) else { return };
        let error = result.as_ref().err().map(|e| format!("{e:#}"));
        if agent.reset_error != error && agent.pending.is_some() {
            agent.reset_error = error;
            let _ = self.save(&registry);
        }
        let retry = registry.agents.get(project).is_some_and(|a| a.pending.is_some());
        drop(registry);
        let mut running = self.resets.lock().unwrap();
        if retry && result.is_err() {
            let failures = running.entry(project.into()).or_default();
            *failures = (*failures + 1).min(6);
            let delay = Duration::from_secs(4 << *failures);
            drop(running);
            self.clone().spawn_reset(project.into(), delay);
        } else {
            running.remove(project);
        }
    }

    /// Carries out the project's pending reset. Call with its operation lock.
    async fn perform(&self, project: &str) -> Result<Value> {
        let client = self.ready().await?;
        let agent = self.find_agent(Some(project), None)?;
        let Some(reset) = agent.pending.clone() else {
            return Ok(json!({"project_id": project, "thread_id": agent.thread_id, "when": "done"}));
        };
        let stop = |thread: &str| client.dispatch(json!({"type": "thread.session.stop", "threadId": thread}));
        let live = |row: &Value| !row["session"].is_null() && row["session"]["status"] != "stopped";
        match reset {
            Reset::Restart => {
                let row = self.thread(&agent.thread_id).context("The app agent's thread is gone")?;
                if live(&row) { stop(&agent.thread_id).await?; }
                self.update_agent(project, |a| { a.refresh = true; a.pending = None; a.reset_error = None; })?;
                Ok(json!({"project_id": project, "thread_id": agent.thread_id, "action": "restart", "when": "now",
                          "next": "The agent's next message starts a new session with the same history and gets the current instructions."}))
            }
            Reset::Fresh { note } => {
                let mut plan = match agent.replacing.clone() {
                    Some(plan) => plan,
                    None => {
                        let row = self.thread(&agent.thread_id).context("The app agent's thread is gone")?;
                        let handoff = self.handoff(&*client, &agent, note.as_deref()).await?;
                        if live(&row) { stop(&agent.thread_id).await?; }
                        let app = self.shell.lock().unwrap().projects.get(project)
                            .and_then(|p| p["title"].as_str().map(str::to_string)).unwrap_or_else(|| "App".into());
                        let day = Command::new("date").arg("+%b %-d").output().await
                            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default();
                        client.dispatch(json!({"type": "thread.meta.update", "threadId": agent.thread_id,
                                               "title": format!("{app} agent (until {day})")})).await?;
                        let plan = Replacement {
                            previous: agent.thread_id.clone(),
                            thread_id: uuid::Uuid::new_v4().to_string(),
                            model: row["modelSelection"]["model"].as_str().unwrap_or(DEFAULT_MODEL).into(),
                            runtime_mode: runtime_mode(row["runtimeMode"].as_str()).unwrap_or_else(|_| AGENT_MODE.into()),
                            handoff,
                            message_id: uuid::Uuid::new_v4().to_string(),
                            handoff_sent: false,
                        };
                        self.update_agent(project, |a| a.replacing = Some(plan.clone()))?;
                        plan
                    }
                };
                if self.thread(&plan.thread_id).is_none() {
                    let dispatched = self.create_thread(&*client, project, &plan.thread_id, Some(&plan.model), &plan.runtime_mode).await;
                    if self.wait_thread(&plan.thread_id).await.is_err() {
                        dispatched?;
                        bail!("T3 has not created the new agent thread yet");
                    }
                }
                {
                    let mut registry = self.registry.lock().unwrap();
                    for worker in registry.workers.values_mut().filter(|w| w.coordinator == plan.previous) {
                        worker.coordinator = plan.thread_id.clone();
                    }
                    for wake in registry.outbox.iter_mut().filter(|w| w.coordinator == plan.previous && !w.attempted) {
                        wake.coordinator = plan.thread_id.clone();
                    }
                    if let Some(agent) = registry.agents.get_mut(project) { agent.thread_id = plan.thread_id.clone(); }
                    self.save(&registry)?;
                }
                if !(plan.handoff_sent && self.has_message(&*client, &plan.thread_id, &plan.message_id).await?) {
                    plan.handoff_sent = true;
                    self.update_agent(project, |a| a.replacing = Some(plan.clone()))?;
                    let record = json!({"version": 1, "contextId": uuid::Uuid::new_v4().to_string(), "label": "Handoff",
                                        "kind": "squircle-handoff", "payload": {"previous": plan.previous}});
                    client.dispatch(json!({
                        "type": "thread.turn.start", "threadId": plan.thread_id,
                        "message": {"messageId": plan.message_id, "role": "user", "text": plan.handoff, "attachments": [],
                                    "context": {"version": 1, "records": [record]}},
                        "runtimeMode": plan.runtime_mode, "interactionMode": "default",
                    })).await?;
                }
                self.update_agent(project, |a| { a.pending = None; a.replacing = None; a.reset_error = None; })?;
                Ok(json!({"project_id": project, "thread_id": plan.thread_id, "previous_thread_id": plan.previous,
                          "action": "fresh", "when": "now",
                          "next": "The new agent has the handoff and is replying; the old conversation stays readable in the app's Threads."}))
            }
        }
    }

    fn update_agent(&self, project: &str, change: impl FnOnce(&mut Agent)) -> Result<()> {
        let mut registry = self.registry.lock().unwrap();
        if let Some(agent) = registry.agents.get_mut(project) { change(agent); }
        self.save(&registry)
    }

    /// What a new agent needs from the old one, gathered without a model:
    /// the app, recent commits, open workers, what the user said lately, the
    /// old agent's last reply and its own note.
    async fn handoff(&self, client: &dyn Peer, agent: &Agent, note: Option<&str>) -> Result<String> {
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
        let candidates: Vec<(Agent, String, PathBuf)> = {
            let agents = self.list();
            let shell = self.shell.lock().unwrap();
            agents.into_iter().filter_map(|a| {
                let project = shell.projects.get(&a.project_id)?;
                let root = PathBuf::from(project["workspaceRoot"].as_str()?);
                Some((a, project["title"].as_str().unwrap_or("this app").to_string(), root))
            }).collect()
        };
        let roots: Vec<&Path> = candidates.iter().map(|(_, _, root)| root.as_path()).collect();
        let (agent, app) = match deepest_root(&roots, cwd) {
            Ok(Some(index)) => (candidates[index].0.clone(), candidates[index].1.clone()),
            Ok(None) => return "[squircle] No app agent works in this folder.".into(),
            Err(tied) => return format!("[squircle] Several app agents work in this folder ({}); worker commands need the right thread ID.",
                tied.iter().map(|i| candidates[*i].1.as_str()).collect::<Vec<_>>().join(", ")),
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
        let mut open: Vec<_> = self.tasks.list(&agent.project_id).into_iter()
            .filter(|t| t.archived_at.is_none() && t.status.open()).collect();
        let rank = |s: Status| [Status::NeedsYou, Status::InProgress, Status::ReadyToTry, Status::Queued].iter().position(|x| *x == s);
        open.sort_by(|a, b| rank(a.status).cmp(&rank(b.status)).then(a.order.total_cmp(&b.order)));
        let tasks = if open.is_empty() { " none".to_string() } else {
            open.iter().take(40).map(|t| format!("\n- [{}] {}{} ({})", t.status.label(), t.ask.replace('\n', " "),
                if t.note.is_empty() { String::new() } else { format!(" — {}", t.note) }, t.id)).collect()
        };
        format!(
            "[squircle] You are {app}'s app agent: you coordinate, and worker threads do the implementation \
             (`{cli} thread --help`), unless the user says otherwise; archive a worker once its work is merged or abandoned, \
             so no branches or worktrees are left behind. Your thread id: {id}. Your workers: {board}\n\
             Your tasks, the user's open asks (`{cli} task --help`):{tasks}\n\
             Add a task for each new ask, in the user's words; link its workers (`thread spawn --task`) and builds (`build start --task`), \
             attach screenshots or clips worth seeing, and set its status and note when that changes (linked workers and builds move it too).\n\
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

    /// Every worker Squircle started, archived ones too, so a conversation
    /// can name the workers its agent talked to.
    pub fn all_workers(&self) -> Vec<Value> {
        let registry = self.registry.lock().unwrap();
        let shell = self.shell.lock().unwrap();
        registry.workers.iter().map(|(id, w)| {
            let state = if w.archived { "archived" } else { shell.threads.get(id).map_or("missing", worker_state) };
            json!({"id": id, "title": w.title, "branch": w.branch, "state": state})
        }).collect()
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn spawn(&self, coordinator: &str, title: &str, branch: &str, base: Option<&str>, prompt: &str,
                       provider: Option<&str>, model: Option<&str>, effort: Option<&str>, runtime_mode: Option<&str>) -> Result<Value> {
        let client = self.ready().await?;
        let agent = self.agent_for_thread(coordinator)
            .with_context(|| format!("{coordinator} is not an app agent's thread"))?;
        ensure!(!title.trim().is_empty() && !prompt.trim().is_empty(), "A worker needs a title and a prompt");
        ensure!(!branch.is_empty() && !branch.contains(char::is_whitespace) && !branch.contains(".."), "Invalid branch name");
        let project = self.shell.lock().unwrap().projects.get(&agent.project_id).cloned().context("The app's T3 project is gone")?;
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
             To run, check or demo the app in a simulator, first run {cli} sim start --thread {id} (see sim --help): Squircle records it, the user watches it live, and the recording appears in your turn. Drive it with the agent-device command it returns; run {cli} sim stop --thread {id} when done. Don't run agent-device record or device_open. \
             For signed builds: {cli} build start --help. \
             A performance recording the user sends from the phone is a linked .perf.json: {cli} perf show PATH summarizes it (hitches with symbolicated main-thread stacks, timeline). \
             The user also reads your replies on their phone: keep them short and plain, show pictures as ![..](/absolute/path) and clips as [..](/absolute/path) \
             (copied out of /tmp into ~/.t3/userdata/attachments), and don't present bare paths or IDs as information.",
            cli = self.cli
        );
        let now = crate::t3::iso_now();
        client.dispatch(json!({
            "type": "thread.turn.start", "threadId": id,
            "message": {"messageId": uuid::Uuid::new_v4().to_string(), "role": "user", "text": text, "attachments": [],
                        "context": {"version": 1, "records": [agent_message("squircle-task", Some(coordinator))]}},
            "modelSelection": selection, "runtimeMode": mode, "interactionMode": "default",
            "bootstrap": {
                "createThread": {"projectId": agent.project_id, "title": title, "modelSelection": selection,
                                 "runtimeMode": mode, "interactionMode": "default", "branch": null, "worktreePath": null, "createdAt": now},
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
        Ok(json!({"id": id, "title": title, "branch": branch, "base": base, "provider": instance, "model": model, "effort": effort,
                  "runtime_mode": mode, "permissions": permissions,
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
        self.send_with(thread_id, text, None).await
    }

    /// `squircle thread send`: a message from an agent, marked as one so the
    /// app never shows it as something the user typed.
    pub async fn message(&self, thread_id: &str, text: &str) -> Result<()> {
        let from = self.registry.lock().unwrap().workers.get(thread_id).map(|w| w.coordinator.clone());
        self.send_with(thread_id, text, Some(agent_message("squircle-agent-message", from.as_deref()))).await
    }

    async fn send_with(&self, thread_id: &str, text: &str, record: Option<Value>) -> Result<()> {
        let client = self.ready().await?;
        let thread = self.wait_thread(thread_id).await?;
        let mut message = json!({"messageId": uuid::Uuid::new_v4().to_string(), "role": "user", "text": text, "attachments": []});
        if let Some(record) = record {
            message["context"] = json!({"version": 1, "records": [record]});
        }
        client.dispatch(json!({
            "type": "thread.turn.start", "threadId": thread_id,
            "message": message,
            "runtimeMode": thread["runtimeMode"].as_str().unwrap_or(AGENT_MODE),
            "interactionMode": thread["interactionMode"].as_str().unwrap_or("default"),
        })).await?;
        Ok(())
    }

    async fn thread_detail(&self, client: &dyn Peer, id: &str) -> Result<Value> {
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
        let thread = self.thread_detail(&*client, id).await?;
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
        let thread = self.thread_detail(&*client, id).await?;
        let (request, questions) = Self::pending_question(&thread).with_context(|| match pending_request(&thread) {
            Some(_) => "That thread is waiting on an approval; the user approves or declines it on the phone",
            None => "That thread is not waiting on a question",
        })?;
        let answers: serde_json::Map<String, Value> = questions.iter()
            .filter_map(|q| q["id"].as_str().or(q["question"].as_str()).map(|k| (k.to_string(), json!(text)))).collect();
        client.dispatch(json!({"type": "thread.user-input.respond", "threadId": id, "requestId": request, "answers": answers})).await?;
        Ok(())
    }

    /// Archives a worker: stops it if `discard` lets a working one go,
    /// removes its worktree and deletes its branch, then archives its thread.
    /// Refuses while the branch has commits not in its base or the worktree
    /// has uncommitted changes, unless `discard` drops them. Nothing is
    /// removed until T3 reports the worker stopped; after a partial failure
    /// running it again finishes the job.
    pub async fn archive(&self, id: &str, discard: bool) -> Result<Value> {
        let client = self.ready().await?;
        let _op = self.op(id).await;
        let is_agent = self.registry.lock().unwrap().agents.values().any(|a| a.thread_id == id);
        ensure!(!is_agent, "That is an app agent's thread, not a worker");
        let worker = self.registry.lock().unwrap().workers.get(id).cloned();
        ensure!(self.thread(id).is_some() || worker.is_some(), "T3 has no thread {id}");
        let mut stopped = false;
        if self.thread(id).is_some_and(|row| worker_state(&row) == "working") {
            ensure!(discard, "That worker is still working; wait for it, or pass --discard to stop it and drop its work");
            client.dispatch(json!({"type": "thread.session.stop", "threadId": id})).await?;
            self.wait_stopped(id).await?;
            stopped = true;
        }
        let thread = self.thread(id);
        let row = thread.clone().unwrap_or(Value::Null);
        let branch = worker.as_ref().map(|w| w.branch.clone()).or_else(|| row["branch"].as_str().map(str::to_string));
        let base = worker.as_ref().map(|w| w.base.clone());
        let project = worker.as_ref().map(|w| w.project_id.clone()).or_else(|| row["projectId"].as_str().map(str::to_string));
        let root = project.and_then(|p| self.shell.lock().unwrap().projects.get(&p).and_then(|p| p["workspaceRoot"].as_str().map(PathBuf::from)));
        let worktree = row["worktreePath"].as_str().map(PathBuf::from);
        let mut result = json!({"archived": id, "stopped": stopped,
                                "title": worker.as_ref().map(|w| w.title.clone()).or_else(|| row["title"].as_str().map(str::to_string))});
        if let Some(root) = &root {
            let base = match base {
                Some(base) => base,
                None => git(root, &["symbolic-ref", "--short", "HEAD"]).await?,
            };
            let state = inspect(root, worktree.as_deref(), branch.as_deref(), Some(&base)).await?;
            if let Some(reason) = state.blocker().filter(|_| !discard) {
                bail!("Not archived: {reason}. Merge it first, or pass --discard to drop that work");
            }
            let cleaned = remove(root, &state, discard).await
                .with_context(|| if stopped { "The worker was stopped, but its files were not all removed; run archive again" } else { "Its files were not all removed; run archive again" })?;
            result["removed_worktree"] = json!(cleaned.worktree);
            result["deleted_branch"] = json!(cleaned.branch);
            result["discarded"] = json!(discard && state.blocker().is_some());
        }
        if thread.is_some_and(|t| t["archivedAt"].is_null()) {
            client.dispatch(json!({"type": "thread.archive", "threadId": id})).await
                .context("Its files were removed, but T3 did not archive the thread; run archive again")?;
        }
        let mut registry = self.registry.lock().unwrap();
        if let Some(worker) = registry.workers.get_mut(id) {
            worker.archived = true;
        }
        self.save(&registry)?;
        Ok(result)
    }

    /// Waits for T3 to report a stopped worker no longer working.
    async fn wait_stopped(&self, id: &str) -> Result<()> {
        for _ in 0..300 {
            if self.thread(id).is_none_or(|row| worker_state(&row) != "working") {
                return Ok(());
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        bail!("The worker did not stop within 30 seconds; nothing was removed")
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
                    if !dry_run {
                        let _op = self.op(&id).await;
                        remove(&root, &git, false).await?;
                    }
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
    fn worker_mode_inherits_its_coordinators_unless_asked() {
        let mode = |driver, coordinator, requested| worker_mode(driver, coordinator, requested).unwrap().0;
        assert_eq!(mode("claudeAgent", Some("auto"), None), "auto");
        assert_eq!(mode("codex", Some("auto"), None), "auto");
        assert_eq!(mode("claudeAgent", Some("approval-required"), None), "approval-required");
        assert_eq!(mode("antigravity", Some("auto"), None), "auto-accept-edits");
        // Asked for explicitly, a mode is kept as is, even where it asks more.
        assert_eq!(mode("antigravity", Some("auto"), Some("auto")), "auto");
        assert_eq!(mode("claudeAgent", Some("auto"), Some("full-access")), "full-access");
        // An agent thread without a known mode is one the service created.
        assert_eq!(mode("claudeAgent", None, None), AGENT_MODE);
        assert_eq!(mode("claudeAgent", Some("bogus"), None), AGENT_MODE);
        assert!(worker_mode("claudeAgent", Some("auto"), Some("yolo")).is_err());
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

    #[test]
    fn a_second_question_in_a_turn_wakes_again() {
        let asking = thread(Some("t"), "running", "running", true);
        assert!(notified_of(Some("t:needs-you:A"), &wake_key(&asking).unwrap()));
        assert!(!notified_of(Some("t:needs-you-later"), "t:needs-you"));
        // Answered: working again forgets the question, so the next is new.
        let working = thread(Some("t"), "running", "running", false);
        assert_eq!(progressed(Some("t:needs-you:A"), &working).as_deref(), Some("t:working"));
        assert!(!notified_of(Some("t:working"), &wake_key(&asking).unwrap()));
        assert_eq!(progressed(Some("t:done"), &working), None);
        let detail = |acts: Value| json!({"activities": acts});
        let ask = |kind: &str, id: &str| json!({"kind": kind, "payload": {"requestId": id}});
        assert_eq!(pending_request(&detail(json!([ask("user-input.requested", "A"), ask("user-input.resolved", "A"),
            ask("approval.requested", "B")]))).as_deref(), Some("B"));
        assert_eq!(pending_request(&detail(json!([ask("approval.requested", "B"), ask("approval.resolved", "B")]))), None);
    }

    #[test]
    fn context_goes_to_the_deepest_project() {
        let temp = tempfile::tempdir().unwrap();
        let repo = temp.path().join("repo");
        let example = repo.join("examples/App");
        std::fs::create_dir_all(example.join("src")).unwrap();
        std::os::unix::fs::symlink(&example, temp.path().join("alias")).unwrap();
        let roots = [repo.as_path(), example.as_path()];
        assert_eq!(deepest_root(&roots, &example.join("src")), Ok(Some(1)));
        assert_eq!(deepest_root(&[example.as_path(), repo.as_path()], &example), Ok(Some(0)));
        assert_eq!(deepest_root(&roots, &repo.join("examples")), Ok(Some(0)));
        assert_eq!(deepest_root(&roots, &temp.path().join("alias/src")), Ok(Some(1)));
        assert_eq!(deepest_root(&roots, temp.path()), Ok(None));
        // `/repo-other` is not inside `/repo`.
        assert_eq!(deepest_root(&roots, &temp.path().join("repo-other")), Ok(None));
        assert_eq!(deepest_root(&[repo.as_path(), example.as_path(), repo.as_path()], &repo), Err(vec![0, 2]));
    }

    /// T3 as the agents see it: records commands, creates thread rows in
    /// the shell after a delay, and remembers the messages it accepted.
    #[derive(Default)]
    struct Fake {
        agents: std::sync::OnceLock<std::sync::Weak<Agents>>,
        log: Mutex<Vec<Value>>,
        messages: Mutex<HashMap<String, Vec<String>>>,
        activities: Mutex<HashMap<String, Value>>,
        /// The next dispatch of this type fails; `true` if T3 applied it anyway (a lost acknowledgement).
        fail: Mutex<Vec<(&'static str, bool)>>,
        shell_delay: Mutex<Duration>,
        on_dispatch: Mutex<Option<Box<dyn Fn(&Value) + Send>>>,
    }

    impl Fake {
        fn agents(&self) -> Arc<Agents> { self.agents.get().unwrap().upgrade().unwrap() }
        fn sent(&self, kind: &str) -> Vec<Value> {
            self.log.lock().unwrap().iter().filter(|c| c["type"] == kind).cloned().collect()
        }
    }

    impl Peer for Fake {
        fn call<'a>(&'a self, tag: &'a str, _: Value) -> crate::push::BoxFuture<'a, Result<Value>> {
            assert_eq!(tag, "server.getConfig");
            Box::pin(async { Ok(json!({"providers": [{"instanceId": INSTANCE, "status": "ready"}]})) })
        }
        fn dispatch<'a>(&'a self, command: Value) -> crate::push::BoxFuture<'a, Result<Value>> {
            Box::pin(async move {
                tokio::time::sleep(Duration::from_millis(20)).await;
                self.log.lock().unwrap().push(command.clone());
                if let Some(hook) = &*self.on_dispatch.lock().unwrap() { hook(&command); }
                let failure = {
                    let mut fail = self.fail.lock().unwrap();
                    fail.iter().position(|(kind, _)| command["type"] == *kind).map(|i| fail.remove(i).1)
                };
                if failure == Some(false) { bail!("T3 rejected the command") }
                match command["type"].as_str() {
                    Some("thread.create") => {
                        let row = json!({"id": command["threadId"], "projectId": command["projectId"], "runtimeMode": command["runtimeMode"],
                                         "modelSelection": command["modelSelection"], "session": null, "archivedAt": null});
                        let (agents, delay) = (self.agents(), *self.shell_delay.lock().unwrap());
                        tokio::spawn(async move {
                            tokio::time::sleep(delay).await;
                            agents.consume_shell(&json!({"kind": "thread-upserted", "thread": row}));
                        });
                    }
                    Some("thread.turn.start") => {
                        self.messages.lock().unwrap().entry(command["threadId"].as_str().unwrap().into()).or_default()
                            .push(command["message"]["messageId"].as_str().unwrap().into());
                    }
                    _ => {}
                }
                if failure == Some(true) { bail!("T3 did not answer") }
                Ok(json!({"sequence": 1}))
            })
        }
        fn snapshot<'a>(&'a self, _: &'a str, payload: Value) -> crate::push::BoxFuture<'a, Result<Value>> {
            Box::pin(async move {
                let id = payload["threadId"].as_str().unwrap();
                let messages: Vec<Value> = self.messages.lock().unwrap().get(id).into_iter().flatten()
                    .map(|m| json!({"id": m, "role": "user", "text": "x"})).collect();
                let activities = self.activities.lock().unwrap().get(id).cloned().unwrap_or(json!([]));
                Ok(json!({"snapshot": {"thread": {"id": id, "messages": messages, "activities": activities}}}))
            })
        }
    }

    fn row(id: &str, project: &str, mode: &str, turn: &str, turn_state: &str, session: &str, needs: bool) -> Value {
        json!({"id": id, "projectId": project, "runtimeMode": mode, "archivedAt": null,
               "modelSelection": {"instanceId": INSTANCE, "model": "m"},
               "latestTurn": {"turnId": turn, "state": turn_state}, "session": {"status": session},
               "hasPendingApprovals": false, "hasPendingUserInput": needs})
    }

    /// Agents on a fake T3 with one project, `p`, rooted at `workspace`.
    fn fake_agents(temp: &Path, workspace: &Path, threads: Vec<Value>) -> (Arc<Agents>, Arc<Fake>) {
        let tasks = Arc::new(Tasks::open(temp).unwrap());
        let agents = Agents::open(temp, "http://127.0.0.1:1", tasks).unwrap();
        let fake = Arc::new(Fake::default());
        fake.agents.set(Arc::downgrade(&agents)).unwrap();
        assert!(agents.fake.set(fake.clone()).is_ok());
        agents.consume_shell(&json!({"kind": "snapshot", "snapshot": {
            "projects": [{"id": "p", "title": "App", "workspaceRoot": workspace}], "threads": threads}}));
        (agents, fake)
    }

    fn registered(agents: &Agents, f: impl FnOnce(&mut Registry)) {
        let mut registry = agents.registry.lock().unwrap();
        f(&mut registry);
        agents.save(&registry).unwrap();
    }

    fn worker(coordinator: &str) -> Worker {
        Worker { coordinator: coordinator.into(), project_id: "p".into(), title: "W".into(), branch: "w".into(),
                 base: "main".into(), created_at: 0, notified: None, archived: false }
    }

    fn agent(thread: &str) -> Agent {
        Agent { project_id: "p".into(), thread_id: thread.into(), created_at: 0, creating: false, pending: None,
                replacing: None, reset_error: None, refresh: false }
    }

    #[tokio::test]
    async fn first_use_creates_one_agent_in_the_chosen_mode() {
        let temp = tempfile::tempdir().unwrap();
        let (agents, fake) = fake_agents(temp.path(), temp.path(), vec![]);
        // The shell shows the new thread only after both requests have asked.
        *fake.shell_delay.lock().unwrap() = Duration::from_millis(300);
        let (a, b) = tokio::join!(agents.ensure("p", None, None, Some("approval-required")),
                                  agents.ensure("p", None, None, Some("approval-required")));
        assert_eq!(a.unwrap().thread_id, b.unwrap().thread_id);
        let created = fake.sent("thread.create");
        assert_eq!(created.len(), 1);
        assert_eq!(created[0]["runtimeMode"], "approval-required");
        assert!(agents.ensure("p", None, None, Some("ask")).await.is_err());
    }

    #[tokio::test]
    async fn an_unconfirmed_creation_is_finished_not_repeated() {
        let temp = tempfile::tempdir().unwrap();
        let (agents, fake) = fake_agents(temp.path(), temp.path(), vec![]);
        fake.fail.lock().unwrap().push(("thread.create", false));
        assert!(agents.ensure("p", None, None, None).await.is_err());
        let reserved = agents.list()[0].clone();
        assert!(reserved.creating);
        let agent = agents.ensure("p", None, None, None).await.unwrap();
        assert_eq!(agent.thread_id, reserved.thread_id);
        assert!(!agents.list()[0].creating);
        let created = fake.sent("thread.create");
        assert_eq!(created.len(), 2);
        assert!(created.iter().all(|c| c["threadId"] == reserved.thread_id.as_str()));
    }

    #[tokio::test]
    async fn a_fresh_start_survives_a_lost_acknowledgement_and_keeps_the_mode() {
        let temp = tempfile::tempdir().unwrap();
        let (agents, fake) = fake_agents(temp.path(), temp.path(),
            vec![row("old", "p", "approval-required", "t", "completed", "ready", false)]);
        registered(&agents, |r| { r.agents.insert("p".into(), agent("old")); r.workers.insert("w1".into(), worker("old")); });
        fake.fail.lock().unwrap().push(("thread.turn.start", true));
        let error = agents.reset(Some("p"), None, Reset::Fresh { note: None }).await.unwrap_err();
        assert!(format!("{error:#}").contains("did not answer"));
        let saved = agents.list()[0].clone();
        assert!(saved.pending.is_some() && saved.reset_error.is_some());
        let plan = saved.replacing.unwrap();
        // The retry finds the handoff delivered and does not send it again.
        let _op = agents.op("p").await;
        let done = agents.perform("p").await.unwrap();
        assert_eq!(done["thread_id"], plan.thread_id.as_str());
        let saved = agents.list()[0].clone();
        assert!(saved.pending.is_none() && saved.replacing.is_none() && saved.thread_id == plan.thread_id);
        assert_eq!(agents.registry.lock().unwrap().workers["w1"].coordinator, plan.thread_id);
        let created = fake.sent("thread.create");
        assert_eq!(created.len(), 1);
        assert_eq!(created[0]["runtimeMode"], "approval-required");
        let turns = fake.sent("thread.turn.start");
        assert_eq!(turns.len(), 1);
        assert_eq!(turns[0]["runtimeMode"], "approval-required");
    }

    #[tokio::test]
    async fn worker_updates_are_sent_once() {
        let temp = tempfile::tempdir().unwrap();
        let (agents, fake) = fake_agents(temp.path(), temp.path(), vec![
            row("agent", "p", "full-access", "a", "completed", "ready", false),
            row("w1", "p", "full-access", "t", "completed", "ready", false)]);
        registered(&agents, |r| { r.agents.insert("p".into(), agent("agent")); r.workers.insert("w1".into(), worker("agent")); });
        // Overlapping flushes.
        let (a, b) = tokio::join!(agents.flush(), agents.flush());
        a.unwrap(); b.unwrap();
        assert_eq!(fake.sent("thread.turn.start").len(), 1);
        // A lost acknowledgement, then a retry with nothing new from T3.
        agents.consume_shell(&json!({"kind": "thread-upserted", "thread": row("w1", "p", "full-access", "t2", "completed", "ready", false)}));
        fake.fail.lock().unwrap().push(("thread.turn.start", true));
        assert!(agents.flush().await.is_err());
        assert!(agents.has_due_wakes());
        agents.flush().await.unwrap();
        assert_eq!(fake.sent("thread.turn.start").len(), 2);
        assert!(!agents.has_due_wakes());
        // A restart reloads the same registry and has nothing to send.
        let reopened = Agents::open(temp.path(), "http://127.0.0.1:1", Arc::new(Tasks::open(temp.path()).unwrap())).unwrap();
        assert_eq!(reopened.registry.lock().unwrap().workers["w1"].notified.as_deref(), Some("t2:done"));

        // Question A, answered (working), then question B in the same turn.
        let asking = row("w1", "p", "full-access", "t3", "running", "running", true);
        let ask = |id: &str| json!([{"kind": "user-input.requested", "payload": {"requestId": id}}]);
        fake.activities.lock().unwrap().insert("w1".into(), ask("A"));
        agents.consume_shell(&json!({"kind": "thread-upserted", "thread": asking}));
        agents.flush().await.unwrap();
        agents.flush().await.unwrap();
        assert_eq!(fake.sent("thread.turn.start").len(), 3);
        agents.consume_shell(&json!({"kind": "thread-upserted", "thread": row("w1", "p", "full-access", "t3", "running", "running", false)}));
        agents.note_progress();
        fake.activities.lock().unwrap().insert("w1".into(), ask("B"));
        agents.consume_shell(&json!({"kind": "thread-upserted", "thread": row("w1", "p", "full-access", "t3", "running", "running", true)}));
        agents.flush().await.unwrap();
        assert_eq!(fake.sent("thread.turn.start").len(), 4);
        assert_eq!(agents.registry.lock().unwrap().workers["w1"].notified.as_deref(), Some("t3:needs-you:B"));
    }

    #[tokio::test]
    async fn discarding_stops_a_working_worker_before_removing_its_files() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("repo");
        std::fs::create_dir(&root).unwrap();
        run(&root, &["init", "-q", "-b", "main"]).await;
        commit(&root, "a").await;
        let tree = temp.path().join("w");
        run(&root, &["worktree", "add", "-q", "-b", "w", tree.to_str().unwrap()]).await;
        commit(&tree, "b").await;
        let mut working = row("w1", "p", "full-access", "t", "running", "running", false);
        working["worktreePath"] = json!(tree);
        let data = temp.path().join("data");
        std::fs::create_dir(&data).unwrap();
        let (agents, fake) = fake_agents(&data, &root, vec![working.clone()]);
        registered(&agents, |r| { r.workers.insert("w1".into(), worker("agent")); });
        assert!(agents.archive("w1", false).await.is_err());
        let (weak, checked) = (Arc::downgrade(&agents), tree.clone());
        *fake.on_dispatch.lock().unwrap() = Some(Box::new(move |command| {
            if command["type"] == "thread.session.stop" {
                assert!(checked.exists(), "files removed before the worker stopped");
                let mut stopped = working.clone();
                stopped["latestTurn"]["state"] = json!("interrupted");
                stopped["session"]["status"] = json!("stopped");
                weak.upgrade().unwrap().consume_shell(&json!({"kind": "thread-upserted", "thread": stopped}));
            } else if command["type"] == "thread.archive" {
                assert!(!checked.exists());
            }
        }));
        let result = agents.archive("w1", true).await.unwrap();
        assert_eq!(result["stopped"], true);
        let order: Vec<Value> = fake.log.lock().unwrap().iter().map(|c| c["type"].clone()).collect();
        assert_eq!(order, [json!("thread.session.stop"), json!("thread.archive")]);
        assert!(!tree.exists() && agents.registry.lock().unwrap().workers["w1"].archived);
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

    #[tokio::test]
    async fn keeps_a_unique_merge_resolution() {
        let temp = tempfile::tempdir().unwrap();
        let root = &temp.path().join("repo");
        std::fs::create_dir(root).unwrap();
        run(root, &["init", "-q", "-b", "main"]).await;
        commit(root, "a").await;
        let edit = |text: &'static str| async move {
            std::fs::write(root.join("value"), text).unwrap();
            run(root, &["add", "value"]).await;
            run(root, &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", text]).await;
        };
        for side in ["left", "right"] {
            run(root, &["checkout", "-q", "-b", side, "main"]).await;
            edit(side).await;
        }
        // Both main and the worker merge left and right, resolving differently.
        for (branch, resolution) in [("main", "main's"), ("worker", "worker's")] {
            if branch == "main" { run(root, &["checkout", "-q", "main"]).await } else { run(root, &["checkout", "-q", "-b", "worker", "left~1"]).await }
            run(root, &["merge", "-q", "left"]).await;
            let _ = git(root, &["-c", "user.name=t", "-c", "user.email=t@t", "merge", "-q", "right"]).await;
            edit(resolution).await;
        }
        run(root, &["checkout", "-q", "main"]).await;
        // `git cherry` alone sees nothing unmerged.
        assert!(!git(root, &["cherry", "main", "worker"]).await.unwrap().contains('+'));
        let state = inspect(root, None, Some("worker"), Some("main")).await.unwrap();
        assert!(state.blocker().is_some(), "{state:?}");
        // A branch that moved after inspection is not deleted.
        let tip = state.tip.clone();
        run(root, &["branch", "-f", "worker", "main"]).await;
        let merged = GitState { tip: tip.clone(), ..inspect(root, None, Some("worker"), Some("main")).await.unwrap() };
        assert!(remove(root, &merged, false).await.is_err());
        assert!(git(root, &["rev-parse", "--verify", "worker"]).await.is_ok());
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
