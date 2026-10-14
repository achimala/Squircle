//! Simulator sessions an agent runs through Squircle (`squircle sim`). Starting
//! one opens the simulator for the agent's T3 thread (T3's own `device.open`,
//! so the phone streams it), boots it and records its screen. Stopping it,
//! or the agent's turn ending, finishes the recording and adds it to the
//! thread's media, dated where the session began, then closes the T3 device
//! session. The phone shows active sessions as a live picture-in-picture and
//! in the turn, and the recording there afterwards.

use crate::agents::{Agents, worker_state};
use crate::media::{self, SimulatorClip};
use crate::t3::T3;
use crate::store::{atomic_json, read_json};
use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
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

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SimSession {
    pub id: String,
    pub thread_id: String,
    pub host_id: String,
    pub device_id: String,
    pub device_name: String,
    /// Seconds since 1970, fractional.
    pub started_at: f64,
    #[serde(default)]
    pub ended_at: Option<f64>,
    /// "recording", "finished" or "failed".
    pub state: String,
    #[serde(default)]
    pub media_id: Option<String>,
    #[serde(default)]
    pub stop_reason: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub recorder_pid: Option<u32>,
}

impl SimSession {
    fn active(&self) -> bool {
        self.state == "recording"
    }
}

#[derive(Default, Serialize, Deserialize)]
struct Ledger {
    #[serde(default)]
    sessions: Vec<SimSession>,
}

#[derive(Default)]
struct State {
    ledger: Ledger,
    recorders: HashMap<String, Child>,
    /// When each session's thread was first seen not working.
    idle_since: HashMap<String, f64>,
}

pub struct Sims {
    root: PathBuf,
    agents: Arc<Agents>,
    state: Mutex<State>,
    /// Starts and stops run one at a time.
    ops: tokio::sync::Mutex<()>,
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
    let small = raw.with_extension("compact.mp4");
    let converted = tokio::time::timeout(Duration::from_secs(180), Command::new("/usr/bin/avconvert")
        .args(["--preset", "Preset1280x720", "--replace", "--source"]).arg(raw).arg("--output").arg(&small)
        .stdout(Stdio::null()).stderr(Stdio::null()).status()).await;
    if matches!(converted, Ok(Ok(status)) if status.success()) && small.metadata().is_ok_and(|m| m.len() > 0) {
        let _ = std::fs::remove_file(raw);
        Some(small)
    } else {
        let _ = std::fs::remove_file(&small);
        None
    }
}

fn alive(pid: u32) -> bool {
    unsafe { libc::kill(pid as i32, 0) == 0 }
}

impl Sims {
    pub fn open(root: &Path, agents: Arc<Agents>) -> Result<Arc<Self>> {
        let path = root.join("sims.json");
        let ledger: Ledger = if path.try_exists()? { read_json(&path)? } else { Ledger::default() };
        Ok(Arc::new(Self {
            root: root.to_path_buf(),
            agents,
            state: Mutex::new(State { ledger, ..State::default() }),
            ops: tokio::sync::Mutex::new(()),
        }))
    }

    fn save(&self, state: &State) -> Result<()> {
        atomic_json(&self.root.join("sims.json"), &state.ledger)
    }

    fn session(&self, id: &str) -> Option<SimSession> {
        self.state.lock().unwrap().ledger.sessions.iter().find(|s| s.id == id).cloned()
    }

    fn update(&self, id: &str, change: impl FnOnce(&mut SimSession)) -> Result<SimSession> {
        let mut state = self.state.lock().unwrap();
        let session = state.ledger.sessions.iter_mut().find(|s| s.id == id).context("No such simulator session")?;
        change(session);
        let session = session.clone();
        self.save(&state)?;
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

    pub async fn start(&self, thread: &str, device: Option<&str>) -> Result<Value> {
        let _op = self.ops.lock().await;
        ensure!(media::valid_thread(thread) && uuid::Uuid::parse_str(thread).is_ok(), "Thread ID must be a T3 thread UUID");
        let client = self.agents.connection().await?;
        ensure!(self.agents.thread_row(thread).is_some(), "T3 has no thread {thread}");
        let inventory = inventory(&client).await?;
        let simulators = local_simulators(&inventory);
        ensure!(!simulators.is_empty(), "{}", no_simulators(&inventory));

        let active: Vec<SimSession> = self.state.lock().unwrap().ledger.sessions.iter().filter(|s| s.active()).cloned().collect();
        let chosen = match device {
            Some(wanted) => simulators.iter().find(|d| d["id"].as_str().is_some_and(|id| id.eq_ignore_ascii_case(wanted))
                    || d["name"].as_str().is_some_and(|n| n.eq_ignore_ascii_case(wanted)))
                .with_context(|| format!("No iOS simulator {wanted} on this Mac; run squircle sim devices"))?,
            None => {
                let last = self.state.lock().unwrap().ledger.sessions.iter().rev()
                    .find(|s| s.thread_id == thread).map(|s| s.device_id.clone());
                let busy = |d: &&&Value| active.iter().any(|s| Some(s.device_id.as_str()) == d["id"].as_str() && s.thread_id != thread);
                simulators.iter().find(|d| last.as_deref() == d["id"].as_str() && !busy(d))
                    .or_else(|| simulators.iter().find(|d| d["booted"] == true && !busy(d)))
                    .or_else(|| simulators.iter().find(|d| !busy(d)))
                    .context("Every simulator on this Mac is in another agent's session; pass --device")?
            }
        };
        let device_id = chosen["id"].as_str().context("Simulator without an ID")?.to_string();
        let device_name = chosen["name"].as_str().unwrap_or("Simulator").to_string();
        let host_id = "local".to_string();

        // Already running here: the same session. On another simulator: end that one first.
        if let Some(existing) = active.iter().find(|s| s.thread_id == thread) {
            if existing.device_id == device_id {
                return Ok(self.started(existing, "This thread's simulator session is already running."));
            }
            self.finish(&existing.id, "replaced").await;
        }
        if let Some(other) = active.iter().find(|s| s.device_id == device_id && s.thread_id != thread) {
            bail!("{device_name} is in use by thread {}; pick another with --device (squircle sim devices)", other.thread_id);
        }

        client.call("device.open", json!({"threadId": thread, "hostId": host_id, "deviceId": device_id, "platform": "ios", "boot": true})).await
            .context("T3 could not open the simulator")?;
        let booted = tokio::time::timeout(Duration::from_secs(180),
            Command::new("xcrun").args(["simctl", "bootstatus", &device_id, "-b"]).stdout(Stdio::null()).stderr(Stdio::null()).status()).await;
        ensure!(matches!(booted, Ok(Ok(status)) if status.success()), "{device_name} did not finish booting");

        let id = uuid::Uuid::new_v4().to_string();
        let path = media::recording_path(&self.root, thread, &id)?;
        let log = std::fs::File::create(path.with_extension("log"))?;
        let mut recorder = Command::new("xcrun")
            .args(["simctl", "io", &device_id, "recordVideo", "--codec=h264", "--force"])
            .arg(&path)
            .stdin(Stdio::null()).stdout(Stdio::null()).stderr(log)
            .kill_on_drop(false)
            .spawn().context("Cannot start simctl recordVideo")?;
        tokio::time::sleep(Duration::from_millis(1200)).await;
        if let Some(status) = recorder.try_wait()? {
            let detail = std::fs::read_to_string(path.with_extension("log")).unwrap_or_default();
            bail!("Recording {device_name} failed ({status}): {}", detail.trim());
        }
        let session = SimSession {
            id: id.clone(), thread_id: thread.into(), host_id, device_id, device_name,
            started_at: now(), ended_at: None, state: "recording".into(), media_id: None,
            stop_reason: None, error: None, recorder_pid: recorder.id(),
        };
        {
            let mut state = self.state.lock().unwrap();
            state.recorders.insert(id.clone(), recorder);
            state.ledger.sessions.push(session.clone());
            let excess = state.ledger.sessions.len().saturating_sub(KEEP);
            state.ledger.sessions.drain(..excess);
            self.save(&state)?;
        }
        Ok(self.started(&session, "Recording. The user watches it live on their phone."))
    }

    fn started(&self, session: &SimSession, status: &str) -> Value {
        let cli = self.agents.cli();
        json!({
            "session": session,
            "status": status,
            "agent_device": agent_device(&session.thread_id, &session.host_id, &session.device_id),
            "next": format!("Drive it with agent_device.command plus agent_device.target_args (or T3's device_screenshot to look). \
                When you are done with the simulator, run {cli} sim stop --thread {}; the recording then appears in this turn. \
                If you forget, it stops when your turn ends.", session.thread_id),
        })
    }

    // MARK: Stop

    /// Stops a thread's session (or one by ID) and files its recording.
    pub async fn stop(&self, thread: Option<&str>, id: Option<&str>) -> Result<SimSession> {
        let _op = self.ops.lock().await;
        let session = {
            let state = self.state.lock().unwrap();
            state.ledger.sessions.iter().rev()
                .find(|s| s.active() && (id.is_some_and(|i| s.id == i) || (id.is_none() && thread.is_some_and(|t| s.thread_id == t))))
                .cloned()
        };
        let Some(session) = session else {
            bail!("No simulator session is running{}", thread.map(|t| format!(" for thread {t}")).unwrap_or_default());
        };
        self.finish(&session.id, "stopped").await.context("The session disappeared")
    }

    /// Ends the recording, moves it into the thread's media and closes T3's
    /// device session. Never fails: problems are recorded on the session.
    async fn finish(&self, id: &str, reason: &str) -> Option<SimSession> {
        let session = self.session(id)?;
        if !session.active() {
            return Some(session);
        }
        let recorder = self.state.lock().unwrap().recorders.remove(id);
        let pid = recorder.as_ref().and_then(|c| c.id()).or(session.recorder_pid);
        if let Some(pid) = pid.filter(|p| alive(*p)) {
            // simctl writes the movie's index when interrupted.
            unsafe { libc::kill(pid as i32, libc::SIGINT) };
        }
        if let Some(mut child) = recorder {
            if tokio::time::timeout(Duration::from_secs(20), child.wait()).await.is_err() {
                let _ = child.kill().await;
            }
        } else if let Some(pid) = pid {
            for _ in 0..40 {
                if !alive(pid) { break }
                tokio::time::sleep(Duration::from_millis(500)).await;
            }
        }
        let ended = now();
        let path = media::recording_path(&self.root, &session.thread_id, id).ok();
        let _ = path.as_ref().map(|p| std::fs::remove_file(p.with_extension("log")));
        let path = match path.filter(|p| p.metadata().is_ok_and(|m| m.len() > 0)) {
            Some(raw) => Some(compact(&raw).await.unwrap_or(raw)),
            None => None,
        };
        let filed = path.map(|p| {
            media::add_recording(&self.root, &session.thread_id, &p, SimulatorClip {
                session_id: id.into(), device_id: session.device_id.clone(), device_name: session.device_name.clone(),
                started_at: session.started_at, ended_at: ended,
            })
        });
        if let Ok(client) = self.agents.connection().await {
            let _ = client.call("device.close", json!({"threadId": session.thread_id, "hostId": session.host_id,
                "deviceId": session.device_id, "platform": "ios"})).await;
        }
        let result = self.update(id, |s| {
            s.ended_at = Some(ended);
            s.stop_reason = Some(reason.into());
            s.recorder_pid = None;
            match &filed {
                Some(Ok(media)) => { s.state = "finished".into(); s.media_id = Some(media.id.clone()); }
                Some(Err(error)) => { s.state = "failed".into(); s.error = Some(format!("{error:#}")); }
                None => { s.state = "failed".into(); s.error = Some("simctl wrote no video".into()); }
            }
        });
        self.state.lock().unwrap().idle_since.remove(id);
        Some(result.unwrap_or(session))
    }

    /// This Mac's iOS simulators, and which thread (if any) is using each.
    pub async fn devices(&self) -> Result<Value> {
        let client = self.agents.connection().await?;
        let inventory = inventory(&client).await?;
        let simulators = local_simulators(&inventory);
        ensure!(!simulators.is_empty(), "{}", no_simulators(&inventory));
        let active: Vec<SimSession> = self.state.lock().unwrap().ledger.sessions.iter().filter(|s| s.active()).cloned().collect();
        let devices: Vec<Value> = simulators.into_iter()
            .map(|d| {
                let session = active.iter().find(|s| Some(s.device_id.as_str()) == d["id"].as_str());
                json!({"id": d["id"], "name": d["name"], "version": d["version"], "booted": d["booted"],
                       "recording_for_thread": session.map(|s| s.thread_id.clone())})
            }).collect();
        Ok(json!({"devices": devices}))
    }

    // MARK: Watching

    /// Ends sessions whose turn has stopped, whose recorder died, or that ran
    /// too long. Sessions left recording by a previous run are finished first.
    pub async fn run(self: Arc<Self>) {
        let orphans: Vec<String> = self.state.lock().unwrap().ledger.sessions.iter().filter(|s| s.active()).map(|s| s.id.clone()).collect();
        for id in orphans {
            let _op = self.ops.lock().await;
            self.finish(&id, "service restarted").await;
        }
        loop {
            tokio::time::sleep(Duration::from_secs(3)).await;
            for (id, reason) in self.due() {
                let _op = self.ops.lock().await;
                self.finish(&id, reason).await;
            }
        }
    }

    fn due(&self) -> Vec<(String, &'static str)> {
        let time = now();
        let mut state = self.state.lock().unwrap();
        let active: Vec<SimSession> = state.ledger.sessions.iter().filter(|s| s.active()).cloned().collect();
        let mut due = Vec::new();
        for session in active {
            let exited = state.recorders.get_mut(&session.id).is_none_or(|c| !matches!(c.try_wait(), Ok(None)));
            let working = self.agents.thread_row(&session.thread_id).is_some_and(|t| worker_state(&t) == "working");
            if working {
                state.idle_since.remove(&session.id);
            }
            let idle = *state.idle_since.entry(session.id.clone()).or_insert(time);
            if exited {
                due.push((session.id, "recorder stopped"));
            } else if time - session.started_at > MAX_SECONDS {
                due.push((session.id, "time limit"));
            } else if !working && time - idle >= IDLE_GRACE {
                due.push((session.id, "turn ended"));
            }
        }
        due
    }
}

/// T3's device state after it re-lists every host. Its `subscribeDeviceState`
/// snapshot is only a cache that starts empty when T3 starts and fills only
/// when some client asks for a list, so read it through `device.list`.
async fn inventory(client: &T3) -> Result<Value> {
    client.call("device.list", json!({})).await.context("T3 could not list its simulators")
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
}
