//! Which booted simulators on this Mac are Squircle's to shut down, and
//! which simulator devices are its to delete.
//!
//! A simulator is ours when Squircle leased it (`squircle sim start`) or an
//! agent's own command created, booted, installed on or built for it (T3's
//! activity log, read read-only). Anything else is the user's and is never
//! touched. A booted simulator of ours is left alone while a lease holds it,
//! while a T3 device session of a working thread or of a thread that isn't
//! Squircle's (the user's Device panel) is on it, or while the agent that
//! booted it outside a lease is still working; otherwise it is shut down
//! once it has been free for the idle time (at once when a lease ends, or
//! on `squircle sim cleanup`). A device an agent created is deleted once
//! nothing has used it for a day.
//!
//! `plan` is the whole policy, from plain facts; `Pool` gathers them and
//! applies its decisions.

use crate::sims::Pending;
use crate::store::{atomic_json, read_json};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    process::Stdio,
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::process::Command;

/// An outside-a-lease use by an agent protects the simulator only this long
/// after the command, and only while that agent is working.
const TOUCH_WINDOW: f64 = 3.0 * 3600.0;

#[derive(Clone, Copy, Debug)]
pub struct Policy {
    /// Concurrent leased simulators (`SQUIRCLE_MAX_SIMULATORS`, default 3).
    pub max_leases: usize,
    /// Seconds a free simulator of ours stays booted (`SQUIRCLE_SIM_IDLE_MINUTES`, default 10).
    pub idle: f64,
    /// Seconds unused before a device an agent created is deleted.
    pub delete_after: f64,
}

impl Policy {
    pub fn from_env() -> Self {
        let number = |name: &str| std::env::var(name).ok().and_then(|v| v.trim().parse::<f64>().ok()).filter(|v| *v >= 0.0);
        Self {
            max_leases: number("SQUIRCLE_MAX_SIMULATORS").map_or(3, |v| (v as usize).max(1)),
            idle: number("SQUIRCLE_SIM_IDLE_MINUTES").map_or(600.0, |m| m * 60.0),
            delete_after: 24.0 * 3600.0,
        }
    }
}

/// One simulator device, as simctl lists it.
#[derive(Clone, Debug)]
pub struct Device {
    pub udid: String,
    pub name: String,
    /// simctl's state: "Booted", "Shutdown", "Booting", ...
    pub state: String,
    /// When CoreSimulator last wrote its device.plist (boot and shutdown do).
    pub changed_at: f64,
}

#[derive(Clone, Debug)]
pub struct Lease {
    pub device_id: String,
    pub thread_id: String,
}

/// What Squircle knows of a device's history, kept in `simpool.json` (the
/// session ledger and T3's activity log are trimmed or slow to rescan).
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Provenance {
    #[serde(default)]
    pub leased: bool,
    /// The thread whose command created it.
    #[serde(default)]
    pub created_by: Option<String>,
    /// The latest thread that used it outside a lease, and when.
    #[serde(default)]
    pub touched_by: Option<String>,
    #[serde(default)]
    pub touched_at: f64,
    /// The latest of any of the above.
    #[serde(default)]
    pub last_used: f64,
}

impl Provenance {
    fn ours(&self) -> bool {
        self.leased || self.created_by.is_some() || self.touched_by.is_some()
    }
}

#[derive(Clone, Copy, Debug)]
pub struct ThreadInfo {
    pub working: bool,
    /// An app agent or worker Squircle started.
    pub squircle: bool,
    pub archived: bool,
}

pub struct Facts<'a> {
    pub now: f64,
    pub devices: &'a [Device],
    pub leases: &'a [Lease],
    /// Open T3 device sessions: (thread, device).
    pub t3_sessions: &'a [(String, String)],
    pub known: &'a HashMap<String, Provenance>,
    /// None: T3 has no such thread.
    pub thread: &'a dyn Fn(&str) -> Option<ThreadInfo>,
    /// When each simulator was first seen booted and free.
    pub idle_since: &'a HashMap<String, f64>,
    /// Never touched (the preview capture's `SQUIRCLE_SIMULATOR_ID`).
    pub reserved: &'a [String],
    pub policy: Policy,
    /// `sim cleanup` and a lease ending: no idle wait.
    pub now_please: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    Shutdown,
    Delete,
}

#[derive(Clone, Debug, Serialize)]
pub struct Row {
    pub udid: String,
    pub name: String,
    pub booted: bool,
    /// "lease", "t3 session", "agent outside a lease", "agent (idle)",
    /// "unowned" (not Squircle's) or "reserved".
    pub owner: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thread: Option<String>,
    pub ours: bool,
    /// Booted, ours and held by nothing: a start can take it.
    pub free: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub action: Option<Action>,
    pub why: String,
}

/// The policy: one row per booted simulator, plus devices to delete.
pub fn plan(facts: &Facts) -> Vec<Row> {
    let mut rows = Vec::new();
    for device in facts.devices {
        let known = facts.known.get(&device.udid).cloned().unwrap_or_default();
        let ours = known.ours();
        let row = |owner, thread: Option<&str>, free, action, why: String| Row {
            udid: device.udid.clone(), name: device.name.clone(), booted: device.state == "Booted",
            owner, thread: thread.map(str::to_string), ours, free, action, why,
        };
        let lease = facts.leases.iter().find(|l| l.device_id == device.udid);
        // A T3 session protects while its thread works, and always when the
        // thread is the user's own (not one Squircle started).
        let session = facts.t3_sessions.iter().filter(|(_, d)| *d == device.udid).find(|(thread, _)| {
            (facts.thread)(thread).is_some_and(|t| !t.archived && (t.working || !t.squircle))
        });
        let toucher = [known.touched_by.as_deref().filter(|_| facts.now - known.touched_at < TOUCH_WINDOW), known.created_by.as_deref()]
            .into_iter().flatten()
            .find(|t| (facts.thread)(t).is_some_and(|t| t.working && !t.archived));

        if device.state != "Booted" {
            let unused = facts.now - known.last_used.max(device.changed_at);
            let deletable = device.state == "Shutdown" && known.created_by.is_some() && lease.is_none()
                && !facts.reserved.contains(&device.udid) && !facts.t3_sessions.iter().any(|(_, d)| *d == device.udid)
                && toucher.is_none() && unused >= facts.policy.delete_after;
            if deletable {
                rows.push(row("agent (idle)", known.created_by.as_deref(), false, Some(Action::Delete),
                    format!("an agent created it; unused for {}", span(unused))));
            }
            continue;
        }
        let r = if let Some(lease) = lease {
            row("lease", Some(&lease.thread_id), false, None, "leased through squircle sim start".into())
        } else if facts.reserved.contains(&device.udid) {
            row("reserved", None, false, None, "the preview capture's simulator".into())
        } else if let Some((thread, _)) = session {
            row("t3 session", Some(thread), false, None, "open in T3's device tools".into())
        } else if !ours {
            row("unowned", None, false, None, "not booted or used by Squircle or its agents; left alone".into())
        } else if let Some(thread) = toucher {
            row("agent outside a lease", Some(thread), false, None, "booted by an agent that is still working".into())
        } else {
            let since = facts.idle_since.get(&device.udid).copied().unwrap_or(facts.now);
            let idle = facts.now - since;
            let due = facts.now_please || idle >= facts.policy.idle;
            let thread = known.touched_by.as_deref().or(known.created_by.as_deref());
            row("agent (idle)", thread, true, due.then_some(Action::Shutdown),
                if due { format!("Squircle's or an agent's, held by nothing (idle {})", span(idle)) }
                else { format!("free; shut down after {} idle", span(facts.policy.idle)) })
        };
        rows.push(r);
    }
    rows
}

fn span(seconds: f64) -> String {
    let minutes = (seconds / 60.0).round() as i64;
    match minutes {
        m if m < 1 => "under a minute".into(),
        m if m < 120 => format!("{m} min"),
        m if m < 48 * 60 => format!("{} h", m / 60),
        m => format!("{} days", m / 1440),
    }
}

// MARK: Agents' own simulator commands

/// What one command in T3's activity log did to simulators.
#[derive(Debug, Default, PartialEq)]
pub struct Use {
    pub created: Vec<String>,
    pub touched: Vec<String>,
    /// Names, resolved against the device list (only when unique).
    pub created_names: Vec<String>,
    pub touched_names: Vec<String>,
}

const UUID_LEN: usize = 36;

fn uuids(text: &str) -> Vec<String> {
    let bytes = text.as_bytes();
    let mut found = Vec::new();
    let mut i = 0;
    while i + UUID_LEN <= bytes.len() {
        let candidate = &bytes[i..i + UUID_LEN];
        let shaped = candidate.iter().enumerate().all(|(j, b)| match j {
            8 | 13 | 18 | 23 => *b == b'-',
            _ => b.is_ascii_hexdigit(),
        });
        let bounded = (i == 0 || !bytes[i - 1].is_ascii_alphanumeric())
            && bytes.get(i + UUID_LEN).is_none_or(|b| !b.is_ascii_alphanumeric());
        if shaped && bounded {
            found.push(String::from_utf8_lossy(candidate).to_ascii_uppercase());
            i += UUID_LEN;
        } else {
            i += 1;
        }
    }
    found
}

/// The first argument after `rest`'s flags: a quoted or bare word.
fn argument(rest: &str) -> Option<String> {
    let mut rest = rest.trim_start();
    while rest.starts_with('-') {
        rest = rest.split_once(char::is_whitespace).map_or("", |(_, r)| r).trim_start();
    }
    let word = match rest.chars().next()? {
        quote @ ('"' | '\'') => rest[1..].split(quote).next()?,
        _ => rest.split(|c: char| c.is_whitespace() || ";&|)".contains(c)).next()?,
    };
    (!word.is_empty() && !word.starts_with('$') && !word.contains('`')).then(|| word.to_string())
}

/// Parses a shell command an agent ran (and its output) for simulators it
/// created (`simctl create/clone`, whose output is the new UDID) and used
/// (`simctl boot/install/launch`, `xcodebuild -destination`).
pub fn parse_use(command: &str, output: &str) -> Use {
    let mut found = Use::default();
    let mut segments = command.split("simctl ");
    segments.next();
    for segment in segments {
        let segment = segment.split(['\n', ';', '|']).next().unwrap_or("").split("&&").next().unwrap_or("");
        let (verb, rest) = segment.trim_start().split_once(char::is_whitespace).unwrap_or((segment.trim(), ""));
        match verb {
            "create" | "clone" => {
                found.created.extend(uuids(output));
                let name = if verb == "clone" { argument(rest.trim_start().split_once(char::is_whitespace).map_or("", |(_, r)| r)) }
                           else { argument(rest) };
                found.created_names.extend(name.filter(|n| uuids(n).is_empty()));
            }
            "boot" | "install" | "launch" | "bootstatus" | "openurl" | "spawn" => {
                let ids = uuids(segment);
                if ids.is_empty() {
                    found.touched_names.extend(argument(rest).filter(|n| n != "booted"));
                }
                found.touched.extend(ids.into_iter().take(1));
            }
            _ => {}
        }
    }
    if command.contains("xcodebuild") {
        for destination in command.split("-destination").skip(1) {
            let spec = argument(destination).unwrap_or_default();
            for part in spec.split(',') {
                match part.split_once('=') {
                    Some(("id", id)) => found.touched.extend(uuids(id)),
                    Some(("name", name)) if spec.contains("Simulator") => found.touched_names.push(name.to_string()),
                    _ => {}
                }
            }
        }
    }
    found.created.sort();
    found.created.dedup();
    found.touched.retain(|t| !found.created.contains(t));
    found
}

// MARK: Applying it

#[derive(Clone, Debug)]
pub struct Activity {
    pub thread: String,
    pub created_at: String,
    pub command: String,
    pub output: String,
}

/// simctl and ps. Tests use a fake.
pub trait Simctl: Send + Sync {
    fn devices(&self) -> Pending<'_, Result<Vec<Device>>>;
    fn shutdown<'a>(&'a self, udid: &'a str) -> Pending<'a, Result<()>>;
    fn delete<'a>(&'a self, udid: &'a str) -> Pending<'a, Result<()>>;
    /// Each simulator's processes' summed CPU (%), by UDID.
    fn cpu(&self) -> HashMap<String, f64>;
}

/// T3, as far as the policy needs it. Tests use a fake.
pub trait World: Send + Sync {
    fn t3_sessions(&self) -> Pending<'_, Result<Vec<(String, String)>>>;
    fn thread(&self, id: &str) -> Option<ThreadInfo>;
    fn title(&self, id: &str) -> Option<String>;
    /// Simulator and xcodebuild commands agents ran after `since` (ISO time).
    fn activity<'a>(&'a self, since: &'a str) -> Pending<'a, Result<Vec<Activity>>>;
}

#[derive(Default, Serialize, Deserialize)]
struct Saved {
    #[serde(default)]
    known: HashMap<String, Provenance>,
    /// T3's activity log is read past this (its `created_at`).
    #[serde(default)]
    activity_seen: String,
}

#[derive(Default)]
struct State {
    saved: Saved,
    idle_since: HashMap<String, f64>,
    /// The last plan, for `free` and the cap's view.
    rows: Vec<Row>,
}

pub struct Pool {
    root: PathBuf,
    simctl: Arc<dyn Simctl>,
    world: Arc<dyn World>,
    pub policy: Policy,
    reserved: Vec<String>,
    state: Mutex<State>,
    /// One plan-and-apply at a time.
    applying: tokio::sync::Mutex<()>,
}

fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

impl Pool {
    pub fn open(root: &Path, agents: Arc<crate::agents::Agents>) -> Result<Arc<Self>> {
        let reserved = std::env::var("SQUIRCLE_SIMULATOR_ID").ok().map(|s| s.trim().to_ascii_uppercase()).into_iter().collect();
        Self::with(root, Arc::new(Xcrun), Arc::new(T3World(agents)), Policy::from_env(), reserved)
    }

    pub fn with(root: &Path, simctl: Arc<dyn Simctl>, world: Arc<dyn World>, policy: Policy, reserved: Vec<String>) -> Result<Arc<Self>> {
        let path = root.join("simpool.json");
        let saved: Saved = if path.try_exists()? { read_json(&path)? } else { Saved::default() };
        Ok(Arc::new(Self { root: root.into(), simctl, world, policy, reserved,
            state: Mutex::new(State { saved, ..State::default() }), applying: tokio::sync::Mutex::new(()) }))
    }

    /// Simulators sessions used before (the session ledger), with when each
    /// was last: Squircle's own, whatever this file has lost.
    pub fn remember_leased(&self, used: impl IntoIterator<Item = (String, f64)>) {
        let mut state = self.state.lock().unwrap();
        for (udid, at) in used {
            let entry = state.saved.known.entry(udid.to_ascii_uppercase()).or_default();
            entry.leased = true;
            entry.last_used = entry.last_used.max(at);
        }
    }

    /// A booted simulator a start may take without booting another.
    pub fn free(&self, udid: &str) -> bool {
        self.state.lock().unwrap().rows.iter().any(|r| r.free && r.udid.eq_ignore_ascii_case(udid))
    }

    /// Notes which threads' commands created or used simulators since the last read.
    async fn read_activity(&self, devices: &[Device]) -> Result<()> {
        let since = self.state.lock().unwrap().saved.activity_seen.clone();
        let rows = self.world.activity(&since).await?;
        let by_name = |name: &str| {
            let matches: Vec<&Device> = devices.iter().filter(|d| d.name == name).collect();
            (matches.len() == 1).then(|| matches[0].udid.clone())
        };
        let mut state = self.state.lock().unwrap();
        for row in &rows {
            let used = parse_use(&row.command, &row.output);
            let at = iso_seconds(&row.created_at).unwrap_or_else(now);
            let created = used.created.iter().cloned().chain(used.created_names.iter().filter_map(|n| by_name(n)));
            for udid in created {
                let entry = state.saved.known.entry(udid).or_default();
                entry.created_by.get_or_insert_with(|| row.thread.clone());
                entry.last_used = entry.last_used.max(at);
            }
            for udid in used.touched.iter().cloned().chain(used.touched_names.iter().filter_map(|n| by_name(n))) {
                let entry = state.saved.known.entry(udid).or_default();
                if at >= entry.touched_at {
                    entry.touched_by = Some(row.thread.clone());
                    entry.touched_at = at;
                }
                entry.last_used = entry.last_used.max(at);
            }
            if row.created_at > state.saved.activity_seen {
                state.saved.activity_seen = row.created_at.clone();
            }
        }
        Ok(())
    }

    /// Gathers the facts and plans. `now_please` skips the idle wait.
    pub async fn refresh(&self, leases: &[Lease], now_please: bool) -> Result<Vec<Row>> {
        let devices = self.simctl.devices().await?;
        if let Err(error) = self.read_activity(&devices).await {
            eprintln!("Simulator pool: T3's activity log not read: {error:#}");
        }
        // Without T3's sessions nothing could be shown to be the user's: no plan.
        let sessions = self.world.t3_sessions().await.context("T3 did not list its device sessions")?;
        let time = now();
        let mut state = self.state.lock().unwrap();
        for lease in leases {
            let entry = state.saved.known.entry(lease.device_id.to_ascii_uppercase()).or_default();
            entry.leased = true;
            entry.last_used = time;
        }
        let world = self.world.clone();
        let thread = move |id: &str| world.thread(id);
        let rows = plan(&Facts {
            now: time, devices: &devices, leases, t3_sessions: &sessions, known: &state.saved.known,
            thread: &thread, idle_since: &state.idle_since, reserved: &self.reserved, policy: self.policy, now_please,
        });
        state.idle_since.retain(|udid, _| rows.iter().any(|r| r.free && &r.udid == udid));
        for row in rows.iter().filter(|r| r.free) {
            state.idle_since.entry(row.udid.clone()).or_insert(time);
        }
        state.rows = rows.clone();
        let _ = atomic_json(&self.root.join("simpool.json"), &state.saved);
        Ok(rows)
    }

    async fn apply(&self, rows: &[Row]) -> Vec<Value> {
        let mut done = Vec::new();
        for row in rows {
            let Some(action) = &row.action else { continue };
            let result = match action {
                Action::Shutdown => self.simctl.shutdown(&row.udid).await,
                Action::Delete => self.simctl.delete(&row.udid).await,
            };
            if result.is_ok() {
                let mut state = self.state.lock().unwrap();
                state.idle_since.remove(&row.udid);
                if *action == Action::Delete {
                    state.saved.known.remove(&row.udid);
                } else if let Some(known) = state.saved.known.get_mut(&row.udid) {
                    known.last_used = now();
                }
            }
            done.push(json!({"udid": row.udid, "name": row.name, "action": action, "why": row.why,
                             "error": result.err().map(|e| format!("{e:#}"))}));
        }
        if !done.is_empty() {
            let state = self.state.lock().unwrap();
            let _ = atomic_json(&self.root.join("simpool.json"), &state.saved);
        }
        done
    }

    /// `thread`'s lease on `udid` ended and no other holds it: shut it down
    /// now, unless the policy keeps it (the user's T3 session on it, say).
    /// The thread's own commands on it don't keep it.
    pub async fn release(&self, udid: &str, thread: &str, leases: &[Lease]) -> Result<()> {
        let _apply = self.applying.lock().await;
        self.remember_leased([(udid.to_string(), now())]);
        let rows = self.refresh(leases, false).await?;
        let mine: Vec<Row> = rows.into_iter()
            .filter(|r| r.udid.eq_ignore_ascii_case(udid))
            .filter(|r| r.free || (r.owner == "agent outside a lease" && r.thread.as_deref() == Some(thread)))
            .map(|mut r| { r.action = Some(Action::Shutdown); r.why = "its lease ended".into(); r }).collect();
        for result in self.apply(&mine).await {
            ensure!(result["error"].is_null(), "{}", result["error"].as_str().unwrap_or("shutdown failed"));
        }
        Ok(())
    }

    /// Shuts down and deletes what the policy says (idle waits included).
    pub async fn tick(&self, leases: &[Lease]) -> Result<Vec<Value>> {
        let _apply = self.applying.lock().await;
        let rows = self.refresh(leases, false).await?;
        Ok(self.apply(&rows).await)
    }

    /// `sim cleanup`: the policy without idle waits; `dry_run` only reports.
    pub async fn cleanup(&self, leases: &[Lease], dry_run: bool) -> Result<Value> {
        let _apply = self.applying.lock().await;
        let rows = self.refresh(leases, true).await?;
        let planned: Vec<&Row> = rows.iter().filter(|r| r.action.is_some()).collect();
        let kept: Vec<&Row> = rows.iter().filter(|r| r.booted && r.action.is_none()).collect();
        let done = if dry_run { Value::Null } else { Value::Array(self.apply(&rows).await) };
        Ok(json!({"dry_run": dry_run, "would": planned, "kept": kept, "done": done}))
    }

    /// Every booted simulator with its owner, for `sim status`.
    pub async fn status(&self, leases: &[Lease]) -> Result<Value> {
        let rows = self.refresh(leases, false).await?;
        let cpu = self.simctl.cpu();
        let booted: Vec<Value> = rows.iter().filter(|r| r.booted).map(|r| {
            let mut value = serde_json::to_value(r).unwrap_or_default();
            value["apps_cpu_percent"] = json!(cpu.get(&r.udid).map(|c| c.round()));
            if let Some(title) = r.thread.as_deref().and_then(|t| self.world.title(t)) {
                value["thread_title"] = json!(title);
            }
            value
        }).collect();
        Ok(json!({"booted": booted, "max_leases": self.policy.max_leases, "idle_minutes": self.policy.idle / 60.0}))
    }

    /// Applies the policy every minute until the service stops.
    pub async fn run(self: Arc<Self>, sims: Arc<crate::sims::Sims>) {
        loop {
            tokio::time::sleep(Duration::from_secs(60)).await;
            match self.tick(&sims.leases()).await {
                Ok(done) => for item in done {
                    eprintln!("Simulator pool: {} {} ({}){}", item["action"], item["name"], item["why"],
                              item["error"].as_str().map(|e| format!(": {e}")).unwrap_or_default());
                },
                Err(error) => eprintln!("Simulator pool not applied: {error:#}"),
            }
        }
    }
}

/// T3's ISO-8601 UTC times (`2026-10-14T22:23:14.016Z`) as Unix seconds.
pub(crate) fn iso_seconds(text: &str) -> Option<f64> {
    let (date, time) = text.trim_end_matches('Z').split_once('T')?;
    let mut d = date.split('-').map(|p| p.parse::<i64>().ok());
    let (y, m, day) = (d.next()??, d.next()??, d.next()??);
    let mut t = time.split(':');
    let (h, min, s) = (t.next()?.parse::<i64>().ok()?, t.next()?.parse::<i64>().ok()?, t.next()?.parse::<f64>().ok()?);
    // Days from civil (Howard Hinnant).
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * ((m + 9) % 12) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    Some((days * 86400 + h * 3600 + min * 60) as f64 + s)
}

/// The real simctl and ps.
pub struct Xcrun;

async fn simctl(args: &[&str]) -> Result<Vec<u8>> {
    let output = tokio::time::timeout(Duration::from_secs(120), Command::new("xcrun").arg("simctl").args(args)
        .stdin(Stdio::null()).kill_on_drop(true).output()).await
        .context("simctl timed out")?.context("Cannot run xcrun simctl")?;
    ensure!(output.status.success(), "simctl {} failed: {}", args.join(" "), String::from_utf8_lossy(&output.stderr).trim());
    Ok(output.stdout)
}

impl Simctl for Xcrun {
    fn devices(&self) -> Pending<'_, Result<Vec<Device>>> {
        Box::pin(async {
            let list: Value = serde_json::from_slice(&simctl(&["list", "devices", "-j"]).await?).context("simctl list output")?;
            let mut devices = Vec::new();
            for (runtime, entries) in list["devices"].as_object().into_iter().flatten() {
                if !runtime.contains("SimRuntime.iOS") { continue }
                for d in entries.as_array().into_iter().flatten() {
                    let Some(udid) = d["udid"].as_str() else { continue };
                    let plist = d["dataPath"].as_str().map(|p| Path::new(p).with_file_name("device.plist"));
                    let changed_at = plist.and_then(|p| p.metadata().ok()?.modified().ok())
                        .and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map_or(0.0, |d| d.as_secs_f64());
                    devices.push(Device { udid: udid.to_ascii_uppercase(), name: d["name"].as_str().unwrap_or("").into(),
                                          state: d["state"].as_str().unwrap_or("").into(), changed_at });
                }
            }
            Ok(devices)
        })
    }

    fn shutdown<'a>(&'a self, udid: &'a str) -> Pending<'a, Result<()>> {
        Box::pin(async move {
            match simctl(&["shutdown", udid]).await {
                // Already shut down.
                Err(error) if format!("{error:#}").contains("current state: Shutdown") => Ok(()),
                other => other.map(|_| ()),
            }
        })
    }

    fn delete<'a>(&'a self, udid: &'a str) -> Pending<'a, Result<()>> {
        Box::pin(async move { simctl(&["delete", udid]).await.map(|_| ()) })
    }

    fn cpu(&self) -> HashMap<String, f64> {
        let mut cpu = HashMap::new();
        let Ok(output) = std::process::Command::new("/bin/ps").args(["-axww", "-o", "pcpu=,command="])
            .stdin(Stdio::null()).stderr(Stdio::null()).output() else { return cpu };
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            let line = line.trim_start();
            let Some((percent, command)) = line.split_once(' ') else { continue };
            let Some(after) = command.split("/CoreSimulator/Devices/").nth(1) else { continue };
            if let (Some(udid), Ok(percent)) = (uuids(&after[..after.len().min(UUID_LEN)]).pop(), percent.parse::<f64>()) {
                *cpu.entry(udid).or_default() += percent;
            }
        }
        cpu
    }
}

struct T3World(Arc<crate::agents::Agents>);

impl World for T3World {
    fn t3_sessions(&self) -> Pending<'_, Result<Vec<(String, String)>>> {
        Box::pin(async {
            // T3's cached state: sessions are its own, and unlike
            // `device.list` this doesn't make it re-list every host.
            let list = self.0.connection().await?.snapshot("subscribeDeviceState", json!({})).await?;
            Ok(list["sessions"].as_array().into_iter().flatten().filter_map(|s| {
                Some((s["threadId"].as_str()?.to_string(), s["deviceId"].as_str()?.to_ascii_uppercase()))
            }).collect())
        })
    }

    fn thread(&self, id: &str) -> Option<ThreadInfo> {
        let row = self.0.thread_row(id)?;
        Some(ThreadInfo {
            working: crate::agents::worker_state(&row) == "working",
            squircle: self.0.is_squircle_thread(id),
            archived: !row["archivedAt"].is_null(),
        })
    }

    fn title(&self, id: &str) -> Option<String> {
        self.0.worker_title(id).or_else(|| self.0.thread_row(id)?["title"].as_str().map(str::to_string))
    }

    fn activity<'a>(&'a self, since: &'a str) -> Pending<'a, Result<Vec<Activity>>> {
        Box::pin(crate::t3steps::simulator_commands(since))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOUR: f64 = 3600.0;
    const POLICY: Policy = Policy { max_leases: 3, idle: 600.0, delete_after: 24.0 * HOUR };

    fn device(udid: &str, state: &str) -> Device {
        Device { udid: udid.into(), name: format!("sim {udid}"), state: state.into(), changed_at: 0.0 }
    }

    fn ours(created_by: Option<&str>) -> Provenance {
        Provenance { leased: created_by.is_none(), created_by: created_by.map(str::to_string), ..Provenance::default() }
    }

    /// Which simulators the policy stops or deletes, and the owners it reports.
    #[test]
    fn policy_stops_only_free_simulators_of_ours() {
        let now = 100.0 * HOUR;
        let devices = [
            device("LEASED", "Booted"), device("USER", "Booted"), device("PANEL", "Booted"),
            device("ADHOC", "Booted"), device("IDLE", "Booted"), device("FRESH", "Booted"),
            device("PREVIEW", "Booted"), device("STALE", "Shutdown"), device("RECENT", "Shutdown"),
            device("STOCK", "Shutdown"),
        ];
        let known: HashMap<String, Provenance> = [
            ("LEASED", ours(None)), ("PANEL", ours(None)), ("IDLE", ours(None)), ("FRESH", ours(None)),
            ("PREVIEW", ours(None)), ("STOCK", ours(None)),
            ("ADHOC", Provenance { touched_by: Some("worker".into()), touched_at: now - 60.0, ..Provenance::default() }),
            ("STALE", Provenance { last_used: now - 30.0 * HOUR, ..ours(Some("old-worker")) }),
            ("RECENT", Provenance { last_used: now - HOUR, ..ours(Some("old-worker")) }),
        ].into_iter().map(|(k, v)| (k.to_string(), v)).collect();
        let thread = |id: &str| match id {
            "worker" => Some(ThreadInfo { working: true, squircle: true, archived: false }),
            "user" => Some(ThreadInfo { working: false, squircle: false, archived: false }),
            _ => None,
        };
        let idle_since: HashMap<String, f64> = [("IDLE".to_string(), now - 700.0), ("FRESH".to_string(), now - 60.0)].into();
        let leases = [Lease { device_id: "LEASED".into(), thread_id: "worker".into() }];
        let sessions = [("user".to_string(), "PANEL".to_string()), ("gone".to_string(), "IDLE".to_string())];
        let reserved = ["PREVIEW".to_string()];
        let facts = |now_please| Facts { now, devices: &devices, leases: &leases, t3_sessions: &sessions, known: &known,
            thread: &thread, idle_since: &idle_since, reserved: &reserved, policy: POLICY, now_please };
        let summary = |rows: Vec<Row>| rows.into_iter().map(|r| (r.udid, r.owner, r.action)).collect::<Vec<_>>();

        assert_eq!(summary(plan(&facts(false))), vec![
            ("LEASED".into(), "lease", None),
            ("USER".into(), "unowned", None),
            ("PANEL".into(), "t3 session", None),
            ("ADHOC".into(), "agent outside a lease", None),
            ("IDLE".into(), "agent (idle)", Some(Action::Shutdown)),
            ("FRESH".into(), "agent (idle)", None),
            ("PREVIEW".into(), "reserved", None),
            ("STALE".into(), "agent (idle)", Some(Action::Delete)),
        ]);
        // On demand the idle wait goes, nothing else.
        let rows = plan(&facts(true));
        assert_eq!(rows.iter().filter(|r| r.action.is_some()).map(|r| r.udid.as_str()).collect::<Vec<_>>(), ["IDLE", "FRESH", "STALE"]);
    }

    #[test]
    fn agent_simulator_commands() {
        let created = "S=$(xcrun simctl create \"simsmooth-scratch\" $T $R) && xcrun simctl boot $S; echo $S";
        assert_eq!(parse_use(created, "5c5214a2-39cf-4937-b0cf-94764a34ea09\n"), Use {
            created: vec!["5C5214A2-39CF-4937-B0CF-94764A34EA09".into()],
            created_names: vec!["simsmooth-scratch".into()], ..Use::default() });
        let used = "xcrun simctl boot 'iPhone 18 Pro Max'; xcrun simctl install 389DF2C3-2656-40AD-830A-A8A90667D730 /tmp/A.app \
                    && xcodebuild test -scheme S -destination 'platform=iOS Simulator,id=DFDF12FB-5C70-4B39-B85C-D5D82D6AB5F7'";
        assert_eq!(parse_use(used, "1F0C7E5A-0000-4000-8000-000000000000"), Use {
            touched: vec!["389DF2C3-2656-40AD-830A-A8A90667D730".into(), "DFDF12FB-5C70-4B39-B85C-D5D82D6AB5F7".into()],
            touched_names: vec!["iPhone 18 Pro Max".into()], ..Use::default() });
        // Listing, reading or recording is not a use; nor is the literal "booted".
        assert_eq!(parse_use("xcrun simctl list devices; xcrun simctl io booted screenshot /tmp/a.png; simctl boot booted", "x"), Use::default());
        assert_eq!(iso_seconds("2026-10-14T22:23:14.016Z").map(|s| s.round()), Some(1_792_016_594.0));
    }

    #[derive(Default)]
    struct Fake {
        devices: Mutex<Vec<Device>>,
        calls: Mutex<Vec<String>>,
    }

    impl Simctl for Fake {
        fn devices(&self) -> Pending<'_, Result<Vec<Device>>> {
            let devices = self.devices.lock().unwrap().clone();
            Box::pin(async move { Ok(devices) })
        }
        fn shutdown<'a>(&'a self, udid: &'a str) -> Pending<'a, Result<()>> {
            self.calls.lock().unwrap().push(format!("shutdown {udid}"));
            for d in self.devices.lock().unwrap().iter_mut().filter(|d| d.udid == udid) { d.state = "Shutdown".into() }
            Box::pin(async { Ok(()) })
        }
        fn delete<'a>(&'a self, udid: &'a str) -> Pending<'a, Result<()>> {
            self.calls.lock().unwrap().push(format!("delete {udid}"));
            Box::pin(async { Ok(()) })
        }
        fn cpu(&self) -> HashMap<String, f64> { HashMap::new() }
    }

    struct Quiet;
    impl World for Quiet {
        fn t3_sessions(&self) -> Pending<'_, Result<Vec<(String, String)>>> { Box::pin(async { Ok(vec![]) }) }
        fn thread(&self, _: &str) -> Option<ThreadInfo> { None }
        fn title(&self, _: &str) -> Option<String> { None }
        fn activity<'a>(&'a self, since: &'a str) -> Pending<'a, Result<Vec<Activity>>> {
            let rows = if since.is_empty() {
                vec![Activity { thread: "w".into(), created_at: "2026-10-14T20:00:00.000Z".into(),
                                command: "xcrun simctl boot AAAAAAAA-0000-4000-8000-000000000000".into(), output: String::new() }]
            } else { vec![] };
            Box::pin(async move { Ok(rows) })
        }
    }

    /// A dry run touches nothing; a lease's simulator stops when it ends; the
    /// user's own booted simulator is never stopped; provenance survives a restart.
    #[tokio::test]
    async fn cleanup_and_release_apply_the_plan() {
        let dir = tempfile::tempdir().unwrap();
        let (adhoc, leased, user) = ("AAAAAAAA-0000-4000-8000-000000000000", "BBBBBBBB-0000-4000-8000-000000000000", "CCCCCCCC-0000-4000-8000-000000000000");
        let fake = Arc::new(Fake::default());
        *fake.devices.lock().unwrap() = vec![device(adhoc, "Booted"), device(leased, "Booted"), device(user, "Booted")];
        let pool = Pool::with(dir.path(), fake.clone(), Arc::new(Quiet), POLICY, vec![]).unwrap();
        let lease = [Lease { device_id: leased.into(), thread_id: "w2".into() }];

        let report = pool.cleanup(&lease, true).await.unwrap();
        assert_eq!(report["would"].as_array().unwrap().len(), 1);
        assert!(fake.calls.lock().unwrap().is_empty());

        pool.release(leased, "w2", &[]).await.unwrap();
        assert_eq!(*fake.calls.lock().unwrap(), [format!("shutdown {leased}")]);
        // Within the idle time the ad-hoc one stays; cleanup takes it now.
        pool.tick(&[]).await.unwrap();
        assert_eq!(fake.calls.lock().unwrap().len(), 1);
        let reopened = Pool::with(dir.path(), fake.clone(), Arc::new(Quiet), POLICY, vec![]).unwrap();
        reopened.cleanup(&[], false).await.unwrap();
        assert_eq!(*fake.calls.lock().unwrap(), [format!("shutdown {leased}"), format!("shutdown {adhoc}")]);
    }
}
