//! Simulator sessions an agent runs through Squircle (`squircle sim`). Starting
//! one opens the simulator for the agent's T3 thread (T3's own `device.open`,
//! so the phone streams it), boots it and records its screen. Stopping it,
//! or the agent's turn ending, finishes the recording and adds it to the
//! thread's media, dated where the session began, closes the T3 device
//! session and lets the pool shut the simulator down. The phone shows active
//! sessions as a live picture-in-picture and in the turn, and the recording
//! there afterwards.
//!
//! This is the owner of the simulator machines (`fsm::sims`): admission and
//! the grant queue (M18), each session's recorder and cleanup obligations
//! (M19), and the device reservations the pool's cleanup (M20) takes from.
//! It is the only executor: every decision is a reducer's, every reduction
//! is saved in `sims.json` through the commit gate before an effect that
//! depends on it runs, and nothing owed is ever dropped. A session reserves
//! its simulator from the moment it is saved until T3 has closed its device
//! session and the pool has decided its release; at most `max_leases`
//! simulators are reserved, unclaimed grants included.
//!
//! Past that, a start joins a first-come queue (saved with the ledger) and
//! the agent ends its turn. When a slot frees, the head is granted it, the
//! grant saved, and only then woken with a service message; its next
//! `sim start` claims the slot. A grant the woken turn leaves unclaimed, or
//! a thread T3 no longer has, gives its place up.
//!
//! A restart hands sessions over rather than ending them (`Exit::Handover`):
//! recorders are separate processes and keep recording, T3's device sessions
//! stay open, and the next run adopts every recording whose recorder is
//! provably still its own (its start time and its command line naming the
//! session's file). Only a real stop (`Exit::Stop`) ends them.

use crate::actor::{Lane, Owner, Rank, Saved, Snapshot};
use crate::agents::{Agents, Observed};
use crate::fsm::core::Disposition;
use crate::fsm::core::commit::{Gate, JsonFile};
use crate::fsm::sims::admission::{self, Answer, Capacity, Reservation, Waiter};
use crate::fsm::sims::session::{self, Boot, Closed, Event, IdleClock, Phase, RecorderID, Released, Served, Session};
use crate::fsm::sims::Seen;
use crate::media::{self, SimulatorClip};
use crate::simpool::{BootReceipt, Exclusion, Holds, Lease, Pool};
use anyhow::{Context, Result, anyhow, bail, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet, hash_map::Entry},
    convert::Infallible,
    future::Future,
    path::{Path, PathBuf},
    pin::Pin,
    process::Stdio,
    sync::{Arc, atomic::{AtomicU64, Ordering}},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::process::{Child, Command};
use tokio::sync::Notify;

pub use crate::fsm::sims::session::DeviceLease;

const KEEP: usize = 200;
/// How long simctl gets to write the movie's index after SIGINT.
const RECORDER_GRACE: Duration = Duration::from_secs(20);
/// The same while the service shuts down (its supervisor won't wait long).
const SHUTDOWN_GRACE: Duration = Duration::from_secs(5);
/// The ledger's format: 2 adds cleanup receipts, boot evidence and grant wakes.
const SCHEMA: u32 = 2;

/// What T3 currently says a thread is doing, as the simulator machines read
/// it: only a current observation decides; stale or unavailable is unknown.
pub fn seen(agents: &Agents, thread: &str) -> Seen {
    match agents.observe(thread) {
        Observed::Current { value: None, .. } => Seen::Gone,
        Observed::Current { value: Some(t), .. } => {
            let turn = t.turn.clone();
            if t.waiting {
                Seen::Waiting { turn }
            } else if t.busy() {
                Seen::Busy { turn }
            } else if t.archived {
                Seen::Gone
            } else {
                Seen::Idle { turn }
            }
        }
        Observed::Stale { value, .. } => Seen::Unknown { turn: value.and_then(|t| t.turn) },
        Observed::Unavailable => Seen::Unknown { turn: None },
    }
}

/// What `stop` hands back: the session as served, and the recording it filed.
#[derive(Serialize)]
pub struct StopReceipt {
    #[serde(flatten)]
    pub session: Served,
    #[serde(skip)]
    pub media_id: Option<String>,
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct Ledger {
    #[serde(default)]
    schema: u32,
    #[serde(default)]
    sessions: Vec<Session>,
    /// Threads waiting for a simulator, first come first served.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    queue: Vec<Waiter>,
}

impl Ledger {
    fn reservations(&self) -> Vec<Reservation> {
        self.sessions.iter().filter(|s| s.reserves())
            .map(|s| Reservation { thread: s.thread_id.clone(), device: s.device_id.to_ascii_uppercase() }).collect()
    }

    fn session(&self, id: &str) -> Option<&Session> {
        self.sessions.iter().find(|s| s.id == id)
    }
}

/// Who may signal a session's recorder. Only a process this run started is
/// owned; one a previous run started is taken over only once its start
/// time and command line proved it is the session's (PIDs are reused).
enum Recorder {
    Owned(Child),
    Recovered(RecorderID),
}

/// Effects running now, by session, so the stop path and the watchdog never
/// run the same one twice.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
enum Work {
    /// Stopping, cleaning up and filing a session, start to end.
    Finish,
    Close,
    Release,
}

/// The session owner's state, reached only by its letters.
struct State {
    ledger: Saved<Ledger, Infallible, JsonFile>,
    saved: Arc<Notify>,
    recorders: HashMap<String, Recorder>,
    clocks: HashMap<String, IdleClock>,
    /// Effects running now, each with the token of the claim that holds it.
    running: HashMap<(String, Work), u64>,
    /// Sessions a start in this run is opening: any other `starting` one was
    /// left by a start that couldn't save its end, and is finished.
    starts: HashSet<String>,
    /// Sessions a previous run left unfinished, finished first by `run`.
    orphans: Vec<String>,
    /// Simulators the pool is cleaning up, each with its exclusion's token:
    /// no start takes them meanwhile.
    excluded: HashMap<String, u64>,
    /// Set by `shutdown` in the same letter that collects the sessions it ends.
    draining: bool,
}

pub type Pending<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// What sessions do to the world: T3's device calls, the thread's state and
/// the simulator's processes. Tests use a fake.
pub trait Host: Send + Sync {
    /// A T3 call (`device.list`, `device.open`, `device.close`).
    fn device<'a>(&'a self, method: &'a str, params: Value) -> Pending<'a, Result<Value>>;
    /// T3's open device sessions (thread, device): settles a close whose answer was lost.
    fn device_sessions(&self) -> Pending<'_, Result<Vec<(String, String)>>>;
    /// What T3 currently says the thread is doing.
    fn seen(&self, thread: &str) -> Seen;
    /// The squircle invocation agents are told to use.
    fn cli(&self) -> String;
    fn boot<'a>(&'a self, device: &'a str) -> Pending<'a, Result<()>>;
    /// Starts recording the device's screen into `path`.
    fn record(&self, device: &str, path: &Path, log: std::fs::File) -> Result<Child>;
    /// A smaller copy of the recording, having removed the original.
    fn compact<'a>(&'a self, raw: &'a Path) -> Pending<'a, Option<PathBuf>>;
    /// Booted simulators of Squircle's that nothing holds (`leases` do).
    fn free<'a>(&'a self, leases: &'a [Lease]) -> Pending<'a, Vec<String>>;
    /// `thread`'s session on `device` no longer uses it: the pool shuts it
    /// down unless its policy keeps it. `others`: what other sessions reserve.
    fn release<'a>(&'a self, device: &'a str, thread: &'a str, others: &'a [Lease]) -> Pending<'a, Result<Released>>;
    /// How many simulators may be reserved at once.
    fn max_leases(&self) -> usize;
    fn title(&self, thread: &str) -> Option<String>;
    /// Queues a service message that starts a turn in `thread` (once per `id`).
    fn wake<'a>(&'a self, thread: &'a str, id: &'a str, text: String) -> Pending<'a, Result<()>>;
    /// The threads now waiting in line for a simulator (their ended turns wake nobody).
    fn waiting(&self, threads: Vec<String>);

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

    fn device_sessions(&self) -> Pending<'_, Result<Vec<(String, String)>>> {
        Box::pin(self.1.t3_sessions())
    }

    fn seen(&self, thread: &str) -> Seen {
        seen(&self.0, thread)
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
            // Outlives a restart or crash so the next run can adopt it or end
            // it cleanly (SIGINT), and a signal to the service's process group
            // (a closed terminal) doesn't end it.
            .kill_on_drop(false)
            .process_group(0)
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

    fn release<'a>(&'a self, device: &'a str, thread: &'a str, others: &'a [Lease]) -> Pending<'a, Result<Released>> {
        Box::pin(self.1.release(device, thread, others))
    }

    fn max_leases(&self) -> usize {
        self.1.policy.max_leases
    }

    fn title(&self, thread: &str) -> Option<String> {
        self.0.worker_title(thread)
    }

    fn wake<'a>(&'a self, thread: &'a str, id: &'a str, text: String) -> Pending<'a, Result<()>> {
        Box::pin(self.0.notify(thread, id, text, crate::agents::Note::SimReady, json!({"thread": thread})))
    }

    fn waiting(&self, threads: Vec<String>) {
        self.0.set_sim_waiting(threads);
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
    /// The ledger and what runs on it this run; reached only by letters.
    owner: Owner<State>,
    /// The ledger as last saved.
    ledger: Snapshot<Ledger>,
    /// Starts are admitted one at a time.
    starts: Lane,
    /// Set once by `shutdown`: no new starts, and `run` returns.
    draining: tokio::sync::watch::Sender<bool>,
    /// Woken after every save: a start waiting for a release receipt looks again.
    saved: Arc<Notify>,
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

/// When the process started (seconds, microseconds since 1970), if it runs.
fn process_start(pid: u32) -> Option<(u64, u64)> {
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    let read = unsafe { libc::proc_pidinfo(pid as libc::c_int, libc::PROC_PIDTBSDINFO, 0, (&mut info as *mut libc::proc_bsdinfo).cast(), size) };
    (read == size).then_some((info.pbi_start_tvsec, info.pbi_start_tvusec))
}

/// The process's command line, if it is running.
fn command_line(pid: u32) -> Option<String> {
    let output = std::process::Command::new("/bin/ps").args(["-ww", "-o", "command=", "-p", &pid.to_string()])
        .stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
    let line = String::from_utf8_lossy(&output.stdout).trim().to_string();
    (output.status.success() && !line.is_empty()).then_some(line)
}

/// Whether `recorder` is still this session's: its command line names the
/// session's own recording file, and (once recorded) it started when the
/// recorder did, which no reused PID can.
fn is_recorder(recorder: RecorderID, session: &str) -> bool {
    let named = command_line(recorder.pid).is_some_and(|line| line.contains(&format!(".{session}.recording.mp4")));
    named && recorder.start.is_none_or(|start| process_start(recorder.pid) == Some(start))
}

/// Saves `candidate` through the gate before the owner starts: nothing is
/// published unless saved.
fn save(gate: &mut Gate<Ledger, Infallible, JsonFile>, candidate: Ledger) -> Result<()> {
    gate.commit(candidate, vec![]).map(|_| ()).map_err(|e| anyhow!("Cannot save the simulator session ledger: {e}"))
}

/// A token telling one holder of a claim or exclusion from the next.
fn token() -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

/// One effect this run is running for a session, so the stop path and the
/// watchdog never run the same one twice. Made before its owner is asked,
/// so a cancelled ask still ends it; dropping it tells the owner.
struct Claim {
    owner: Owner<State>,
    key: (String, Work),
    token: u64,
}

impl Drop for Claim {
    fn drop(&mut self) {
        let (key, token) = (self.key.clone(), self.token);
        self.owner.tell(move |s| {
            if s.running.get(&key) == Some(&token) {
                s.running.remove(&key);
            }
        });
    }
}

impl State {
    fn ledger(&self) -> &Ledger {
        self.ledger.committed()
    }

    fn resolve(&mut self) -> Result<()> {
        self.ledger.resolve().map_err(|e| anyhow!("Cannot save the simulator session ledger: {e}"))
    }

    /// Changes a copy of the saved ledger and saves it; the change is seen,
    /// and effects after it run, only once it is saved. An earlier save
    /// whose outcome is unknown is written again first.
    fn change<T>(&mut self, change: impl FnOnce(&mut Ledger) -> Result<T>) -> Result<T> {
        self.resolve()?;
        let mut candidate = self.ledger().clone();
        let out = change(&mut candidate)?;
        self.ledger.commit(candidate, vec![]).map_err(|e| anyhow!("Cannot save the simulator session ledger: {e}"))?;
        self.saved.notify_waiters();
        Ok(out)
    }

    /// Reduces one event for one session and saves the result. Returns the
    /// decision and the effects to run now that it is saved.
    fn step(&mut self, id: &str, event: Event) -> Result<(Disposition, Vec<session::Effect>)> {
        let current = self.ledger().session(id).cloned().context("No such simulator session")?;
        let reduction = session::reduce(current, event);
        if let Disposition::ProtocolFault(why) = &reduction.disposition {
            bail!("Simulator session {id}: {why}");
        }
        debug_assert!(session::violations(&reduction.state).is_empty(), "{:?}", session::violations(&reduction.state));
        let mut effects = reduction.effects;
        if effects.first() == Some(&session::Effect::Commit) {
            effects.remove(0);
            let next = reduction.state;
            self.change(|ledger| {
                let slot = ledger.sessions.iter_mut().find(|s| s.id == id).context("No such simulator session")?;
                *slot = next;
                Ok(())
            })?;
        }
        Ok((reduction.disposition, effects))
    }

    /// A start that failed or was cancelled before it committed: its
    /// partial movie goes, and the session ends owing the close and release
    /// of whatever it may have acquired. Nothing if the start committed (or
    /// never reserved anything).
    fn abandon_start(&mut self, root: &Path, id: &str, error: String) {
        if !self.starts.remove(id) {
            return;
        }
        let Some(thread) = self.ledger().session(id).map(|s| s.thread_id.clone()) else { return };
        if let Ok(path) = media::recording_path(root, &thread, id) {
            let _ = std::fs::remove_file(path.with_extension("log"));
            let _ = std::fs::remove_file(path);
        }
        // If this can't be saved, the watchdog finds the session stranded and finishes it.
        if let Err(error) = self.step(id, Event::StartFailed { error, now: now() }) {
            eprintln!("{error:#}");
        }
    }
}

impl Sims {
    pub fn open(root: &Path, agents: Arc<Agents>, pool: Arc<Pool>) -> Result<Arc<Self>> {
        let sims = Self::with_host(root, Arc::new(AgentsHost(agents, pool.clone())))?;
        let holds: Arc<dyn Holds> = sims.clone();
        pool.attach(Arc::downgrade(&holds));
        Ok(sims)
    }

    pub fn with_host(root: &Path, host: Arc<dyn Host>) -> Result<Arc<Self>> {
        let path = root.join("sims.json");
        let file = JsonFile::new(path.clone());
        let (ledger, revision) = file.read::<Ledger>()?.unwrap_or((Ledger { schema: SCHEMA, ..Ledger::default() }, Default::default()));
        let legacy = ledger.schema < SCHEMA;
        let mut gate = Gate::restore(ledger, revision, file);
        // An earlier ledger: keep the original beside it, then save it once
        // in this format before anything is admitted.
        if legacy {
            let backup = root.join(format!("sims.schema{}.json", gate.committed().schema.max(1)));
            if !backup.try_exists()? {
                std::fs::copy(&path, &backup).with_context(|| format!("Cannot keep the earlier simulator ledger as {}", backup.display()))?;
            }
            let candidate = Ledger { schema: SCHEMA, ..gate.committed().clone() };
            save(&mut gate, candidate)?;
        }
        // A recorder a previous run left is taken over only if it is provably
        // this session's; one from before start times were saved gets its own now.
        let mut recorders = HashMap::new();
        let mut adopted = vec![];
        for s in gate.committed().sessions.iter().filter(|s| s.holds_device()) {
            let Some(recorder) = s.recorder().filter(|r| is_recorder(*r, &s.id)) else { continue };
            let recorder = RecorderID { start: recorder.start.or_else(|| process_start(recorder.pid)), ..recorder };
            if s.active() && s.recorder() != Some(recorder) {
                adopted.push((s.id.clone(), recorder));
            }
            recorders.insert(s.id.clone(), Recorder::Recovered(recorder));
        }
        if !adopted.is_empty() {
            let mut candidate = gate.committed().clone();
            for (id, recorder) in adopted {
                if let Some(s) = candidate.sessions.iter_mut().find(|s| s.id == id) {
                    *s = session::reduce(s.clone(), Event::RecorderAdopted(recorder)).state;
                }
            }
            save(&mut gate, candidate)?;
        }
        // A recording handed over with its recorder still running carries on,
        // watched like any other; the rest a previous run left are finished.
        let orphans = gate.committed().sessions.iter().filter(|s| !s.ended() && !(s.active() && recorders.contains_key(&s.id)))
            .map(|s| s.id.clone()).collect();
        let (ledger, snapshot) = Saved::new(gate);
        let saved = Arc::new(Notify::new());
        let state = State {
            ledger, saved: saved.clone(), recorders, clocks: HashMap::new(), running: HashMap::new(), starts: HashSet::new(),
            orphans, excluded: HashMap::new(), draining: false,
        };
        let sims = Arc::new(Self {
            root: root.to_path_buf(),
            host,
            owner: Owner::spawn("simulator sessions", state),
            ledger: snapshot,
            starts: Lane::new(Rank::SimStart),
            draining: tokio::sync::watch::channel(false).0,
            saved,
        });
        sims.announce_waiting();
        Ok(sims)
    }

    /// The ledger as last saved.
    fn ledger(&self) -> Arc<Ledger> {
        self.ledger.get()
    }

    /// Reduces one event for one session and saves the result.
    async fn step(&self, id: &str, event: Event) -> Result<(Disposition, Vec<session::Effect>)> {
        let id = id.to_string();
        self.owner.ask(move |s| s.step(&id, event)).await
    }

    async fn claim(&self, id: &str, work: Work) -> Option<Claim> {
        let claim = Claim { owner: self.owner.clone(), key: (id.to_string(), work), token: token() };
        let (key, token) = (claim.key.clone(), claim.token);
        let claimed = self.owner.ask(move |s| match s.running.entry(key) {
            Entry::Vacant(free) => { free.insert(token); true }
            Entry::Occupied(_) => false,
        }).await;
        claimed.then_some(claim)
    }

    /// Every simulator a session has used, with when it was last used.
    pub fn used(&self) -> Vec<(String, f64)> {
        self.ledger().sessions.iter().map(|s| (s.device_id.clone(), s.ended_at().unwrap_or(s.started_at))).collect()
    }

    /// The simulators sessions reserve now: in use, or their cleanup unsettled.
    pub fn leases(&self) -> Vec<Lease> {
        self.ledger().reservations().into_iter().map(|r| Lease { device_id: r.device, thread_id: r.thread }).collect()
    }

    /// Sessions still recording, and recent ones (newest first), optionally for one thread.
    pub fn list(&self, thread: Option<&str>) -> Value {
        let ledger = self.ledger();
        let mine = |s: &&Session| thread.is_none_or(|t| s.thread_id == t);
        let active: Vec<Served> = ledger.sessions.iter().filter(mine).filter(|s| s.active()).map(Served::from).collect();
        let recent: Vec<Served> = ledger.sessions.iter().rev().filter(mine).filter(|s| !s.active()).take(50).map(Served::from).collect();
        let queue: Vec<Value> = ledger.queue.iter().enumerate().map(|(i, w)| json!({
            "position": i + 1, "thread_id": w.thread_id, "title": self.host.title(&w.thread_id), "queued_at": w.queued_at,
            "state": if w.grant.is_some() { "held for it" } else { "waiting" },
        })).collect();
        json!({"active": active, "recent": recent, "queue": queue, "limit": self.host.max_leases()})
    }

    // MARK: Start

    pub async fn start(self: &Arc<Self>, thread: &str, device: Option<&str>) -> Result<Value> {
        ensure!(media::valid_thread(thread) && uuid::Uuid::parse_str(thread).is_ok(), "Thread ID must be a T3 thread UUID");
        loop {
            // Listening before looking, so a save in between isn't missed.
            let saved = self.saved.notified();
            tokio::pin!(saved);
            saved.as_mut().enable();
            match self.starts.run(self.try_start(thread, device)).await? {
                Started::Done(value) => return Ok(value),
                // This thread's previous session on that simulator is still
                // being cleaned up: its release receipt frees it.
                Started::Wait => saved.await,
            }
        }
    }

    async fn try_start(self: &Arc<Self>, thread: &str, device: Option<&str>) -> Result<Started> {
        ensure!(!*self.draining.borrow(), "Squircle is restarting or stopping; start the simulator again once it is back");
        let inventory = inventory(&*self.host).await?;
        ensure!(self.host.seen(thread) != Seen::Gone, "T3 has no thread {thread}");
        let simulators = local_simulators(&inventory);
        ensure!(!simulators.is_empty(), "{}", no_simulators(&inventory));

        // At most `max_leases` simulators at once; past that, the thread waits its turn.
        let max = self.host.max_leases();
        if let Some(queued) = self.admit(thread, max).await? {
            return Ok(Started::Done(queued));
        }

        let ledger = self.ledger();
        let reserved: Vec<&Session> = ledger.sessions.iter().filter(|s| s.reserves()).collect();
        let excluded: HashSet<String> = self.owner.ask(|s| s.excluded.keys().cloned().collect()).await;
        let id = |d: &Value| d["id"].as_str().unwrap_or("").to_ascii_uppercase();
        let mine = |d: &Value| reserved.iter().any(|s| s.device_id.eq_ignore_ascii_case(&id(d)) && s.thread_id == thread && s.active());
        let chosen = match device {
            Some(wanted) => simulators.iter().find(|d| d["id"].as_str().is_some_and(|id| id.eq_ignore_ascii_case(wanted))
                    || d["name"].as_str().is_some_and(|n| n.eq_ignore_ascii_case(wanted)))
                .with_context(|| format!("No iOS simulator {wanted} on this Mac; run squircle sim devices"))?,
            None => {
                let last = ledger.sessions.iter().rev().find(|s| s.thread_id == thread).map(|s| s.device_id.to_ascii_uppercase());
                let used: HashSet<String> = ledger.sessions.iter().map(|s| s.device_id.to_ascii_uppercase()).collect();
                let free = self.host.free(&self.leases()).await;
                // Reserved by a session (another thread's, or this thread's
                // still being cleaned up) or being cleaned up by the pool.
                let taken = |d: &Value| (reserved.iter().any(|s| s.device_id.eq_ignore_ascii_case(&id(d))) && !mine(d)) || excluded.contains(&id(d));
                // A booted simulator is taken only when it is Squircle's and
                // free: never the user's own, nor another agent's.
                let takeable = |d: &Value| !taken(d) && (d["booted"] != true || free.contains(&id(d)) || mine(d));
                simulators.iter().copied().find(|d| last.as_deref().is_some_and(|l| l.eq_ignore_ascii_case(&id(d))) && takeable(d))
                    .or_else(|| simulators.iter().copied().find(|d| d["booted"] == true && takeable(d)))
                    .or_else(|| simulators.iter().copied().find(|d| used.contains(&id(d)) && takeable(d)))
                    .or_else(|| simulators.iter().copied().find(|d| takeable(d)))
                    .context("No free simulator: the booted ones are the user's or other agents'; pass --device (squircle sim devices)")?
            }
        };
        let device_id = chosen["id"].as_str().context("Simulator without an ID")?.to_string();
        let device_name = chosen["name"].as_str().unwrap_or("Simulator").to_string();
        let booted = chosen["booted"] == true;

        // Already running here: the same session. On another simulator: end that one first.
        if let Some(existing) = reserved.iter().find(|s| s.thread_id == thread && s.active()) {
            if existing.device_id.eq_ignore_ascii_case(&device_id) {
                return Ok(Started::Done(self.started(existing, "This thread's simulator session is already running.")));
            }
            let sims = self.clone();
            let old = existing.id.clone();
            tokio::spawn(async move {
                if let Err(error) = sims.finish(&old, "replaced").await {
                    eprintln!("Simulator session {old} not ended: {error:#}");
                }
            });
        }
        if let Some(other) = reserved.iter().find(|s| s.device_id.eq_ignore_ascii_case(&device_id) && !s.active()) {
            if other.thread_id != thread {
                bail!("{device_name} is in use by thread {}; pick another with --device (squircle sim devices)", other.thread_id);
            }
            if let Some(error) = cleanup_error(other) {
                bail!("{device_name} is still held by this thread's previous session, whose cleanup is failing ({error}); \
                    Squircle keeps retrying. Pick another simulator with --device meanwhile.");
            }
            return Ok(Started::Wait);
        }
        if let Some(other) = reserved.iter().find(|s| s.device_id.eq_ignore_ascii_case(&device_id) && s.thread_id != thread) {
            bail!("{device_name} is in use by thread {}; pick another with --device (squircle sim devices)", other.thread_id);
        }

        // The reservation, saved (with its place in line given up) before T3
        // opens anything: whatever happens next, a close and a release are
        // owed. The startup exists first, so even a cancelled ask is rolled back.
        let id = uuid::Uuid::new_v4().to_string();
        let session = Session::reserve(id.clone(), thread.into(), device_id, device_name, booted, now());
        let mut startup = Startup { owner: self.owner.clone(), root: self.root.clone(), id: id.clone(), child: None, error: None };
        let (reserving, claimant) = (session.clone(), thread.to_string());
        self.owner.ask(move |s| {
            ensure!(!s.excluded.contains_key(&reserving.device_id.to_ascii_uppercase()),
                "{} is being shut down by the simulator cleanup; start again, or pick another with --device", reserving.device_name);
            s.starts.insert(reserving.id.clone());
            let reserved = s.change(|ledger| {
                ensure!(!ledger.sessions.iter().any(|s| s.reserves() && s.device_id.eq_ignore_ascii_case(&reserving.device_id)),
                    "{} was taken meanwhile; start again", reserving.device_name);
                let reservations = ledger.reservations();
                let claim = admission::Event::Claim { thread: claimant };
                ledger.queue = admission::reduce(std::mem::take(&mut ledger.queue), &Capacity { limit: max, reservations: &reservations }, claim).state;
                ledger.sessions.push(reserving.clone());
                trim(ledger);
                Ok(())
            });
            if reserved.is_err() {
                // An unsaved reservation left in doubt is finished by the watchdog once it is saved.
                s.starts.remove(&reserving.id);
            }
            reserved
        }).await?;
        self.announce_waiting();
        match self.begin(&session, &mut startup).await {
            Ok(session) => Ok(Started::Done(self.started(&session, "Recording. The user watches it live on their phone."))),
            Err(error) => {
                startup.error = Some(format!("{error:#}"));
                drop(startup);
                self.cleanup(&id, false).await;
                Err(error)
            }
        }
    }

    /// Opens, boots and records, saving each step; `startup` ends the
    /// session if this fails or is cancelled.
    async fn begin(&self, session: &Session, startup: &mut Startup) -> Result<Session> {
        let name = &session.device_name;
        self.host.device("device.open", json!({"threadId": session.thread_id, "hostId": session.host_id,
            "deviceId": session.device_id, "platform": "ios", "boot": true})).await
            .context("T3 could not open the simulator")?;
        self.step(&session.id, Event::Opened).await?;
        self.host.boot(&session.device_id).await.with_context(|| format!("{name} did not finish booting"))?;
        self.step(&session.id, Event::Booted { at: now() }).await?;

        let path = media::recording_path(&self.root, &session.thread_id, &session.id)?;
        let log = std::fs::File::create(path.with_extension("log"))?;
        let recorder = startup.child.insert(self.host.record(&session.device_id, &path, log)?);
        let pid = recorder.id().context("The recorder exited at once")?;
        self.step(&session.id, Event::RecorderStarted(RecorderID { pid, start: process_start(pid) })).await?;
        tokio::time::sleep(Duration::from_millis(1200)).await;
        if let Some(status) = startup.child.as_mut().and_then(|c| c.try_wait().transpose()).transpose()? {
            let detail = std::fs::read_to_string(path.with_extension("log")).unwrap_or_default();
            bail!("Recording {name} failed ({status}): {}", detail.trim());
        }
        // In one letter with shutdown's collection of the sessions it ends:
        // either shutdown sees this recording, or this sees shutdown.
        let (id, child) = (session.id.clone(), startup.child.take());
        self.owner.ask(move |s| {
            let mut child = child;
            let recording = if s.draining { Err(anyhow!("Squircle is shutting down")) } else { s.step(&id, Event::Recording).map(drop) };
            if let Err(error) = recording {
                // The partial movie is useless; tokio reaps the killed child.
                if let Some(child) = &mut child { let _ = child.start_kill(); }
                return Err(error);
            }
            if let Some(child) = child {
                s.recorders.insert(id.clone(), Recorder::Owned(child));
            }
            s.starts.remove(&id);
            s.ledger().session(&id).cloned().context("No such simulator session")
        }).await
    }

    /// Admission: None if `thread` may reserve a simulator now; otherwise it
    /// keeps (or takes) its place in line, saved, and this tells the agent.
    async fn admit(&self, thread: &str, max: usize) -> Result<Option<Value>> {
        let (asking, waiter) = (thread.to_string(), uuid::Uuid::new_v4().to_string());
        let position = self.owner.ask(move |s| -> Result<Option<usize>> {
            s.resolve()?;
            let ledger = s.ledger();
            let reservations = ledger.reservations();
            let ask = admission::Event::Ask { thread: asking, now: now(), waiter };
            let reduction = admission::reduce(ledger.queue.clone(), &Capacity { limit: max, reservations: &reservations }, ask);
            let position = match reduction.effects.iter().find_map(|e| match e { admission::Effect::Answer(a) => Some(a.clone()), _ => None }) {
                Some(Answer::Admitted) | None => return Ok(None),
                Some(Answer::Queued { position }) => position,
            };
            if reduction.effects.contains(&admission::Effect::Commit) {
                let queue = reduction.state;
                s.change(|ledger| { ledger.queue = queue; Ok(()) })?;
            }
            Ok(Some(position))
        }).await?;
        let Some(position) = position else { return Ok(None) };
        let holders: Vec<String> = self.ledger().sessions.iter().filter(|s| s.reserves())
            .map(|s| format!("{} ({})", s.device_name, self.host.title(&s.thread_id).unwrap_or_else(|| s.thread_id.clone()))).collect();
        self.announce_waiting();
        let cli = self.host.cli();
        Ok(Some(json!({
            "status": "queued",
            "position": position,
            "in_use": holders,
            "limit": max,
            "next": format!("All {max} simulators are in use; this thread is number {position} in line and keeps its place. \
                End your turn now. When a simulator is free, Squircle holds it for this thread and wakes it with a \
                [simulator ready] message; then run {cli} sim start --thread {thread} again. \
                To leave the line: {cli} sim stop --thread {thread}."),
        })))
    }

    /// Whether `thread` has a session recording.
    pub fn running(&self, thread: &str) -> bool {
        self.ledger().sessions.iter().any(|s| s.thread_id == thread && s.active())
    }

    /// Takes `thread` out of the line (a held slot frees for the next).
    pub async fn leave(&self, thread: &str) -> Result<bool> {
        let (max, leaving) = (self.host.max_leases(), thread.to_string());
        let left = self.owner.ask(move |s| -> Result<bool> {
            s.resolve()?;
            let reservations = s.ledger().reservations();
            let queue = s.ledger().queue.clone();
            let reduction = admission::reduce(queue, &Capacity { limit: max, reservations: &reservations },
                admission::Event::Leave { thread: leaving });
            if reduction.disposition != Disposition::Applied {
                return Ok(false);
            }
            let queue = reduction.state;
            s.change(|ledger| { ledger.queue = queue; Ok(()) })?;
            Ok(true)
        }).await?;
        if left {
            self.announce_waiting();
        }
        Ok(left)
    }

    fn announce_waiting(&self) {
        let threads = self.ledger().queue.iter().map(|w| w.thread_id.clone()).collect();
        self.host.waiting(threads);
    }

    /// One coherent look at the line: gives up the places of threads T3 no
    /// longer has and grants left unclaimed, grants free slots to the head,
    /// saves that, and only then queues the wakes it owes.
    async fn advance(&self) {
        let max = self.host.max_leases();
        // What T3 says of each thread in line, read before the owner decides;
        // one that joined meanwhile is unknown, which keeps its place.
        let seen: HashMap<String, Seen> = self.ledger().queue.iter().map(|w| (w.thread_id.clone(), self.host.seen(&w.thread_id))).collect();
        let decided = self.owner.ask(move |s| -> Option<(Vec<Waiter>, bool)> {
            s.resolve().ok()?;
            let ledger = s.ledger();
            let reservations = ledger.reservations();
            let seen = ledger.queue.iter()
                .map(|w| (w.thread_id.clone(), seen.get(&w.thread_id).cloned().unwrap_or(Seen::Unknown { turn: None }))).collect();
            let reduction = admission::reduce(ledger.queue.clone(), &Capacity { limit: max, reservations: &reservations },
                admission::Event::Advance { now: now(), seen });
            if reduction.effects.contains(&admission::Effect::Commit) {
                let queue = reduction.state;
                if let Err(error) = s.change(|ledger| { ledger.queue = queue; Ok(()) }) {
                    // Nothing was granted, so nobody is woken.
                    eprintln!("Simulator queue not advanced: {error:#}");
                    return None;
                }
            }
            let wakes = reduction.effects.iter().filter_map(|e| match e { admission::Effect::Wake(w) => Some(w.clone()), _ => None }).collect();
            Some((wakes, reduction.effects.contains(&admission::Effect::Announce)))
        }).await;
        let Some((wakes, announce)) = decided else { return };
        if announce {
            self.announce_waiting();
        }
        let cli = self.host.cli();
        for waiter in wakes {
            let thread = &waiter.thread_id;
            let text = format!("[simulator ready]\nA simulator is free and held for this thread. Run {cli} sim start --thread {thread} \
                now to take it, then carry on. If you no longer need it, run {cli} sim stop --thread {thread} to give it up.");
            if let Err(error) = self.host.wake(thread, &waiter.id, text).await {
                eprintln!("Simulator wake for {thread} not queued: {error:#}");
                continue;
            }
            let (thread, woken) = (thread.clone(), waiter.id.clone());
            self.owner.ask(move |s| {
                let reservations = s.ledger().reservations();
                let queue = s.ledger().queue.clone();
                let reduction = admission::reduce(queue, &Capacity { limit: max, reservations: &reservations },
                    admission::Event::WakeQueued { waiter: woken });
                if reduction.disposition == Disposition::Applied {
                    let queue = reduction.state;
                    if let Err(error) = s.change(|ledger| { ledger.queue = queue; Ok(()) }) {
                        // The outbox dedupes by the waiter's ID; the wake is asked for again.
                        eprintln!("Simulator wake for {thread} queued but not recorded: {error:#}");
                    }
                }
            }).await;
        }
    }

    fn started(&self, session: &Session, status: &str) -> Value {
        let cli = self.host.cli();
        json!({
            "session": Served::from(session),
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
        let session = self.ledger().sessions.iter().rev()
            .find(|s| s.active() && (id.is_some_and(|i| s.id == i) || (id.is_none() && thread.is_some_and(|t| s.thread_id == t))))
            .cloned();
        let Some(session) = session else {
            bail!("No simulator session is running{}", thread.map(|t| format!(" for thread {t}")).unwrap_or_default());
        };
        let session = self.finish(&session.id, "stopped").await?;
        let media_id = match &session.phase { Phase::Finished { media_id, .. } => Some(media_id.clone()), _ => None };
        Ok(StopReceipt { session: Served::from(&session), media_id })
    }

    /// Ends the recording, closes T3's device session, has the pool release
    /// the simulator and files the recording. Problems are recorded on the
    /// session; an error means a save failed, or another stop has it.
    async fn finish(&self, id: &str, reason: &str) -> Result<Session> {
        let _finish = self.claim(id, Work::Finish).await.context("The session is already being stopped")?;
        self.halt(id, reason, RECORDER_GRACE, false).await?.context("The session is already being stopped")?;
        self.cleanup(id, false).await;
        self.file(id, true).await
    }

    /// A session left part-way (a previous run's, or one whose step couldn't
    /// be saved) is finished from where it stands.
    async fn resume(&self, id: &str, reason: &str) {
        let Some(_finish) = self.claim(id, Work::Finish).await else { return };
        if let Err(error) = self.halt(id, reason, RECORDER_GRACE, true).await {
            eprintln!("Simulator session {id} not stopped: {error:#}");
        }
        self.cleanup(id, false).await;
        if let Err(error) = self.file(id, true).await {
            eprintln!("Simulator session {id} not filed: {error:#}");
        }
    }

    /// Claims a session (saved), stops its recorder and saves that it
    /// stopped: from then on its close, release and filing are owed. None if
    /// it isn't this call's to stop.
    async fn halt(&self, id: &str, reason: &str, grace: Duration, recovering: bool) -> Result<Option<Session>> {
        let (stopping, reason) = (id.to_string(), reason.to_string());
        let halted = self.owner.ask(move |s| -> Result<Option<(Session, Option<Recorder>)>> {
            let (disposition, _) = s.step(&stopping, Event::Stop { reason, recovering })?;
            if disposition != Disposition::Applied {
                return Ok(None);
            }
            let session = s.ledger().session(&stopping).cloned().context("No such simulator session")?;
            s.clocks.remove(&stopping);
            Ok(Some((session, s.recorders.remove(&stopping))))
        }).await?;
        let Some((session, recorder)) = halted else { return Ok(None) };
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
            Some(Recorder::Recovered(recorder)) if is_recorder(recorder, id) => {
                unsafe { libc::kill(recorder.pid as i32, libc::SIGINT) };
                let polls = (grace.as_millis() / 250).max(1);
                for _ in 0..polls {
                    if !is_recorder(recorder, id) { break }
                    tokio::time::sleep(Duration::from_millis(250)).await;
                }
            }
            _ => if let Some(recorder) = session.recorder().filter(|r| alive(r.pid)) {
                warning = Some(format!("Process {} is no longer this session's recorder; it was left alone", recorder.pid));
            },
        }
        self.step(id, Event::RecorderStopped { now: now(), warning }).await?;
        Ok(self.ledger().session(id).cloned())
    }

    /// Runs a session's owed cleanup now: T3's close, then the pool's
    /// release. `force` ignores retry backoff (the service is stopping).
    async fn cleanup(&self, id: &str, force: bool) {
        self.close(id, force).await;
        self.release(id, force).await;
    }

    /// Closes the session's T3 device session if a close is owed. A lost
    /// answer is settled by T3's list of open sessions; a failure stays owed.
    async fn close(&self, id: &str, force: bool) {
        let Some(_close) = self.claim(id, Work::Close).await else { return };
        let time = if force { f64::INFINITY } else { now() };
        let Some(session) = self.ledger().session(id).cloned().filter(|s| s.close_due(time)) else { return };
        let closed = self.host.device("device.close", json!({"threadId": session.thread_id, "hostId": session.host_id,
            "deviceId": session.device_id, "platform": "ios"})).await;
        let outcome = match closed {
            Ok(_) => Closed::Closed,
            Err(error) => match self.host.device_sessions().await {
                Ok(open) if !open.iter().any(|(t, d)| *t == session.thread_id && d.eq_ignore_ascii_case(&session.device_id)) => Closed::Absent,
                _ => Closed::Failed(format!("T3 did not close the simulator: {error:#}")),
            },
        };
        if let Err(error) = self.step(id, Event::CloseResult { outcome, now: now() }).await {
            eprintln!("{error:#}");
        }
    }

    /// Asks the pool to release the simulator once T3's device session is
    /// closed. Its answer is the receipt that frees the slot; a failure stays owed.
    async fn release(&self, id: &str, force: bool) {
        let Some(_release) = self.claim(id, Work::Release).await else { return };
        let time = if force { f64::INFINITY } else { now() };
        let ledger = self.ledger();
        let Some(session) = ledger.session(id).cloned().filter(|s| s.release_due(time)) else { return };
        let others: Vec<Lease> = ledger.sessions.iter().filter(|s| s.id != id && s.reserves())
            .map(|s| Lease { device_id: s.device_id.to_ascii_uppercase(), thread_id: s.thread_id.clone() }).collect();
        let outcome = self.host.release(&session.device_id, &session.thread_id, &others).await.map_err(|e| format!("{e:#}"));
        if let Err(error) = &outcome {
            eprintln!("Simulator {} not released after its session: {error}", session.device_id);
        }
        if let Err(error) = self.step(id, Event::ReleaseResult { outcome, now: now() }).await {
            eprintln!("{error:#}");
        }
    }

    /// Moves a stopped session's recording into the thread's media.
    async fn file(&self, id: &str, shrink: bool) -> Result<Session> {
        let session = self.ledger().session(id).cloned().context("The session disappeared")?;
        let Phase::Filing { ended_at, warning, .. } = session.phase.clone() else { return Ok(session) };
        let raw = media::recording_path(&self.root, &session.thread_id, id);
        let path = match &raw {
            Ok(raw) => {
                let _ = std::fs::remove_file(raw.with_extension("log"));
                let nonempty = |p: &Path| p.metadata().is_ok_and(|m| m.len() > 0);
                if nonempty(raw) {
                    // Declared policy: if compressing fails, the original is filed as it is.
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
        let result = match filed {
            Some(Ok(media)) => Ok(media.id),
            Some(Err(error)) => Err(format!("{error:#}")),
            None => Err(warning.unwrap_or_else(|| "simctl wrote no video".into())),
        };
        self.step(id, Event::Filed(result)).await?;
        self.ledger().session(id).cloned().context("The session disappeared")
    }

    /// This Mac's iOS simulators, and which thread (if any) is using each.
    pub async fn devices(&self) -> Result<Value> {
        let inventory = inventory(&*self.host).await?;
        let simulators = local_simulators(&inventory);
        ensure!(!simulators.is_empty(), "{}", no_simulators(&inventory));
        let ledger = self.ledger();
        let held: Vec<&Session> = ledger.sessions.iter().filter(|s| s.holds_device()).collect();
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
    /// too long, and runs owed cleanup and saves. Sessions a previous run
    /// left unfinished are finished first. Returns once `shutdown` begins.
    pub async fn run(self: Arc<Self>) {
        let mut draining = self.draining.subscribe();
        let orphans = self.owner.ask(|s| std::mem::take(&mut s.orphans)).await;
        for id in orphans {
            if *draining.borrow() { return }
            self.resume(&id, "service restarted").await;
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
        if let Err(error) = self.owner.ask(|s| s.ledger.resolve()).await {
            eprintln!("Simulator session ledger still not saved: {error}");
        }
        for (id, reason) in self.due().await {
            // Filing can take minutes; it never holds up other sessions.
            let sims = self.clone();
            tokio::spawn(async move {
                if let Err(error) = sims.finish(&id, reason).await {
                    eprintln!("Simulator session {id} not ended: {error:#}");
                }
            });
        }
        // Sessions a step's failed save left part-way: finished from where they stand.
        for id in self.stranded().await {
            let sims = self.clone();
            tokio::spawn(async move { sims.resume(&id, "interrupted").await });
        }
        let time = now();
        let owed: Vec<String> = self.ledger().sessions.iter().filter(|s| s.close_due(time) || s.release_due(time)).map(|s| s.id.clone()).collect();
        for id in owed {
            self.cleanup(&id, false).await;
        }
        // Not while a start is deciding whether it may take a slot.
        self.starts.try_run(self.advance()).await;
    }

    /// Sessions nothing in this run is working on that are stuck before
    /// their end: a start that couldn't save its failure, a stop or filing
    /// whose save failed.
    async fn stranded(&self) -> Vec<String> {
        self.owner.ask(|s| {
            let orphans: HashSet<&String> = s.orphans.iter().collect();
            s.ledger().sessions.iter()
                .filter(|session| match session.phase {
                    Phase::Starting { .. } => !s.starts.contains(&session.id),
                    Phase::Stopping { .. } | Phase::Filing { .. } => true,
                    _ => false,
                })
                .filter(|session| !orphans.contains(&session.id) && !s.running.contains_key(&(session.id.clone(), Work::Finish)))
                .map(|session| session.id.clone()).collect()
        }).await
    }

    /// Sessions to stop now, and why: the recorder died, the time limit
    /// passed, or T3 confirmed the turn over for the grace.
    async fn due(&self) -> Vec<(String, &'static str)> {
        let time = now();
        // What T3 says of each recording session's thread, read before the owner decides.
        let seen: HashMap<String, Seen> = self.ledger().sessions.iter().filter(|s| s.active())
            .map(|s| (s.thread_id.clone(), self.host.seen(&s.thread_id))).collect();
        self.owner.ask(move |s| {
            let active: Vec<Session> = s.ledger().sessions.iter().filter(|s| s.active()).cloned().collect();
            let mut due = Vec::new();
            for session in active {
                let alive = match s.recorders.get_mut(&session.id) {
                    Some(Recorder::Owned(child)) => matches!(child.try_wait(), Ok(None)),
                    Some(Recorder::Recovered(recorder)) => is_recorder(*recorder, &session.id),
                    None => false,
                };
                let seen = seen.get(&session.thread_id).cloned().unwrap_or(Seen::Unknown { turn: None });
                let clock = s.clocks.get(&session.id).copied().unwrap_or_default();
                let (clock, reason) = session::watch(&session, clock, alive, &seen, time);
                s.clocks.insert(session.id.clone(), clock);
                if let Some(reason) = reason {
                    due.push((session.id, reason));
                }
            }
            due
        }).await
    }

    /// For the service's graceful exit: refuses new starts and stops the
    /// watchdog. A stop ends every recording (filed uncompressed, to be
    /// quick); a handover leaves them recording for the next run. Either way
    /// owed closes and releases are run. Anything it can't finish stays owed
    /// in the ledger for the next run.
    pub async fn shutdown(&self, exit: Exit) {
        // Not in the start lane: a start booting a simulator could hold it
        // for minutes. One past its commit check is rolled back instead.
        self.draining.send_replace(true);
        let live: Vec<String> = self.owner.ask(move |s| {
            s.draining = true;
            s.ledger().sessions.iter().filter(|s| s.active() && exit == Exit::Stop).map(|s| s.id.clone()).collect()
        }).await;
        futures_util::future::join_all(live.iter().map(|id| async move {
            let Some(_finish) = self.claim(id, Work::Finish).await else { return };
            match self.halt(id, "service stopped", SHUTDOWN_GRACE, false).await {
                Ok(Some(_)) => {
                    self.cleanup(id, true).await;
                    let _ = self.file(id, false).await;
                }
                Ok(None) => {}
                Err(error) => eprintln!("Simulator session {id} not stopped: {error:#}"),
            }
        })).await;
        let owed: Vec<String> = self.ledger().sessions.iter().filter(|s| s.close_due(f64::INFINITY) || s.release_owed()).map(|s| s.id.clone()).collect();
        futures_util::future::join_all(owed.iter().map(|id| self.cleanup(id, true))).await;
        if let Err(error) = self.owner.ask(|s| s.ledger.resolve()).await {
            eprintln!("Simulator session ledger not saved: {error}");
        }
    }
}

impl Holds for Sims {
    fn leases(&self) -> Vec<Lease> {
        Sims::leases(self)
    }

    fn boots(&self) -> Vec<(String, BootReceipt)> {
        self.ledger().sessions.iter().filter_map(|s| match s.boot {
            Boot::BootedHere { at } => Some((s.device_id.to_ascii_uppercase(), BootReceipt { at, thread: None, session: Some(s.id.clone()) })),
            _ => None,
        }).collect()
    }

    fn exclude<'a>(&'a self, udid: &'a str) -> Pending<'a, Option<Exclusion>> {
        Box::pin(async move {
            let (udid, token) = (udid.to_ascii_uppercase(), token());
            let (owner, released) = (self.owner.clone(), udid.clone());
            // Made before the owner is asked, so even a cancelled ask is released.
            let exclusion = Exclusion::new(move || owner.tell(move |s| {
                if s.excluded.get(&released) == Some(&token) {
                    s.excluded.remove(&released);
                }
            }));
            // In the owner's turn, as a start's reservation is: the two can't interleave.
            let excluded = self.owner.ask(move |s| {
                let reserved = s.ledger().sessions.iter().any(|s| s.reserves() && s.device_id.eq_ignore_ascii_case(&udid));
                if reserved || s.excluded.contains_key(&udid) {
                    return false;
                }
                s.excluded.insert(udid, token);
                true
            }).await;
            excluded.then_some(exclusion)
        })
    }
}

/// How a start ended up.
enum Started {
    Done(Value),
    /// Wait for a save, then look again.
    Wait,
}

/// Why a session's cleanup is failing, if it is.
fn cleanup_error(session: &Session) -> Option<String> {
    let retry = match (&session.device, &session.release) {
        (DeviceLease::CloseOwed(retry), _) | (DeviceLease::Closed, session::Release::Owed(retry)) => retry,
        _ => return None,
    };
    retry.error.clone()
}

/// How the service is exiting.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Exit {
    /// A restart (SIGTERM): live sessions carry on into the next run.
    Handover,
    /// A real stop (SIGINT, `squircle service stop`): live sessions end.
    Stop,
}

/// Owns a starting session's provisional resources: unless the start
/// commits, dropping it (an error or a cancelled request) kills the
/// recorder and tells the owner to end the session, which then owes the
/// close and release of whatever it may have acquired.
struct Startup {
    owner: Owner<State>,
    root: PathBuf,
    id: String,
    child: Option<Child>,
    error: Option<String>,
}

impl Drop for Startup {
    fn drop(&mut self) {
        if let Some(child) = &mut self.child {
            // The partial movie is useless; tokio reaps the killed child.
            let _ = child.start_kill();
        }
        let (root, id) = (self.root.clone(), self.id.clone());
        let error = self.error.take().unwrap_or_else(|| "The start was cancelled".into());
        self.owner.tell(move |s| s.abandon_start(&root, &id, error));
    }
}

/// Drops the oldest settled sessions over `KEEP`; anything still owed stays.
fn trim(ledger: &mut Ledger) {
    let mut excess = ledger.sessions.len().saturating_sub(KEEP);
    ledger.sessions.retain(|s| {
        let gone = excess > 0 && s.settled();
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
// Fakes record calls behind leaf locks; never held across a call.
#[allow(clippy::disallowed_types)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering::SeqCst};

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
    const B: &str = "0e7c4a1d-5f0b-4c8e-9a51-2b6f1c3d4e5f";
    const C: &str = "1e7c4a1d-5f0b-4c8e-9a51-2b6f1c3d4e5f";
    const D: &str = "2e7c4a1d-5f0b-4c8e-9a51-2b6f1c3d4e5f";

    /// T3 and simctl stand-ins: two simulators, a recorder that writes its
    /// movie on SIGINT like simctl, closes and releases that fail on request,
    /// and T3's list of open device sessions.
    #[derive(Default)]
    struct Fake {
        calls: Mutex<Vec<String>>,
        close_fails: AtomicBool,
        /// T3 still lists the closed device sessions (so a failed close stays owed).
        lists_open: AtomicBool,
        release_fails: AtomicBool,
        boot: Mutex<Option<std::result::Result<(), ()>>>,
        seen: Mutex<Option<Seen>>,
        /// Per-thread T3 state, over `seen`.
        threads: Mutex<HashMap<String, Seen>>,
        woken: Mutex<Vec<(String, String)>>,
        waiting: Mutex<Vec<String>>,
        max: AtomicUsize,
    }

    impl Fake {
        fn count(&self, call: &str) -> usize {
            self.calls.lock().unwrap().iter().filter(|c| *c == call).count()
        }

        fn closes(&self) -> usize {
            self.count("device.close")
        }

        fn set(&self, thread: &str, seen: Seen) {
            self.threads.lock().unwrap().insert(thread.into(), seen);
        }
    }

    fn busy(turn: &str) -> Seen { Seen::Busy { turn: Some(turn.into()) } }
    fn idle(turn: &str) -> Seen { Seen::Idle { turn: Some(turn.into()) } }

    impl Host for Fake {
        fn device<'a>(&'a self, method: &'a str, _: Value) -> Pending<'a, Result<Value>> {
            self.calls.lock().unwrap().push(method.into());
            let fails = method == "device.close" && self.close_fails.load(SeqCst);
            Box::pin(async move {
                ensure!(!fails, "disconnected");
                Ok(json!({"devices": [{"id": "SIM1", "name": "iPhone", "platform": "ios", "hostId": "local", "booted": true},
                                       {"id": "SIM2", "name": "iPad", "platform": "ios", "hostId": "local", "booted": false}]}))
            })
        }
        fn device_sessions(&self) -> Pending<'_, Result<Vec<(String, String)>>> {
            let open = self.lists_open.load(SeqCst);
            Box::pin(async move {
                ensure!(open, "T3 is offline");
                Ok(vec![(THREAD.to_string(), "SIM1".to_string()), (B.to_string(), "SIM1".to_string())])
            })
        }
        fn seen(&self, thread: &str) -> Seen {
            self.threads.lock().unwrap().get(thread).cloned()
                .unwrap_or_else(|| self.seen.lock().unwrap().clone().unwrap_or(busy("t0")))
        }
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
                .arg(path).stderr(log).spawn()?)
        }
        fn compact<'a>(&'a self, _: &'a Path) -> Pending<'a, Option<PathBuf>> {
            Box::pin(async { None })
        }
        fn free<'a>(&'a self, _: &'a [Lease]) -> Pending<'a, Vec<String>> {
            Box::pin(async { vec!["SIM1".into()] })
        }
        fn release<'a>(&'a self, device: &'a str, _: &'a str, _: &'a [Lease]) -> Pending<'a, Result<Released>> {
            self.calls.lock().unwrap().push(format!("release {device}"));
            let fails = self.release_fails.load(SeqCst);
            Box::pin(async move {
                ensure!(!fails, "simctl shutdown failed");
                Ok(Released::ShutDown)
            })
        }
        fn max_leases(&self) -> usize { self.max.load(SeqCst).max(1) }
        fn title(&self, _: &str) -> Option<String> { None }
        fn wake<'a>(&'a self, thread: &'a str, id: &'a str, _: String) -> Pending<'a, Result<()>> {
            self.woken.lock().unwrap().push((thread.into(), id.into()));
            Box::pin(async { Ok(()) })
        }
        fn waiting(&self, threads: Vec<String>) { *self.waiting.lock().unwrap() = threads }
    }

    fn sims(root: &Path, boot: Option<std::result::Result<(), ()>>) -> (Arc<Sims>, Arc<Fake>) {
        let fake = Arc::new(Fake { boot: Mutex::new(boot), ..Fake::default() });
        (Sims::with_host(root, fake.clone()).unwrap(), fake)
    }

    fn state(session: &Session) -> String {
        Served::from(session).state
    }

    fn only(sims: &Sims) -> Session {
        sims.ledger().sessions.last().cloned().unwrap()
    }

    fn only_of(sims: &Sims, thread: &str) -> Session {
        sims.ledger().sessions.iter().rev().find(|s| s.thread_id == thread).cloned().unwrap()
    }

    fn queue(sims: &Sims) -> Vec<(String, bool)> {
        sims.ledger().queue.iter().map(|w| (w.thread_id.clone(), w.grant.is_some())).collect()
    }

    /// Makes every owed retry due now.
    async fn due_now(sims: &Sims) {
        sims.owner.ask(|state| state.change(|ledger| {
            for s in &mut ledger.sessions {
                if let DeviceLease::CloseOwed(retry) = &mut s.device { retry.retry_at = 0.0 }
                if let session::Release::Owed(retry) = &mut s.release { retry.retry_at = 0.0 }
            }
            Ok(())
        })).await.unwrap();
    }

    /// Waits for every letter told so far (a dropped guard's) to be read.
    async fn settled(sims: &Sims) {
        sims.owner.ask(|_| ()).await;
    }

    /// A second cleanup of a session already being cleaned up (`sim stop`
    /// racing the watchdog) is turned away without touching the first's
    /// claim, and one whose ask was cancelled holds nothing. Claims once
    /// self-deadlocked on the state lock and hung the service.
    #[tokio::test]
    async fn overlapping_claims_neither_deadlock_nor_release_the_holder() {
        let dir = tempfile::tempdir().unwrap();
        let (sims, _) = sims(dir.path(), None);
        let held = sims.claim("s", Work::Release).await.expect("first claim");
        assert!(sims.claim("s", Work::Release).await.is_none());
        assert!(sims.claim("s", Work::Release).await.is_none(), "a refused claim released the holder's");
        drop(held);
        let again = sims.claim("s", Work::Release).await.expect("released on drop");
        drop(again);
        // Cancelled after asking, before the owner granted it: the guard,
        // made first, still releases what the owner then grants.
        let mut cancelled = Box::pin(sims.claim("s", Work::Close));
        assert!(std::future::poll_fn(|cx| std::task::Poll::Ready(cancelled.as_mut().poll(cx).is_pending())).await);
        drop(cancelled);
        assert!(sims.claim("s", Work::Close).await.is_some() && sims.claim("s", Work::Release).await.is_some());
    }

    /// The shapes that once deadlocked, all at once: sessions stopping and
    /// cleaned up by the watchdog while new starts are admitted, claims are
    /// raced and dropped, and the pool takes and drops exclusions. Every one
    /// finishes.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn owners_interacting_concurrently_never_deadlock() {
        let dir = tempfile::tempdir().unwrap();
        let (sims, fake) = sims(dir.path(), Some(Ok(())));
        fake.max.store(2, SeqCst);
        let work = async {
            let (a, b) = tokio::join!(sims.start(THREAD, None), sims.start(B, Some("SIM2")));
            assert!(a.is_ok() && b.is_ok());
            let racing = (0..16).map(|i| {
                let sims = sims.clone();
                tokio::spawn(async move {
                    let work = if i % 2 == 0 { Work::Close } else { Work::Release };
                    let claim = sims.claim(if i % 3 == 0 { "x" } else { "y" }, work).await;
                    let exclusion = sims.exclude(if i % 2 == 0 { "SIM9" } else { "SIM1" }).await;
                    tokio::task::yield_now().await;
                    drop((claim, exclusion));
                })
            });
            let _ = tokio::join!(
                async { (sims.stop(Some(THREAD), None).await, sims.stop(Some(B), None).await) },
                sims.tick(),
                sims.tick(),
                futures_util::future::join_all(racing),
                async { (sims.start(C, None).await, sims.leave(C).await, sims.stop(Some(C), None).await) },
            );
            sims.tick().await;
        };
        tokio::time::timeout(Duration::from_secs(30), work).await.expect("the owners deadlocked");
        settled(&sims).await;
        assert!(sims.owner.ask(|s| s.running.is_empty() && s.excluded.is_empty()).await, "a dropped guard was never released");
    }

    /// Recovery signals a saved PID only while it is still that session's
    /// recorder: its command line and its start time.
    #[test]
    fn recorder_identity_is_the_session_file_and_start() {
        let id = uuid::Uuid::new_v4().to_string();
        let mut child = std::process::Command::new("/bin/sh").args(["-c", "sleep 5; true", "sh"])
            .arg(format!("/tmp/.{id}.recording.mp4")).spawn().unwrap();
        let pid = child.id();
        let start = process_start(pid);
        assert!(start.is_some());
        assert!(is_recorder(RecorderID { pid, start }, &id));
        assert!(is_recorder(RecorderID { pid, start: None }, &id));
        assert!(!is_recorder(RecorderID { pid, start: Some((1, 0)) }, &id), "a different start time passed");
        assert!(!is_recorder(RecorderID { pid, start }, &uuid::Uuid::new_v4().to_string()));
        child.kill().unwrap();
        child.wait().unwrap();
        assert!(!is_recorder(RecorderID { pid, start }, &id));
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
        let id = sims.owner.ask(|s| std::mem::take(&mut s.orphans)).await.pop().unwrap();
        sims.resume(&id, "service restarted").await;
        let session = only(&sims);
        assert!(stranger.try_wait().unwrap().is_none(), "the unrelated process was signalled");
        assert!(matches!(&session.phase, Phase::Failed { error, .. } if error.contains("left alone")));
        // A pre-upgrade record owes no close; the release is owed and runs.
        assert_eq!((fake.closes(), fake.count("release SIM1")), (0, 1));
        assert!(session.settled());
        stranger.kill().unwrap();
        stranger.wait().unwrap();
    }

    /// A failed or cancelled start kills its recorder and still closes T3's
    /// device session and releases the simulator.
    #[tokio::test]
    async fn failed_or_cancelled_start_rolls_back() {
        let dir = tempfile::tempdir().unwrap();
        let (sims, fake) = sims(dir.path(), Some(Err(())));
        assert!(sims.start(THREAD, None).await.is_err());
        let session = only(&sims);
        assert_eq!((state(&session).as_str(), session.settled()), ("failed", true));
        assert_eq!((fake.closes(), fake.count("release SIM1")), (1, 1));

        *fake.boot.lock().unwrap() = None;
        assert!(tokio::time::timeout(Duration::from_millis(100), sims.start(THREAD, None)).await.is_err());
        settled(&sims).await;
        let session = only(&sims);
        assert!(session.reserves() && matches!(&session.phase, Phase::Failed { error, .. } if error.contains("cancelled")));
        sims.tick().await;
        assert!(only(&sims).settled());
        assert_eq!((fake.closes(), fake.count("release SIM1")), (2, 2));
    }

    /// The recording is filed even when T3 is unreachable; the close is owed
    /// (and the slot held, Q4) until T3 answers or shows it gone; a failed
    /// release is owed too, never cleared.
    #[tokio::test]
    async fn failed_cleanup_is_retried_and_holds_the_slot() {
        let dir = tempfile::tempdir().unwrap();
        let (sims, fake) = sims(dir.path(), Some(Ok(())));
        sims.start(THREAD, None).await.unwrap();
        fake.close_fails.store(true, SeqCst);
        fake.lists_open.store(true, SeqCst);
        let session = sims.stop(Some(THREAD), None).await.unwrap().session;
        assert_eq!(session.state, "finished");
        assert!(matches!(&session.device_session, Some(DeviceLease::CloseOwed(crate::fsm::sims::RetryState { error: Some(_), .. }))));
        assert_eq!(media::list(dir.path(), THREAD).unwrap().len(), 1);
        // The blocked close keeps the slot: the next thread waits.
        assert_eq!(sims.start(B, None).await.unwrap()["status"], "queued");

        fake.close_fails.store(false, SeqCst);
        fake.release_fails.store(true, SeqCst);
        sims.tick().await;
        assert!(only_of(&sims, THREAD).device.owed(), "retried before its backoff");
        due_now(&sims).await;
        sims.tick().await;
        let s = only_of(&sims, THREAD);
        assert!(!s.device.owed() && s.release_owed() && s.reserves(), "a failed release was cleared");
        assert_eq!(queue(&sims), [(B.into(), false)]);
        fake.release_fails.store(false, SeqCst);
        due_now(&sims).await;
        sims.tick().await;
        assert!(only_of(&sims, THREAD).settled());
        assert_eq!(queue(&sims), [(B.into(), true)]);
        // Saved: a restart owes nothing.
        let (reopened, _) = super::tests::sims(dir.path(), Some(Ok(())));
        assert!(reopened.owner.ask(|s| s.orphans.is_empty()).await && only_of(&reopened, THREAD).settled());
    }

    /// A close whose answer is lost is settled by T3 no longer listing the session.
    #[tokio::test]
    async fn a_lost_close_is_settled_by_t3s_list() {
        let dir = tempfile::tempdir().unwrap();
        let (sims, fake) = sims(dir.path(), Some(Ok(())));
        sims.start(B, Some("SIM2")).await.unwrap();
        fake.close_fails.store(true, SeqCst);
        fake.lists_open.store(true, SeqCst);
        // T3 lists (THREAD, SIM1) and (B, SIM1); B's session is on SIM2.
        let session = sims.stop(Some(B), None).await.unwrap().session;
        assert_eq!(session.device_session, Some(DeviceLease::Closed));
        assert!(!session.release_pending);
    }

    /// Shutdown ends recordings, files them, closes the device session and refuses new starts.
    #[tokio::test]
    async fn shutdown_files_and_refuses_starts() {
        let dir = tempfile::tempdir().unwrap();
        let (sims, fake) = sims(dir.path(), Some(Ok(())));
        sims.start(THREAD, None).await.unwrap();
        sims.shutdown(Exit::Stop).await;
        let session = only(&sims);
        assert_eq!((state(&session).as_str(), session.settled()), ("finished", true));
        assert_eq!(fake.closes(), 1);
        assert!(sims.start(THREAD, None).await.is_err());
        assert!(sims.owner.ask(|s| s.recorders.is_empty()).await);
    }

    /// A restart hands a recording over: its recorder keeps running and T3's
    /// device session stays open; the next run adopts it (no "service
    /// restarted" stop), watches it, and a later stop files the whole movie.
    /// One whose recorder died meanwhile is finished instead.
    #[tokio::test]
    async fn handover_keeps_recording_into_the_next_run() {
        let dir = tempfile::tempdir().unwrap();
        let (sims, fake) = sims(dir.path(), Some(Ok(())));
        fake.max.store(2, SeqCst);
        sims.start(THREAD, None).await.unwrap();
        sims.start(B, Some("SIM2")).await.unwrap();
        let (ids, recorders): (Vec<String>, Vec<RecorderID>) = sims.ledger().sessions.iter()
            .map(|s| (s.id.clone(), s.recorder().unwrap())).unzip();
        assert!(recorders.iter().all(|r| r.start.is_some()));
        sims.shutdown(Exit::Handover).await;
        assert!(sims.start(THREAD, None).await.is_err(), "started while handing over");
        assert_eq!((fake.closes(), fake.count("release SIM1")), (0, 0));
        assert!(sims.ledger().sessions.iter().all(|s| s.active() && s.device == DeviceLease::Open));
        drop(sims);
        assert!(recorders.iter().all(|r| alive(r.pid)), "a recorder stopped with the old run");
        // The second session's recorder dies between the runs.
        unsafe { libc::kill(recorders[1].pid as i32, libc::SIGKILL) };
        while is_recorder(recorders[1], &ids[1]) {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }

        let reopened = Sims::with_host(dir.path(), fake.clone()).unwrap();
        let orphans = reopened.owner.ask(|s| s.orphans.clone()).await;
        assert_eq!(orphans, [ids[1].clone()]);
        // Watched again: only the one whose recorder died is due to end.
        assert_eq!(reopened.due().await, [(ids[1].clone(), "recorder stopped")]);
        let receipt = reopened.stop(Some(THREAD), None).await.unwrap();
        assert!(matches!(only_of(&reopened, THREAD).phase, Phase::Finished { ref reason, .. } if reason == "stopped"));
        assert!(receipt.media_id.is_some());
        assert_eq!(std::fs::read(&media::list(dir.path(), THREAD).unwrap()[0].file).unwrap(), b"movie");
        assert_eq!(fake.closes(), 1);
    }

    /// The upgrade: a ledger from before cleanup receipts, with a live
    /// recording handed over (its recorder saved by PID only) and a line with
    /// a woken grant, opens with its original kept beside it; the recording
    /// is adopted and given its recorder's start time, the line and grant
    /// survive, and nobody is woken twice.
    #[tokio::test]
    async fn an_earlier_ledger_is_migrated_with_its_sessions_and_line() {
        let dir = tempfile::tempdir().unwrap();
        let id = uuid::Uuid::new_v4().to_string();
        std::fs::create_dir_all(dir.path().join("media")).unwrap();
        let path = media::recording_path(dir.path(), THREAD, &id).unwrap();
        let mut recorder = Command::new("/bin/sh")
            .args(["-c", "trap 'printf movie > \"$1\"; exit 0' INT; while :; do sleep 0.05; done", "sh"]).arg(&path).spawn().unwrap();
        let pid = recorder.id().unwrap();
        let ledger = json!({
            "sessions": [
                {"id": id, "thread_id": THREAD, "host_id": "local", "device_id": "SIM1", "device_name": "iPhone", "started_at": now(),
                 "ended_at": null, "state": "recording", "media_id": null, "stop_reason": null, "error": null, "recorder_pid": pid,
                 "device_session": {"phase": "open"}, "release_pending": false},
                {"id": "old", "thread_id": C, "host_id": "local", "device_id": "SIM2", "device_name": "iPad", "started_at": 1.0,
                 "ended_at": 2.0, "state": "finished", "media_id": "m", "stop_reason": "stopped", "error": null, "recorder_pid": null,
                 "device_session": {"phase": "closed"}, "release_pending": true}],
            "queue": [{"id": "w1", "thread_id": B, "queued_at": 1.0, "grant": {"at": 2.0, "turn": "t1", "woken": true}}]});
        std::fs::write(dir.path().join("sims.json"), ledger.to_string()).unwrap();
        let fake = Arc::new(Fake { boot: Mutex::new(Some(Ok(()))), ..Fake::default() });
        fake.max.store(3, SeqCst);
        let sims = Sims::with_host(dir.path(), fake.clone()).unwrap();

        let original: Value = serde_json::from_slice(&std::fs::read(dir.path().join("sims.schema1.json")).unwrap()).unwrap();
        assert_eq!(original, ledger);
        let saved: Value = serde_json::from_slice(&std::fs::read(dir.path().join("sims.json")).unwrap()).unwrap();
        assert_eq!((saved["schema"].as_u64(), saved["queue"][0]["grant"]["wake"].as_str()), (Some(2), Some("queued")));
        let live = only_of(&sims, THREAD);
        assert!(live.active() && live.recorder().unwrap().start.is_some() && sims.owner.ask(|s| s.orphans.is_empty()).await);
        // The pre-upgrade release is still owed and runs; the grant is not woken again.
        sims.tick().await;
        assert_eq!((fake.count("release SIM2"), fake.woken.lock().unwrap().len()), (1, 0));
        assert_eq!(queue(&sims), [(B.into(), true)]);
        // The handed-over recording still files as a whole movie.
        let receipt = sims.stop(Some(THREAD), None).await.unwrap();
        assert!(receipt.media_id.is_some());
        let _ = recorder.wait().await;
    }

    /// A session's end shuts its simulator down once T3's device session is
    /// closed; a start past the limit waits in line rather than booting another.
    #[tokio::test]
    async fn ended_session_releases_its_simulator_and_the_limit_holds() {
        let dir = tempfile::tempdir().unwrap();
        let (sims, fake) = sims(dir.path(), Some(Ok(())));
        sims.start(THREAD, None).await.unwrap();
        assert_eq!(sims.start(B, None).await.unwrap()["status"], "queued");
        assert_eq!(fake.count("device.open"), 1);
        sims.stop(Some(THREAD), None).await.unwrap();
        assert_eq!(fake.count("release SIM1"), 1);
        assert!(only_of(&sims, THREAD).settled());
        sims.tick().await;
        assert_eq!(fake.count("release SIM1"), 1, "released twice");
    }

    /// Past the limit, starts wait first come first served: a freed slot is
    /// held for the head (a later thread can't take it) and the head is woken
    /// once, even across a restart; its next start takes the slot.
    #[tokio::test]
    async fn full_starts_wait_in_line_and_the_head_is_woken() {
        let dir = tempfile::tempdir().unwrap();
        let (sims, fake) = sims(dir.path(), Some(Ok(())));
        sims.start(THREAD, None).await.unwrap();
        assert_eq!(sims.start(B, None).await.unwrap()["position"], 1);
        assert_eq!(sims.start(C, None).await.unwrap()["position"], 2);
        // Asking again keeps the place.
        assert_eq!(sims.start(B, None).await.unwrap()["position"], 1);
        assert_eq!(*fake.waiting.lock().unwrap(), [B, C]);

        sims.stop(Some(THREAD), None).await.unwrap();
        sims.tick().await;
        assert_eq!(queue(&sims), [(B.into(), true), (C.into(), false)]);
        assert_eq!(fake.woken.lock().unwrap().iter().map(|w| w.0.as_str()).collect::<Vec<_>>(), [B]);
        // The held slot isn't anyone else's, newcomer or next in line.
        assert_eq!(sims.start(D, None).await.unwrap()["position"], 2);
        assert_eq!(sims.start(C, None).await.unwrap()["status"], "queued");

        // A restart neither loses the line nor wakes the head again.
        drop(sims);
        let reopened = Sims::with_host(dir.path(), fake.clone()).unwrap();
        reopened.tick().await;
        assert_eq!(fake.woken.lock().unwrap().len(), 1);
        assert_eq!(queue(&reopened), [(B.into(), true), (C.into(), false), (D.into(), false)]);

        reopened.start(B, None).await.unwrap();
        assert_eq!(queue(&reopened), [(C.into(), false), (D.into(), false)]);
        assert_eq!(*fake.waiting.lock().unwrap(), [C, D]);
        reopened.stop(Some(B), None).await.unwrap();
    }

    /// A grant whose save fails is neither seen nor woken; once the ledger
    /// can be saved, the grant is saved and then woken, once.
    #[tokio::test]
    async fn no_wake_before_its_grant_is_saved() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let (sims, fake) = sims(dir.path(), Some(Ok(())));
        sims.start(THREAD, None).await.unwrap();
        assert_eq!(sims.start(B, None).await.unwrap()["status"], "queued");
        sims.stop(Some(THREAD), None).await.unwrap();
        std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o500)).unwrap();
        sims.tick().await;
        std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!((queue(&sims), fake.woken.lock().unwrap().len()), (vec![(B.into(), false)], 0));
        sims.tick().await;
        assert_eq!((queue(&sims), fake.woken.lock().unwrap().len()), (vec![(B.into(), true)], 1));
        let saved: Value = serde_json::from_slice(&std::fs::read(dir.path().join("sims.json")).unwrap()).unwrap();
        assert_eq!(saved["queue"][0]["grant"]["wake"], "queued");
    }

    /// A place is given up by leaving, when T3 no longer has the thread, or
    /// when the woken turn ends without taking the slot; not while the turn
    /// that queued is still finishing, nor on unknown state.
    #[tokio::test]
    async fn places_are_given_up_only_when_unwanted() {
        let dir = tempfile::tempdir().unwrap();
        let (sims, fake) = sims(dir.path(), Some(Ok(())));
        sims.start(THREAD, None).await.unwrap();
        for thread in [B, C, D] {
            fake.set(thread, busy("t1"));
            sims.start(thread, None).await.unwrap();
        }
        assert!(sims.leave(C).await.unwrap());
        fake.set(D, Seen::Gone);
        sims.tick().await;
        assert_eq!(queue(&sims), [(B.into(), false)]);

        sims.stop(Some(THREAD), None).await.unwrap();
        sims.tick().await;
        assert_eq!(queue(&sims), [(B.into(), true)]);
        // The turn that queued ends: it isn't the woken turn, so the slot stays held.
        fake.set(B, idle("t1"));
        sims.tick().await;
        fake.set(B, Seen::Unknown { turn: Some("t2".into()) });
        sims.tick().await;
        assert_eq!(queue(&sims), [(B.into(), true)]);
        // The woken turn ends without taking it: the place goes.
        fake.set(B, idle("t2"));
        sims.tick().await;
        assert!(queue(&sims).is_empty());
    }

    /// Only T3 confirming the turn over ends a session; while T3's state is
    /// unknown, or the thread waits on the user, the session keeps running,
    /// and uncertain time never counts toward the grace.
    #[tokio::test]
    async fn unknown_or_waiting_thread_state_never_ends_a_session() {
        let dir = tempfile::tempdir().unwrap();
        let (sims, fake) = sims(dir.path(), Some(Ok(())));
        sims.start(THREAD, None).await.unwrap();
        *fake.seen.lock().unwrap() = Some(idle("t"));
        assert!(sims.due().await.is_empty(), "ended before its grace");
        sims.owner.ask(|s| s.clocks.values_mut().for_each(|c| c.since = Some(0.0))).await;
        for seen in [Seen::Unknown { turn: None }, Seen::Waiting { turn: None }] {
            *fake.seen.lock().unwrap() = Some(seen);
            assert!(sims.due().await.is_empty(), "ended on an unknown or waiting state");
        }
        *fake.seen.lock().unwrap() = Some(idle("t"));
        assert!(sims.due().await.is_empty(), "uncertain time counted as idle");
        sims.owner.ask(|s| s.clocks.values_mut().for_each(|c| c.since = Some(0.0))).await;
        assert_eq!(sims.due().await.into_iter().map(|d| d.1).collect::<Vec<_>>(), ["turn ended"]);
        sims.stop(Some(THREAD), None).await.unwrap();
    }
}
