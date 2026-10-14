//! Simulator sessions an agent runs through Squircle (`squircle sim`). Starting
//! one opens the simulator for the agent's T3 thread (T3's own `device.open`,
//! so the phone streams it), boots it and records its screen. Stopping it,
//! or the agent's turn ending, finishes the recording and adds it to the
//! thread's media, dated where the session began, then closes the T3 device
//! session. The phone shows active sessions as a live picture-in-picture and
//! in the turn, and the recording there afterwards.
//!
//! Every step is saved before its side effect, so a crash, a cancelled
//! request or a failed call leaves a session the next tick (or the next
//! run) can finish: its `SessionPhase` goes starting → recording → stopping
//! → filing → finished or failed, and its `DeviceLease` (T3's device
//! session) is owed a close from just before T3 opens it until T3 confirms
//! it closed.
//!
//! The session is the simulator's lease: once it ends (`release_pending`),
//! the simulator is shut down unless another session holds it or the pool's
//! policy keeps it (`simpool`). Starts reuse a free booted simulator of
//! Squircle's before booting another, and at most `max_leases` run at once.

use crate::agents::{Agents, Observed};
use crate::media::{self, SimulatorClip};
use crate::simpool::{Lease, Pool};
use crate::store::{atomic_json, read_json};
use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    future::Future,
    path::{Path, PathBuf},
    pin::Pin,
    process::Stdio,
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::process::{Child, Command};

/// A turn that stops working this long ends its sessions.
const IDLE_GRACE: f64 = 8.0;
/// Recordings never run longer than this.
const MAX_SECONDS: f64 = 30.0 * 60.0;
const KEEP: usize = 200;
/// How long simctl gets to write the movie's index after SIGINT.
const RECORDER_GRACE: Duration = Duration::from_secs(20);
/// The same while the service shuts down (its supervisor won't wait long).
const SHUTDOWN_GRACE: Duration = Duration::from_secs(5);
/// A close T3 keeps failing is given up after this many tries.
const CLOSE_TRIES: u32 = 20;

/// Where a session is in its life. Each phase carries what it alone has: a
/// recorder's PID only while one may run (it identifies the process, it
/// doesn't own it: see `Recorder`), an end time once stopped, a media ID
/// only once filed.
#[derive(Clone, Debug, PartialEq)]
pub enum SessionPhase {
    Starting { recorder_pid: Option<u32> },
    Recording { recorder_pid: Option<u32> },
    Stopping { reason: String, recorder_pid: Option<u32> },
    /// Stopped; the recording is still to be moved into the thread's media.
    /// `warning`: something about the stop worth knowing (a recorder left alone).
    Filing { reason: String, ended_at: f64, warning: Option<String> },
    Finished { reason: String, ended_at: f64, media_id: String, warning: Option<String> },
    Failed { reason: Option<String>, ended_at: f64, error: String },
}

/// T3's device session for the thread and simulator.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "phase", rename_all = "snake_case")]
pub enum DeviceLease {
    /// Saved before T3 is asked to open it: whatever happens next, a close is owed.
    Opening,
    Open,
    /// The session ended; T3 has not confirmed the close yet.
    CloseOwed(RetryState),
    Closed,
    /// T3 kept failing to close it; given up.
    Abandoned { error: String },
}

#[derive(Clone, Debug, PartialEq, Default, Serialize, Deserialize)]
pub struct RetryState {
    pub tries: u32,
    /// Not before this (seconds since 1970).
    pub retry_at: f64,
    pub error: Option<String>,
}

impl DeviceLease {
    /// T3's device session may still be open.
    fn owed(&self) -> bool {
        matches!(self, DeviceLease::Opening | DeviceLease::Open | DeviceLease::CloseOwed(_))
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(from = "SessionRecord", into = "SessionRecord")]
pub struct SimSession {
    pub id: String,
    pub thread_id: String,
    pub host_id: String,
    pub device_id: String,
    pub device_name: String,
    /// Seconds since 1970, fractional.
    pub started_at: f64,
    pub phase: SessionPhase,
    pub device: DeviceLease,
    /// Ended, and its simulator is still to be shut down (if nothing else holds it).
    pub release_pending: bool,
}

/// A session as saved and served: flat fields, as the phone and earlier
/// ledgers have them. Read only through `SimSession`'s conversion.
#[derive(Serialize, Deserialize)]
struct SessionRecord {
    id: String,
    thread_id: String,
    host_id: String,
    device_id: String,
    device_name: String,
    started_at: f64,
    state: String,
    #[serde(default)]
    ended_at: Option<f64>,
    #[serde(default)]
    media_id: Option<String>,
    #[serde(default)]
    stop_reason: Option<String>,
    #[serde(default)]
    error: Option<String>,
    #[serde(default)]
    recorder_pid: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    device_session: Option<DeviceLease>,
    /// Before `device_session`: whether a close was owed, and why it last failed.
    #[serde(default, skip_serializing)]
    close_pending: bool,
    #[serde(default, skip_serializing)]
    close_error: Option<String>,
    #[serde(default)]
    release_pending: bool,
}

impl From<SessionRecord> for SimSession {
    fn from(r: SessionRecord) -> Self {
        let ended_at = r.ended_at.unwrap_or(r.started_at);
        let reason = r.stop_reason.clone().unwrap_or_default();
        let phase = match (r.state.as_str(), r.media_id) {
            ("starting", _) => SessionPhase::Starting { recorder_pid: r.recorder_pid },
            ("recording", _) => SessionPhase::Recording { recorder_pid: r.recorder_pid },
            ("stopping", _) => SessionPhase::Stopping { reason, recorder_pid: r.recorder_pid },
            ("filing", _) => SessionPhase::Filing { reason, ended_at, warning: r.error },
            ("finished", Some(media_id)) => SessionPhase::Finished { reason, ended_at, media_id, warning: r.error },
            ("failed", _) => SessionPhase::Failed { reason: r.stop_reason, ended_at, error: r.error.unwrap_or_else(|| "Failed".into()) },
            (state, _) => SessionPhase::Failed { reason: r.stop_reason, ended_at,
                error: format!("Unreadable saved state {state:?}") },
        };
        let held = matches!(phase, SessionPhase::Starting { .. } | SessionPhase::Recording { .. } | SessionPhase::Stopping { .. });
        let device = r.device_session.unwrap_or(match (r.close_pending, held) {
            (false, _) => DeviceLease::Closed,
            (true, true) => DeviceLease::Open,
            (true, false) => DeviceLease::CloseOwed(RetryState { error: r.close_error, ..RetryState::default() }),
        });
        SimSession { id: r.id, thread_id: r.thread_id, host_id: r.host_id, device_id: r.device_id, device_name: r.device_name,
                     started_at: r.started_at, phase, device, release_pending: r.release_pending }
    }
}

impl From<SimSession> for SessionRecord {
    fn from(s: SimSession) -> Self {
        let (state, ended_at, media_id, stop_reason, error, recorder_pid) = match s.phase {
            SessionPhase::Starting { recorder_pid } => ("starting", None, None, None, None, recorder_pid),
            SessionPhase::Recording { recorder_pid } => ("recording", None, None, None, None, recorder_pid),
            SessionPhase::Stopping { reason, recorder_pid } => ("stopping", None, None, Some(reason), None, recorder_pid),
            SessionPhase::Filing { reason, ended_at, warning } => ("filing", Some(ended_at), None, Some(reason), warning, None),
            SessionPhase::Finished { reason, ended_at, media_id, warning } =>
                ("finished", Some(ended_at), Some(media_id), Some(reason), warning, None),
            SessionPhase::Failed { reason, ended_at, error } => ("failed", Some(ended_at), None, reason, Some(error), None),
        };
        SessionRecord { id: s.id, thread_id: s.thread_id, host_id: s.host_id, device_id: s.device_id, device_name: s.device_name,
                        started_at: s.started_at, state: state.into(), ended_at, media_id, stop_reason, error, recorder_pid,
                        device_session: Some(s.device), close_pending: false, close_error: None, release_pending: s.release_pending }
    }
}

impl SimSession {
    /// Recording, as the phone shows it.
    fn active(&self) -> bool {
        matches!(self.phase, SessionPhase::Recording { .. })
    }

    /// Its simulator is not free for another session yet.
    fn holds_device(&self) -> bool {
        matches!(self.phase, SessionPhase::Starting { .. } | SessionPhase::Recording { .. } | SessionPhase::Stopping { .. })
    }

    fn ended(&self) -> bool {
        matches!(self.phase, SessionPhase::Finished { .. } | SessionPhase::Failed { .. })
    }

    fn ended_at(&self) -> Option<f64> {
        match self.phase {
            SessionPhase::Filing { ended_at, .. } | SessionPhase::Finished { ended_at, .. } | SessionPhase::Failed { ended_at, .. } => Some(ended_at),
            _ => None,
        }
    }

    fn recorder_pid(&self) -> Option<u32> {
        match self.phase {
            SessionPhase::Starting { recorder_pid } | SessionPhase::Recording { recorder_pid }
            | SessionPhase::Stopping { recorder_pid, .. } => recorder_pid,
            _ => None,
        }
    }

    /// A close of T3's device session is owed and due: the session no
    /// longer holds the simulator and any backoff has passed.
    fn close_due(&self, time: f64) -> bool {
        !self.holds_device() && match &self.device {
            DeviceLease::Opening | DeviceLease::Open => true,
            DeviceLease::CloseOwed(retry) => retry.retry_at <= time,
            DeviceLease::Closed | DeviceLease::Abandoned { .. } => false,
        }
    }
}

/// What `stop` hands back: the session, and the recording it filed.
#[derive(Serialize)]
pub struct StopReceipt {
    #[serde(flatten)]
    pub session: SimSession,
    #[serde(skip)]
    pub media_id: Option<String>,
}

#[derive(Default, Serialize, Deserialize)]
struct Ledger {
    #[serde(default)]
    sessions: Vec<SimSession>,
}

/// Who may signal a session's recorder. Only a process this run started is
/// owned; one a previous run started is taken over only after its command
/// line proved it is the session's (PIDs are reused).
enum Recorder {
    Owned(Child),
    Recovered { pid: u32 },
}

/// Whether a session's turn has ended, from what T3 says of its thread.
#[derive(Clone, Copy, PartialEq, Debug)]
enum StopPolicy {
    Active,
    /// T3 confirmed the thread stopped working at `since`; it ends after the
    /// grace unless the thread works again. Unknown T3 state keeps it waiting.
    AwaitingEnd { since: f64 },
}

/// What T3 currently says a thread is doing. Only `Idle` and `Gone` are
/// confirmed; `Unknown` (T3 disconnected or its snapshot not in yet) never
/// ends a session.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Activity {
    Working,
    Idle,
    Gone,
    Unknown,
}

#[derive(Default)]
struct State {
    ledger: Ledger,
    recorders: HashMap<String, Recorder>,
    stop_policy: HashMap<String, StopPolicy>,
    /// Sessions a previous run left unfinished, finished first by `run`.
    orphans: Vec<String>,
    /// The ledger on disk is behind (a save failed); retried each tick.
    dirty: bool,
}

pub type Pending<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// What sessions do to the world: T3's device calls, the thread's state and
/// the simulator's processes. Tests use a fake.
pub trait Host: Send + Sync {
    /// A T3 call (`device.list`, `device.open`, `device.close`).
    fn device<'a>(&'a self, method: &'a str, params: Value) -> Pending<'a, Result<Value>>;
    /// What T3 says the thread is doing, and whether it can be trusted.
    fn activity(&self, thread: &str) -> Activity;
    /// The squircle invocation agents are told to use.
    fn cli(&self) -> String;
    fn boot<'a>(&'a self, device: &'a str) -> Pending<'a, Result<()>>;
    /// Starts recording the device's screen into `path`.
    fn record(&self, device: &str, path: &Path, log: std::fs::File) -> Result<Child>;
    /// A smaller copy of the recording, having removed the original.
    fn compact<'a>(&'a self, raw: &'a Path) -> Pending<'a, Option<PathBuf>>;
    /// Booted simulators of Squircle's that nothing holds (`leases` do).
    fn free<'a>(&'a self, leases: &'a [Lease]) -> Pending<'a, Vec<String>>;
    /// `thread`'s lease on `device` ended: shut it down unless the policy keeps it.
    fn release<'a>(&'a self, device: &'a str, thread: &'a str, leases: &'a [Lease]) -> Pending<'a, Result<()>>;
    /// How many sessions may hold simulators at once.
    fn max_leases(&self) -> usize;
    fn title(&self, thread: &str) -> Option<String>;

    /// Saves the device's screen as a small JPEG at `path`, best effort:
    /// the recording's poster, so the phone needn't download the movie to
    /// show it.
    fn poster<'a>(&'a self, _device: &'a str, _path: &'a Path) -> Pending<'a, ()> {
        Box::pin(async {})
    }
}

struct AgentsHost(Arc<Agents>, Arc<Pool>);

impl Host for AgentsHost {
    fn device<'a>(&'a self, method: &'a str, params: Value) -> Pending<'a, Result<Value>> {
        Box::pin(async move { self.0.connection().await?.call(method, params).await })
    }

    fn activity(&self, thread: &str) -> Activity {
        match self.0.observe(thread) {
            Observed::Current { value: Some(thread), .. } if thread.phase() == crate::agents::Phase::Working => Activity::Working,
            Observed::Current { value: Some(_), .. } => Activity::Idle,
            Observed::Current { value: None, .. } => Activity::Gone,
            Observed::Stale { .. } | Observed::Unavailable => Activity::Unknown,
        }
    }

    fn cli(&self) -> String {
        self.0.cli().to_string()
    }

    fn boot<'a>(&'a self, device: &'a str) -> Pending<'a, Result<()>> {
        Box::pin(async move {
            let status = Command::new("xcrun").args(["simctl", "bootstatus", device, "-b"])
                .stdout(Stdio::null()).stderr(Stdio::null()).kill_on_drop(true).status();
            let booted = tokio::time::timeout(Duration::from_secs(180), status).await;
            ensure!(matches!(booted, Ok(Ok(status)) if status.success()), "did not finish booting");
            Ok(())
        })
    }

    fn record(&self, device: &str, path: &Path, log: std::fs::File) -> Result<Child> {
        Command::new("xcrun")
            .args(["simctl", "io", device, "recordVideo", "--codec=h264", "--force"])
            .arg(path)
            .stdin(Stdio::null()).stdout(Stdio::null()).stderr(log)
            // Outlives a crash so the next run can end it cleanly (SIGINT).
            .kill_on_drop(false)
            .spawn().context("Cannot start simctl recordVideo")
    }

    fn compact<'a>(&'a self, raw: &'a Path) -> Pending<'a, Option<PathBuf>> {
        Box::pin(compact(raw))
    }

    fn free<'a>(&'a self, leases: &'a [Lease]) -> Pending<'a, Vec<String>> {
        Box::pin(async move {
            self.1.refresh(leases, false).await.map(|rows| rows.into_iter().filter(|r| r.free).map(|r| r.udid).collect())
                .unwrap_or_default()
        })
    }

    fn release<'a>(&'a self, device: &'a str, thread: &'a str, leases: &'a [Lease]) -> Pending<'a, Result<()>> {
        Box::pin(self.1.release(device, thread, leases))
    }

    fn max_leases(&self) -> usize {
        self.1.policy.max_leases
    }

    fn title(&self, thread: &str) -> Option<String> {
        self.0.worker_title(thread)
    }

    fn poster<'a>(&'a self, device: &'a str, path: &'a Path) -> Pending<'a, ()> {
        Box::pin(async move {
            let run = |program: &str, args: &[&std::ffi::OsStr]| {
                let status = Command::new(program).args(args).stdout(Stdio::null()).stderr(Stdio::null()).kill_on_drop(true).status();
                tokio::time::timeout(Duration::from_secs(15), status)
            };
            let shot = path.with_extension("png");
            let taken = run("xcrun", &["simctl".as_ref(), "io".as_ref(), device.as_ref(), "screenshot".as_ref(), shot.as_os_str()]).await;
            if matches!(taken, Ok(Ok(s)) if s.success()) {
                let _ = run("/usr/bin/sips", &["-Z".as_ref(), "900".as_ref(), "-s".as_ref(), "format".as_ref(), "jpeg".as_ref(),
                    "-s".as_ref(), "formatOptions".as_ref(), "70".as_ref(), shot.as_os_str(), "--out".as_ref(), path.as_os_str()]).await;
            }
            let _ = std::fs::remove_file(&shot);
        })
    }
}

pub struct Sims {
    root: PathBuf,
    host: Arc<dyn Host>,
    state: Mutex<State>,
    /// Admission: starts, close retries and shutdown run one at a time.
    /// Stopping and filing a session don't take it; claiming the session's
    /// state excludes a second stop instead.
    ops: tokio::sync::Mutex<()>,
    /// Set once by `shutdown`: no new starts, and `run` returns.
    draining: tokio::sync::watch::Sender<bool>,
}

fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// T3's 24-hex-digit key (sha256 prefix) for agent-device files.
fn key(value: &str) -> String {
    Sha256::digest(value.as_bytes()).iter().take(12).map(|b| format!("{b:02x}")).collect()
}

/// The agent-device invocation T3's `device_open` tool gives agents for this
/// thread and simulator (same config file and session name as T3 0.0.45).
pub fn agent_device(thread: &str, host: &str, device: &str) -> Value {
    let base = dirs::home_dir().unwrap_or_default().join(".t3/userdata/device");
    let config = base.join("hosts").join(format!("{}.json", key(host)));
    let session = format!("t3-{}", key(&serde_json::to_string(&[thread, host, device]).unwrap_or_default()));
    let args = vec!["--platform".to_string(), "ios".into(), "--udid".into(), device.into(),
                    "--config".into(), config.display().to_string(), "--session".into(), session];
    json!({
        "command": base.join("bin/agent-device"),
        "target_args": args,
        "config_exists": config.is_file(),
    })
}

/// simctl records at about 6 Mbit/s; the phone downloads recordings over
/// cellular. macOS's own `avconvert` re-encodes them far smaller (mostly
/// still screens). Returns the smaller file, having removed the original.
async fn compact(raw: &Path) -> Option<PathBuf> {
    let small = compacted(raw);
    let converted = tokio::time::timeout(Duration::from_secs(180), Command::new("/usr/bin/avconvert")
        .args(["--preset", "Preset1280x720", "--replace", "--source"]).arg(raw).arg("--output").arg(&small)
        .stdout(Stdio::null()).stderr(Stdio::null()).kill_on_drop(true).status()).await;
    if matches!(converted, Ok(Ok(status)) if status.success()) && small.metadata().is_ok_and(|m| m.len() > 0) {
        let _ = std::fs::remove_file(raw);
        Some(small)
    } else {
        let _ = std::fs::remove_file(&small);
        None
    }
}

fn compacted(raw: &Path) -> PathBuf {
    raw.with_extension("compact.mp4")
}

fn alive(pid: u32) -> bool {
    unsafe { libc::kill(pid as i32, 0) == 0 }
}

/// The process's command line, if it is running.
fn command_line(pid: u32) -> Option<String> {
    let output = std::process::Command::new("/bin/ps").args(["-ww", "-o", "command=", "-p", &pid.to_string()])
        .stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
    let line = String::from_utf8_lossy(&output.stdout).trim().to_string();
    (output.status.success() && !line.is_empty()).then_some(line)
}

/// Whether `pid` is still this session's recorder: its command line names
/// the session's own recording file, which no reused PID can.
fn is_recorder(pid: u32, session: &str) -> bool {
    command_line(pid).is_some_and(|line| line.contains(&format!(".{session}.recording.mp4")))
}

impl Sims {
    pub fn open(root: &Path, agents: Arc<Agents>, pool: Arc<Pool>) -> Result<Arc<Self>> {
        Self::with_host(root, Arc::new(AgentsHost(agents, pool)))
    }

    /// Every simulator a session has used, with when it was last used.
    pub fn used(&self) -> Vec<(String, f64)> {
        self.state.lock().unwrap().ledger.sessions.iter()
            .map(|s| (s.device_id.clone(), s.ended_at().unwrap_or(s.started_at))).collect()
    }

    /// The simulators sessions hold now.
    pub fn leases(&self) -> Vec<Lease> {
        self.state.lock().unwrap().ledger.sessions.iter().filter(|s| s.holds_device())
            .map(|s| Lease { device_id: s.device_id.to_ascii_uppercase(), thread_id: s.thread_id.clone() }).collect()
    }

    pub fn with_host(root: &Path, host: Arc<dyn Host>) -> Result<Arc<Self>> {
        let path = root.join("sims.json");
        let ledger: Ledger = if path.try_exists()? { read_json(&path)? } else { Ledger::default() };
        let orphans = ledger.sessions.iter().filter(|s| !s.ended()).map(|s| s.id.clone()).collect();
        // A recorder a previous run left is taken over only if it is provably this session's.
        let recorders = ledger.sessions.iter()
            .filter_map(|s| Some((s.id.clone(), s.recorder_pid().filter(|pid| is_recorder(*pid, &s.id))?)))
            .map(|(id, pid)| (id, Recorder::Recovered { pid })).collect();
        Ok(Arc::new(Self {
            root: root.to_path_buf(),
            host,
            state: Mutex::new(State { ledger, orphans, recorders, ..State::default() }),
            ops: tokio::sync::Mutex::new(()),
            draining: tokio::sync::watch::channel(false).0,
        }))
    }

    /// Saves the ledger; a failure is retried on the next tick.
    fn save(&self, state: &mut State) -> Result<()> {
        let saved = atomic_json(&self.root.join("sims.json"), &state.ledger);
        state.dirty = saved.is_err();
        saved.context("Cannot save the simulator session ledger")
    }

    fn session(&self, id: &str) -> Option<SimSession> {
        self.state.lock().unwrap().ledger.sessions.iter().find(|s| s.id == id).cloned()
    }

    fn update(&self, id: &str, change: impl FnOnce(&mut SimSession)) -> Result<SimSession> {
        let mut state = self.state.lock().unwrap();
        let session = state.ledger.sessions.iter_mut().find(|s| s.id == id).context("No such simulator session")?;
        change(session);
        let session = session.clone();
        self.save(&mut state)?;
        Ok(session)
    }

    /// Sessions still recording, and recent ones (newest first), optionally for one thread.
    pub fn list(&self, thread: Option<&str>) -> Value {
        let state = self.state.lock().unwrap();
        let mine = |s: &&SimSession| thread.is_none_or(|t| s.thread_id == t);
        let active: Vec<&SimSession> = state.ledger.sessions.iter().filter(mine).filter(|s| s.active()).collect();
        let recent: Vec<&SimSession> = state.ledger.sessions.iter().rev().filter(mine).filter(|s| !s.active()).take(50).collect();
        json!({"active": active, "recent": recent})
    }

    // MARK: Start

    pub async fn start(self: &Arc<Self>, thread: &str, device: Option<&str>) -> Result<Value> {
        ensure!(media::valid_thread(thread) && uuid::Uuid::parse_str(thread).is_ok(), "Thread ID must be a T3 thread UUID");
        let _op = self.ops.lock().await;
        ensure!(!*self.draining.borrow(), "Squircle is shutting down; start the simulator again once it is back");
        let inventory = inventory(&*self.host).await?;
        ensure!(self.host.activity(thread) != Activity::Gone, "T3 has no thread {thread}");
        let simulators = local_simulators(&inventory);
        ensure!(!simulators.is_empty(), "{}", no_simulators(&inventory));

        let held: Vec<SimSession> = self.state.lock().unwrap().ledger.sessions.iter().filter(|s| s.holds_device()).cloned().collect();
        let chosen = match device {
            Some(wanted) => simulators.iter().find(|d| d["id"].as_str().is_some_and(|id| id.eq_ignore_ascii_case(wanted))
                    || d["name"].as_str().is_some_and(|n| n.eq_ignore_ascii_case(wanted)))
                .with_context(|| format!("No iOS simulator {wanted} on this Mac; run squircle sim devices"))?,
            None => {
                let (last, used) = {
                    let state = self.state.lock().unwrap();
                    let sessions = &state.ledger.sessions;
                    (sessions.iter().rev().find(|s| s.thread_id == thread).map(|s| s.device_id.clone()),
                     sessions.iter().map(|s| s.device_id.to_ascii_uppercase()).collect::<std::collections::HashSet<_>>())
                };
                let free = self.host.free(&self.leases()).await;
                let id = |d: &Value| d["id"].as_str().unwrap_or("").to_ascii_uppercase();
                let busy = |d: &Value| held.iter().any(|s| s.device_id.eq_ignore_ascii_case(&id(d)) && s.thread_id != thread);
                let mine = |d: &Value| held.iter().any(|s| s.device_id.eq_ignore_ascii_case(&id(d)) && s.thread_id == thread);
                // A booted simulator is taken only when it is Squircle's and
                // free: never the user's own, nor another agent's.
                let takeable = |d: &Value| !busy(d) && (d["booted"] != true || free.contains(&id(d)) || mine(d));
                simulators.iter().copied().find(|d| last.as_deref().is_some_and(|l| l.eq_ignore_ascii_case(&id(d))) && takeable(d))
                    .or_else(|| simulators.iter().copied().find(|d| d["booted"] == true && takeable(d)))
                    .or_else(|| simulators.iter().copied().find(|d| used.contains(&id(d)) && takeable(d)))
                    .or_else(|| simulators.iter().copied().find(|d| takeable(d)))
                    .context("No free simulator: the booted ones are the user's or other agents'; pass --device (squircle sim devices)")?
            }
        };
        // At most `max_leases` simulators run for agents; reusing a free
        // booted one adds none.
        let max = self.host.max_leases();
        let others: std::collections::BTreeSet<String> = held.iter().filter(|s| s.thread_id != thread)
            .map(|s| s.device_id.to_ascii_uppercase()).collect();
        let reusing = chosen["booted"] == true && device.is_none() && !others.contains(&chosen["id"].as_str().unwrap_or("").to_ascii_uppercase());
        if others.len() >= max && !reusing {
            let users: Vec<String> = held.iter().filter(|s| s.thread_id != thread)
                .map(|s| format!("{} ({})", s.device_name, self.host.title(&s.thread_id).unwrap_or_else(|| s.thread_id.clone()))).collect();
            bail!("{} simulators already run for other agents: {}. The limit is {max} (SQUIRCLE_MAX_SIMULATORS). \
                   Try again when one stops (squircle sim status).", others.len(), users.join(", "));
        }
        let device_id = chosen["id"].as_str().context("Simulator without an ID")?.to_string();
        let device_name = chosen["name"].as_str().unwrap_or("Simulator").to_string();
        let host_id = "local".to_string();

        // Already running here: the same session. On another simulator: end that one first.
        if let Some(existing) = held.iter().find(|s| s.thread_id == thread && s.active()) {
            if existing.device_id == device_id {
                return Ok(self.started(existing, "This thread's simulator session is already running."));
            }
            if self.halt(&existing.id, "replaced", RECORDER_GRACE, false).await.is_some() {
                let sims = self.clone();
                let id = existing.id.clone();
                tokio::spawn(async move { sims.file(&id, true).await });
            }
        }
        if let Some(other) = held.iter().find(|s| s.device_id == device_id && s.thread_id != thread) {
            bail!("{device_name} is in use by thread {}; pick another with --device (squircle sim devices)", other.thread_id);
        }
        // A stop of this thread's session on this simulator is still closing it.
        for _ in 0..120 {
            let stopping = self.state.lock().unwrap().ledger.sessions.iter()
                .any(|s| s.device_id == device_id && s.holds_device());
            if !stopping { break }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }

        // The reservation, saved before T3 opens anything: whatever happens
        // next, a close is owed.
        let id = uuid::Uuid::new_v4().to_string();
        let session = SimSession {
            id: id.clone(), thread_id: thread.into(), host_id, device_id, device_name, started_at: now(),
            phase: SessionPhase::Starting { recorder_pid: None }, device: DeviceLease::Opening, release_pending: false,
        };
        {
            let mut state = self.state.lock().unwrap();
            // The open below supersedes an older close of the same T3 device session.
            for old in state.ledger.sessions.iter_mut()
                .filter(|s| s.device.owed() && !s.holds_device() && s.thread_id == thread && s.device_id == session.device_id) {
                old.device = DeviceLease::Closed;
            }
            state.ledger.sessions.push(session.clone());
            trim(&mut state.ledger);
            if let Err(error) = self.save(&mut state) {
                state.ledger.sessions.retain(|s| s.id != id);
                return Err(error);
            }
        }
        let mut startup = Startup { sims: self, id: id.clone(), child: None, error: None, committed: false };
        match self.begin(&session, &mut startup).await {
            Ok(session) => Ok(self.started(&session, "Recording. The user watches it live on their phone.")),
            Err(error) => {
                startup.error = Some(format!("{error:#}"));
                drop(startup);
                self.close(&id).await;
                Err(error)
            }
        }
    }

    /// Opens, boots and records; `startup` rolls back whatever this did if
    /// it fails or is cancelled.
    async fn begin(&self, session: &SimSession, startup: &mut Startup<'_>) -> Result<SimSession> {
        let name = &session.device_name;
        self.host.device("device.open", json!({"threadId": session.thread_id, "hostId": session.host_id,
            "deviceId": session.device_id, "platform": "ios", "boot": true})).await
            .context("T3 could not open the simulator")?;
        self.update(&session.id, |s| s.device = DeviceLease::Open)?;
        self.host.boot(&session.device_id).await.with_context(|| format!("{name} did not finish booting"))?;

        let path = media::recording_path(&self.root, &session.thread_id, &session.id)?;
        let log = std::fs::File::create(path.with_extension("log"))?;
        let recorder = startup.child.insert(self.host.record(&session.device_id, &path, log)?);
        let recorder_pid = recorder.id();
        self.update(&session.id, |s| s.phase = SessionPhase::Starting { recorder_pid })?;
        tokio::time::sleep(Duration::from_millis(1200)).await;
        if let Some(status) = startup.child.as_mut().and_then(|c| c.try_wait().transpose()).transpose()? {
            let detail = std::fs::read_to_string(path.with_extension("log")).unwrap_or_default();
            bail!("Recording {name} failed ({status}): {}", detail.trim());
        }
        let mut state = self.state.lock().unwrap();
        // Shutdown collects the sessions it ends under this lock.
        ensure!(!*self.draining.borrow(), "Squircle is shutting down");
        let entry = state.ledger.sessions.iter_mut().find(|s| s.id == session.id).context("No such simulator session")?;
        entry.phase = SessionPhase::Recording { recorder_pid };
        let committed = entry.clone();
        if let Some(child) = startup.child.take() {
            state.recorders.insert(session.id.clone(), Recorder::Owned(child));
        }
        startup.committed = true;
        // Recording either way; an unsaved state is saved on the next tick.
        let _ = self.save(&mut state);
        Ok(committed)
    }

    fn started(&self, session: &SimSession, status: &str) -> Value {
        let cli = self.host.cli();
        json!({
            "session": session,
            "status": status,
            "agent_device": agent_device(&session.thread_id, &session.host_id, &session.device_id),
            "next": format!("Drive it with agent_device.command plus agent_device.target_args (or T3's device_screenshot to look). \
                When you are done with the simulator, run {cli} sim stop --thread {}; the recording then appears in this turn \
                and the simulator shuts down. If you forget, that happens when your turn ends. Don't boot or create simulators yourself.", session.thread_id),
        })
    }

    // MARK: Stop

    /// Stops a thread's session (or one by ID) and files its recording.
    pub async fn stop(&self, thread: Option<&str>, id: Option<&str>) -> Result<StopReceipt> {
        let session = {
            let state = self.state.lock().unwrap();
            state.ledger.sessions.iter().rev()
                .find(|s| s.active() && (id.is_some_and(|i| s.id == i) || (id.is_none() && thread.is_some_and(|t| s.thread_id == t))))
                .cloned()
        };
        let Some(session) = session else {
            bail!("No simulator session is running{}", thread.map(|t| format!(" for thread {t}")).unwrap_or_default());
        };
        let session = self.finish(&session.id, "stopped").await?;
        let media_id = match &session.phase { SessionPhase::Finished { media_id, .. } => Some(media_id.clone()), _ => None };
        Ok(StopReceipt { session, media_id })
    }

    /// Ends the recording, closes T3's device session and files the
    /// recording. Problems are recorded on the session; an error means the
    /// ledger could not be saved, or another stop has the session.
    async fn finish(&self, id: &str, reason: &str) -> Result<SimSession> {
        self.halt(id, reason, RECORDER_GRACE, false).await.context("The session is already being stopped")?;
        self.file(id, true).await
    }

    /// Claims a session, stops its recorder and closes its device session,
    /// leaving it filing. None if it isn't this call's to stop.
    async fn halt(&self, id: &str, reason: &str, grace: Duration, recovering: bool) -> Option<SimSession> {
        let (session, recorder) = {
            let mut state = self.state.lock().unwrap();
            let session = state.ledger.sessions.iter_mut().find(|s| s.id == id)?;
            let claimable = session.active() || (recovering && session.holds_device());
            if !claimable {
                return None;
            }
            session.phase = SessionPhase::Stopping { reason: reason.into(), recorder_pid: session.recorder_pid() };
            let session = session.clone();
            let recorder = state.recorders.remove(id);
            state.stop_policy.remove(id);
            let _ = self.save(&mut state);
            (session, recorder)
        };
        if let Ok(raw) = media::recording_path(&self.root, &session.thread_id, id) {
            self.host.poster(&session.device_id, &raw.with_extension("poster.jpg")).await;
        }
        let mut warning = None;
        match recorder {
            Some(Recorder::Owned(mut child)) => {
                if let Some(pid) = child.id() {
                    // simctl writes the movie's index when interrupted.
                    unsafe { libc::kill(pid as i32, libc::SIGINT) };
                }
                if tokio::time::timeout(grace, child.wait()).await.is_err() {
                    let _ = child.kill().await;
                }
            }
            // Checked again just before the signal: the PID may have been reused since.
            Some(Recorder::Recovered { pid }) if is_recorder(pid, id) => {
                unsafe { libc::kill(pid as i32, libc::SIGINT) };
                let polls = (grace.as_millis() / 250).max(1);
                for _ in 0..polls {
                    if !is_recorder(pid, id) { break }
                    tokio::time::sleep(Duration::from_millis(250)).await;
                }
            }
            _ => if let Some(pid) = session.recorder_pid().filter(|p| alive(*p)) {
                warning = Some(format!("Process {pid} is no longer this session's recorder; it was left alone"));
            },
        }
        // Closed while the session still holds the simulator, so a new start
        // there can't be closed by this one.
        self.close(id).await;
        let _ = self.update(id, |s| {
            s.phase = SessionPhase::Filing { reason: reason.into(), ended_at: now(), warning };
            s.release_pending = true;
        });
        self.session(id)
    }

    /// Moves a halted session's recording into the thread's media.
    async fn file(&self, id: &str, shrink: bool) -> Result<SimSession> {
        let session = self.session(id).context("The session disappeared")?;
        let SessionPhase::Filing { reason, ended_at, warning } = session.phase.clone() else { return Ok(session) };
        let raw = media::recording_path(&self.root, &session.thread_id, id);
        let path = match &raw {
            Ok(raw) => {
                let _ = std::fs::remove_file(raw.with_extension("log"));
                let nonempty = |p: &Path| p.metadata().is_ok_and(|m| m.len() > 0);
                if nonempty(raw) {
                    Some(if shrink { self.host.compact(raw).await.unwrap_or(raw.clone()) } else { raw.clone() })
                } else {
                    // A previous run compacted it but stopped before filing.
                    Some(compacted(raw)).filter(|p| nonempty(p))
                }
            }
            Err(_) => None,
        };
        let filed = path.map(|p| {
            media::add_recording(&self.root, &session.thread_id, &p, SimulatorClip {
                session_id: id.into(), device_id: session.device_id.clone(), device_name: session.device_name.clone(),
                started_at: session.started_at, ended_at,
            })
        });
        if let (Ok(raw), Some(Ok(media))) = (&raw, &filed) {
            let _ = std::fs::rename(raw.with_extension("poster.jpg"), media.file.with_extension("poster.jpg"));
        }
        let phase = match filed {
            Some(Ok(media)) => SessionPhase::Finished { reason, ended_at, media_id: media.id, warning },
            Some(Err(error)) => SessionPhase::Failed { reason: Some(reason), ended_at, error: format!("{error:#}") },
            None => SessionPhase::Failed { reason: Some(reason), ended_at, error: warning.unwrap_or_else(|| "simctl wrote no video".into()) },
        };
        self.update(id, |s| s.phase = phase)
    }

    /// Closes the session's T3 device session if it may still be open. A
    /// failure stays owed and is retried with backoff.
    async fn close(&self, id: &str) {
        let Some(session) = self.session(id).filter(|s| s.device.owed()) else { return };
        let closed = self.host.device("device.close", json!({"threadId": session.thread_id, "hostId": session.host_id,
            "deviceId": session.device_id, "platform": "ios"})).await;
        let mut state = self.state.lock().unwrap();
        let Some(entry) = state.ledger.sessions.iter_mut().find(|s| s.id == id && s.device.owed()) else { return };
        let tries = match &entry.device { DeviceLease::CloseOwed(retry) => retry.tries, _ => 0 } + 1;
        entry.device = match closed {
            Ok(_) => DeviceLease::Closed,
            Err(error) => {
                let error = format!("T3 did not close the simulator: {error:#}");
                if tries >= CLOSE_TRIES {
                    DeviceLease::Abandoned { error }
                } else {
                    let wait = (3.0 * 2f64.powi(tries as i32 - 1)).min(300.0);
                    DeviceLease::CloseOwed(RetryState { tries, retry_at: now() + wait, error: Some(error) })
                }
            }
        };
        let _ = self.save(&mut state);
    }

    /// This Mac's iOS simulators, and which thread (if any) is using each.
    pub async fn devices(&self) -> Result<Value> {
        let inventory = inventory(&*self.host).await?;
        let simulators = local_simulators(&inventory);
        ensure!(!simulators.is_empty(), "{}", no_simulators(&inventory));
        let held: Vec<SimSession> = self.state.lock().unwrap().ledger.sessions.iter().filter(|s| s.holds_device()).cloned().collect();
        let devices: Vec<Value> = simulators.into_iter()
            .map(|d| {
                let session = held.iter().find(|s| Some(s.device_id.as_str()) == d["id"].as_str());
                json!({"id": d["id"], "name": d["name"], "version": d["version"], "booted": d["booted"],
                       "recording_for_thread": session.map(|s| s.thread_id.clone())})
            }).collect();
        Ok(json!({"devices": devices}))
    }

    // MARK: Watching

    /// Ends sessions whose turn has stopped, whose recorder died, or that ran
    /// too long, and retries owed closes and saves. Sessions a previous run
    /// left unfinished are finished first. Returns once `shutdown` begins.
    pub async fn run(self: Arc<Self>) {
        let mut draining = self.draining.subscribe();
        let orphans = std::mem::take(&mut self.state.lock().unwrap().orphans);
        for id in orphans {
            if *draining.borrow() { return }
            self.halt(&id, "service restarted", RECORDER_GRACE, true).await;
            let _ = self.file(&id, true).await;
            self.close(&id).await;
        }
        loop {
            tokio::select! {
                _ = tokio::time::sleep(Duration::from_secs(3)) => {}
                _ = draining.wait_for(|d| *d) => return,
            }
            if *draining.borrow() { return }
            self.tick().await;
        }
    }

    async fn tick(self: &Arc<Self>) {
        {
            let mut state = self.state.lock().unwrap();
            if state.dirty {
                let _ = self.save(&mut state);
            }
        }
        for (id, reason) in self.due() {
            // Filing can take minutes; it never holds up other sessions.
            let sims = self.clone();
            tokio::spawn(async move { sims.finish(&id, reason).await });
        }
        let time = now();
        let owed: Vec<String> = self.state.lock().unwrap().ledger.sessions.iter()
            .filter(|s| s.close_due(time)).map(|s| s.id.clone()).collect();
        if !owed.is_empty() {
            // Not while a start may be opening the same device session.
            let _op = self.ops.lock().await;
            for id in owed {
                self.close(&id).await;
            }
        }
        if self.releases_owed() {
            let _op = self.ops.lock().await;
            self.release(None).await;
        }
    }

    fn releases_owed(&self) -> bool {
        self.state.lock().unwrap().ledger.sessions.iter().any(|s| s.release_pending && !s.holds_device() && !s.device.owed())
    }

    /// Shuts down the simulators of ended sessions that nothing else holds
    /// (once their T3 device session is closed). Done or not, each is owed
    /// once: the pool's own sweep stops one this misses.
    async fn release(&self, wait: Option<Duration>) {
        let (owed, leases) = {
            let state = self.state.lock().unwrap();
            let owed: Vec<(String, String, String)> = state.ledger.sessions.iter()
                .filter(|s| s.release_pending && !s.holds_device() && !s.device.owed())
                .map(|s| (s.id.clone(), s.device_id.to_ascii_uppercase(), s.thread_id.clone())).collect();
            (owed, state.ledger.sessions.iter().filter(|s| s.holds_device())
                .map(|s| Lease { device_id: s.device_id.to_ascii_uppercase(), thread_id: s.thread_id.clone() }).collect::<Vec<_>>())
        };
        let mut devices: Vec<(&String, &String)> = owed.iter().map(|(_, d, t)| (d, t))
            .filter(|(d, _)| !leases.iter().any(|l| &l.device_id == *d)).collect();
        devices.sort();
        devices.dedup_by(|a, b| a.0 == b.0);
        for (device, thread) in devices {
            let released = self.host.release(device, thread, &leases);
            let result = match wait {
                Some(wait) => tokio::time::timeout(wait, released).await.unwrap_or_else(|_| Err(anyhow::anyhow!("timed out"))),
                None => released.await,
            };
            if let Err(error) = result {
                eprintln!("Simulator {device} not shut down after its session: {error:#}");
            }
        }
        let mut state = self.state.lock().unwrap();
        for session in state.ledger.sessions.iter_mut().filter(|s| owed.iter().any(|(id, ..)| *id == s.id)) {
            session.release_pending = false;
        }
        let _ = self.save(&mut state);
    }

    /// Sessions to stop now, and why: the recorder died, the time limit
    /// passed, or T3 confirmed the turn stopped working a grace ago.
    fn due(&self) -> Vec<(String, &'static str)> {
        let time = now();
        let mut state = self.state.lock().unwrap();
        let active: Vec<SimSession> = state.ledger.sessions.iter().filter(|s| s.active()).cloned().collect();
        let mut due = Vec::new();
        for session in active {
            let exited = match state.recorders.get_mut(&session.id) {
                Some(Recorder::Owned(child)) => !matches!(child.try_wait(), Ok(None)),
                Some(Recorder::Recovered { pid }) => !is_recorder(*pid, &session.id),
                None => true,
            };
            let activity = self.host.activity(&session.thread_id);
            let policy = state.stop_policy.entry(session.id.clone()).or_insert(StopPolicy::Active);
            match (activity, *policy) {
                (Activity::Working, _) => *policy = StopPolicy::Active,
                (Activity::Idle | Activity::Gone, StopPolicy::Active) => *policy = StopPolicy::AwaitingEnd { since: time },
                _ => {}
            }
            let ended = matches!((activity, *policy), (Activity::Idle | Activity::Gone, StopPolicy::AwaitingEnd { since }) if time - since >= IDLE_GRACE);
            if exited {
                due.push((session.id, "recorder stopped"));
            } else if time - session.started_at > MAX_SECONDS {
                due.push((session.id, "time limit"));
            } else if ended {
                due.push((session.id, "turn ended"));
            }
        }
        due
    }

    /// For the service's graceful shutdown: refuses new starts, stops the
    /// watchdog, ends every recording (filed uncompressed, to be quick) and
    /// closes T3's device sessions. Anything it can't finish stays in the
    /// ledger for the next run.
    pub async fn shutdown(&self) {
        // Not behind `ops`: a start booting a simulator could hold it for
        // minutes. One past its commit check is rolled back instead.
        self.draining.send_replace(true);
        let live: Vec<String> = self.state.lock().unwrap().ledger.sessions.iter()
            .filter(|s| s.active()).map(|s| s.id.clone()).collect();
        futures_util::future::join_all(live.iter().map(|id| async move {
            if self.halt(id, "service stopped", SHUTDOWN_GRACE, false).await.is_some() {
                let _ = self.file(id, false).await;
            }
        })).await;
        let owed: Vec<String> = self.state.lock().unwrap().ledger.sessions.iter()
            .filter(|s| s.device.owed() && !s.holds_device()).map(|s| s.id.clone()).collect();
        futures_util::future::join_all(owed.iter().map(|id| async move {
            let _ = tokio::time::timeout(Duration::from_secs(3), self.close(id)).await;
        })).await;
        self.release(Some(Duration::from_secs(4))).await;
        let mut state = self.state.lock().unwrap();
        if state.dirty {
            let _ = self.save(&mut state);
        }
    }
}

/// Owns a starting session's provisional resources: unless startup commits,
/// dropping it (an error or a cancelled request) kills the recorder and marks
/// the session failed, with its device close still owed.
struct Startup<'a> {
    sims: &'a Sims,
    id: String,
    child: Option<Child>,
    error: Option<String>,
    committed: bool,
}

impl Drop for Startup<'_> {
    fn drop(&mut self) {
        if self.committed {
            return;
        }
        if let Some(child) = &mut self.child {
            // The partial movie is useless; tokio reaps the killed child.
            let _ = child.start_kill();
        }
        let mut state = self.sims.state.lock().unwrap();
        let Some(session) = state.ledger.sessions.iter_mut().find(|s| s.id == self.id) else { return };
        if let Ok(path) = media::recording_path(&self.sims.root, &session.thread_id, &self.id) {
            let _ = std::fs::remove_file(path.with_extension("log"));
            let _ = std::fs::remove_file(path);
        }
        session.phase = SessionPhase::Failed { reason: None, ended_at: now(),
            error: self.error.take().unwrap_or_else(|| "The start was cancelled".into()) };
        // T3's open may have booted it.
        session.release_pending = true;
        let _ = self.sims.save(&mut state);
    }
}

/// Drops the oldest ended sessions over `KEEP`; unfinished ones and owed
/// closes stay.
fn trim(ledger: &mut Ledger) {
    let mut excess = ledger.sessions.len().saturating_sub(KEEP);
    ledger.sessions.retain(|s| {
        let gone = excess > 0 && s.ended() && !s.device.owed();
        excess -= gone as usize;
        !gone
    });
}

/// T3's device state after it re-lists every host. Its `subscribeDeviceState`
/// snapshot is only a cache that starts empty when T3 starts and fills only
/// when some client asks for a list, so read it through `device.list`.
async fn inventory(host: &dyn Host) -> Result<Value> {
    host.device("device.list", json!({})).await.context("T3 could not list its simulators")
}

fn local_simulators(inventory: &Value) -> Vec<&Value> {
    inventory["devices"].as_array().into_iter().flatten()
        .filter(|d| d["platform"] == "ios" && d["physical"] != true && d["hostId"] == "local").collect()
}

/// Why T3 listed no simulators, from its own host status.
fn no_simulators(inventory: &Value) -> String {
    let status = inventory["hostStatus"].as_str().unwrap_or("unknown");
    let detail = inventory["hostStatusDetail"].as_str()
        .or_else(|| inventory["hostStatuses"]["local"]["detail"].as_str())
        .map(|d| format!(": {d}")).unwrap_or_default();
    if status == "disabled" {
        return "T3 lists no simulators because its device support is off; turn it on in T3's Device panel".into();
    }
    format!("T3 lists no iOS simulators on this Mac (T3 device host {status}{detail}); check `xcrun simctl list devices` and T3's Device panel")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The session name must match T3's, or agent-device drives a session T3
    /// does not show (values from a real T3 0.0.45 device_open result).
    #[test]
    fn agent_device_session_matches_t3() {
        let value = agent_device("f56d4de2-8173-425d-b251-84d841fd8d97", "local", "C800634B-1469-491D-9477-9BF9A883EEF7");
        let args: Vec<&str> = value["target_args"].as_array().unwrap().iter().map(|v| v.as_str().unwrap()).collect();
        assert_eq!(args.last(), Some(&"t3-b283255e0eea683562ba6ae8"));
        assert!(args.iter().any(|a| a.ends_with("/hosts/25bf8e1a2393f1108d37029b.json")));
    }

    const THREAD: &str = "f56d4de2-8173-425d-b251-84d841fd8d97";

    /// T3 and simctl stand-ins: one simulator, a recorder that writes its
    /// movie on SIGINT like simctl, and closes that fail on request.
    #[derive(Default)]
    struct Fake {
        calls: Mutex<Vec<String>>,
        close_fails: std::sync::atomic::AtomicBool,
        boot: Mutex<Option<std::result::Result<(), ()>>>,
        activity: Mutex<Option<Activity>>,
    }

    impl Fake {
        fn count(&self, call: &str) -> usize {
            self.calls.lock().unwrap().iter().filter(|c| *c == call).count()
        }

        fn closes(&self) -> usize {
            self.calls.lock().unwrap().iter().filter(|c| *c == "device.close").count()
        }
    }

    impl Host for Fake {
        fn device<'a>(&'a self, method: &'a str, _: Value) -> Pending<'a, Result<Value>> {
            self.calls.lock().unwrap().push(method.into());
            let fails = method == "device.close" && self.close_fails.load(std::sync::atomic::Ordering::SeqCst);
            Box::pin(async move {
                ensure!(!fails, "disconnected");
                Ok(json!({"devices": [{"id": "SIM1", "name": "iPhone", "platform": "ios", "hostId": "local", "booted": true},
                                       {"id": "SIM2", "name": "iPad", "platform": "ios", "hostId": "local", "booted": false}]}))
            })
        }
        fn activity(&self, _: &str) -> Activity { self.activity.lock().unwrap().unwrap_or(Activity::Working) }
        fn cli(&self) -> String { "squircle".into() }
        fn boot<'a>(&'a self, _: &'a str) -> Pending<'a, Result<()>> {
            let outcome = *self.boot.lock().unwrap();
            Box::pin(async move {
                match outcome {
                    None => std::future::pending().await,
                    Some(Ok(())) => Ok(()),
                    Some(Err(())) => bail!("boot failed"),
                }
            })
        }
        fn record(&self, _: &str, path: &Path, log: std::fs::File) -> Result<Child> {
            Ok(Command::new("/bin/sh")
                .args(["-c", "trap 'printf movie > \"$1\"; exit 0' INT; while :; do sleep 0.05; done", "sh"])
                .arg(path).stderr(log).kill_on_drop(true).spawn()?)
        }
        fn compact<'a>(&'a self, _: &'a Path) -> Pending<'a, Option<PathBuf>> {
            Box::pin(async { None })
        }
        fn free<'a>(&'a self, _: &'a [Lease]) -> Pending<'a, Vec<String>> {
            Box::pin(async { vec!["SIM1".into()] })
        }
        fn release<'a>(&'a self, device: &'a str, _: &'a str, _: &'a [Lease]) -> Pending<'a, Result<()>> {
            self.calls.lock().unwrap().push(format!("release {device}"));
            Box::pin(async { Ok(()) })
        }
        fn max_leases(&self) -> usize { 1 }
        fn title(&self, _: &str) -> Option<String> { None }
    }

    fn sims(root: &Path, boot: Option<std::result::Result<(), ()>>) -> (Arc<Sims>, Arc<Fake>) {
        let fake = Arc::new(Fake { boot: Mutex::new(boot), ..Fake::default() });
        (Sims::with_host(root, fake.clone()).unwrap(), fake)
    }

    fn state(session: &SimSession) -> String {
        SessionRecord::from(session.clone()).state
    }

    fn only(sims: &Sims) -> SimSession {
        sims.state.lock().unwrap().ledger.sessions.last().cloned().unwrap()
    }

    /// Recovery signals a saved PID only while it is still that session's recorder.
    #[test]
    fn recorder_identity_is_the_session_file() {
        let id = uuid::Uuid::new_v4().to_string();
        let mut child = std::process::Command::new("/bin/sh").args(["-c", "sleep 5", "sh"])
            .arg(format!("/tmp/.{id}.recording.mp4")).spawn().unwrap();
        let pid = child.id();
        assert!(is_recorder(pid, &id));
        assert!(!is_recorder(pid, &uuid::Uuid::new_v4().to_string()));
        child.kill().unwrap();
        child.wait().unwrap();
        assert!(!is_recorder(pid, &id));
    }

    /// A process that took over a saved recorder PID is never signalled.
    #[tokio::test]
    async fn restart_leaves_a_reused_pid_alone() {
        let dir = tempfile::tempdir().unwrap();
        let mut stranger = std::process::Command::new("/bin/sleep").arg("5").spawn().unwrap();
        let ledger = json!({"sessions": [{"id": uuid::Uuid::new_v4().to_string(), "thread_id": THREAD, "host_id": "local",
            "device_id": "SIM1", "device_name": "iPhone", "started_at": 1.0, "state": "recording", "recorder_pid": stranger.id()}]});
        std::fs::write(dir.path().join("sims.json"), ledger.to_string()).unwrap();
        let (sims, fake) = sims(dir.path(), Some(Ok(())));
        let id = std::mem::take(&mut sims.state.lock().unwrap().orphans).pop().unwrap();
        sims.halt(&id, "service restarted", Duration::from_millis(100), true).await.unwrap();
        let session = sims.file(&id, true).await.unwrap();
        assert!(stranger.try_wait().unwrap().is_none(), "the unrelated process was signalled");
        assert!(matches!(&session.phase, SessionPhase::Failed { error, .. } if error.contains("left alone")));
        // A pre-upgrade record owes no close; nothing is retried.
        assert_eq!(fake.closes(), 0);
        stranger.kill().unwrap();
        stranger.wait().unwrap();
    }

    /// A failed or cancelled start kills its recorder and still closes T3's device session.
    #[tokio::test]
    async fn failed_or_cancelled_start_rolls_back() {
        let dir = tempfile::tempdir().unwrap();
        let (sims, fake) = sims(dir.path(), Some(Err(())));
        assert!(sims.start(THREAD, None).await.is_err());
        let session = only(&sims);
        assert_eq!((state(&session).as_str(), session.device.owed()), ("failed", false));
        assert_eq!(fake.closes(), 1);

        *fake.boot.lock().unwrap() = None;
        assert!(tokio::time::timeout(Duration::from_millis(100), sims.start(THREAD, None)).await.is_err());
        let session = only(&sims);
        assert!(session.device.owed() && matches!(&session.phase, SessionPhase::Failed { error, .. } if error.contains("cancelled")));
        sims.tick().await;
        assert!(!only(&sims).device.owed());
        assert_eq!(fake.closes(), 2);
    }

    /// The recording is filed even when T3 is unreachable; the close is owed until it answers.
    #[tokio::test]
    async fn failed_close_is_retried() {
        let dir = tempfile::tempdir().unwrap();
        let (sims, fake) = sims(dir.path(), Some(Ok(())));
        sims.start(THREAD, None).await.unwrap();
        fake.close_fails.store(true, std::sync::atomic::Ordering::SeqCst);
        let session = sims.stop(Some(THREAD), None).await.unwrap().session;
        assert_eq!(state(&session), "finished");
        assert!(matches!(&session.device, DeviceLease::CloseOwed(RetryState { error: Some(_), .. })));
        assert_eq!(media::list(dir.path(), THREAD).unwrap().len(), 1);

        fake.close_fails.store(false, std::sync::atomic::Ordering::SeqCst);
        sims.tick().await;
        assert!(only(&sims).device.owed(), "retried before its backoff");
        for s in &mut sims.state.lock().unwrap().ledger.sessions {
            if let DeviceLease::CloseOwed(retry) = &mut s.device { retry.retry_at = 0.0 }
        }
        sims.tick().await;
        assert_eq!(only(&sims).device, DeviceLease::Closed);
        // Saved: a restart owes nothing.
        let (reopened, _) = super::tests::sims(dir.path(), Some(Ok(())));
        assert!(reopened.state.lock().unwrap().orphans.is_empty() && !only(&reopened).device.owed());
    }

    /// Shutdown ends recordings, files them, closes the device session and refuses new starts.
    #[tokio::test]
    async fn shutdown_files_and_refuses_starts() {
        let dir = tempfile::tempdir().unwrap();
        let (sims, fake) = sims(dir.path(), Some(Ok(())));
        sims.start(THREAD, None).await.unwrap();
        sims.shutdown().await;
        let session = only(&sims);
        assert_eq!((state(&session).as_str(), session.device.owed()), ("finished", false));
        assert_eq!(fake.closes(), 1);
        assert!(sims.start(THREAD, None).await.is_err());
        assert!(sims.state.lock().unwrap().recorders.is_empty());
    }

    /// A session's end shuts its simulator down once T3's device session is
    /// closed; a start past the limit is refused rather than booting another.
    #[tokio::test]
    async fn ended_session_releases_its_simulator_and_the_limit_holds() {
        let dir = tempfile::tempdir().unwrap();
        let (sims, fake) = sims(dir.path(), Some(Ok(())));
        sims.start(THREAD, None).await.unwrap();
        let other = "0e7c4a1d-5f0b-4c8e-9a51-2b6f1c3d4e5f";
        assert!(sims.start(other, None).await.unwrap_err().to_string().contains("limit is 1"));
        sims.stop(Some(THREAD), None).await.unwrap();
        assert!(only_of(&sims, THREAD).release_pending);
        sims.tick().await;
        assert_eq!(fake.count("release SIM1"), 1);
        assert!(!only_of(&sims, THREAD).release_pending);
        sims.tick().await;
        assert_eq!(fake.count("release SIM1"), 1, "released twice");
    }

    fn only_of(sims: &Sims, thread: &str) -> SimSession {
        sims.state.lock().unwrap().ledger.sessions.iter().rev().find(|s| s.thread_id == thread).cloned().unwrap()
    }

    /// Only T3 confirming the turn stopped ends a session; while T3's state
    /// is unknown (disconnected, or stale) the session keeps running.
    #[tokio::test]
    async fn unknown_thread_state_never_ends_a_session() {
        let dir = tempfile::tempdir().unwrap();
        let (sims, fake) = sims(dir.path(), Some(Ok(())));
        sims.start(THREAD, None).await.unwrap();
        *fake.activity.lock().unwrap() = Some(Activity::Idle);
        assert!(sims.due().is_empty(), "ended before its grace");
        sims.state.lock().unwrap().stop_policy.values_mut().for_each(|p| *p = StopPolicy::AwaitingEnd { since: 0.0 });
        *fake.activity.lock().unwrap() = Some(Activity::Unknown);
        assert!(sims.due().is_empty(), "ended on an unknown state");
        *fake.activity.lock().unwrap() = Some(Activity::Idle);
        assert_eq!(sims.due().into_iter().map(|d| d.1).collect::<Vec<_>>(), ["turn ended"]);
        sims.stop(Some(THREAD), None).await.unwrap();
    }

    /// A ledger from before typed phases keeps its owed closes and running sessions.
    #[test]
    fn earlier_ledger_records_read_as_phases() {
        let record = |state: &str, close_pending: bool| serde_json::from_value::<SimSession>(json!({
            "id": "a", "thread_id": THREAD, "host_id": "local", "device_id": "SIM1", "device_name": "iPhone",
            "started_at": 1.0, "ended_at": null, "state": state, "media_id": if state == "finished" { json!("m") } else { json!(null) },
            "stop_reason": null, "error": null, "recorder_pid": 7, "close_pending": close_pending, "close_error": "x",
            "release_pending": false})).unwrap();
        let running = record("recording", true);
        assert_eq!((running.phase, running.device), (SessionPhase::Recording { recorder_pid: Some(7) }, DeviceLease::Open));
        let finished = record("finished", true);
        assert!(matches!(finished.phase, SessionPhase::Finished { ref media_id, .. } if media_id == "m"));
        assert!(matches!(finished.device, DeviceLease::CloseOwed(RetryState { tries: 0, .. })));
        assert_eq!(record("failed", false).device, DeviceLease::Closed);
        // Saved again, it reads back the same.
        let again: SimSession = serde_json::from_value(serde_json::to_value(&finished).unwrap()).unwrap();
        assert_eq!((again.phase, again.device), (finished.phase, finished.device));
    }
}
