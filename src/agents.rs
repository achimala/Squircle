//! One agent per app. The app agent is an ordinary T3 thread on Squircle's
//! own Claude instance (see `setup`), in the project's folder. It can run
//! ordinary T3 worker threads, each in its own worktree. Squircle adds only
//! what T3 lacks: who owns which worker, the agent's thread ID and workers at
//! the start of each turn, and a wake-up when a worker finishes or needs
//! input. How to work is up to the user and the agent. No model runs here.

use crate::fsm::coordinator::agent::{self as m14, Order};
use crate::fsm::coordinator::upkeep::{self as m26, Origin, Reading};
use crate::fsm::coordinator::outbox::{self, Outbound, Settled};
use crate::fsm::coordinator::worker::{self as m15, ArchiveOrder, BootEffect, BootEvent};
use crate::fsm::coordinator::{Command, Dispatched, Identity, Pending};
use crate::actor::{Lane, Lanes, Owner, Published, Rank, Snapshot};
use crate::fsm::core::commit::{Gate, JsonFile};
use crate::fsm::core::{self as core, CommandID, Disposition, Epoch, Revision};
use crate::store::private_dir;
use crate::t3::{T3, T3Config};
use crate::tasks::{Source, Status, Tasks};
use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap},
    convert::Infallible,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

pub use crate::fsm::coordinator::outbox::Delivery;
use tokio::process::Command as Process;

/// The T3 provider instance `squircle agent setup` creates.
pub const INSTANCE: &str = "squircle";
const DEFAULT_MODEL: &str = "claude-opus-5-5";

#[derive(Clone, Serialize, Deserialize)]
#[serde(try_from = "AgentFile")]
pub struct Agent {
    pub project_id: String,
    pub thread_id: String,
    pub created_at: u64,
    pub lifecycle: Lifecycle,
}

pub use crate::fsm::coordinator::agent::{Lifecycle, Replacement, Reset};
pub use crate::fsm::coordinator::thread::{Execution, Phase, ThreadObservation};
pub use crate::fsm::coordinator::worker::{ArchiveStep, Stage};

impl Lifecycle {
    /// Records a reset attempt's outcome; returns the backoff before the
    /// next attempt after a failure.
    fn attempted(&mut self, failure: Option<String>) -> Option<Duration> {
        let (Lifecycle::ResetQueued { error, failures, .. } | Lifecycle::Restarting { error, failures, .. }
             | Lifecycle::Replacing { error, failures, .. }) = self else { return None };
        *failures = if failure.is_some() { (*failures + 1).min(6) } else { 0 };
        *error = failure;
        error.is_some().then(|| Duration::from_secs(4 << *failures))
    }
}

/// `agents.json` as written before `lifecycle` (flags and optionals), or now.
#[derive(Deserialize)]
struct AgentFile {
    project_id: String,
    thread_id: String,
    created_at: u64,
    #[serde(default)]
    lifecycle: Option<Lifecycle>,
    #[serde(default)]
    creating: bool,
    #[serde(default)]
    pending: Option<Reset>,
    #[serde(default)]
    replacing: Option<Replacement>,
    #[serde(default)]
    reset_error: Option<String>,
    #[serde(default)]
    refresh: bool,
}

impl TryFrom<AgentFile> for Agent {
    type Error = String;
    fn try_from(f: AgentFile) -> std::result::Result<Self, String> {
        let lifecycle = match f.lifecycle {
            Some(lifecycle) => lifecycle,
            None => match (f.creating, f.pending, f.replacing) {
                (true, None, None) => Lifecycle::Creating { command: None },
                (false, Some(Reset::Fresh { .. }), Some(replacement)) => Lifecycle::Replacing { replacement, error: f.reset_error, failures: 0 },
                (false, Some(reset), None) => Lifecycle::ResetQueued { reset, error: f.reset_error, failures: 0 },
                (false, None, None) => Lifecycle::Ready { refresh: f.refresh },
                _ => return Err(format!("agent of project {} has contradictory reset fields", f.project_id)),
            },
        };
        Ok(Agent { project_id: f.project_id, thread_id: f.thread_id, created_at: f.created_at, lifecycle })
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Worker {
    pub coordinator: String,
    pub project_id: String,
    pub title: String,
    pub branch: String,
    pub base: String,
    pub created_at: u64,
    /// The last event its coordinator was told about, so a restart neither
    /// repeats nor misses a wake-up.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notified: Option<WorkerEvent>,
    #[serde(default, alias = "archived", deserialize_with = "stage_or_legacy")]
    pub stage: Stage,
}

fn stage_or_legacy<'de, D: serde::Deserializer<'de>>(d: D) -> std::result::Result<Stage, D::Error> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum File { Archived(bool), Stage(Stage) }
    Ok(match File::deserialize(d)? {
        File::Archived(true) => Stage::Archived,
        File::Archived(false) => Stage::Active,
        File::Stage(stage) => stage,
    })
}

/// What a worker's coordinator is told about: a turn that stopped (done,
/// error), one waiting on a request, or one working again after a question
/// was answered (so the next question in the same turn is new).
#[derive(Clone, Serialize, PartialEq, Eq, Debug)]
pub struct WorkerEvent {
    pub turn: String,
    pub kind: EventKind,
    /// For `needs-you`: the question or approval, which T3's shell row does
    /// not carry; added from the thread's detail before it is queued.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request: Option<String>,
}

#[derive(Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Debug)]
#[serde(rename_all = "kebab-case")]
pub enum EventKind {
    Done,
    Error,
    NeedsYou,
    Working,
}

impl WorkerEvent {
    /// Whether telling the coordinator about `self` already covers `due`
    /// (an event without its request matches any request of the same kind).
    fn covers(&self, due: &WorkerEvent) -> bool {
        self.turn == due.turn && self.kind == due.kind && (due.request.is_none() || self.request == due.request)
    }
}

impl<'de> Deserialize<'de> for WorkerEvent {
    /// Also reads the colon-delimited keys written before (`turn:needs-you:request`).
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct Fields { turn: String, kind: EventKind, #[serde(default)] request: Option<String> }
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum File { Key(String), Fields(Fields) }
        match File::deserialize(d)? {
            File::Fields(Fields { turn, kind, request }) => Ok(WorkerEvent { turn, kind, request }),
            File::Key(key) => {
                let mut parts = key.splitn(3, ':');
                let (turn, kind) = (parts.next().unwrap_or_default(), parts.next().unwrap_or_default());
                let kind = serde_json::from_value(json!(kind)).map_err(|_| serde::de::Error::custom(format!("unknown worker event {key:?}")))?;
                Ok(WorkerEvent { turn: turn.into(), kind, request: parts.next().map(str::to_string) })
            }
        }
    }
}

/// A worker update for one agent, recorded before it is sent so a lost
/// acknowledgement or a restart re-sends the same message, never a second.
/// Removing it from the outbox and advancing its workers' `notified` is one
/// registry transition. Every decision about its delivery is M16's
/// (`crate::fsm::coordinator::outbox`).
#[derive(Clone, Serialize, Deserialize)]
pub struct Wake {
    pub coordinator: String,
    pub message_id: String,
    /// Each worker and the event this update tells about.
    pub workers: Vec<(String, WorkerEvent)>,
    pub text: String,
    pub record: Value,
    #[serde(flatten)]
    pub outbound: Outbound,
    /// For a build update: the build it tells about.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub build: Option<String>,
}

/// What an app agent has been told about one of its builds.
#[derive(Clone, Serialize, Deserialize, PartialEq, Debug)]
#[serde(tag = "state", rename_all = "kebab-case")]
pub enum BuildWatch {
    /// The agent started it in this turn of its own: a build that finishes
    /// while that turn still runs is already in its conversation.
    Started { turn: Option<String>, at: u64 },
    /// Its update is queued or delivered, or it needed none.
    Told { at: u64 },
}

impl BuildWatch {
    fn at(&self) -> u64 {
        match self { BuildWatch::Started { at, .. } | BuildWatch::Told { at } => *at }
    }
}

/// A build that finished, as its app agent is told.
pub struct FinishedBuild {
    pub id: String,
    /// The thread that started it, if known.
    pub thread: Option<String>,
    pub app: String,
    pub succeeded: bool,
    /// Why it failed, in a line.
    pub reason: Option<String>,
}

/// An outbox entry that left without reaching anyone, kept as its receipt.
#[derive(Clone, Serialize, Deserialize)]
pub struct Undelivered {
    pub message_id: String,
    pub coordinator: String,
    pub reason: String,
    pub at: u64,
}

/// How many undelivered receipts are kept.
const UNDELIVERED_KEPT: usize = 20;

#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Registry {
    #[serde(default)]
    pub agents: BTreeMap<String, Agent>,
    #[serde(default)]
    pub workers: BTreeMap<String, Worker>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub outbox: Vec<Wake>,
    /// Builds by ID, from their start (an agent's own) or their update.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub builds: BTreeMap<String, BuildWatch>,
    /// Per project, what idle upkeep last decided for its agent (M26).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub upkeep: BTreeMap<String, m26::Record>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub undelivered: Vec<Undelivered>,
    /// Commands callers wait for whose answer was lost, newest last.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub intents: Vec<Pending>,
}

/// How many unanswered caller commands are kept.
const INTENTS_KEPT: usize = 20;

type RegistryGate = Gate<Registry, Infallible, JsonFile>;

/// A new command identity: what the owner allocates for each intent.
fn identity() -> Identity {
    Identity { id: CommandID::fresh(), created_at: crate::t3::iso_now() }
}

/// How long a build's watch is kept: past this, a build is long finished.
const BUILD_WATCH_SECS: u64 = 14 * 24 * 3600;

/// T3's runtime modes. A new app agent gets the one the user chose, or
/// `full-access`; a fresh start keeps its predecessor's, and workers inherit
/// their agent's. A thread whose mode T3 doesn't report is never given one.
const RUNTIME_MODES: [&str; 4] = ["approval-required", "auto-accept-edits", "auto", "full-access"];
const AGENT_MODE: &str = "full-access";

fn runtime_mode(mode: Option<&str>) -> Result<String> {
    let mode = mode.unwrap_or(AGENT_MODE);
    ensure!(RUNTIME_MODES.contains(&mode), "Unknown runtime mode \"{mode}\". Modes: {}", RUNTIME_MODES.join(", "));
    Ok(mode.into())
}

/// The runtime mode T3 reports for a thread, as the commands that continue
/// it send it back. None if T3 doesn't say: then nothing is sent.
fn thread_mode(row: &Value) -> Result<&str> {
    row["runtimeMode"].as_str().context("T3 doesn't say which runtime mode the thread runs in, so nothing was sent")
}

/// The part of T3 the agents use; a fake stands in for it in tests.
pub trait Peer: Send + Sync {
    fn call<'a>(&'a self, tag: &'a str, payload: Value) -> crate::push::BoxFuture<'a, Result<Value>>;
    fn dispatch<'a>(&'a self, command: &'a Command) -> crate::push::BoxFuture<'a, Dispatched>;
    fn snapshot<'a>(&'a self, tag: &'a str, payload: Value) -> crate::push::BoxFuture<'a, Result<Value>>;
}

impl Peer for T3 {
    fn call<'a>(&'a self, tag: &'a str, payload: Value) -> crate::push::BoxFuture<'a, Result<Value>> {
        Box::pin(T3::call(self, tag, payload))
    }
    fn dispatch<'a>(&'a self, command: &'a Command) -> crate::push::BoxFuture<'a, Dispatched> {
        Box::pin(T3::dispatch(self, command))
    }
    fn snapshot<'a>(&'a self, tag: &'a str, payload: Value) -> crate::push::BoxFuture<'a, Result<Value>> {
        Box::pin(T3::snapshot(self, tag, payload))
    }
}

/// A message Squircle puts in a conversation in the user's place: T3 sends
/// every message as the user's, so each one carries a context record whose
/// kind starts with `squircle-`. The app shows any marked message as
/// Squircle's line (whatever the kind, so a new one can't pass as the
/// user's) and only unmarked ones as the user's own words.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Note {
    /// The service's wake-up that workers moved on.
    WorkerUpdate,
    /// The service's news that a build failed.
    BuildUpdate,
    /// The briefing a fresh agent starts from.
    Handoff,
    /// A worker's prompt from its app agent.
    Task,
    /// `thread send` from another agent.
    AgentMessage,
    /// The service's news that a simulator is held for a thread in line.
    SimReady,
    /// The service compacting an idle agent's context.
    Upkeep,
}

impl Note {
    pub const ALL: [Note; 7] = [Note::WorkerUpdate, Note::BuildUpdate, Note::Handoff, Note::Task, Note::AgentMessage, Note::SimReady, Note::Upkeep];

    fn kind(self) -> &'static str {
        match self {
            Note::WorkerUpdate => "squircle-worker-update",
            Note::BuildUpdate => "squircle-build-update",
            Note::Handoff => "squircle-handoff",
            Note::Task => "squircle-task",
            Note::AgentMessage => "squircle-agent-message",
            Note::SimReady => "squircle-sim-ready",
            Note::Upkeep => "squircle-upkeep",
        }
    }

    fn label(self) -> &'static str {
        match self {
            Note::WorkerUpdate => "Worker update",
            Note::BuildUpdate => "Build update",
            Note::Handoff => "Handoff",
            Note::Task | Note::AgentMessage => "Agent message",
            Note::SimReady => "Simulator ready",
            Note::Upkeep => "Tidied up",
        }
    }

    /// The context record that marks a message as this note.
    pub fn record(self, payload: Value) -> Value {
        self.labeled(self.label(), payload)
    }

    /// The record with its own label, which the app shows as the line.
    fn labeled(self, label: &str, payload: Value) -> Value {
        json!({"version": 1, "contextId": uuid::Uuid::new_v4().to_string(), "label": label,
               "kind": self.kind(), "payload": payload})
    }

    /// The user message T3 is sent for this note.
    pub fn message(self, id: &str, text: &str, payload: Value) -> Value {
        Self::with_record(id, text, self.record(payload))
    }

    fn with_record(id: &str, text: &str, record: Value) -> Value {
        json!({"messageId": id, "role": "user", "text": text, "attachments": [],
               "context": {"version": 1, "records": [record]}})
    }

    /// The note marking a T3 message, if any.
    fn of(message: &Value) -> Option<Note> {
        let records = message["context"]["records"].as_array()?;
        records.iter().find_map(|r| Note::ALL.into_iter().find(|n| r["kind"] == n.kind()))
    }
}

/// Whether the user wrote this T3 message: a user message no note marks.
fn users_own(message: &Value) -> bool {
    message["role"] == "user" && !message["context"]["records"].as_array().into_iter().flatten()
        .any(|r| r["kind"].as_str().is_some_and(|k| k.starts_with("squircle-")))
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
        None => match coordinator.filter(|mode| RUNTIME_MODES.contains(mode)) {
            Some("auto") if driver == "antigravity" => "auto-accept-edits".into(),
            Some(mode) => mode.into(),
            None => bail!("T3 doesn't report a runtime mode this service knows for the app agent ({}), so the worker can't inherit it; \
                           pass --runtime-mode", coordinator.unwrap_or("none")),
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
    fn quiet<'a>(&'a self, thread: &'a str) -> crate::push::BoxFuture<'a, bool> {
        Box::pin(async move {
            let Ok(client) = self.client().await else { return false };
            let Ok(detail) = self.thread_detail(&*client, thread).await else { return false };
            detail["messages"].as_array().into_iter().flatten().rev().find(|m| m["role"] == "user" || m["role"] == "assistant")
                .is_some_and(|m| Note::of(m) == Some(Note::Upkeep))
        })
    }
}

impl ThreadObservation {
    /// The wake-up its state calls for, if any: a stopped turn (done, error)
    /// or one waiting on its owner, each delivered once.
    fn wake(&self) -> Option<WorkerEvent> {
        let kind = match self.phase() {
            Phase::Working => return None,
            Phase::NeedsYou => EventKind::NeedsYou,
            Phase::Error => EventKind::Error,
            Phase::Done => EventKind::Done,
        };
        Some(WorkerEvent { turn: self.turn.clone()?, kind, request: None })
    }

    /// What to remember once a worker is working again: a question it was
    /// waiting on has been answered, so the next one in the same turn is new.
    fn progressed(&self, notified: Option<&WorkerEvent>) -> Option<WorkerEvent> {
        let turn = self.turn.as_ref()?;
        let answered = notified.is_some_and(|n| &n.turn == turn && n.kind == EventKind::NeedsYou);
        (self.phase() == Phase::Working && answered).then(|| WorkerEvent { turn: turn.clone(), kind: EventKind::Working, request: None })
    }
}

/// What a worker is doing, from T3's shell row, as the label views show.
pub fn worker_state(thread: &Value) -> &'static str {
    ThreadObservation::decode(thread).phase().label()
}

/// A fact from T3's shell and how fresh it is. `epoch` counts connections:
/// `current` facts come from the live subscription; `stale` ones are what
/// the last connection said. Stale facts may be shown, never acted on
/// destructively. `Current(None)` means T3 has no such thread.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Observed<T> {
    Unavailable,
    Stale { epoch: u64, value: T },
    Current { epoch: u64, value: T },
}

impl<T> Observed<T> {
    /// The value if it is current.
    pub fn current(self) -> Option<T> {
        match self {
            Observed::Current { value, .. } => Some(value),
            _ => None,
        }
    }
    /// The value however fresh, for display.
    pub fn latest(self) -> Option<T> {
        match self {
            Observed::Current { value, .. } | Observed::Stale { value, .. } => Some(value),
            Observed::Unavailable => None,
        }
    }
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

#[derive(Clone, Default)]
struct Shell {
    threads: HashMap<String, Arc<Value>>,
    projects: HashMap<String, Arc<Value>>,
    link: Link,
}

/// The shell subscription. Its maps outlive a disconnect, as stale facts.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Link {
    /// Not subscribed; the maps are what connection `epoch` last said.
    Offline { epoch: u64 },
    /// Subscribed; T3's snapshot has not arrived yet.
    Syncing { epoch: u64 },
    Current { epoch: u64 },
}

impl Default for Link {
    fn default() -> Self { Link::Offline { epoch: 0 } }
}

impl Link {
    fn epoch(self) -> u64 {
        match self { Link::Offline { epoch } | Link::Syncing { epoch } | Link::Current { epoch } => epoch }
    }
}

impl Shell {
    fn current(&self) -> bool {
        matches!(self.link, Link::Current { .. })
    }
    fn observe(&self, id: &str) -> Observed<Option<ThreadObservation>> {
        let value = self.threads.get(id).map(|t| ThreadObservation::decode(t));
        match self.link {
            Link::Current { epoch } => Observed::Current { epoch, value },
            Link::Offline { epoch } | Link::Syncing { epoch } if value.is_some() => Observed::Stale { epoch, value },
            _ => Observed::Unavailable,
        }
    }
    fn thread(&self, id: &str) -> Option<Value> {
        self.threads.get(id).map(|t| (**t).clone())
    }
    fn project(&self, id: &str) -> Option<&Value> {
        self.projects.get(id).map(|p| &**p)
    }
}

/// What the agents owner publishes: the registry as saved, T3's shell as
/// last received, and the connection. Every reader reads one of these.
#[derive(Clone)]
struct View {
    registry: Arc<Registry>,
    shell: Arc<Shell>,
    status: Arc<str>,
    t3: Option<Arc<T3>>,
}

/// The agents owner's state, reached only by its letters.
struct State {
    /// `agents.json` behind the commit gate: changes are saved before anyone reads them.
    gate: RegistryGate,
    shell: Arc<Shell>,
    status: Arc<str>,
    t3: Option<Arc<T3>>,
    /// The registry as last published, and its revision.
    published: (Arc<Registry>, Revision),
    view: Published<View>,
    flush_scheduled: bool,
    flush_failures: u32,
    /// Threads in line for a simulator: a worker that ends its turn to wait
    /// wakes nobody; the service wakes it when its simulator is held.
    sim_waiting: std::collections::HashSet<String>,
    /// Projects whose reset task is running or waiting to retry; the
    /// attempt count and error belong to the agent's `Lifecycle`.
    resets: std::collections::HashSet<String>,
}

impl State {
    fn registry(&self) -> &Registry {
        self.gate.committed()
    }

    /// Publishes what readers see: the saved registry (cloned only when a
    /// save changed it), the shell and the connection.
    fn publish(&mut self) {
        if self.gate.revision() != self.published.1 {
            self.published = (Arc::new(self.gate.committed().clone()), self.gate.revision());
        }
        self.view.set(View { registry: self.published.0.clone(), shell: self.shell.clone(), status: self.status.clone(), t3: self.t3.clone() });
    }

    /// Writes a blocked earlier candidate again before anything new is decided.
    fn resolve(&mut self) -> Result<()> {
        let resolved = self.gate.resolve();
        self.publish();
        Ok(resolved?)
    }

    /// Saves `next` as the registry; readers see it only once it is saved.
    fn commit(&mut self, next: Registry) -> Result<()> {
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
    fn change_if<T>(&mut self, f: impl FnOnce(&mut Registry, &Shell) -> Option<T>) -> Result<Option<T>> {
        self.resolve()?;
        let mut next = self.registry().clone();
        let Some(out) = f(&mut next, &self.shell) else { return Ok(None) };
        self.commit(next)?;
        Ok(Some(out))
    }

    fn shell_mut(&mut self) -> &mut Shell {
        Arc::make_mut(&mut self.shell)
    }

    fn consume_shell(&mut self, item: &Value) {
        let shell = self.shell_mut();
        match item["kind"].as_str() {
            Some("snapshot") => {
                let snapshot = &item["snapshot"];
                shell.threads = snapshot["threads"].as_array().into_iter().flatten()
                    .filter_map(|t| Some((t["id"].as_str()?.to_string(), Arc::new(t.clone())))).collect();
                shell.projects = snapshot["projects"].as_array().into_iter().flatten()
                    .filter_map(|p| Some((p["id"].as_str()?.to_string(), Arc::new(p.clone())))).collect();
                shell.link = Link::Current { epoch: shell.link.epoch() };
            }
            Some("thread-upserted") => {
                if let Some(id) = item["thread"]["id"].as_str() {
                    shell.threads.insert(id.to_string(), Arc::new(item["thread"].clone()));
                }
            }
            Some("project-upserted") => {
                if let Some(id) = item["project"]["id"].as_str() {
                    shell.projects.insert(id.to_string(), Arc::new(item["project"].clone()));
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
        self.publish();
    }

    /// Follows workers in T3's shell: a reserved worker whose thread has
    /// appeared is running (T3 accepted its bootstrap), and one that waited
    /// on a question and is working again has had it answered.
    fn observe_workers(&mut self) {
        let changes = |registry: &Registry, shell: &Shell| -> (Vec<String>, Vec<(String, WorkerEvent)>) {
            let adopted = registry.workers.iter()
                .filter(|(id, w)| matches!(w.stage, Stage::Bootstrapping { .. }) && shell.threads.contains_key(*id))
                .map(|(id, _)| id.clone()).collect();
            let progressed = registry.workers.iter().filter(|(_, w)| w.stage.live())
                .filter_map(|(id, w)| {
                    let event = ThreadObservation::decode(shell.threads.get(id)?).progressed(w.notified.as_ref())?;
                    Some((id.clone(), event))
                }).collect();
            (adopted, progressed)
        };
        // Most shell events change nothing here; only then is a change made.
        let (a, p) = changes(self.registry(), &self.shell);
        if a.is_empty() && p.is_empty() { return }
        let saved = self.change_if(|registry, shell| {
            let (adopted, progressed) = changes(registry, shell);
            if adopted.is_empty() && progressed.is_empty() { return None }
            let shown = core::Observed::Current { epoch: Epoch::default(), revision: Revision::default(), value: true };
            for id in adopted {
                if let Some(worker) = registry.workers.get_mut(&id) {
                    worker.stage = m15::bootstrap(worker.stage.clone(), BootEvent::Look { thread: shown.clone() }).state;
                }
            }
            for (id, event) in progressed {
                if let Some(worker) = registry.workers.get_mut(&id) { worker.notified = Some(event); }
            }
            Some(())
        });
        if let Err(error) = saved {
            eprintln!("Worker state not saved: {error:#}");
        }
    }

    /// Workers whose state calls for a wake-up their coordinator has not had
    /// and that is not already queued. Only from a current shell.
    fn due_wakes(&self) -> Vec<(String, Worker, WorkerEvent)> {
        let (registry, shell) = (self.registry(), &self.shell);
        if !shell.current() {
            return vec![];
        }
        registry.workers.iter().filter(|(_, w)| w.stage.live()).filter_map(|(id, worker)| {
            let event = ThreadObservation::decode(shell.threads.get(id)?).wake()?;
            if event.kind == EventKind::Done && self.sim_waiting.contains(id) {
                return None;
            }
            let queued = registry.outbox.iter().any(|w| w.workers.iter().any(|(queued, _)| queued == id));
            (!queued && !worker.notified.as_ref().is_some_and(|n| n.covers(&event)))
                .then(|| (id.clone(), worker.clone(), event))
        }).collect()
    }

    fn has_due_wakes(&self) -> bool {
        !self.registry().outbox.is_empty() || !self.due_wakes().is_empty()
    }

    /// Reduces `event` for the queued update `id` and saves what it decided:
    /// its new delivery state, or its removal together with what settling it
    /// implies. Returns the update as decided and the effects to run next;
    /// `None` if it is no longer queued.
    fn reduce_wake(&mut self, id: &str, event: outbox::Event) -> Result<Option<(Wake, Vec<outbox::Effect>)>> {
        self.resolve()?;
        let Some(index) = self.registry().outbox.iter().position(|w| w.message_id == id) else { return Ok(None) };
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
        let settled = reduction.effects.iter().find_map(|e| match e { outbox::Effect::Settle(s) => Some(s.clone()), _ => None });
        if settled.is_some() || reduction.effects.contains(&outbox::Effect::Commit) {
            let mut next = self.registry().clone();
            match &settled {
                None => next.outbox[index].outbound = reduction.state.clone(),
                Some(settled) => {
                    next.outbox.remove(index);
                    // Delivered, or nobody left to tell: either way that event is settled.
                    for (worker, told) in &wake.workers {
                        if let Some(worker) = next.workers.get_mut(worker) { worker.notified = Some(told.clone()); }
                    }
                    if let Settled::Undelivered(reason) = settled {
                        next.undelivered.push(Undelivered { message_id: wake.message_id.clone(), coordinator: wake.coordinator.clone(),
                                                            reason: (*reason).into(), at: crate::model::now() });
                        let excess = next.undelivered.len().saturating_sub(UNDELIVERED_KEPT);
                        next.undelivered.drain(..excess);
                    }
                }
            }
            self.commit(next)?;
        }
        Ok(Some((Wake { outbound: reduction.state, ..wake }, reduction.effects)))
    }

    /// Reduces `event` for the app's agent (M14) and saves what it decided,
    /// with the rebinding a replacement's handoff step implies, before any
    /// effect it asks for runs.
    fn reduce_agent(&mut self, project: &str, event: m14::Event) -> Result<Vec<m14::Effect>> {
        self.resolve()?;
        let agent = self.registry().agents.get(project).cloned().context("The app has no agent")?;
        let reduction = m14::reduce(agent.lifecycle, event);
        if let Disposition::ProtocolFault(fault) = &reduction.disposition {
            debug_assert!(false, "{fault}");
            eprintln!("Agent lifecycle fault for {project}: {fault}");
        }
        #[cfg(debug_assertions)]
        for violation in m14::violations(&reduction.state) {
            eprintln!("Agent lifecycle invariant broken for {project}: {}", violation.0);
        }
        let rebind = reduction.effects.contains(&m14::Effect::Rebind);
        if rebind || reduction.effects.contains(&m14::Effect::Commit) {
            let mut next = self.registry().clone();
            if let (true, Lifecycle::Replacing { replacement, .. }) = (rebind, &reduction.state) {
                Agents::rebind(&mut next, project, &replacement.previous, &replacement.thread_id);
            }
            if let Some(agent) = next.agents.get_mut(project) { agent.lifecycle = reduction.state; }
            self.commit(next)?;
        }
        Ok(reduction.effects)
    }

    /// Reduces `event` for the app's upkeep record and saves the result, with
    /// the queued fresh start it may call for. A fresh start is only queued
    /// for an agent still ready on the same thread; otherwise nothing is
    /// saved and nothing happens.
    fn reduce_upkeep(&mut self, project: &str, event: m26::Event) -> Result<Vec<m26::Effect>> {
        self.resolve()?;
        let reduction = m26::reduce(self.registry().upkeep.get(project).cloned(), event);
        if let Disposition::ProtocolFault(fault) = &reduction.disposition {
            debug_assert!(false, "{fault}");
            eprintln!("Upkeep fault for {project}: {fault}");
        }
        let fresh = reduction.effects.iter().find_map(|e| match e { m26::Effect::StartFresh(r) => Some(r.clone()), _ => None });
        if fresh.is_none() && !reduction.effects.contains(&m26::Effect::Commit) {
            return Ok(reduction.effects);
        }
        let mut next = self.registry().clone();
        if let Some(reading) = fresh {
            let thread = reduction.state.as_ref().map(|r| r.thread.as_str());
            let Some(agent) = next.agents.get_mut(project)
                .filter(|a| matches!(a.lifecycle, Lifecycle::Ready { .. }) && Some(a.thread_id.as_str()) == thread) else { return Ok(vec![]) };
            let nightly = matches!(reading.decision, crate::upkeep::Tidy::Fresh { nightly: true });
            let note = format!("Squircle started this conversation fresh{} because the previous one had grown to {} tokens \
                while the user was away. Ask the history subagent about anything earlier.", if nightly { " overnight" } else { "" },
                crate::upkeep::tokens(reading.tokens));
            agent.lifecycle = Lifecycle::ResetQueued { reset: Reset::Fresh { note: Some(note) }, error: None, failures: 0 };
        }
        match reduction.state {
            Some(record) => next.upkeep.insert(project.into(), record),
            None => next.upkeep.remove(project),
        };
        self.commit(next)?;
        Ok(reduction.effects)
    }

    fn reduce_boot(&mut self, id: &str, event: BootEvent) -> Result<Vec<BootEffect>> {
        self.resolve()?;
        let Some(worker) = self.registry().workers.get(id) else { return Ok(vec![BootEffect::Done]) };
        let reduction = m15::bootstrap(worker.stage.clone(), event);
        if reduction.effects.contains(&BootEffect::Commit) {
            let mut next = self.registry().clone();
            if let Some(worker) = next.workers.get_mut(id) { worker.stage = reduction.state; }
            self.commit(next)?;
        }
        Ok(reduction.effects)
    }

    /// Reduces `event` for a worker's archive and, for a registered worker,
    /// saves the new stage before any effect it asks for runs. Returns the
    /// stage it decided and the effects.
    fn reduce_archive(&mut self, id: &str, registered: bool, stage: Stage, event: m15::ArchiveEvent) -> Result<(Stage, Vec<m15::ArchiveEffect>)> {
        let mut stage = stage;
        if registered {
            self.resolve()?;
            stage = self.registry().workers.get(id).context("The worker is gone from the registry")?.stage.clone();
        }
        let reduction = m15::archive(stage, event);
        if let Disposition::ProtocolFault(fault) = &reduction.disposition {
            debug_assert!(false, "{fault}");
            eprintln!("Archive fault for {id}: {fault}");
        }
        if registered && reduction.effects.contains(&m15::ArchiveEffect::Commit) {
            let mut next = self.registry().clone();
            if let Some(worker) = next.workers.get_mut(id) { worker.stage = reduction.state.clone(); }
            self.commit(next)?;
        }
        Ok((reduction.state, reduction.effects))
    }

    /// The command for `purpose` a caller waits for: the one saved for it
    /// while T3 left it unanswered, or a new one, saved before it is sent.
    fn intent(&mut self, purpose: String, build: impl FnOnce(&Identity) -> Command) -> Result<Command> {
        self.resolve()?;
        if let Some(pending) = self.registry().intents.iter().find(|p| p.purpose == purpose) {
            return Ok(pending.command.clone());
        }
        let command = build(&identity());
        let mut next = self.registry().clone();
        next.intents.push(Pending { purpose, command: command.clone(), at: crate::model::now() });
        let excess = next.intents.len().saturating_sub(INTENTS_KEPT);
        next.intents.drain(..excess);
        self.commit(next)?;
        Ok(command)
    }
}

pub struct Agents {
    root: PathBuf,
    /// The squircle executable and its arguments, for instructions to agents.
    cli: String,
    /// The registry, T3's shell and the connection; reached only by letters.
    owner: Owner<State>,
    view: Snapshot<View>,
    /// Stands in for T3 in tests.
    fake: std::sync::OnceLock<Arc<dyn Peer>>,
    /// One operation at a time per project (create, reset) and per worker
    /// (archive), so concurrent requests see each other's result.
    ops: Lanes<String>,
    /// One spawn at a time per agent and branch.
    spawning: Lanes<String>,
    /// One flush at a time, so overlapping triggers cannot send twice.
    flushing: Lane,
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
    Ok(crate::git::text(dir, args).await?.trim().to_string())
}

/// The project root that contains `cwd` most closely, comparing resolved
/// paths so symlinked aliases match. Two projects with the same root are
/// ambiguous: all of their indexes.
pub(crate) fn deepest_root(roots: &[&Path], cwd: &Path) -> std::result::Result<Option<usize>, Vec<usize>> {
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
        let contained = Process::new("git").arg("-C").arg(root).args(["merge-base", "--is-ancestor", tip, base])
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
/// Proof that T3 reported the worker's session stopped (or no thread at
/// all) on the live shell; only `Agents::stopped` makes one, and removing a
/// worker's files takes one.
struct StopReceipt(());

async fn remove(root: &Path, state: &GitState, discard: bool, _stopped: &StopReceipt) -> Result<Removed> {
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

/// See `Agents::build_owner`.
fn owner<'a>(registry: &'a Registry, tasks: &[crate::tasks::Task], thread: Option<&str>, build: &str) -> Option<&'a Agent> {
    let by_thread = thread.and_then(|t| {
        let coordinator = registry.workers.get(t).map_or(t, |w| w.coordinator.as_str());
        registry.agents.values().find(|a| a.thread_id == coordinator)
    });
    by_thread.or_else(|| tasks.iter().find(|t| t.builds.iter().any(|b| b == build)).and_then(|t| registry.agents.get(&t.project_id)))
}

impl Agents {
    pub fn open(root: &Path, server: &str, tasks: Arc<Tasks>) -> Result<Arc<Self>> {
        let file = JsonFile::new(root.join("agents.json"));
        let (registry, revision) = file.read()?.unwrap_or_default();
        let gate: RegistryGate = Gate::restore(registry, revision, file);
        let registry = Arc::new(gate.committed().clone());
        let status: Arc<str> = "Not connected to T3".into();
        let shell = Arc::new(Shell::default());
        let (view, snapshot) = Published::new(View { registry: registry.clone(), shell: shell.clone(), status: status.clone(), t3: None });
        let state = State {
            gate, shell, status, t3: None, published: (registry, revision), view,
            flush_scheduled: false, flush_failures: 0, sim_waiting: Default::default(), resets: Default::default(),
        };
        Ok(Arc::new(Self {
            root: root.to_path_buf(),
            cli: cli_invocation(root, server),
            owner: Owner::spawn("agents", state),
            view: snapshot,
            fake: std::sync::OnceLock::new(),
            ops: Lanes::new("agent operations", Rank::AgentOp),
            spawning: Lanes::new("worker spawns", Rank::AgentSpawn),
            flushing: Lane::new(Rank::AgentFlush),
            push: std::sync::OnceLock::new(),
            tasks,
        }))
    }

    /// The registry as last saved.
    fn registry(&self) -> Arc<Registry> {
        self.view.get().registry.clone()
    }

    /// T3's shell as last received.
    fn shell(&self) -> Arc<Shell> {
        self.view.get().shell.clone()
    }

    /// Changes the registry and saves it before anyone can read the change.
    /// A failed save leaves everything as it was; one whose outcome is
    /// unknown is written again before the next change.
    async fn change<T: Send + 'static>(&self, f: impl FnOnce(&mut Registry) -> T + Send + 'static) -> Result<T> {
        self.change_if(|registry| Some(f(registry))).await.map(|changed| changed.expect("always changed"))
    }

    /// `change` for a closure that may find nothing to change (`None`, and
    /// then it must not have changed anything): nothing is saved.
    async fn change_if<T: Send + 'static>(&self, f: impl FnOnce(&mut Registry) -> Option<T> + Send + 'static) -> Result<Option<T>> {
        self.owner.ask(move |s| s.change_if(|registry, _| f(registry))).await
    }

    async fn client(&self) -> Result<Arc<dyn Peer>> {
        if let Some(fake) = self.fake.get() {
            return Ok(fake.clone());
        }
        let view = self.view.get();
        match &view.t3 {
            Some(client) => Ok(client.clone()),
            None => bail!("{}", view.status),
        }
    }

    /// Keeps a live copy of T3's shell and delivers wake-ups. Reconnects with
    /// backoff that doubles while connections keep failing and starts over
    /// after one that stayed up; a missing pairing is reported, not fatal to
    /// the service.
    pub async fn run(self: Arc<Self>) {
        const STABLE: Duration = Duration::from_secs(60);
        let mut delay = 1;
        loop {
            let started = std::time::Instant::now();
            let error = self.clone().session().await.unwrap_err();
            eprintln!("T3: {error:#}");
            let status: Arc<str> = format!("{error:#}").into();
            let synced = self.owner.ask(move |s| {
                s.status = status;
                s.t3 = None;
                let shell = s.shell_mut();
                let synced = shell.current();
                shell.link = Link::Offline { epoch: shell.link.epoch() };
                s.publish();
                synced
            }).await;
            if synced && started.elapsed() >= STABLE {
                delay = 1;
            }
            tokio::time::sleep(Duration::from_secs(delay)).await;
            delay = (delay * 2).min(30);
        }
    }

    /// One connection, until it fails or closes.
    async fn session(self: Arc<Self>) -> Result<std::convert::Infallible> {
        let config = T3Config::load(&self.root)?;
        let client = T3::connect(config).await?;
        let (_, mut shell) = client.subscribe("orchestration.subscribeShell", json!({}))?;
        let connected = client.clone();
        self.owner.ask(move |s| {
            let shell = s.shell_mut();
            shell.link = Link::Syncing { epoch: shell.link.epoch() + 1 };
            s.t3 = Some(connected);
            s.status = "Connected".into();
            s.publish();
        }).await;
        loop {
            tokio::select! {
                item = shell.recv() => {
                    let Some(item) = item else { break };
                    self.owner.ask(move |s| { s.consume_shell(&item); s.observe_workers(); }).await;
                    if let Some(push) = self.push.get() { push.apps_changed(self.app_views()).await; }
                    self.schedule_flush();
                    self.run_due_resets().await;
                }
                _ = client.closed() => break,
            }
        }
        bail!("T3 connection closed")
    }

    /// Applies one item of T3's shell subscription.
    #[cfg(test)]
    async fn consume_shell(&self, item: &Value) {
        let item = item.clone();
        self.owner.ask(move |s| s.consume_shell(&item)).await
    }

    fn thread(&self, id: &str) -> Option<Value> {
        self.shell().thread(id)
    }

    /// What T3 says a thread is doing, and how fresh that is. Views may show
    /// a stale observation; tasks, simulators and notifications must not
    /// stop or remove anything on one.
    pub fn observe(&self, id: &str) -> Observed<Option<ThreadObservation>> {
        self.shell().observe(id)
    }

    /// Notifications and Live Activities follow the agents from here on.
    pub fn attach_push(self: &Arc<Self>, push: Arc<crate::push::Push>) {
        push.set_threads(self.clone());
        let _ = self.push.set(push);
    }

    /// Each app's agent and live workers, for notifications.
    fn app_views(&self) -> Vec<crate::push::AppView> {
        let View { registry, shell, .. } = &*self.view.get();
        registry.agents.values().map(|agent| crate::push::AppView {
            project_id: agent.project_id.clone(),
            app: shell.project(&agent.project_id).and_then(|p| p["title"].as_str()).unwrap_or("App").to_string(),
            agent: shell.thread(&agent.thread_id).map(|row| (agent.thread_id.clone(), row)),
            workers: registry.workers.iter()
                .filter(|(_, w)| w.stage.live() && w.coordinator == agent.thread_id)
                .filter_map(|(id, w)| Some((id.clone(), w.title.clone(), shell.thread(id)?)))
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
        let View { registry, shell, .. } = &*self.view.get();
        if let Some(agent) = registry.agents.values().find(|a| a.thread_id == thread) {
            return Some(agent.project_id.clone());
        }
        if let Some(worker) = registry.workers.get(thread) {
            return Some(worker.project_id.clone());
        }
        shell.threads.get(thread).and_then(|t| t["projectId"].as_str().map(str::to_string))
    }

    /// An app agent's or worker's thread (not one the user started in T3).
    pub fn is_squircle_thread(&self, id: &str) -> bool {
        let registry = self.registry();
        registry.workers.contains_key(id) || registry.agents.values().any(|a| a.thread_id == id)
    }

    /// A worker's title, even once T3 has archived its thread.
    pub fn worker_title(&self, id: &str) -> Option<String> {
        self.registry().workers.get(id).map(|w| w.title.clone())
    }

    /// The user's latest message to an app agent: where a task it adds now
    /// came from.
    pub async fn source_message(&self, thread: &str) -> Option<Source> {
        self.agent_for_thread(thread)?;
        let client = self.ready().await.ok()?;
        let detail = self.thread_detail(&*client, thread).await.ok()?;
        detail["messages"].as_array()?.iter().rev()
            .find(|m| users_own(m) && !m["text"].as_str().unwrap_or("").starts_with('['))
            .and_then(|m| m["id"].as_str().or(m["messageId"].as_str()))
            .map(|id| Source { thread_id: thread.into(), message_id: id.into() })
    }

    /// The live T3 connection once its thread list has arrived.
    pub async fn connection(&self) -> Result<Arc<T3>> {
        self.ready().await?;
        self.view.get().t3.clone().with_context(|| self.status())
    }

    /// The squircle invocation agents are told to use.
    pub fn cli(&self) -> &str {
        &self.cli
    }

    async fn ready(&self) -> Result<Arc<dyn Peer>> {
        let client = self.client().await?;
        for _ in 0..50 {
            if self.shell().current() {
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
        let this = self.clone();
        tokio::spawn(async move {
            let scheduled = this.owner.ask(|s| {
                if s.flush_scheduled || !s.has_due_wakes() {
                    return false;
                }
                s.flush_scheduled = true;
                true
            }).await;
            if !scheduled {
                return;
            }
            tokio::time::sleep(delay).await;
            this.owner.ask(|s| s.flush_scheduled = false).await;
            match this.flush().await {
                Ok(()) => {
                    this.owner.ask(|s| s.flush_failures = 0).await;
                    // An update whose attempt failed is due again at its own
                    // saved time, even if T3 sends nothing new meanwhile.
                    if let Some(at) = this.next_retry() {
                        this.schedule_flush_in(Duration::from_secs(at.saturating_sub(crate::model::now()).max(1)));
                    }
                }
                Err(error) => {
                    eprintln!("Wake-up not delivered: {error:#}");
                    let failures = this.owner.ask(|s| {
                        s.flush_failures = (s.flush_failures + 1).min(6);
                        s.flush_failures
                    }).await;
                    this.schedule_flush_in(Duration::from_secs(outbox::backoff(failures)));
                }
            }
        });
    }

    /// Follows workers in T3's shell (see `State::observe_workers`).
    #[cfg(test)]
    async fn observe_workers(&self) {
        self.owner.ask(|s| s.observe_workers()).await
    }

    /// Workers whose state calls for a wake-up their coordinator has not had
    /// and that is not already queued. Only from a current shell.
    async fn due_wakes(&self) -> Vec<(String, Worker, WorkerEvent)> {
        self.owner.ask(|s| s.due_wakes()).await
    }

    #[cfg(test)]
    async fn has_due_wakes(&self) -> bool {
        self.owner.ask(|s| s.has_due_wakes()).await
    }

    /// When the soonest queued update that failed is due again.
    fn next_retry(&self) -> Option<u64> {
        self.registry().outbox.iter().filter_map(|w| w.outbound.retry_at).min()
    }

    /// Queues the due wake-ups, then delivers the queue in order. Each queued
    /// update keeps its message ID, and each attempt its saved command
    /// identity: an unanswered one is sent again as the same command, which
    /// T3 answers from its receipt if it already has it.
    async fn flush(&self) -> Result<()> {
        self.flushing.run(async {
            let client = self.client().await?;
            let mut due = vec![];
            for (id, worker, mut event) in self.due_wakes().await {
                // A question's request tells this one from an earlier one in the turn.
                if event.kind == EventKind::NeedsYou {
                    event.request = pending_request(&self.thread_detail(&*client, &id).await?);
                }
                if worker.notified.as_ref() != Some(&event) {
                    due.push((id, worker, event));
                }
            }
            self.queue(due).await?;
            let queued: Vec<String> = self.registry().outbox.iter().map(|w| w.message_id.clone()).collect();
            for id in queued {
                self.deliver(&*client, &id).await?;
            }
            Ok(())
        }).await
    }

    /// Takes one queued update as far as it goes now: M16 decides, each of
    /// its decisions is saved before what it asks for runs.
    async fn deliver(&self, client: &dyn Peer, id: &str) -> Result<()> {
        let Some(coordinator) = self.registry().outbox.iter().find(|w| w.message_id == id).map(|w| w.coordinator.clone()) else { return Ok(()) };
        let mut event = outbox::Event::Due { now: crate::model::now(), recipient: self.recipient(&coordinator), next: identity() };
        loop {
            let reducing = id.to_string();
            let Some((wake, effects)) = self.owner.ask(move |s| s.reduce_wake(&reducing, event)).await? else { return Ok(()) };
            let mut next = None;
            for effect in effects {
                match effect {
                    outbox::Effect::Commit | outbox::Effect::Settle(_) => {}
                    outbox::Effect::Send(identity) => {
                        let outcome = match self.wake_command(&wake, &identity) {
                            Ok(command) => client.dispatch(&command).await,
                            Err(why) => Dispatched::NotSent(why),
                        };
                        if let Dispatched::Refused(detail) | Dispatched::NotSent(detail) | Dispatched::Unknown(detail) = &outcome {
                            eprintln!("Wake-up {id} not delivered yet: {detail}");
                        }
                        next = Some(outbox::Event::Sent { outcome, now: crate::model::now(), next: self::identity() });
                    }
                    outbox::Effect::LookUp => {
                        let found = self.has_message(client, &wake.coordinator, &wake.message_id).await.map_err(|e| format!("{e:#}"));
                        next = Some(outbox::Event::LookedUp { found, now: crate::model::now(), next: identity() });
                    }
                }
            }
            match next {
                Some(following) => event = following,
                None => return Ok(()),
            }
        }
    }

    /// What the live shell says of a thread, as the machines read it.
    fn seen<T>(&self, thread: &str, f: impl Fn(Option<ThreadObservation>) -> T) -> core::Observed<T> {
        match self.observe(thread) {
            Observed::Current { epoch, value } => core::Observed::Current { epoch: Epoch(epoch), revision: Revision::default(), value: f(value) },
            Observed::Stale { epoch, value } => core::Observed::Stale { epoch: Epoch(epoch), revision: Revision::default(), last: Some(f(value)) },
            Observed::Unavailable => core::Observed::Unavailable("T3's thread list is not current".into()),
        }
    }

    /// Whether the live shell has a thread, as M16 sees it.
    fn recipient(&self, thread: &str) -> core::Observed<bool> {
        self.seen(thread, |o| o.is_some())
    }

    /// The update as T3 is sent it, under `identity`. T3 dedupes by command
    /// ID alone, so the rest may follow the thread's current mode.
    fn wake_command(&self, wake: &Wake, identity: &Identity) -> std::result::Result<Command, String> {
        let agent = self.thread(&wake.coordinator).ok_or("T3's shell no longer has the agent's thread")?;
        let mode = thread_mode(&agent).map_err(|e| e.to_string())?;
        Ok(Command::new(identity, json!({
            "type": "thread.turn.start", "threadId": wake.coordinator,
            "message": {"messageId": wake.message_id, "role": "user", "text": wake.text, "attachments": [],
                        "context": {"version": 1, "records": [wake.record]}},
            "runtimeMode": mode,
            "interactionMode": "default",
        })))
    }

    /// Records one update per coordinator for the given wake-ups.
    async fn queue(&self, due: Vec<(String, Worker, WorkerEvent)>) -> Result<()> {
        if due.is_empty() { return Ok(()) }
        let mut by_coordinator: BTreeMap<String, Vec<(String, Worker, WorkerEvent)>> = BTreeMap::new();
        for due in due {
            by_coordinator.entry(due.1.coordinator.clone()).or_default().push(due);
        }
        let label = |kind: EventKind| match kind {
            EventKind::NeedsYou => Phase::NeedsYou,
            EventKind::Error => Phase::Error,
            EventKind::Done => Phase::Done,
            EventKind::Working => Phase::Working,
        }.label();
        let wakes: Vec<Wake> = by_coordinator.into_iter().map(|(coordinator, notes)| {
            let lines: Vec<String> = notes.iter().map(|(id, w, event)| {
                let what = match event.kind {
                    EventKind::NeedsYou => "is waiting on a question or approval",
                    EventKind::Error => "stopped with an error",
                    _ => "finished its turn",
                };
                format!("- \"{}\" ({id}, {}) {what}.", w.title, w.branch)
            }).collect();
            Wake {
                coordinator,
                message_id: uuid::Uuid::new_v4().to_string(),
                workers: notes.iter().map(|(id, _, event)| (id.clone(), event.clone())).collect(),
                text: format!("[worker update]\n{}\nRun `squircle thread read ID` for details, then decide what to do next.", lines.join("\n")),
                record: Note::WorkerUpdate.record(json!({
                    "workers": notes.iter().map(|(id, w, event)| json!({"id": id, "title": w.title, "branch": w.branch, "state": label(event.kind)})).collect::<Vec<_>>()
                })),
                outbound: Outbound::default(),
                build: None,
            }
        }).collect();
        self.change(|registry| registry.outbox.extend(wakes)).await
    }

    /// Queues a service message that starts a turn in `thread`; `id` is its
    /// message ID, so queuing it again changes nothing.
    pub async fn notify(self: &Arc<Self>, thread: &str, id: &str, text: String, note: Note, payload: Value) -> Result<()> {
        let (thread, id) = (thread.to_string(), id.to_string());
        let queued = self.change_if(move |registry| {
            if registry.outbox.iter().any(|w| w.message_id == id) {
                return None;
            }
            registry.outbox.push(Wake {
                coordinator: thread, message_id: id, workers: vec![], text, record: note.record(payload),
                outbound: Outbound::default(), build: None,
            });
            Some(())
        }).await?;
        if queued.is_some() { self.schedule_flush(); }
        Ok(())
    }

    /// The threads now waiting in line for a simulator.
    pub fn set_sim_waiting(&self, threads: Vec<String>) {
        self.owner.tell(move |s| s.sim_waiting = threads.into_iter().collect());
    }

    /// Whether T3 has a message with this ID in the thread.
    async fn has_message(&self, client: &dyn Peer, thread: &str, message: &str) -> Result<bool> {
        let detail = self.thread_detail(client, thread).await?;
        Ok(detail["messages"].as_array().into_iter().flatten()
            .any(|m| m["id"] == message || m["messageId"] == message))
    }

    // MARK: Builds

    /// The app agent a build belongs to: the agent that started it, the
    /// coordinator of the worker that did, or the agent of the app whose
    /// task links it.
    pub fn build_owner(&self, thread: Option<&str>, build: &str) -> Option<Agent> {
        let tasks = self.tasks.all();
        owner(&self.registry(), &tasks, thread, build).cloned()
    }

    /// Each build's app agent thread, for the phone, in order.
    pub fn build_owners<'a>(&self, builds: impl IntoIterator<Item = (Option<&'a str>, &'a str)>) -> Vec<Option<String>> {
        let tasks = self.tasks.all();
        let registry = self.registry();
        builds.into_iter().map(|(thread, build)| owner(&registry, &tasks, thread, build).map(|a| a.thread_id.clone())).collect()
    }

    /// The live worker whose worktree holds `path`, for a build started
    /// there without naming its thread.
    pub fn worker_at(&self, path: &Path) -> Option<String> {
        let View { registry, shell, .. } = &*self.view.get();
        registry.workers.iter().filter(|(_, w)| w.stage.live()).find(|(id, _)| {
            shell.threads.get(*id).and_then(|t| t["worktreePath"].as_str()).is_some_and(|tree| path.starts_with(tree))
        }).map(|(id, _)| id.clone())
    }

    /// Remembers the turn an app agent started a build in.
    pub async fn build_started(&self, build: &str, thread: Option<&str>) -> Result<()> {
        let (build, thread) = (build.to_string(), thread.map(str::to_string));
        self.owner.ask(move |s| s.change_if(|registry, shell| {
            let thread = thread.filter(|t| registry.agents.values().any(|a| a.thread_id == *t))?;
            let turn = shell.threads.get(&thread).map(|t| ThreadObservation::decode(t))
                .filter(ThreadObservation::busy).and_then(|o| o.turn);
            let now = crate::model::now();
            registry.builds.retain(|_, w| now.saturating_sub(w.at()) < BUILD_WATCH_SECS);
            registry.builds.insert(build, BuildWatch::Started { turn, at: now });
            Some(())
        })).await.map(drop)
    }

    /// A failed build queues one update to its app agent, which wakes it to
    /// act and shows the failure in its conversation. A build that succeeded
    /// wakes nobody: the app shows its card where it finished, and a reply
    /// to it would only repeat the card.
    pub async fn build_finished(self: &Arc<Self>, build: &FinishedBuild) -> Result<()> {
        let tasks = self.tasks.all();
        let build = FinishedBuild { id: build.id.clone(), thread: build.thread.clone(), app: build.app.clone(),
                                    succeeded: build.succeeded, reason: build.reason.clone() };
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
        if queued == Some(true) { self.schedule_flush(); }
        Ok(())
    }

    // MARK: Agents

    pub fn list(&self) -> Vec<Agent> {
        self.registry().agents.values().cloned().collect()
    }

    /// The app agent for a T3 project, created on first use: a thread on
    /// Squircle's instance in the project's folder, in `runtime_mode` (the
    /// mode of an existing agent is the phone's to change on its thread).
    pub async fn ensure(&self, project_id: &str, message: Option<&str>, model: Option<&str>, runtime_mode: Option<&str>) -> Result<Agent> {
        let mode = self::runtime_mode(runtime_mode)?;
        let client = self.ready().await?;
        let agent = self.ops.run(project_id.to_string(), self.existing_or_create(&*client, project_id, model, &mode)).await?;
        if let Some(text) = message.filter(|t| !t.trim().is_empty()) {
            self.send(&agent.thread_id, text).await?;
        }
        Ok(agent)
    }

    /// Call in the project's operation lane.
    async fn existing_or_create(&self, client: &dyn Peer, project_id: &str, model: Option<&str>, mode: &str) -> Result<Agent> {
        let saved = self.registry().agents.get(project_id).cloned();
        let agent = match saved {
            Some(agent @ Agent { lifecycle: Lifecycle::Creating { .. }, .. }) => agent,
            Some(agent @ Agent { lifecycle: Lifecycle::Replacing { .. }, .. }) => return Ok(agent),
            Some(agent) => {
                // A thread T3 has not sent yet may just be new: wait for it a moment.
                let row = match self.thread(&agent.thread_id) {
                    None => self.wait_thread(&agent.thread_id).await.ok(),
                    row => row,
                };
                if row.is_some_and(|row| row["archivedAt"].is_null()) {
                    return Ok(agent);
                }
                // Archived or deleted in T3: start a new agent.
                self.reserve(client, project_id).await?
            }
            None => self.reserve(client, project_id).await?,
        };
        self.create(client, &agent, model, mode).await
    }

    /// Reserves a new agent in the registry before T3 hears of it, so a
    /// retry or a restart finishes that thread instead of making another.
    async fn reserve(&self, client: &dyn Peer, project_id: &str) -> Result<Agent> {
        let config = client.call("server.getConfig", json!({})).await?;
        let ready = config["providers"].as_array().into_iter().flatten()
            .any(|p| p["instanceId"] == INSTANCE && p["status"] == "ready");
        ensure!(ready, "T3 has no ready \"{INSTANCE}\" agent instance. Run: squircle agent setup");
        let agent = Agent {
            project_id: project_id.into(), thread_id: uuid::Uuid::new_v4().to_string(), created_at: crate::model::now(),
            lifecycle: Lifecycle::Creating { command: None },
        };
        let reserved = agent.clone();
        self.change(move |registry| registry.agents.insert(reserved.project_id.clone(), reserved)).await?;
        Ok(agent)
    }

    /// Has T3 create a reserved agent's thread (M14): the creation is saved
    /// before it is sent, and one T3 left unanswered is sent again as itself.
    async fn create(&self, client: &dyn Peer, agent: &Agent, model: Option<&str>, mode: &str) -> Result<Agent> {
        let (project, thread) = (agent.project_id.as_str(), agent.thread_id.as_str());
        let create = self.create_command(project, thread, model, mode, &identity())?;
        let mut event = m14::Event::Create { exists: self.seen(thread, |o| o.is_some()), create };
        loop {
            let mut next = None;
            for effect in self.reduce_agent(project, event).await? {
                match effect {
                    m14::Effect::Commit | m14::Effect::Rebind => {}
                    m14::Effect::SendCreate(command) => {
                        next = Some(m14::Event::Sent { outcome: client.dispatch(&command).await, next: identity() });
                    }
                    m14::Effect::Done => {
                        // T3 has it; it shows in the shell a moment later.
                        let _ = self.wait_thread(thread).await;
                        return self.registry().agents.get(project).cloned().context("The app's agent is gone");
                    }
                    m14::Effect::Failed(detail) => bail!(detail),
                    other => bail!("Unexpected step while creating the app's agent: {other:?}"),
                }
            }
            event = next.context("The app agent's creation stopped without an answer")?;
        }
    }

    fn create_command(&self, project_id: &str, thread_id: &str, model: Option<&str>, mode: &str, identity: &Identity) -> Result<Command> {
        let shell = self.shell();
        let project = shell.project(project_id).with_context(|| format!("T3 has no project {project_id}"))?;
        let model = model.map(str::to_string)
            .or_else(|| project["defaultModelSelection"]["model"].as_str().filter(|_| project["defaultModelSelection"]["instanceId"] == "claudeAgent").map(str::to_string))
            .unwrap_or_else(|| DEFAULT_MODEL.into());
        let name = project["title"].as_str().unwrap_or("App");
        Ok(Command::new(identity, json!({
            "type": "thread.create", "threadId": thread_id, "projectId": project_id,
            "title": format!("{name} agent"),
            "modelSelection": {"instanceId": INSTANCE, "model": model},
            "runtimeMode": mode, "interactionMode": "default",
            "branch": null, "worktreePath": null,
        })))
    }

    /// Reduces `event` for the app's agent (M14) and saves what it decided
    /// before any effect it asks for runs (see `State::reduce_agent`).
    async fn reduce_agent(&self, project: &str, event: m14::Event) -> Result<Vec<m14::Effect>> {
        let project = project.to_string();
        self.owner.ask(move |s| s.reduce_agent(&project, event)).await
    }

    /// The agent, its workers and its updates not sent yet follow the new
    /// thread. One that may have reached the old thread is settled there
    /// (M16), never resent.
    fn rebind(registry: &mut Registry, project: &str, previous: &str, thread: &str) {
        for worker in registry.workers.values_mut().filter(|w| w.coordinator == previous) {
            worker.coordinator = thread.into();
        }
        for wake in registry.outbox.iter_mut().filter(|w| w.coordinator == previous && w.outbound.delivery == Delivery::Queued) {
            wake.coordinator = thread.into();
        }
        if let Some(agent) = registry.agents.get_mut(project) { agent.thread_id = thread.into(); }
    }

    fn agent_for_thread(&self, thread_id: &str) -> Option<Agent> {
        self.registry().agents.values().find(|a| a.thread_id == thread_id).cloned()
    }

    // MARK: Restart and fresh start

    /// The agent named by its project or its thread.
    fn find_agent(&self, project_id: Option<&str>, thread_id: Option<&str>) -> Result<Agent> {
        let registry = self.registry();
        match (project_id, thread_id) {
            (Some(project), _) => registry.agents.get(project).cloned()
                .with_context(|| format!("The app {project} has no agent yet")),
            (None, Some(thread)) => registry.agents.values().find(|a| a.thread_id == thread).cloned()
                .with_context(|| format!("{thread} is not an app agent's thread")),
            (None, None) => bail!("Name the app (--project) or the agent's thread (--thread)"),
        }
    }

    /// Restarts or replaces an app's agent: now if it is between turns,
    /// otherwise once no turn is running. The request is saved first and
    /// cleared only once it succeeds; a failure is retried and shows as the
    /// agent's reset `error`.
    pub async fn reset(self: &Arc<Self>, project_id: Option<&str>, thread_id: Option<&str>, reset: Reset) -> Result<Value> {
        self.ready().await?;
        let project = self.find_agent(project_id, thread_id)?.project_id;
        self.ops.run(project.clone(), async {
            let agent = self.find_agent(Some(&project), None)?;
            self.thread(&agent.thread_id).context("The app agent's thread is gone")?;
            for effect in self.reduce_agent(&project, m14::Event::Request(reset)).await? {
                if let m14::Effect::Failed(detail) = effect { bail!(detail) }
            }
            let running = project.clone();
            self.owner.ask(move |s| { s.resets.insert(running); }).await;
            let result = self.perform(&project).await;
            self.reset_finished(&project, &result).await;
            result
        }).await
    }

    /// Starts the queued resets whose agent has no turn running, and resumes
    /// interrupted fresh starts.
    async fn run_due_resets(self: &Arc<Self>) {
        let due: Vec<String> = self.owner.ask(|s| {
            let due: Vec<String> = s.registry().agents.values().filter(|agent| {
                !s.resets.contains(&agent.project_id) && match agent.lifecycle {
                    Lifecycle::Replacing { .. } => s.shell.current(),
                    Lifecycle::ResetQueued { .. } | Lifecycle::Restarting { .. } =>
                        s.shell.observe(&agent.thread_id).current().flatten().is_some_and(|o| !o.busy()),
                    _ => false,
                }
            }).map(|a| a.project_id.clone()).collect();
            s.resets.extend(due.iter().cloned());
            due
        }).await;
        for project in due {
            self.clone().spawn_reset(project, Duration::ZERO);
        }
    }

    fn spawn_reset(self: Arc<Self>, project: String, delay: Duration) {
        tokio::spawn(async move {
            tokio::time::sleep(delay).await;
            let result = self.ops.run(project.clone(), self.perform(&project)).await;
            if let Err(error) = &result {
                eprintln!("Agent reset failed: {error:#}");
            }
            self.reset_finished(&project, &result).await;
        });
    }

    /// Records the outcome in the reset's own state; a failure retries it
    /// with backoff, without waiting for T3 to send anything. A deferred one
    /// waits for the shell to show its agent between turns.
    async fn reset_finished(self: &Arc<Self>, project: &str, result: &Result<Value>) {
        let (finished, failure) = (project.to_string(), result.as_ref().err().map(|e| format!("{e:#}")));
        let retry = self.change(move |registry| registry.agents.get_mut(&finished)
            .and_then(|agent| agent.lifecycle.attempted(failure))).await;
        // Unsaved, the reset is still queued in the saved lifecycle: the next
        // look at due resets starts it again.
        let retry = retry.unwrap_or_else(|error| {
            eprintln!("Agent state not saved: {error:#}");
            None
        });
        match retry {
            Some(delay) => self.clone().spawn_reset(project.into(), delay),
            None => {
                let done = project.to_string();
                self.owner.ask(move |s| { s.resets.remove(&done); }).await;
            }
        }
    }

    /// The agent thread as T3 shows it now; nothing older is acted on.
    fn observe_now(&self, thread: &str) -> Result<ThreadObservation> {
        match self.observe(thread) {
            Observed::Current { value: Some(observation), .. } => Ok(observation),
            Observed::Current { value: None, .. } => bail!("The app agent's thread is gone"),
            _ => bail!("T3's thread list is not current; try again"),
        }
    }

    /// What T3 shows now of the agent's thread and, during a replacement,
    /// of the new one: what a reset step decides on.
    fn look(&self, agent: &Agent) -> m14::Event {
        let successor = match &agent.lifecycle {
            Lifecycle::Replacing { replacement, .. } => self.seen(&replacement.thread_id, |o| o.is_some()),
            _ => core::Observed::Unavailable("no replacement".into()),
        };
        m14::Event::Look { agent: self.seen(&agent.thread_id, |o| o), successor, next: identity() }
    }

    /// Carries out the project's queued or interrupted reset (M14), each
    /// step saved before its command is sent. Call in its operation lane.
    /// Nothing is stopped while a turn may be running, the agent's or a
    /// newer one: that defers the reset until it ends.
    async fn perform(&self, project: &str) -> Result<Value> {
        let client = self.ready().await?;
        let start = self.find_agent(Some(project), None)?;
        let (action, mut previous) = match &start.lifecycle {
            Lifecycle::ResetQueued { reset: Reset::Restart, .. } | Lifecycle::Restarting { .. } => ("restart", start.thread_id.clone()),
            Lifecycle::ResetQueued { reset: Reset::Fresh { .. }, .. } => ("fresh", start.thread_id.clone()),
            Lifecycle::Replacing { replacement, .. } => ("fresh", replacement.previous.clone()),
            Lifecycle::Creating { .. } | Lifecycle::Ready { .. } =>
                return Ok(json!({"project_id": project, "thread_id": start.thread_id, "when": "done"})),
        };
        let mut event = self.look(&start);
        loop {
            let mut next = None;
            for effect in self.reduce_agent(project, event).await? {
                let agent = self.find_agent(Some(project), None)?;
                match effect {
                    m14::Effect::Commit | m14::Effect::Rebind => {}
                    m14::Effect::Send(order, identity) => {
                        let command = self.order(&agent, order, &identity)?;
                        let outcome = client.dispatch(&command).await;
                        next = Some(m14::Event::Sent { outcome, next: self::identity() });
                    }
                    m14::Effect::Gather => {
                        let plan = self.plan(&*client, &agent).await.map_err(|e| format!("{e:#}"));
                        if let Ok(plan) = &plan { previous = plan.previous.clone(); }
                        // Gathering took a while: what counts is the agent right after.
                        next = Some(m14::Event::Gathered { plan, agent: self.seen(&agent.thread_id, |o| o), next: identity() });
                    }
                    m14::Effect::LookUp => {
                        let Lifecycle::Replacing { replacement, .. } = &agent.lifecycle else { bail!("A handoff looked for outside a fresh start") };
                        let found = self.has_message(&*client, &replacement.thread_id, &replacement.message_id).await.map_err(|e| format!("{e:#}"));
                        next = Some(m14::Event::LookedUp { found, next: identity() });
                    }
                    m14::Effect::Deferred => return Ok(json!({
                        "project_id": project, "thread_id": agent.thread_id, "action": action, "when": "after-turn",
                        "next": "Happens when the agent's current turn ends. If that is you: end your turn now, telling the user in a sentence."})),
                    m14::Effect::Done if action == "restart" => return Ok(json!({
                        "project_id": project, "thread_id": agent.thread_id, "action": "restart", "when": "now",
                        "next": "The agent's next message starts a new session with the same history and gets the current instructions."})),
                    m14::Effect::Done => return Ok(json!({
                        "project_id": project, "thread_id": agent.thread_id, "previous_thread_id": previous,
                        "action": "fresh", "when": "now",
                        "next": "The new agent has the handoff and is replying; the old conversation stays readable in the app's Threads."})),
                    m14::Effect::Failed(detail) => bail!(detail),
                    m14::Effect::SendCreate(_) => bail!("Unexpected creation during a reset"),
                }
            }
            event = next.context("The reset stopped without an answer")?;
        }
    }

    /// The command for a reset step, from the saved lifecycle.
    fn order(&self, agent: &Agent, order: Order, identity: &Identity) -> Result<Command> {
        let body = match (order, &agent.lifecycle) {
            (Order::Stop, Lifecycle::Restarting { .. }) => json!({"type": "thread.session.stop", "threadId": agent.thread_id}),
            (Order::Stop, Lifecycle::Replacing { replacement, .. }) => json!({"type": "thread.session.stop", "threadId": replacement.previous}),
            (Order::Rename, Lifecycle::Replacing { replacement, .. }) => json!({
                "type": "thread.meta.update", "threadId": replacement.previous,
                "title": replacement.title.as_deref().context("The fresh start has no title for the old thread")?}),
            (Order::Create, Lifecycle::Replacing { replacement, .. }) =>
                return self.create_command(&agent.project_id, &replacement.thread_id, Some(&replacement.model), &replacement.runtime_mode, identity),
            (Order::Handoff, Lifecycle::Replacing { replacement, .. }) => json!({
                "type": "thread.turn.start", "threadId": replacement.thread_id,
                "message": Note::Handoff.message(&replacement.message_id, &replacement.handoff, json!({"previous": replacement.previous})),
                "runtimeMode": replacement.runtime_mode, "interactionMode": "default",
            }),
            (order, lifecycle) => bail!("No {order:?} command for an agent that is {lifecycle:?}"),
        };
        Ok(Command::new(identity, body))
    }

    /// A fresh start's plan: the handoff, the new thread's identities and
    /// the old thread's new title. The new agent keeps the old one's model
    /// and runtime mode; a mode T3 doesn't report holds the fresh start.
    async fn plan(&self, client: &dyn Peer, agent: &Agent) -> Result<Replacement> {
        let Lifecycle::ResetQueued { reset: Reset::Fresh { note }, .. } = &agent.lifecycle else { bail!("No fresh start is queued") };
        let handoff = self.handoff(client, agent, note.as_deref()).await?;
        let row = self.thread(&agent.thread_id).context("The app agent's thread is gone")?;
        let mode = row["runtimeMode"].as_str().filter(|mode| RUNTIME_MODES.contains(mode)).with_context(|| format!(
            "T3 doesn't report a runtime mode this service knows for the app agent ({}), so the fresh start waits",
            row["runtimeMode"].as_str().unwrap_or("none")))?;
        let app = self.shell().project(&agent.project_id)
            .and_then(|p| p["title"].as_str().map(str::to_string)).unwrap_or_else(|| "App".into());
        let day = Process::new("date").arg("+%b %-d").output().await
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default();
        Ok(Replacement {
            previous: agent.thread_id.clone(),
            thread_id: uuid::Uuid::new_v4().to_string(),
            model: row["modelSelection"]["model"].as_str().unwrap_or(DEFAULT_MODEL).into(),
            runtime_mode: mode.into(),
            handoff,
            message_id: uuid::Uuid::new_v4().to_string(),
            title: Some(format!("{app} agent (until {day})")),
            note: None,
            step: None,
            delivery: Delivery::Queued,
        })
    }

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
    fn upkeep_blocker(&self, agent: &Agent) -> Option<&'static str> {
        if !matches!(agent.lifecycle, Lifecycle::Ready { .. }) { return Some("being created or reset") }
        if !matches!(self.observe(&agent.thread_id), Observed::Current { value: Some(ref o), .. } if !o.busy()) { return Some("busy or not current") }
        if self.workers(Some(&agent.thread_id)).iter().any(|w| matches!(w["state"].as_str(), Some("working" | "starting" | "archiving"))) {
            return Some("a worker is working");
        }
        None
    }

    async fn upkeep_agent(self: &Arc<Self>, config: &crate::upkeep::Upkeep, agent: &Agent) -> Result<()> {
        use crate::upkeep::tokens;
        let thread = &agent.thread_id;
        if !crate::t3steps::valid(thread, &[]) || self.upkeep_blocker(agent).is_some() { return Ok(()); }
        let latest = |column: &str| format!("(select {column} from projection_thread_activities where thread_id='{thread}' \
            and kind='context-window.updated' order by created_at desc limit 1)");
        let rows = crate::t3steps::query(&format!("select {} reading_at, {} used, max(\
            coalesce((select max(created_at) from projection_thread_messages where thread_id='{thread}'),''), \
            coalesce((select max(created_at) from projection_thread_activities where thread_id='{thread}'),'')) last_at",
            latest("created_at"), latest("json_extract(payload_json,'$.usedTokens')")), crate::t3steps::DETAIL_READ).await?;
        let row = rows.first().context("no reading")?;
        let (Some(reading), Some(used), Some(last)) = (row["reading_at"].as_str(), row["used"].as_u64(),
            row["last_at"].as_str().and_then(crate::t3::iso_parse)) else { return Ok(()) };
        let idle = (crate::model::now() as f64 - last).max(0.0) as u64;
        let wanted = config.decide(used, idle, crate::upkeep::local_hour())
            .map(|decision| Reading { origin: Origin::Automatic, decision, at: Some(reading.into()), tokens: used });
        // The read took a while: decide only on what T3 shows now.
        let Some(agent) = self.registry().agents.get(&agent.project_id).filter(|a| a.thread_id == *thread).cloned() else { return Ok(()) };
        if self.upkeep_blocker(&agent).is_some() { return Ok(()); }
        let compact = self.compact_command(thread, &format!("Compacted while idle ({} tokens)", tokens(used)), used)?;
        let event = m26::Event::Checked { thread: thread.clone(), reading: wanted.clone(), compact };
        match self.run_upkeep(&agent.project_id, event).await? {
            Some(Dispatched::Accepted(_)) => eprintln!("Agent upkeep: compacting {thread} at {} tokens, idle {} min", tokens(used), idle / 60),
            Some(Dispatched::Refused(detail) | Dispatched::NotSent(detail) | Dispatched::Unknown(detail)) =>
                eprintln!("Agent upkeep: compaction of {thread} not confirmed: {detail}"),
            None => {}
        }
        Ok(())
    }

    /// Feeds one event to the app's upkeep (M26) and carries out what it
    /// decides, each decision saved before its effect runs. A fresh start is
    /// saved as the agent's queued reset in the same change, then left to
    /// the reset runner. Returns what the last compaction sent got.
    async fn run_upkeep(self: &Arc<Self>, project: &str, event: m26::Event) -> Result<Option<Dispatched>> {
        let mut event = Some(event);
        let mut outcome = None;
        while let Some(current) = event.take() {
            let reducing = project.to_string();
            for effect in self.owner.ask(move |s| s.reduce_upkeep(&reducing, current)).await? {
                match effect {
                    m26::Effect::Commit => {}
                    m26::Effect::StartFresh(reading) => {
                        eprintln!("Agent upkeep: fresh start of the {project} agent at {} tokens", crate::upkeep::tokens(reading.tokens));
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
    pub async fn compact(self: &Arc<Self>, project_id: Option<&str>, thread_id: Option<&str>) -> Result<Value> {
        self.ready().await?;
        let agent = self.find_agent(project_id, thread_id)?;
        ensure!(matches!(agent.lifecycle, Lifecycle::Ready { .. }), "The app's agent is being created or reset");
        ensure!(!self.observe_now(&agent.thread_id)?.busy(), "The agent is working; compact it once its turn ends");
        let compact = self.compact_command(&agent.thread_id, "Compacted", 0)?;
        match self.run_upkeep(&agent.project_id, m26::Event::Manual { thread: agent.thread_id.clone(), compact }).await? {
            Some(Dispatched::Accepted(_)) => {}
            Some(Dispatched::Unknown(detail) | Dispatched::NotSent(detail)) =>
                bail!("T3 has not confirmed the compaction ({detail}); the same one is sent again when the agent is next idle"),
            Some(Dispatched::Refused(detail)) => bail!(detail),
            None => bail!("The compaction was not sent"),
        }
        Ok(json!({"project_id": agent.project_id, "thread_id": agent.thread_id, "action": "compact",
                  "next": "The agent's context is being compacted; T3 shows the sizes before and after."}))
    }

    /// The command that asks Claude to compact the agent's context, keeping
    /// what the agent needs, with its identity; `line` is what the
    /// conversation shows for it.
    fn compact_command(&self, thread: &str, line: &str, tokens: u64) -> Result<Command> {
        let row = self.thread(thread).context("The app agent's thread is gone")?;
        let mode = thread_mode(&row)?;
        let text = "/compact Keep: the user's open tasks and where each stands, decisions and preferences they stated, \
            workers still running or waiting and their branches, and the last few exchanges. Drop tool output and finished detail.";
        let record = Note::Upkeep.labeled(line, json!({"action": "compact", "tokens": tokens}));
        Ok(Command::new(&identity(), json!({
            "type": "thread.turn.start", "threadId": thread,
            "message": Note::with_record(&uuid::Uuid::new_v4().to_string(), text, record),
            "runtimeMode": mode,
            "interactionMode": row["interactionMode"].as_str().unwrap_or("default"),
        })))
    }

    /// What a new agent needs from the old one, gathered without a model:
    /// the app, recent commits, open workers, what the user said lately, the
    /// old agent's last reply and its own note.
    async fn handoff(&self, client: &dyn Peer, agent: &Agent, note: Option<&str>) -> Result<String> {
        let project = self.shell().project(&agent.project_id).cloned().context("The app's T3 project is gone")?;
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
            .filter(|m| users_own(m))
            .filter_map(|m| m["text"].as_str())
            .map(|t| t.split("\n\n---\n").next().unwrap_or(t).trim())
            .filter(|t| !t.is_empty() && !t.starts_with('['))
            .map(|t| if t.chars().count() > 300 { format!("{}…", t.chars().take(300).collect::<String>()) } else { t.to_string() })
            .collect();
        let said = said[said.len().saturating_sub(8)..].iter().map(|t| format!("\n- {}", t.replace('\n', " "))).collect::<String>();
        let mut text = format!(
            "[handoff] You are taking over as {app}'s app agent in a fresh conversation. \
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
    pub async fn context(&self, cwd: &Path) -> String {
        let candidates: Vec<(Agent, String, PathBuf)> = {
            let View { registry, shell, .. } = &*self.view.get();
            registry.agents.values().filter_map(|a| {
                let project = shell.project(&a.project_id)?;
                let root = PathBuf::from(project["workspaceRoot"].as_str()?);
                Some((a.clone(), project["title"].as_str().unwrap_or("this app").to_string(), root))
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
        let refreshed = if agent.lifecycle == (Lifecycle::Ready { refresh: true }) {
            let project = agent.project_id.clone();
            let cleared = self.change_if(move |registry| {
                let agent = registry.agents.get_mut(&project).filter(|a| a.lifecycle == Lifecycle::Ready { refresh: true })?;
                agent.lifecycle = Lifecycle::Ready { refresh: false };
                Some(())
            }).await;
            // Unsaved, the next turn gets the instructions again.
            if let Err(error) = cleared { eprintln!("Agent state not saved: {error:#}"); }
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
        let notes = match crate::notes::load(&self.root, &agent.project_id) {
            Ok(notes) if notes.notes.is_empty() => " none yet; add the user's preferences, decisions and gotchas as you learn them".to_string(),
            Ok(notes) => notes.notes.iter().map(|n| format!("\n- {}", n.text)).collect(),
            Err(error) => format!(" unreadable ({error:#})"),
        };
        format!(
            "[squircle] You are {app}'s app agent: you coordinate, and worker threads do the implementation \
             (`{cli} thread --help`), unless the user says otherwise. Every piece of delegated work, reviews and research included, \
             runs as a T3 worker via `thread spawn` (`--provider codex --model <slug> --effort <level>` for Codex), never by running the codex \
             or claude CLIs yourself or through subagents or workflows, so the user can see it; the one subagent is `squircle:history`, \
             cheap and read-only: ask it, in the foreground, before answering anything about past work or decisions. Archive a worker once its work is merged or abandoned, \
             so no branches or worktrees are left behind. Your thread id: {id}. Your workers: {board}\n\
             Your tasks, the user's open asks (`{cli} task --help`):{tasks}\n\
             Your notes (`{cli} notes --help`; keep them current):{notes}\n\
             Add a task for each new ask, in the user's words; link its workers (`thread spawn --task`) and builds (`build start --task`), \
             attach screenshots or clips worth seeing, and set its status and note when that changes (linked workers and builds move it too).\n\
             Reply for a phone: short and conversational. Show pictures as ![..](/absolute/path) and clips as [..](/absolute/path), \
             copied out of /tmp into ~/.t3/userdata/attachments. Builds you or your workers start (`build start --thread {id}`) appear in the chat \
             by themselves when they finish, with Install or why they failed: don't promise otherwise or paste build IDs. \
             No bare paths, IDs, branch names, commit hashes or Squircle internals unless asked.{refreshed}",
            cli = self.cli, id = agent.thread_id,
        )
    }

    // MARK: Workers

    pub fn workers(&self, coordinator: Option<&str>) -> Vec<Value> {
        let View { registry, shell, .. } = &*self.view.get();
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
        let View { registry, shell, .. } = &*self.view.get();
        registry.workers.iter().map(|(id, w)| {
            let state = if w.stage == Stage::Archived { "archived" } else { shell.threads.get(id).map_or("missing", |t| worker_state(t)) };
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
                 To run, check or demo the app in a simulator, first run {cli} sim start --thread {id} (see sim --help): Squircle records it, the user watches it live, and the recording appears in your turn. Drive it with the agent-device command it returns; run {cli} sim stop --thread {id} when done (it shuts the simulator down). If it says you're queued, end your turn: a [simulator ready] message wakes you when one is held for you; run sim start again then. Use sim start for every simulator: don't boot or create simulators with simctl or xcodebuild, and don't run agent-device record or device_open. \
                 For signed builds: {cli} build start --thread {id} ... (see build start --help); the user gets it in their chat when it finishes. \
                 A performance recording the user sends from the phone is a linked .perf.json: {cli} perf show PATH summarizes it (hitches with symbolicated main-thread stacks, timeline). \
                 The user also reads your replies on their phone: keep them short and plain, show pictures as ![..](/absolute/path) and clips as [..](/absolute/path) \
                 (copied out of /tmp into ~/.t3/userdata/attachments), and don't present bare paths or IDs as information.",
                cli = self.cli
            );
            let now = crate::t3::iso_now();
            let message_id = uuid::Uuid::new_v4().to_string();
            let command = json!({
                "type": "thread.turn.start", "threadId": id,
                "message": Note::Task.message(&message_id, &text, json!({"from": coordinator})),
                "modelSelection": selection, "runtimeMode": mode, "interactionMode": "default",
                "bootstrap": {
                    "createThread": {"projectId": agent.project_id, "title": title, "modelSelection": selection,
                                     "runtimeMode": mode, "interactionMode": "default", "branch": null, "worktreePath": null, "createdAt": now},
                    "prepareWorktree": {"projectCwd": project["workspaceRoot"], "baseBranch": base, "branch": branch},
                    "runSetupScript": true,
                },
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
    /// message IDs) only if T3 doesn't show it. T3 runs a bootstrap's
    /// worktree setup before its receipt check, so each attempt is its own
    /// command. Call in the worker's operation lane.
    async fn bootstrap(&self, client: &dyn Peer, id: &str, again: bool) -> Result<()> {
        let mut effects = match again {
            true => self.reduce_boot(id, BootEvent::Look { thread: self.seen(id, |o| o.is_some()) }).await?,
            false => vec![BootEffect::Send],
        };
        loop {
            let Some(Stage::Bootstrapping { message_id, command }) = self.registry().workers.get(id).map(|w| w.stage.clone()) else { return Ok(()) };
            let mut next = None;
            for effect in effects {
                match effect {
                    BootEffect::Commit => {}
                    BootEffect::Send => next = Some(BootEvent::Sent(client.dispatch(&Command::new(&identity(), command.clone())).await)),
                    BootEffect::Confirm(detail) => {
                        let found = match self.thread(id) {
                            Some(_) => Ok(true),
                            None => self.has_message(client, id, &message_id).await.map_err(|e| format!("{e:#}")),
                        };
                        next = Some(BootEvent::Confirmed { found, detail });
                    }
                    BootEffect::Done => return Ok(()),
                    BootEffect::Failed(detail) => bail!(detail),
                }
            }
            effects = self.reduce_boot(id, next.context("The worker's bootstrap stopped without an answer")?).await?;
        }
    }

    async fn reduce_boot(&self, id: &str, event: BootEvent) -> Result<Vec<BootEffect>> {
        let id = id.to_string();
        self.owner.ask(move |s| s.reduce_boot(&id, event)).await
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
        let from = self.registry().workers.get(thread_id).map(|w| w.coordinator.clone());
        self.send_with(thread_id, text, Some((Note::AgentMessage, json!({"from": from})))).await
    }

    async fn send_with(&self, thread_id: &str, text: &str, note: Option<(Note, Value)>) -> Result<()> {
        let client = self.ready().await?;
        let thread = self.wait_thread(thread_id).await?;
        let mode = thread_mode(&thread)?.to_string();
        let purpose = format!("send {thread_id} {}\n{text}", note.as_ref().map_or("user", |(note, _)| note.kind()));
        let id = uuid::Uuid::new_v4().to_string();
        let message = match note {
            Some((note, payload)) => note.message(&id, text, payload),
            None => json!({"messageId": id, "role": "user", "text": text, "attachments": []}),
        };
        let (thread_id, interaction) = (thread_id.to_string(), thread["interactionMode"].as_str().unwrap_or("default").to_string());
        self.dispatch_intent(&*client, purpose, move |identity| Command::new(identity, json!({
            "type": "thread.turn.start", "threadId": thread_id,
            "message": message,
            "runtimeMode": mode,
            "interactionMode": interaction,
        }))).await?;
        Ok(())
    }

    /// Sends a command a caller waits for under a saved identity. Asked
    /// again while T3 has left it unanswered, the same request sends that
    /// same command (T3 answers it from its receipt if it has it), never a
    /// second; any answer settles it.
    async fn dispatch_intent(&self, client: &dyn Peer, purpose: String, build: impl FnOnce(&Identity) -> Command + Send + 'static) -> Result<Value> {
        let command = self.owner.ask(move |s| s.intent(purpose, build)).await?;
        let outcome = client.dispatch(&command).await;
        if !matches!(outcome, Dispatched::Unknown(_)) {
            let settled = command.clone();
            let forgotten = self.change_if(move |registry| {
                let index = registry.intents.iter().position(|p| p.command.id() == settled.id())?;
                registry.intents.remove(index);
                Some(())
            }).await;
            // Unsaved, it only stays as a record the same request would send again (T3 answers from its receipt).
            if let Err(error) = forgotten { eprintln!("Settled command not saved: {error:#}"); }
        }
        match outcome {
            Dispatched::Accepted(value) => Ok(value),
            Dispatched::Unknown(detail) =>
                bail!("T3 has not confirmed it ({detail}). Ask again with the same text: the same one is sent again, never a second"),
            Dispatched::Refused(detail) | Dispatched::NotSent(detail) => bail!(detail),
        }
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
        let worker = self.registry().workers.get(id).cloned();
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
        let purpose = format!("answer {id} {request}\n{text}");
        let id = id.to_string();
        self.dispatch_intent(&*client, purpose, move |identity| Command::new(identity,
            json!({"type": "thread.user-input.respond", "threadId": id, "requestId": request, "answers": answers}))).await?;
        Ok(())
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
        self.ops.run(id.to_string(), self.archive_in_lane(&*client, id, discard)).await
    }

    async fn archive_in_lane(&self, client: &dyn Peer, id: &str, discard: bool) -> Result<Value> {
        let is_agent = self.registry().agents.values().any(|a| a.thread_id == id);
        ensure!(!is_agent, "That is an app agent's thread, not a worker");
        let worker = self.registry().workers.get(id).cloned();
        let observed = self.observe(id).current().context("T3's thread list is not current; try again")?;
        ensure!(observed.is_some() || worker.is_some(), "T3 has no thread {id}");
        let title = worker.as_ref().map(|w| w.title.clone()).or_else(|| self.thread(id).and_then(|r| r["title"].as_str().map(str::to_string)));
        // A thread Squircle didn't start goes through the same steps, unsaved.
        let mut stage = worker.as_ref().map_or(Stage::Active, |w| w.stage.clone());
        let mut result = json!({"archived": id, "stopped": false, "title": title});
        let mut inspected = None;
        let look = || m15::ArchiveEvent::Look { thread: self.seen(id, |o| o), discard, next: identity() };
        let mut event = look();
        loop {
            let mut next = None;
            let (archiving, registered) = (id.to_string(), worker.is_some());
            let (decided, effects) = self.owner.ask(move |s| s.reduce_archive(&archiving, registered, stage, event)).await?;
            stage = decided;
            for effect in effects {
                match effect {
                    m15::ArchiveEffect::Commit => {}
                    m15::ArchiveEffect::Send(order, identity) => {
                        let kind = match order { ArchiveOrder::Stop => "thread.session.stop", ArchiveOrder::Archive => "thread.archive" };
                        let outcome = client.dispatch(&Command::new(&identity, json!({"type": kind, "threadId": id}))).await;
                        if order == ArchiveOrder::Stop && matches!(outcome, Dispatched::Accepted(_)) { result["stopped"] = json!(true); }
                        next = Some(m15::ArchiveEvent::Sent { outcome, next: self::identity() });
                    }
                    m15::ArchiveEffect::AwaitStopped => next = Some(m15::ArchiveEvent::Stopped(self.wait_stopped(id).await.is_ok())),
                    m15::ArchiveEffect::Inspect => {
                        let found = self.inspect_worker(id, worker.as_ref()).await;
                        let blocker = found.as_ref().map(|f| f.as_ref().and_then(|(_, state)| state.blocker())).map_err(|e| format!("{e:#}"));
                        inspected = found.ok().flatten();
                        next = Some(m15::ArchiveEvent::Inspected { blocker, discard });
                    }
                    m15::ArchiveEffect::Remove => {
                        // Stopped right now, not just when it was inspected.
                        let removed = match (&inspected, self.stopped(id)) {
                            (_, None) => Err("Its session is live again, so nothing more was removed".to_string()),
                            (None, Some(_)) => Ok(()),
                            (Some((root, state)), Some(receipt)) => match remove(root, state, discard, &receipt).await {
                                Ok(cleaned) => {
                                    result["removed_worktree"] = json!(cleaned.worktree);
                                    result["deleted_branch"] = json!(cleaned.branch);
                                    result["discarded"] = json!(discard && state.blocker().is_some());
                                    Ok(())
                                }
                                Err(error) => Err(format!("{error:#}")),
                            },
                        };
                        next = Some(m15::ArchiveEvent::Removed(removed));
                    }
                    m15::ArchiveEffect::Look => next = Some(look()),
                    m15::ArchiveEffect::Refused(why) | m15::ArchiveEffect::Failed(why) => bail!(why),
                    m15::ArchiveEffect::Done => return Ok(result),
                    m15::ArchiveEffect::NeverStarted =>
                        return Ok(json!({"archived": id, "stopped": false, "title": title, "never_started": true})),
                }
            }
            event = next.context("The archive stopped without an answer")?;
        }
    }

    /// The worker's checkout and its Git state, if its project has a folder.
    async fn inspect_worker(&self, id: &str, worker: Option<&Worker>) -> Result<Option<(PathBuf, GitState)>> {
        let row = self.thread(id).unwrap_or(Value::Null);
        let branch = worker.map(|w| w.branch.clone()).or_else(|| row["branch"].as_str().map(str::to_string));
        let project = worker.map(|w| w.project_id.clone()).or_else(|| row["projectId"].as_str().map(str::to_string));
        let root = project.and_then(|p| self.shell().project(&p).and_then(|p| p["workspaceRoot"].as_str().map(PathBuf::from)));
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
    fn stopped(&self, id: &str) -> Option<StopReceipt> {
        match self.observe(id).current()? {
            Some(now) if now.execution != Execution::Stopped => None,
            _ => Some(StopReceipt(())),
        }
    }

    /// Waits for T3 to report a stopped worker's session stopped. A thread
    /// still waiting on the user, or a disconnected shell, does not count.
    async fn wait_stopped(&self, id: &str) -> Result<StopReceipt> {
        for _ in 0..300 {
            if let Some(receipt) = self.stopped(id) {
                return Ok(receipt);
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
        let root = self.shell().project(&agent.project_id)
            .and_then(|p| p["workspaceRoot"].as_str().map(PathBuf::from)).context("The app's T3 project is gone")?;
        let workers: Vec<(String, Worker)> = self.registry().workers.iter()
            .filter(|(_, w)| w.coordinator == coordinator).map(|(id, w)| (id.clone(), w.clone())).collect();
        let (mut archived, mut deleted, mut left) = (vec![], vec![], vec![]);
        for (id, worker) in workers {
            let row = self.thread(&id);
            let observed = self.observe(&id).current().context("T3's thread list is not current; try again")?;
            let worktree = row.as_ref().and_then(|t| t["worktreePath"].as_str().map(PathBuf::from));
            let entry = json!({"id": id, "title": worker.title, "branch": worker.branch});
            let reason = match (&worker.stage, &observed) {
                (Stage::Bootstrapping { .. }, _) => Some("still starting".to_string()),
                (Stage::Active, Some(now)) if matches!(now.phase(), Phase::Working | Phase::NeedsYou) => Some(format!("still {}", now.phase().label())),
                (Stage::Archived, Some(now)) if now.execution != Execution::Stopped => Some("its session is still live".into()),
                _ => None,
            };
            if let Some(reason) = reason {
                left.push(json!({"worker": entry, "reason": reason}));
                continue;
            }
            if matches!(worker.stage, Stage::FilesRemoved | Stage::Archiving(_)) {
                if !dry_run { self.archive(&id, false).await?; }
                archived.push(entry);
                continue;
            }
            let git = inspect(&root, worktree.as_deref(), Some(&worker.branch), Some(&worker.base)).await?;
            if let Some(reason) = git.blocker() {
                left.push(json!({"worker": entry, "reason": reason}));
                continue;
            }
            if worker.stage == Stage::Archived {
                if git.branch_exists || git.worktree.is_some() {
                    if !dry_run {
                        self.ops.run(id.clone(), async {
                            let receipt = self.stopped(&id).context("Its session is still live; nothing was removed")?;
                            remove(&root, &git, false, &receipt).await
                        }).await?;
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
        self.view.get().status.to_string()
    }

    /// T3's providers for the phone's model menus. T3's config also carries,
    /// per instance, the skill and command catalog of each of the last 16
    /// folders it ran a turn in (about 35 KB each, so about 1 MB with
    /// workers' worktrees), which the phone would otherwise carry over cellular.
    pub async fn providers(&self) -> Result<Value> {
        let config = self.client().await?.call("server.getConfig", json!({})).await?;
        Ok(Value::Array(config["providers"].as_array().into_iter().flatten().map(|provider| {
            let mut provider = provider.clone();
            if let Some(fields) = provider.as_object_mut() {
                for key in ["workspaceSnapshots", "skills", "slashCommands"] { fields.remove(key); }
            }
            provider
        }).collect()))
    }
}

#[cfg(test)]
// Fakes record calls behind leaf locks; never held across a call.
#[allow(clippy::disallowed_types)]
mod tests {
    use super::*;
    use std::sync::Mutex;

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
        // An agent mode T3 doesn't report, or that isn't known, is never assumed.
        assert!(worker_mode("claudeAgent", None, None).is_err());
        assert!(worker_mode("claudeAgent", Some("bogus"), None).is_err());
        assert!(worker_mode("claudeAgent", Some("auto"), Some("yolo")).is_err());
    }

    #[test]
    fn wakes_once_per_turn_outcome() {
        let wake = |row: Value| ThreadObservation::decode(&row).wake();
        // Not started yet, and running, call for nothing.
        assert_eq!(wake(thread(None, "", "starting", false)), None);
        assert_eq!(wake(thread(Some("a"), "running", "running", false)), None);
        // A question mid-turn wakes; the same turn finishing wakes again.
        assert_eq!(wake(thread(Some("a"), "running", "running", true)), Some(event("a:needs-you")));
        assert_eq!(wake(thread(Some("a"), "completed", "ready", false)), Some(event("a:done")));
        // A session that stopped between turns is still the same outcome.
        assert_eq!(wake(thread(Some("a"), "completed", "stopped", false)), Some(event("a:done")));
        assert_eq!(wake(thread(Some("b"), "error", "error", false)), Some(event("b:error")));
    }

    #[test]
    fn waiting_on_the_user_is_a_live_turn() {
        let observe = |turn: &str, session: &str, needs: bool| ThreadObservation::decode(&thread(Some("a"), turn, session, needs));
        // A question or approval keeps the turn, and its session, running.
        let asking = observe("running", "running", true);
        assert_eq!((asking.phase(), asking.execution), (Phase::NeedsYou, Execution::Running));
        assert!(observe("completed", "ready", true).busy());
        // Between turns the session is live but idle; only `stopped` is stopped.
        assert_eq!(observe("completed", "ready", false).execution, Execution::Idle);
        assert_eq!(observe("error", "error", false).execution, Execution::Idle);
        assert_eq!(observe("interrupted", "stopped", true).execution, Execution::Stopped);
        // A status this service doesn't know is not assumed stopped.
        assert!(observe("completed", "paused", false).busy());
    }

    #[test]
    fn reads_the_registry_written_before_typed_states() {
        let registry: Registry = serde_json::from_value(json!({
            "agents": {
                "p": {"project_id": "p", "thread_id": "a", "created_at": 1, "pending": {"kind": "fresh", "note": null},
                      "replacing": {"previous": "a", "thread_id": "b", "model": "m", "runtime_mode": "auto",
                                    "handoff": "h", "message_id": "m1", "handoff_sent": true}, "reset_error": "x"},
                "q": {"project_id": "q", "thread_id": "c", "created_at": 1, "refresh": true},
            },
            "workers": {"w": {"coordinator": "a", "project_id": "p", "title": "W", "branch": "w", "base": "main",
                              "created_at": 1, "notified": "t:needs-you:R", "archived": true}},
            "outbox": [{"coordinator": "a", "message_id": "m2", "workers": [["w", "t:done"]], "text": "", "record": null, "attempted": true}],
        })).unwrap();
        let Lifecycle::Replacing { replacement, error, .. } = &registry.agents["p"].lifecycle else { panic!() };
        assert_eq!((replacement.delivery, error.as_deref()), (Delivery::OutcomeUnknown, Some("x")));
        assert_eq!(registry.agents["q"].lifecycle, Lifecycle::Ready { refresh: true });
        let worker = &registry.workers["w"];
        assert_eq!((worker.stage.clone(), worker.notified.clone()), (Stage::Archived,
            Some(WorkerEvent { turn: "t".into(), kind: EventKind::NeedsYou, request: Some("R".into()) })));
        assert_eq!((registry.outbox[0].outbound.delivery, &registry.outbox[0].workers[0].1), (Delivery::OutcomeUnknown, &event("t:done")));
        // Contradictory flags are reported, not guessed at.
        assert!(serde_json::from_value::<Agent>(json!({"project_id": "p", "thread_id": "a", "created_at": 1,
            "creating": true, "pending": {"kind": "restart"}})).is_err());
    }

    fn event(key: &str) -> WorkerEvent {
        serde_json::from_value(json!(key)).unwrap()
    }

    #[test]
    fn a_second_question_in_a_turn_wakes_again() {
        let asking = ThreadObservation::decode(&thread(Some("t"), "running", "running", true));
        assert!(event("t:needs-you:A").covers(&asking.wake().unwrap()));
        // Answered: working again forgets the question, so the next is new.
        let working = ThreadObservation::decode(&thread(Some("t"), "running", "running", false));
        assert_eq!(working.progressed(Some(&event("t:needs-you:A"))), Some(event("t:working")));
        assert!(!event("t:working").covers(&asking.wake().unwrap()));
        assert_eq!(working.progressed(Some(&event("t:done"))), None);
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
    /// the shell after a delay, and remembers the messages it accepted. Like
    /// T3, it keeps a receipt per command ID: an accepted ID sent again is
    /// answered from it and changes nothing.
    #[derive(Default)]
    struct Fake {
        /// The agents it shows new threads to: the latest opened.
        agents: Mutex<std::sync::Weak<Agents>>,
        log: Mutex<Vec<Value>>,
        receipts: Mutex<HashMap<String, bool>>,
        messages: Mutex<HashMap<String, Vec<String>>>,
        activities: Mutex<HashMap<String, Value>>,
        /// The next dispatch of this type fails; `true` if T3 applied it anyway (a lost acknowledgement).
        fail: Mutex<Vec<(&'static str, bool)>>,
        shell_delay: Mutex<Duration>,
        on_dispatch: Mutex<Option<Box<dyn Fn(&Value) + Send>>>,
        /// A shell item T3 sends while a thread's detail is read.
        on_snapshot: Mutex<Option<Box<dyn Fn(&str) -> Option<Value> + Send>>>,
    }

    impl Fake {
        fn agents(&self) -> Arc<Agents> { self.agents.lock().unwrap().upgrade().unwrap() }
        fn sent(&self, kind: &str) -> Vec<Value> {
            self.log.lock().unwrap().iter().filter(|c| c["type"] == kind).cloned().collect()
        }
    }

    impl Peer for Fake {
        fn call<'a>(&'a self, tag: &'a str, _: Value) -> crate::push::BoxFuture<'a, Result<Value>> {
            assert_eq!(tag, "server.getConfig");
            Box::pin(async { Ok(json!({"providers": [{"instanceId": INSTANCE, "status": "ready"},
                {"instanceId": "claudeAgent", "driver": "claudeAgent", "status": "ready", "models": [{"slug": "m"}]}]})) })
        }
        fn dispatch<'a>(&'a self, command: &'a Command) -> crate::push::BoxFuture<'a, Dispatched> {
            Box::pin(async move {
                let command = command.body().clone();
                tokio::time::sleep(Duration::from_millis(20)).await;
                let id = command["commandId"].as_str().expect("every command has its identity").to_string();
                assert!(command["createdAt"].is_string());
                match self.receipts.lock().unwrap().get(&id) {
                    Some(true) => return Dispatched::Accepted(json!({"sequence": 1})),
                    Some(false) => return Dispatched::Refused("Previously rejected".into()),
                    None => {}
                }
                self.log.lock().unwrap().push(command.clone());
                if let Some(hook) = &*self.on_dispatch.lock().unwrap() { hook(&command); }
                let failure = {
                    let mut fail = self.fail.lock().unwrap();
                    fail.iter().position(|(kind, _)| command["type"] == *kind).map(|i| fail.remove(i).1)
                };
                if failure == Some(false) {
                    self.receipts.lock().unwrap().insert(id, false);
                    return Dispatched::Refused("T3 rejected the command".into());
                }
                self.receipts.lock().unwrap().insert(id, true);
                match command["type"].as_str() {
                    Some("thread.create") => {
                        let row = json!({"id": command["threadId"], "projectId": command["projectId"], "runtimeMode": command["runtimeMode"],
                                         "modelSelection": command["modelSelection"], "session": null, "archivedAt": null});
                        let (agents, delay) = (self.agents(), *self.shell_delay.lock().unwrap());
                        tokio::spawn(async move {
                            tokio::time::sleep(delay).await;
                            agents.consume_shell(&json!({"kind": "thread-upserted", "thread": row})).await;
                        });
                    }
                    Some("thread.turn.start") => {
                        self.messages.lock().unwrap().entry(command["threadId"].as_str().unwrap().into()).or_default()
                            .push(command["message"]["messageId"].as_str().unwrap().into());
                    }
                    _ => {}
                }
                if failure == Some(true) { return Dispatched::Unknown("T3 did not answer".into()) }
                Dispatched::Accepted(json!({"sequence": 1}))
            })
        }
        fn snapshot<'a>(&'a self, _: &'a str, payload: Value) -> crate::push::BoxFuture<'a, Result<Value>> {
            Box::pin(async move {
                let id = payload["threadId"].as_str().unwrap();
                let item = self.on_snapshot.lock().unwrap().as_ref().and_then(|hook| hook(id));
                if let Some(item) = item { self.agents().consume_shell(&item).await; }
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
    async fn fake_agents(temp: &Path, workspace: &Path, threads: Vec<Value>) -> (Arc<Agents>, Arc<Fake>) {
        let tasks = Arc::new(Tasks::open(temp).unwrap());
        let agents = Agents::open(temp, "http://127.0.0.1:1", tasks).unwrap();
        let fake = Arc::new(Fake::default());
        assert!(agents.fake.set(fake.clone()).is_ok());
        *fake.agents.lock().unwrap() = Arc::downgrade(&agents);
        agents.consume_shell(&json!({"kind": "snapshot", "snapshot": {
            "projects": [{"id": "p", "title": "App", "workspaceRoot": workspace}], "threads": threads}})).await;
        (agents, fake)
    }

    async fn registered(agents: &Agents, f: impl FnOnce(&mut Registry) + Send + 'static) {
        agents.change(f).await.unwrap();
    }

    fn worker(coordinator: &str) -> Worker {
        Worker { coordinator: coordinator.into(), project_id: "p".into(), title: "W".into(), branch: "w".into(),
                 base: "main".into(), created_at: 0, notified: None, stage: Stage::Active }
    }

    fn agent(thread: &str) -> Agent {
        Agent { project_id: "p".into(), thread_id: thread.into(), created_at: 0, lifecycle: Lifecycle::Ready { refresh: false } }
    }

    #[tokio::test]
    async fn first_use_creates_one_agent_in_the_chosen_mode() {
        let temp = tempfile::tempdir().unwrap();
        let (agents, fake) = fake_agents(temp.path(), temp.path(), vec![]).await;
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
        let (agents, fake) = fake_agents(temp.path(), temp.path(), vec![]).await;
        fake.fail.lock().unwrap().push(("thread.create", false));
        assert!(agents.ensure("p", None, None, None).await.is_err());
        let reserved = agents.list()[0].clone();
        assert_eq!(reserved.lifecycle, Lifecycle::Creating { command: None });
        let agent = agents.ensure("p", None, None, None).await.unwrap();
        assert_eq!(agent.thread_id, reserved.thread_id);
        assert_eq!(agents.list()[0].lifecycle, Lifecycle::Ready { refresh: false });
        let created = fake.sent("thread.create");
        assert_eq!(created.len(), 2);
        assert!(created.iter().all(|c| c["threadId"] == reserved.thread_id.as_str()));
    }

    #[tokio::test]
    async fn a_fresh_start_survives_a_lost_acknowledgement_and_keeps_the_mode() {
        let temp = tempfile::tempdir().unwrap();
        let (agents, fake) = fake_agents(temp.path(), temp.path(),
            vec![row("old", "p", "approval-required", "t", "completed", "ready", false)]).await;
        registered(&agents, |r| { r.agents.insert("p".into(), agent("old")); r.workers.insert("w1".into(), worker("old")); }).await;
        fake.fail.lock().unwrap().push(("thread.turn.start", true));
        let error = agents.reset(Some("p"), None, Reset::Fresh { note: None }).await.unwrap_err();
        assert!(format!("{error:#}").contains("did not answer"));
        let Lifecycle::Replacing { replacement: plan, error: Some(_), .. } = agents.list()[0].lifecycle.clone() else { panic!() };
        // The retry finds the handoff delivered and does not send it again.
        let done = agents.ops.run("p".into(), agents.perform("p")).await.unwrap();
        assert_eq!(done["thread_id"], plan.thread_id.as_str());
        let saved = agents.list()[0].clone();
        assert!(saved.lifecycle == Lifecycle::Ready { refresh: false } && saved.thread_id == plan.thread_id);
        assert_eq!(agents.registry().workers["w1"].coordinator, plan.thread_id);
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
            row("w1", "p", "full-access", "t", "completed", "ready", false)]).await;
        registered(&agents, |r| { r.agents.insert("p".into(), agent("agent")); r.workers.insert("w1".into(), worker("agent")); }).await;
        // Overlapping flushes.
        let (a, b) = tokio::join!(agents.flush(), agents.flush());
        a.unwrap(); b.unwrap();
        assert_eq!(fake.sent("thread.turn.start").len(), 1);
        // A lost acknowledgement: the update waits, possibly sent, until its retry is due…
        agents.consume_shell(&json!({"kind": "thread-upserted", "thread": row("w1", "p", "full-access", "t2", "completed", "ready", false)})).await;
        fake.fail.lock().unwrap().push(("thread.turn.start", true));
        agents.flush().await.unwrap();
        let waiting = agents.registry().outbox[0].outbound.clone();
        assert!(waiting.delivery == Delivery::OutcomeUnknown && waiting.retry_at.is_some());
        agents.flush().await.unwrap();
        assert_eq!(agents.registry().outbox.len(), 1);
        // …and then, after a restart, goes again as the same command, which T3
        // answers from its receipt without a second message.
        registered(&agents, |r| r.outbox[0].outbound.retry_at = Some(0)).await;
        let shell = agents.shell().threads.values().map(|t| (**t).clone()).collect::<Vec<_>>();
        drop(agents);
        let agents = Agents::open(temp.path(), "http://127.0.0.1:1", Arc::new(Tasks::open(temp.path()).unwrap())).unwrap();
        assert!(agents.fake.set(fake.clone()).is_ok());
        agents.consume_shell(&json!({"kind": "snapshot", "snapshot": {"projects": [{"id": "p", "title": "App"}], "threads": shell}})).await;
        agents.flush().await.unwrap();
        let sent = fake.sent("thread.turn.start");
        assert_eq!(sent.len(), 2);
        assert_eq!(sent[1]["commandId"], json!(waiting.command.unwrap().id));
        assert!(!agents.has_due_wakes().await);
        // A restart reloads the same registry and has nothing to send.
        let reopened = Agents::open(temp.path(), "http://127.0.0.1:1", Arc::new(Tasks::open(temp.path()).unwrap())).unwrap();
        assert_eq!(reopened.registry().workers["w1"].notified, Some(event("t2:done")));

        // Question A, answered (working), then question B in the same turn.
        let asking = row("w1", "p", "full-access", "t3", "running", "running", true);
        let ask = |id: &str| json!([{"kind": "user-input.requested", "payload": {"requestId": id}}]);
        fake.activities.lock().unwrap().insert("w1".into(), ask("A"));
        agents.consume_shell(&json!({"kind": "thread-upserted", "thread": asking})).await;
        agents.flush().await.unwrap();
        agents.flush().await.unwrap();
        assert_eq!(fake.sent("thread.turn.start").len(), 3);
        agents.consume_shell(&json!({"kind": "thread-upserted", "thread": row("w1", "p", "full-access", "t3", "running", "running", false)})).await;
        agents.observe_workers().await;
        fake.activities.lock().unwrap().insert("w1".into(), ask("B"));
        agents.consume_shell(&json!({"kind": "thread-upserted", "thread": row("w1", "p", "full-access", "t3", "running", "running", true)})).await;
        agents.flush().await.unwrap();
        assert_eq!(fake.sent("thread.turn.start").len(), 4);
        assert_eq!(agents.registry().workers["w1"].notified, Some(event("t3:needs-you:B")));
    }

    #[tokio::test]
    async fn failed_builds_reach_their_agent_once() {
        let temp = tempfile::tempdir().unwrap();
        let (agents, fake) = fake_agents(temp.path(), temp.path(), vec![
            row("agent", "p", "full-access", "a1", "running", "running", false),
            row("w1", "p", "full-access", "t", "running", "running", false)]).await;
        registered(&agents, |r| { r.agents.insert("p".into(), agent("agent")); r.workers.insert("w1".into(), worker("agent")); }).await;
        let finished = |id: &str, thread: Option<&str>| FinishedBuild {
            id: id.into(), thread: thread.map(str::to_string), app: "App".into(), succeeded: false, reason: Some("x".into()) };
        let updates = |fake: &Fake| fake.sent("thread.turn.start").into_iter()
            .map(|c| c["message"]["context"]["records"][0]["payload"]["build"].as_str().unwrap().to_string()).collect::<Vec<_>>();
        let (by_worker, by_task, own, own_later, stranger) = ("b-worker", uuid::Uuid::new_v4().to_string(), "b-own", "b-own-later", "b-x");

        // A worker's build, told twice (a link after it finished), goes once.
        agents.build_started(by_worker, Some("w1")).await.unwrap();
        agents.build_finished(&finished(by_worker, Some("w1"))).await.unwrap();
        agents.build_finished(&finished(by_worker, Some("w1"))).await.unwrap();
        // A build no thread claims, linked to one of the app's tasks.
        let task = agents.tasks.add("p", "ship it", None, None, crate::tasks::By::Agent, None, vec![]).await.unwrap();
        agents.tasks.link(&task.id, None, Some(&by_task), false).await.unwrap();
        agents.build_finished(&finished(&by_task, None)).await.unwrap();
        // Nobody's build.
        agents.build_finished(&finished(stranger, Some("someone"))).await.unwrap();
        // The agent's own build, finishing in the turn that started it: already in its chat.
        agents.build_started(own, Some("agent")).await.unwrap();
        agents.build_finished(&finished(own, Some("agent"))).await.unwrap();
        // One it started, finishing after that turn ended.
        agents.build_started(own_later, Some("agent")).await.unwrap();
        agents.consume_shell(&json!({"kind": "thread-upserted", "thread": row("agent", "p", "full-access", "a1", "completed", "ready", false)})).await;
        agents.build_finished(&finished(own_later, Some("agent"))).await.unwrap();
        agents.flush().await.unwrap();
        assert_eq!(updates(&fake), vec![by_worker.to_string(), by_task.clone(), own_later.to_string()]);

        // A restart neither repeats nor loses them.
        let reopened = Agents::open(temp.path(), "http://127.0.0.1:1", Arc::new(Tasks::open(temp.path()).unwrap())).unwrap();
        reopened.build_finished(&finished(own_later, Some("agent"))).await.unwrap();
        assert!(reopened.registry().outbox.is_empty());
        assert_eq!(agents.build_owner(None, &by_task).map(|a| a.thread_id), Some("agent".into()));

        // A build that succeeded only shows its card: it wakes nobody.
        let done = FinishedBuild { id: "b-ok".into(), thread: Some("w1".into()), app: "App".into(), succeeded: true, reason: None };
        agents.build_finished(&done).await.unwrap();
        agents.flush().await.unwrap();
        assert_eq!(updates(&fake).len(), 3);
    }

    #[tokio::test]
    async fn an_update_that_cannot_be_saved_is_neither_seen_nor_sent() {
        let temp = tempfile::tempdir().unwrap();
        let (agents, fake) = fake_agents(temp.path(), temp.path(), vec![row("agent", "p", "full-access", "a", "completed", "ready", false)]).await;
        registered(&agents, |r| { r.agents.insert("p".into(), agent("agent")); }).await;
        let failed = |id: &str| FinishedBuild { id: id.into(), thread: Some("agent".into()), app: "App".into(), succeeded: false, reason: None };
        let file = temp.path().join("agents.json");
        std::fs::remove_file(&file).unwrap();
        std::fs::create_dir(&file).unwrap();
        assert!(agents.build_finished(&failed("b1")).await.is_err());
        assert!(agents.registry().outbox.is_empty() && agents.registry().builds.is_empty());
        agents.flush().await.unwrap();
        assert!(fake.sent("thread.turn.start").is_empty());
        // Once storage works again, the next change is saved and sent once.
        std::fs::remove_dir(&file).unwrap();
        agents.build_finished(&failed("b1")).await.unwrap();
        agents.flush().await.unwrap();
        assert_eq!(fake.sent("thread.turn.start").len(), 1);
        assert!(Agents::open(temp.path(), "x", Arc::new(Tasks::open(temp.path()).unwrap())).unwrap().registry().outbox.is_empty());
    }

    #[tokio::test]
    async fn an_update_for_a_gone_agent_is_settled_as_undelivered_only_on_a_current_shell() {
        let temp = tempfile::tempdir().unwrap();
        let (agents, fake) = fake_agents(temp.path(), temp.path(), vec![row("w1", "p", "full-access", "t", "completed", "ready", false)]).await;
        registered(&agents, |r| { r.agents.insert("p".into(), agent("gone")); r.workers.insert("w1".into(), worker("gone")); }).await;
        agents.queue(agents.due_wakes().await).await.unwrap();
        // Disconnected, the missing thread may just not have arrived yet.
        agents.owner.ask(|s| { s.shell_mut().link = Link::Offline { epoch: 1 }; s.publish() }).await;
        agents.flush().await.unwrap();
        assert_eq!(agents.registry().outbox.len(), 1);
        agents.owner.ask(|s| { s.shell_mut().link = Link::Current { epoch: 2 }; s.publish() }).await;
        agents.flush().await.unwrap();
        let registry = agents.registry();
        assert!(registry.outbox.is_empty() && fake.sent("thread.turn.start").is_empty());
        assert_eq!(registry.undelivered.len(), 1);
        assert_eq!(registry.workers["w1"].notified, Some(event("t:done")));
    }

    #[tokio::test]
    async fn a_compaction_whose_answer_is_lost_is_settled_by_the_same_command() {
        let temp = tempfile::tempdir().unwrap();
        let (agents, fake) = fake_agents(temp.path(), temp.path(), vec![row("agent", "p", "auto", "a", "completed", "ready", false)]).await;
        registered(&agents, |r| { r.agents.insert("p".into(), agent("agent")); }).await;
        let wanted = |at: &str, decision| Some(Reading { origin: Origin::Automatic, decision, at: Some(at.into()), tokens: 300_000 });
        let checked = |at: &str, decision| m26::Event::Checked { thread: "agent".into(), reading: wanted(at, decision),
            compact: agents.compact_command("agent", "Compacted", 0).unwrap() };
        fake.fail.lock().unwrap().push(("thread.turn.start", true));
        let lost = agents.run_upkeep("p", checked("r1", m26::Decision::Compact)).await.unwrap();
        assert!(matches!(lost, Some(Dispatched::Unknown(_))));
        // Restarted, the next check that wants compaction sends that command again; T3 has it.
        let agents = Agents::open(temp.path(), "x", Arc::new(Tasks::open(temp.path()).unwrap())).unwrap();
        assert!(agents.fake.set(fake.clone()).is_ok());
        agents.consume_shell(&json!({"kind": "snapshot", "snapshot": {"projects": [], "threads": [row("agent", "p", "auto", "a", "completed", "ready", false)]}})).await;
        let settled = agents.run_upkeep("p", checked("r2", m26::Decision::Compact)).await.unwrap();
        assert!(matches!(settled, Some(Dispatched::Accepted(_))));
        let sent = fake.sent("thread.turn.start");
        assert_eq!((sent.len(), sent[0]["runtimeMode"].as_str()), (1, Some("auto")));
        assert!(matches!(&agents.registry().upkeep["p"].intent, m26::Intent::Applied { reading } if reading.at.as_deref() == Some("r1")));
        // A fresh start is saved as the agent's queued reset, in the same change.
        assert_eq!(agents.run_upkeep("p", checked("r3", m26::Decision::Fresh { nightly: true })).await.unwrap(), None);
        let registry = agents.registry();
        assert!(matches!(&registry.agents["p"].lifecycle, Lifecycle::ResetQueued { reset: Reset::Fresh { note: Some(note) }, .. } if note.contains("overnight")));
        assert!(matches!(&registry.upkeep["p"].intent, m26::Intent::Applied { reading } if reading.at.as_deref() == Some("r3")));
    }

    /// Every message the service sends in the user's place is marked, and
    /// the marked ones are never taken for the user's own words.
    #[test]
    fn service_messages_are_marked() {
        for note in Note::ALL {
            let message = note.message("m", "[x] for the agent", json!({}));
            assert!(!users_own(&message), "{note:?}");
        }
        // A kind the service adds later is still Squircle's.
        let later = json!({"role": "user", "text": "t", "context": {"records": [{"kind": "squircle-later"}]}});
        assert!(!users_own(&later));
        assert!(users_own(&json!({"role": "user", "text": "hi"})));
        assert!(users_own(&json!({"role": "user", "text": "hi", "context": {"records": [{"kind": "file"}]}})));
    }

    #[tokio::test]
    async fn discarding_stops_a_worker_waiting_on_the_user_before_removing_its_files() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("repo");
        std::fs::create_dir(&root).unwrap();
        run(&root, &["init", "-q", "-b", "main"]).await;
        commit(&root, "a").await;
        let tree = temp.path().join("w");
        run(&root, &["worktree", "add", "-q", "-b", "w", tree.to_str().unwrap()]).await;
        commit(&tree, "b").await;
        // Blocked on an approval: shown as needs-you, but its turn is live.
        let mut asking = row("w1", "p", "full-access", "t", "running", "running", true);
        asking["worktreePath"] = json!(tree);
        let data = temp.path().join("data");
        std::fs::create_dir(&data).unwrap();
        let (agents, fake) = fake_agents(&data, &root, vec![asking.clone()]).await;
        registered(&agents, |r| { r.workers.insert("w1".into(), worker("agent")); }).await;
        let refused = agents.archive("w1", false).await.unwrap_err();
        assert!(format!("{refused:#}").contains("waiting on a question"), "{refused:#}");
        let (weak, checked) = (Arc::downgrade(&agents), tree.clone());
        *fake.on_dispatch.lock().unwrap() = Some(Box::new(move |command| {
            if command["type"] == "thread.session.stop" {
                // T3 first re-sends the waiting row, and only later the stop.
                let (agents, checked, asking) = (weak.upgrade().unwrap(), checked.clone(), asking.clone());
                tokio::spawn(async move {
                    agents.consume_shell(&json!({"kind": "thread-upserted", "thread": asking})).await;
                    tokio::time::sleep(Duration::from_millis(300)).await;
                    assert!(checked.exists(), "files removed before the worker stopped");
                    let mut stopped = asking.clone();
                    stopped["latestTurn"]["state"] = json!("interrupted");
                    stopped["session"]["status"] = json!("stopped");
                    agents.consume_shell(&json!({"kind": "thread-upserted", "thread": stopped})).await;
                });
            } else if command["type"] == "thread.archive" {
                assert!(!checked.exists());
            }
        }));
        let result = agents.archive("w1", true).await.unwrap();
        assert_eq!(result["stopped"], true);
        let order: Vec<Value> = fake.log.lock().unwrap().iter().map(|c| c["type"].clone()).collect();
        assert_eq!(order, [json!("thread.session.stop"), json!("thread.archive")]);
        assert!(!tree.exists() && agents.registry().workers["w1"].stage == Stage::Archived);
    }

    #[tokio::test]
    async fn a_reset_never_stops_a_newer_turn() {
        let temp = tempfile::tempdir().unwrap();
        let idle = row("agent", "p", "full-access", "t1", "completed", "ready", false);
        let busy = row("agent", "p", "full-access", "t2", "running", "running", false);
        let (agents, fake) = fake_agents(temp.path(), temp.path(), vec![idle.clone()]).await;
        let queued = |reset: Reset| Lifecycle::ResetQueued { reset, error: Some("earlier failure".into()), failures: 1 };
        registered(&agents, move |r| { r.agents.insert("p".into(), Agent { lifecycle: queued(Reset::Restart), ..agent("agent") }); }).await;
        let upsert = |row: &Value| { let item = json!({"kind": "thread-upserted", "thread": row}); let agents = agents.clone(); async move { agents.consume_shell(&item).await } };
        // The user started a turn while the restart waited to retry.
        upsert(&busy).await;
        assert_eq!(agents.perform("p").await.unwrap()["when"], "after-turn");
        assert!(fake.sent("thread.session.stop").is_empty());
        assert!(matches!(agents.list()[0].lifecycle, Lifecycle::ResetQueued { .. }));
        upsert(&idle).await;
        assert_eq!(agents.perform("p").await.unwrap()["when"], "now");
        assert_eq!(fake.sent("thread.session.stop").len(), 1);
        assert_eq!(agents.list()[0].lifecycle, Lifecycle::Ready { refresh: true });

        // A turn that starts while the fresh start gathers its handoff.
        registered(&agents, move |r| r.agents.get_mut("p").unwrap().lifecycle = queued(Reset::Fresh { note: None })).await;
        *fake.on_snapshot.lock().unwrap() = Some(Box::new(move |_| Some(json!({"kind": "thread-upserted", "thread": busy.clone()}))));
        assert_eq!(agents.perform("p").await.unwrap()["when"], "after-turn");
        assert_eq!(fake.log.lock().unwrap().len(), 1, "only the earlier restart's stop");
        assert!(matches!(agents.list()[0].lifecycle, Lifecycle::ResetQueued { reset: Reset::Fresh { .. }, .. }));
    }

    #[tokio::test]
    async fn a_worker_is_reserved_before_its_bootstrap_is_sent() {
        let temp = tempfile::tempdir().unwrap();
        let (agents, fake) = fake_agents(temp.path(), temp.path(), vec![row("agent", "p", "full-access", "a", "completed", "ready", false)]).await;
        registered(&agents, |r| { r.agents.insert("p".into(), agent("agent")); }).await;
        let spawn = |agents: Arc<Agents>, branch: &'static str| async move {
            agents.spawn("agent", "W", branch, Some("main"), "do it", None, None, None, None).await
        };
        // T3 starts the worker but its acknowledgement is lost.
        fake.fail.lock().unwrap().push(("thread.turn.start", true));
        let first = spawn(agents.clone(), "one").await.unwrap();
        assert_eq!(agents.registry().workers[first["id"].as_str().unwrap()].stage, Stage::Active);

        // Rejected (or never arrived): the reservation stays, and the
        // service restarts before anything else happens.
        fake.fail.lock().unwrap().push(("thread.turn.start", false));
        assert!(spawn(agents.clone(), "two").await.is_err());
        drop(agents);
        let (agents, fake) = fake_agents(temp.path(), temp.path(), vec![row("agent", "p", "full-access", "a", "completed", "ready", false)]).await;
        let reserved: Vec<String> = agents.registry().workers.iter()
            .filter(|(_, w)| matches!(w.stage, Stage::Bootstrapping { .. })).map(|(id, _)| id.clone()).collect();
        assert_eq!(reserved.len(), 1);
        // Asking again finishes that worker with the same identities.
        let again = spawn(agents.clone(), "two").await.unwrap();
        assert_eq!((again["id"].as_str(), again["existing"].as_bool()), (Some(reserved[0].as_str()), Some(true)));
        let sent = fake.sent("thread.turn.start");
        assert_eq!((sent.len(), sent[0]["threadId"].as_str()), (1, Some(reserved[0].as_str())));
        assert_eq!(agents.registry().workers.len(), 2);

        // Unconfirmed, then T3's shell shows it finishing its first turn:
        // it is adopted and its coordinator woken.
        fake.fail.lock().unwrap().push(("thread.turn.start", false));
        assert!(spawn(agents.clone(), "three").await.is_err());
        let id = agents.registry().workers.iter()
            .find(|(_, w)| w.branch == "three").map(|(id, _)| id.clone()).unwrap();
        agents.consume_shell(&json!({"kind": "thread-upserted", "thread": row(&id, "p", "full-access", "t", "completed", "ready", false)})).await;
        agents.observe_workers().await;
        assert_eq!(agents.registry().workers[&id].stage, Stage::Active);
        assert!(agents.due_wakes().await.iter().any(|(due, _, _)| *due == id));
    }

    /// The same agents, as a restarted service: the registry from disk, the
    /// same fake T3 and its shell.
    async fn reopened(temp: &Path, fake: &Arc<Fake>, threads: Vec<Value>, workspace: &Path) -> Arc<Agents> {
        let agents = Agents::open(temp, "http://127.0.0.1:1", Arc::new(Tasks::open(temp).unwrap())).unwrap();
        assert!(agents.fake.set(fake.clone()).is_ok());
        *fake.agents.lock().unwrap() = Arc::downgrade(&agents);
        agents.consume_shell(&json!({"kind": "snapshot", "snapshot": {
            "projects": [{"id": "p", "title": "App", "workspaceRoot": workspace}], "threads": threads}})).await;
        agents
    }

    /// A fresh start whose answer is lost at each step in turn, with the
    /// service restarted right after: it resumes from the saved step, and T3
    /// gets each command once (a resend is answered from its receipt). The
    /// agent, its workers and its unsent update move to the new thread in
    /// one save; an update that may have reached the old thread stays there.
    #[tokio::test]
    async fn a_fresh_start_resumes_after_a_crash_at_any_step() {
        for step in ["thread.session.stop", "thread.meta.update", "thread.create", "thread.turn.start"] {
            let temp = tempfile::tempdir().unwrap();
            let old = row("old", "p", "auto", "t", "completed", "ready", false);
            let (agents, fake) = fake_agents(temp.path(), temp.path(), vec![old.clone()]).await;
            let wake = |id: &str, delivery| Wake { coordinator: "old".into(), message_id: id.into(), workers: vec![], text: "x".into(),
                                                   record: json!({}), outbound: Outbound { delivery, ..Default::default() }, build: None };
            registered(&agents, move |r| {
                r.agents.insert("p".into(), agent("old"));
                r.workers.insert("w1".into(), worker("old"));
                r.outbox.push(wake("unsent", Delivery::Queued));
                r.outbox.push(wake("maybe", Delivery::OutcomeUnknown));
            }).await;
            fake.fail.lock().unwrap().push((step, true));
            assert!(agents.reset(Some("p"), None, Reset::Fresh { note: Some("n".into()) }).await.is_err(), "{step}");
            let threads: Vec<Value> = agents.shell().threads.values().map(|t| (**t).clone()).collect();
            drop(agents);
            let agents = reopened(temp.path(), &fake, threads, temp.path()).await;
            let done = agents.ops.run("p".into(), agents.perform("p")).await.unwrap();
            assert_eq!((done["when"].as_str(), done["previous_thread_id"].as_str()), (Some("now"), Some("old")), "{step}");
            let registry = agents.registry();
            let new = registry.agents["p"].thread_id.clone();
            assert!(new != "old" && registry.agents["p"].lifecycle == Lifecycle::Ready { refresh: false }, "{step}");
            assert_eq!(registry.workers["w1"].coordinator, new);
            let by_id = |id: &str| registry.outbox.iter().find(|w| w.message_id == id).unwrap().coordinator.clone();
            assert_eq!((by_id("unsent"), by_id("maybe")), (new.clone(), "old".to_string()), "{step}");
            for kind in ["thread.session.stop", "thread.meta.update", "thread.create", "thread.turn.start"] {
                assert_eq!(fake.sent(kind).len(), 1, "{kind} after a cut at {step}");
            }
            assert_eq!(fake.sent("thread.turn.start")[0]["runtimeMode"], "auto");
        }
    }

    /// A fresh start never makes up a runtime mode for the new agent.
    #[tokio::test]
    async fn a_fresh_start_waits_for_a_known_runtime_mode() {
        let temp = tempfile::tempdir().unwrap();
        let mut old = row("old", "p", "auto", "t", "completed", "ready", false);
        old.as_object_mut().unwrap().remove("runtimeMode");
        let (agents, fake) = fake_agents(temp.path(), temp.path(), vec![old]).await;
        registered(&agents, |r| { r.agents.insert("p".into(), agent("old")); }).await;
        let error = agents.reset(Some("p"), None, Reset::Fresh { note: None }).await.unwrap_err();
        assert!(format!("{error:#}").contains("runtime mode"), "{error:#}");
        assert!(fake.log.lock().unwrap().is_empty());
        assert!(matches!(agents.list()[0].lifecycle, Lifecycle::ResetQueued { error: Some(_), .. }));
        // Nor sends a message into a thread whose mode it doesn't know.
        assert!(agents.send("old", "hi").await.is_err());
        assert!(fake.log.lock().unwrap().is_empty());
    }

    /// A message whose answer is lost is sent again, when asked again, as
    /// the same command: T3 shows it once.
    #[tokio::test]
    async fn a_send_asked_again_after_a_lost_answer_is_the_same_command() {
        let temp = tempfile::tempdir().unwrap();
        let (agents, fake) = fake_agents(temp.path(), temp.path(), vec![row("w1", "p", "auto", "t", "completed", "ready", false)]).await;
        fake.fail.lock().unwrap().push(("thread.turn.start", true));
        assert!(agents.message("w1", "go on").await.is_err());
        assert_eq!(agents.registry().intents.len(), 1);
        let agents = reopened(temp.path(), &fake, vec![row("w1", "p", "auto", "t", "completed", "ready", false)], temp.path()).await;
        agents.message("w1", "go on").await.unwrap();
        assert_eq!(fake.messages.lock().unwrap()["w1"].len(), 1);
        assert!(agents.registry().intents.is_empty());
        // A new request is a new command.
        agents.message("w1", "go on").await.unwrap();
        assert_eq!(fake.messages.lock().unwrap()["w1"].len(), 2);
    }

    /// An archive cut after the stop and after T3's archive, each answer
    /// lost and the service restarted: it resumes from the saved step,
    /// sends each command once and removes files only once T3 shows the
    /// worker stopped.
    #[tokio::test]
    async fn an_archive_resumes_after_lost_answers_and_a_restart() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("repo");
        std::fs::create_dir(&root).unwrap();
        run(&root, &["init", "-q", "-b", "main"]).await;
        commit(&root, "a").await;
        let tree = temp.path().join("w");
        run(&root, &["worktree", "add", "-q", "-b", "w", tree.to_str().unwrap()]).await;
        let mut idle = row("w1", "p", "auto", "t", "completed", "ready", false);
        idle["worktreePath"] = json!(tree);
        let data = temp.path().join("data");
        std::fs::create_dir(&data).unwrap();
        let (agents, fake) = fake_agents(&data, &root, vec![idle.clone()]).await;
        registered(&agents, |r| { r.workers.insert("w1".into(), worker("agent")); }).await;
        let (weak, checked, stopped) = (Arc::downgrade(&agents), tree.clone(), {
            let mut stopped = idle.clone();
            stopped["session"]["status"] = json!("stopped");
            stopped
        });
        let shown = stopped.clone();
        *fake.on_dispatch.lock().unwrap() = Some(Box::new(move |command| {
            if command["type"] == "thread.session.stop" {
                assert!(checked.exists());
                // T3 shows the stop only after the (lost) answer.
                let (agents, stopped) = (weak.upgrade().unwrap(), shown.clone());
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    agents.consume_shell(&json!({"kind": "thread-upserted", "thread": stopped})).await;
                });
            }
        }));
        fake.fail.lock().unwrap().push(("thread.session.stop", true));
        let error = agents.archive("w1", false).await.unwrap_err();
        assert!(format!("{error:#}").contains("nothing was removed"), "{error:#}");
        assert!(tree.exists() && matches!(agents.registry().workers["w1"].stage, Stage::Archiving(ArchiveStep::Stopping { .. })));
        tokio::time::sleep(Duration::from_millis(200)).await;
        fake.fail.lock().unwrap().push(("thread.archive", true));
        assert!(agents.archive("w1", false).await.is_err());
        assert!(!tree.exists() && matches!(agents.registry().workers["w1"].stage, Stage::Archiving(ArchiveStep::Thread { .. })));
        drop(agents);
        let agents = reopened(&data, &fake, vec![stopped], &root).await;
        let result = agents.archive("w1", false).await.unwrap();
        assert_eq!(result["archived"], "w1");
        assert_eq!(agents.registry().workers["w1"].stage, Stage::Archived);
        let order: Vec<Value> = fake.log.lock().unwrap().iter().map(|c| c["type"].clone()).collect();
        assert_eq!(order, [json!("thread.session.stop"), json!("thread.archive")]);
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
            remove(root, &s, false, &StopReceipt(())).await.unwrap();
            assert!(!tree(name).exists() && !state(name).await.branch_exists, "{name}");
        }
        assert_eq!(state("open").await.blocker().as_deref(), Some("1 commit not merged"));
        assert_eq!(state("dirty").await.blocker().as_deref(), Some("1 commit not merged and 1 uncommitted file"));
        // Discarding drops unmerged commits and uncommitted changes.
        remove(root, &state("dirty").await, true, &StopReceipt(())).await.unwrap();
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
        assert!(remove(root, &merged, false, &StopReceipt(())).await.is_err());
        assert!(git(root, &["rev-parse", "--verify", "worker"]).await.is_ok());
    }
}

const PLUGIN_FILES: [(&str, &str); 4] = [
    (".claude-plugin/plugin.json", include_str!("../plugin/squircle/.claude-plugin/plugin.json")),
    ("agents/app-agent.md", include_str!("../plugin/squircle/agents/app-agent.md")),
    ("agents/history.md", include_str!("../plugin/squircle/agents/history.md")),
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
