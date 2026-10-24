//! Which booted simulators on this Mac are Squircle's to shut down, and
//! which simulator devices are its to delete: the owner of M20
//! (`fsm::sims::pool`, the policy itself, from plain facts).
//!
//! A simulator is Squircle's only on proof (Q4): an agent's own command
//! created it, or the current boot was a session's open or an agent's own
//! `simctl boot` (T3's activity log, read read-only). Leasing, installing
//! or building for one is an observation, not ownership. Anything else is
//! the user's and is never touched. A booted simulator of ours is left
//! alone while a session reserves it, while a T3 device session of a thread
//! that may be working (busy, waiting on the user, or unknown) or of a
//! thread that isn't Squircle's (the user's Device panel) is on it, or while
//! an agent that used it outside a session may still be working; otherwise
//! it is shut down once it has been free for the idle time (at once when a
//! session releases it, or on `squircle sim cleanup`). A device an agent
//! created is deleted once nothing has used it for a day; any shut-down
//! device, once nothing has for two weeks, unless the owner keeps it
//! (`sim-keep.json`, `squircle sim keep`).
//!
//! What is known is saved through the commit gate before anything acts on
//! it; a cleanup is saved as an intent, revalidated on a fresh snapshot
//! under a device reservation from the session owner (so a start can't take
//! the simulator meanwhile), and settled only by simctl's answer or the
//! next inventory.

use crate::actor::{Lane, Owner, Rank};
use crate::fsm::core::commit::{Gate, JsonFile};
use crate::fsm::sims::pool::{self as policy, Acting};
pub use crate::fsm::sims::pool::{
    Action, BootReceipt, Device, Facts, Lease, Policy, Provenance, Row, ThreadInfo, plan,
};
use crate::fsm::sims::session::Released;
use crate::sims::Pending;
use anyhow::{Context, Result, anyhow, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    convert::Infallible,
    path::Path,
    process::Stdio,
    sync::{Arc, OnceLock, Weak},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::process::Command;

impl Policy {
    pub fn from_env() -> Self {
        let number = |name: &str| {
            std::env::var(name)
                .ok()
                .and_then(|v| v.trim().parse::<f64>().ok())
                .filter(|v| *v >= 0.0)
        };
        Self {
            max_leases: number("SQUIRCLE_MAX_SIMULATORS").map_or(3, |v| (v as usize).max(1)),
            idle: number("SQUIRCLE_SIM_IDLE_MINUTES").map_or(600.0, |m| m * 60.0),
            delete_after: 24.0 * 3600.0,
            stale_after: number("SQUIRCLE_SIM_STALE_DAYS").unwrap_or(14.0) * 24.0 * 3600.0,
            hold_idle: number("SQUIRCLE_SIM_HOLD_IDLE_MINUTES").map_or(1800.0, |m| m * 60.0),
        }
    }
}

/// The owner's keep list: device names and UDIDs never deleted.
const KEEP_FILE: &str = "sim-keep.json";

#[derive(Default, Serialize, Deserialize)]
struct KeepList {
    #[serde(default)]
    keep: Vec<String>,
}

fn read_keep(root: &Path) -> Result<Vec<String>> {
    let path = root.join(KEEP_FILE);
    match std::fs::read(&path) {
        Ok(bytes) => Ok(serde_json::from_slice::<KeepList>(&bytes)
            .with_context(|| format!("{} is not a keep list; fix or remove it", path.display()))?
            .keep),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(vec![]),
        Err(error) => Err(error).with_context(|| format!("Cannot read {}", path.display())),
    }
}

// MARK: Agents' own simulator commands

/// What one command in T3's activity log did to simulators.
#[derive(Debug, Default, PartialEq)]
pub struct Use {
    pub created: Vec<String>,
    /// Booted by this command (`simctl boot`): a boot receipt.
    pub booted: Vec<String>,
    /// Used (booted, installed on, launched, built for): an observation.
    pub touched: Vec<String>,
    /// Names, resolved against the device list (only when unique).
    pub created_names: Vec<String>,
    pub booted_names: Vec<String>,
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
            && bytes
                .get(i + UUID_LEN)
                .is_none_or(|b| !b.is_ascii_alphanumeric());
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
        rest = rest
            .split_once(char::is_whitespace)
            .map_or("", |(_, r)| r)
            .trim_start();
    }
    let word = match rest.chars().next()? {
        quote @ ('"' | '\'') => rest[1..].split(quote).next()?,
        _ => rest
            .split(|c: char| c.is_whitespace() || ";&|)".contains(c))
            .next()?,
    };
    (!word.is_empty() && !word.starts_with('$') && !word.contains('`')).then(|| word.to_string())
}

/// Parses a shell command an agent ran (and its output) for simulators it
/// created (`simctl create/clone`, whose output is the new UDID), booted
/// (`simctl boot`) and used (`simctl boot/install/launch`, `xcodebuild
/// -destination`, T3's `agent-device --udid`).
pub fn parse_use(command: &str, output: &str) -> Use {
    let mut found = Use::default();
    let mut segments = command.split("simctl ");
    segments.next();
    for segment in segments {
        let segment = segment
            .split(['\n', ';', '|'])
            .next()
            .unwrap_or("")
            .split("&&")
            .next()
            .unwrap_or("");
        let (verb, rest) = segment
            .trim_start()
            .split_once(char::is_whitespace)
            .unwrap_or((segment.trim(), ""));
        match verb {
            "create" | "clone" => {
                found.created.extend(uuids(output));
                let name = if verb == "clone" {
                    argument(
                        rest.trim_start()
                            .split_once(char::is_whitespace)
                            .map_or("", |(_, r)| r),
                    )
                } else {
                    argument(rest)
                };
                found
                    .created_names
                    .extend(name.filter(|n| uuids(n).is_empty()));
            }
            "boot" | "install" | "launch" | "bootstatus" | "openurl" | "spawn" => {
                let ids = uuids(segment);
                let name = if ids.is_empty() {
                    argument(rest).filter(|n| n != "booted")
                } else {
                    None
                };
                // A boot of an already booted device boots nothing.
                if verb == "boot" && !output.contains("current state: Booted") {
                    found.booted.extend(ids.iter().take(1).cloned());
                    found.booted_names.extend(name.clone());
                }
                found.touched_names.extend(name);
                found.touched.extend(ids.into_iter().take(1));
            }
            _ => {}
        }
    }
    // T3's agent-device driving a simulator (`--udid`): a use.
    for segment in command.split("agent-device").skip(1) {
        let segment = segment.split(['\n', ';', '|']).next().unwrap_or("");
        if let Some((_, rest)) = segment.split_once("--udid") {
            found.touched.extend(uuids(rest).into_iter().take(1));
        }
    }
    if command.contains("xcodebuild") {
        for destination in command.split("-destination").skip(1) {
            let spec = argument(destination).unwrap_or_default();
            for part in spec.split(',') {
                match part.split_once('=') {
                    Some(("id", id)) => found.touched.extend(uuids(id)),
                    Some(("name", name)) if spec.contains("Simulator") => {
                        found.touched_names.push(name.to_string())
                    }
                    _ => {}
                }
            }
        }
    }
    found.created.sort();
    found.created.dedup();
    found.touched.retain(|t| !found.created.contains(t));
    found.booted.retain(|t| !found.created.contains(t));
    found
}

// MARK: Applying it

/// Notes which threads' commands created, booted or used simulators.
fn merge_activity(saved: &mut Saved, rows: &[Activity], devices: &[Device]) {
    let by_name = |name: &str| {
        let matches: Vec<&Device> = devices.iter().filter(|d| d.name == name).collect();
        (matches.len() == 1).then(|| matches[0].udid.clone())
    };
    for row in rows {
        let used = parse_use(&row.command, &row.output);
        let at = crate::t3::iso_parse(&row.created_at).unwrap_or_else(now);
        for udid in used
            .created
            .iter()
            .cloned()
            .chain(used.created_names.iter().filter_map(|n| by_name(n)))
        {
            let entry = saved.known.entry(udid).or_default();
            entry.created_by.get_or_insert_with(|| row.thread.clone());
            entry.last_used = entry.last_used.max(at);
        }
        for udid in used
            .booted
            .iter()
            .cloned()
            .chain(used.booted_names.iter().filter_map(|n| by_name(n)))
        {
            saved.known.entry(udid).or_default().note_boot(BootReceipt {
                at,
                thread: Some(row.thread.clone()),
                session: None,
            });
        }
        for udid in used
            .touched
            .iter()
            .cloned()
            .chain(used.touched_names.iter().filter_map(|n| by_name(n)))
        {
            saved
                .known
                .entry(udid)
                .or_default()
                .note_touch(&row.thread, at);
        }
        if row.created_at > saved.activity_seen {
            saved.activity_seen = row.created_at.clone();
        }
    }
}

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
    /// Creates and boots a simulator of the default model; returns its UDID and name.
    fn create(&self) -> Pending<'_, Result<(String, String)>>;
    /// Each simulator's processes' summed CPU (%), by UDID.
    fn cpu(&self) -> Pending<'_, HashMap<String, f64>>;
}

/// T3, as far as the policy needs it. Tests use a fake.
pub trait World: Send + Sync {
    fn t3_sessions(&self) -> Pending<'_, Result<Vec<(String, String)>>>;
    fn thread(&self, id: &str) -> ThreadInfo;
    fn title(&self, id: &str) -> Option<String>;
    /// Simulator and xcodebuild commands agents ran after `since` (ISO time).
    fn activity<'a>(&'a self, since: &'a str) -> Pending<'a, Result<Vec<Activity>>>;
    /// Closes `thread`'s T3 device session on `device` (its simulator was shut down).
    fn close<'a>(&'a self, thread: &'a str, device: &'a str) -> Pending<'a, Result<()>>;
}

/// The session owner, the one authority on which simulators are reserved.
pub trait Holds: Send + Sync {
    /// Simulators sessions reserve now (in use, or their cleanup unsettled).
    fn leases(&self) -> Vec<Lease>;
    /// Boots sessions' opens did: Squircle's, recorded in its ledger first.
    fn boots(&self) -> Vec<(String, BootReceipt)>;
    /// Reserves `udid` for a cleanup unless a session reserves it; no start
    /// takes it until the returned exclusion is dropped.
    fn exclude<'a>(&'a self, udid: &'a str) -> Pending<'a, Option<Exclusion>>;
}

/// A cleanup's reservation of one simulator; released when dropped. The
/// release only tells the session owner (it never locks or waits).
pub struct Exclusion(Option<Box<dyn FnOnce() + Send>>);

impl Exclusion {
    pub fn new(release: impl FnOnce() + Send + 'static) -> Self {
        Self(Some(Box::new(release)))
    }
}

impl Drop for Exclusion {
    fn drop(&mut self) {
        if let Some(release) = self.0.take() {
            release();
        }
    }
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct Saved {
    #[serde(default)]
    known: HashMap<String, Provenance>,
    /// T3's activity log is read past this (its `created_at`).
    #[serde(default)]
    activity_seen: String,
}

/// The pool owner's state, reached only by its letters.
struct State {
    root: std::path::PathBuf,
    gate: Gate<Saved, Infallible, JsonFile>,
    idle_since: HashMap<String, f64>,
    /// When each simulator was first seen kept only by a working thread's T3 hold.
    held_since: HashMap<String, f64>,
    /// Cleanups a previous run left unanswered have been settled from an inventory.
    reconciled: bool,
}

impl State {
    /// Changes what is known and saves it before anything reads or acts on it.
    fn change<T>(&mut self, change: impl FnOnce(&mut Saved) -> T) -> Result<T> {
        self.gate
            .resolve()
            .map_err(|e| anyhow!("Simulator pool state not saved: {e}"))?;
        let mut candidate = self.gate.committed().clone();
        let out = change(&mut candidate);
        self.gate
            .commit(candidate, vec![])
            .map_err(|e| anyhow!("Simulator pool state not saved: {e}"))?;
        Ok(out)
    }
}

pub struct Pool {
    simctl: Arc<dyn Simctl>,
    world: Arc<dyn World>,
    pub policy: Policy,
    reserved: Vec<String>,
    owner: Owner<State>,
    /// The session owner, attached once it exists.
    holds: OnceLock<Weak<dyn Holds>>,
    /// One plan-and-apply at a time.
    applying: Lane,
    /// The simulator host's health, as the watch last found it.
    health: crate::actor::Published<crate::simwatch::Health>,
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// What one look at the world found.
struct Snapshot {
    now: f64,
    devices: Vec<Device>,
    sessions: Vec<(String, String)>,
    leases: Vec<Lease>,
}

impl Pool {
    pub fn open(root: &Path, agents: Arc<crate::agents::Agents>) -> Result<Arc<Self>> {
        let reserved = std::env::var("SQUIRCLE_SIMULATOR_ID")
            .ok()
            .map(|s| s.trim().to_ascii_uppercase())
            .into_iter()
            .collect();
        Self::with(
            root,
            Arc::new(Xcrun),
            Arc::new(T3World(agents)),
            Policy::from_env(),
            reserved,
        )
    }

    pub fn with(
        root: &Path,
        simctl: Arc<dyn Simctl>,
        world: Arc<dyn World>,
        policy: Policy,
        reserved: Vec<String>,
    ) -> Result<Arc<Self>> {
        let file = JsonFile::new(root.join("simpool.json"));
        let (saved, revision) = file.read::<Saved>()?.unwrap_or_default();
        let state = State {
            root: root.to_path_buf(),
            gate: Gate::restore(saved, revision, file),
            idle_since: HashMap::new(),
            held_since: HashMap::new(),
            reconciled: false,
        };
        Ok(Arc::new(Self {
            simctl,
            world,
            policy,
            reserved,
            owner: Owner::spawn("simulator pool", state),
            holds: OnceLock::new(),
            applying: Lane::new(Rank::PoolApply),
            health: crate::actor::Published::new(crate::simwatch::Health::default()).0,
        }))
    }

    pub fn health(&self) -> Arc<crate::simwatch::Health> {
        self.health.get()
    }

    pub fn set_health(&self, health: crate::simwatch::Health) {
        self.health.set(health);
    }

    /// The owner's keep list.
    pub async fn keep_list(&self) -> Result<Vec<String>> {
        self.owner.ask(|s| read_keep(&s.root)).await
    }

    /// Adds or removes device names or UDIDs on the keep list; returns it.
    pub async fn keep(&self, add: Vec<String>, remove: Vec<String>) -> Result<Vec<String>> {
        self.owner
            .ask(move |s| {
                let mut keep = read_keep(&s.root)?;
                for entry in add {
                    let entry = entry.trim().to_string();
                    ensure!(!entry.is_empty(), "Name a simulator or its UDID");
                    if !keep.iter().any(|k| k.eq_ignore_ascii_case(&entry)) {
                        keep.push(entry);
                    }
                }
                keep.retain(|k| !remove.iter().any(|r| r.trim().eq_ignore_ascii_case(k)));
                crate::store::atomic_json(
                    &s.root.join(KEEP_FILE),
                    &KeepList { keep: keep.clone() },
                )?;
                Ok(keep)
            })
            .await
    }

    /// The session owner: its reservations, boots and cleanup exclusions.
    pub fn attach(&self, holds: Weak<dyn Holds>) {
        let _ = self.holds.set(holds);
    }

    fn holds(&self) -> Option<Arc<dyn Holds>> {
        self.holds.get()?.upgrade()
    }

    /// Changes what is known and saves it before anything reads or acts on it.
    async fn change<T: Send + 'static>(
        &self,
        change: impl FnOnce(&mut Saved) -> T + Send + 'static,
    ) -> Result<T> {
        self.owner.ask(move |s| s.change(change)).await
    }

    /// Simulators sessions used before (the session ledger), with when each
    /// was last: an observation, whatever this file has lost.
    pub async fn remember_leased(&self, used: impl IntoIterator<Item = (String, f64)>) {
        let used: Vec<(String, f64)> = used.into_iter().collect();
        let saved = self
            .change(move |saved| {
                for (udid, at) in &used {
                    let entry = saved.known.entry(udid.to_ascii_uppercase()).or_default();
                    entry.leased = true;
                    entry.last_used = entry.last_used.max(*at);
                }
            })
            .await;
        if let Err(error) = saved {
            eprintln!("{error:#}");
        }
    }

    /// A fresh simulator for `thread`, for a start that found none free:
    /// saved as created by it, so it is Squircle's (shut down when idle,
    /// deleted once unused for a day).
    pub async fn create(&self, thread: &str) -> Result<(String, String)> {
        let (udid, name) = self.simctl.create().await?;
        let (created, by) = (udid.clone(), thread.to_string());
        self.change(move |saved| {
            let entry = saved.known.entry(created).or_default();
            entry.created_by = Some(by);
            entry.last_used = now();
        })
        .await?;
        Ok((udid, name))
    }

    /// The facts as they are now, with T3's sessions: without them nothing
    /// could be shown to be the user's, so no plan.
    async fn look(&self, leases: Vec<Lease>) -> Result<Snapshot> {
        let devices = self.simctl.devices().await?;
        let sessions = self
            .world
            .t3_sessions()
            .await
            .context("T3 did not list its device sessions")?;
        Ok(Snapshot {
            now: now(),
            devices,
            sessions,
            leases,
        })
    }

    /// Commands agents ran since the last read, or None if T3's activity
    /// log couldn't be read (then an unseen use could protect any of ours).
    async fn read_activity(&self) -> Option<Vec<Activity>> {
        let since = self
            .owner
            .ask(|s| s.gate.committed().activity_seen.clone())
            .await;
        match self.world.activity(&since).await {
            Ok(rows) => Some(rows),
            Err(error) => {
                eprintln!(
                    "Simulator pool: T3's activity log not read, so nothing of ours is cleaned up: {error:#}"
                );
                None
            }
        }
    }

    /// Gathers the facts, saves what they prove, and plans. `now_please`
    /// skips the idle wait.
    pub async fn refresh(&self, leases: &[Lease], now_please: bool) -> Result<Vec<Row>> {
        let snapshot = Arc::new(self.look(leases.to_vec()).await?);
        let activity = self.read_activity().await;
        let complete = activity.is_some();
        let boots = self.holds().map(|h| h.boots()).unwrap_or_default();
        let facts = snapshot.clone();
        let (known, idle_since, held_since, keep) = self
            .owner
            .ask(move |s| -> Result<_> {
                let keep = read_keep(&s.root)?;
                let reconcile = !s.reconciled;
                s.change(|saved| {
                    merge_activity(
                        saved,
                        activity.as_deref().unwrap_or_default(),
                        &facts.devices,
                    );
                    for (udid, receipt) in boots {
                        saved
                            .known
                            .entry(udid.to_ascii_uppercase())
                            .or_default()
                            .note_boot(receipt);
                    }
                    for lease in &facts.leases {
                        let entry = saved
                            .known
                            .entry(lease.device_id.to_ascii_uppercase())
                            .or_default();
                        entry.leased = true;
                        entry.last_used = facts.now;
                    }
                    policy::observe(&mut saved.known, &facts.devices, facts.now);
                    if reconcile {
                        policy::reconcile(&mut saved.known, &facts.devices);
                    }
                })?;
                s.reconciled = true;
                Ok((
                    s.gate.committed().known.clone(),
                    s.idle_since.clone(),
                    s.held_since.clone(),
                    keep,
                ))
            })
            .await?;
        // The policy is pure; it runs here, on what was just saved, asking T3
        // (the agents' published shell) about threads as it goes.
        let world = self.world.clone();
        let thread = move |id: &str| world.thread(id);
        let rows = plan(&Facts {
            now: snapshot.now,
            devices: &snapshot.devices,
            leases: &snapshot.leases,
            t3_sessions: &snapshot.sessions,
            known: &known,
            thread: &thread,
            activity_complete: complete,
            idle_since: &idle_since,
            reserved: &self.reserved,
            policy: self.policy,
            now_please,
            keep: &keep,
            held_since: &held_since,
        });
        let ids = |keep: fn(&Row) -> bool| -> Vec<String> {
            rows.iter()
                .filter(|r| keep(r))
                .map(|r| r.udid.clone())
                .collect()
        };
        let (free, held) = (ids(|r| r.free), ids(|r| r.hold));
        let seen_at = snapshot.now;
        self.owner
            .ask(move |s| {
                for (clock, ids) in [(&mut s.idle_since, free), (&mut s.held_since, held)] {
                    clock.retain(|udid, _| ids.contains(udid));
                    for udid in ids {
                        clock.entry(udid).or_insert(seen_at);
                    }
                }
            })
            .await;
        Ok(rows)
    }

    /// Runs one planned cleanup: reserves the simulator from the session
    /// owner, saves the intent, plans again on a fresh snapshot, and acts
    /// only if that still asks for it. Every outcome is saved.
    async fn act(&self, row: &Row, now_please: bool) -> Value {
        let report = |error: Option<String>| json!({"udid": row.udid, "name": row.name, "action": row.action, "why": row.why, "error": error});
        let Some(action) = row.action else {
            return report(None);
        };
        let Some(holds) = self.holds() else {
            return report(Some("no session owner to reserve it from".into()));
        };
        let Some(_exclusion) = holds.exclude(&row.udid).await else {
            return report(Some("a session took it meanwhile; left alone".into()));
        };
        let udid = row.udid.clone();
        let acting = |udid: String, acting: Option<Acting>| {
            move |saved: &mut Saved| {
                if let Some(entry) = saved.known.get_mut(&udid) {
                    entry.acting = acting;
                }
            }
        };
        if let Err(error) = self
            .change(acting(udid.clone(), Some(Acting { action, at: now() })))
            .await
        {
            return report(Some(format!("{error:#}")));
        }
        let fresh = match self.refresh(&holds.leases(), now_please).await {
            Ok(rows) => rows.into_iter().find(|r| r.udid == row.udid),
            Err(error) => {
                let _ = self.change(acting(udid, None)).await;
                return report(Some(format!("not revalidated, left alone: {error:#}")));
            }
        };
        if !policy::revalidate(action, fresh.as_ref()) {
            let _ = self.change(acting(udid, None)).await;
            let why = fresh.map(|r| r.why).unwrap_or_else(|| "it is gone".into());
            return report(Some(format!("no longer due ({why}); left alone")));
        }
        let result = match action {
            Action::Shutdown => self.simctl.shutdown(&row.udid).await,
            Action::Delete => self.simctl.delete(&row.udid).await,
        }
        .map_err(|e| format!("{e:#}"));
        let error = result.clone().err();
        let settled = udid.clone();
        if let Err(saved) = self
            .change(move |saved| policy::settle(&mut saved.known, &settled, action, result, now()))
            .await
        {
            eprintln!("{saved:#}");
        }
        if error.is_none() {
            self.owner
                .ask(move |s| {
                    s.idle_since.remove(&udid);
                    s.held_since.remove(&udid);
                })
                .await;
            // A working thread's idle hold: its T3 device session goes with it.
            if let (Action::Shutdown, "t3 session", Some(thread)) =
                (action, row.owner, row.thread.as_deref())
                && let Err(close) = self.world.close(thread, &row.udid).await
            {
                eprintln!(
                    "Simulator pool: {} shut down, but T3's device session not closed: {close:#}",
                    row.name
                );
            }
        }
        report(error)
    }

    async fn apply(&self, rows: &[Row], now_please: bool) -> Vec<Value> {
        let mut done = Vec::new();
        for row in rows.iter().filter(|r| r.action.is_some()) {
            done.push(self.act(row, now_please).await);
        }
        done
    }

    /// A session on `udid` ended and its cleanup asks what to do with the
    /// simulator. `others`: what other sessions reserve. The session's own
    /// reservation keeps starts off it meanwhile; its thread's own commands
    /// on it don't keep it.
    pub async fn release(&self, udid: &str, thread: &str, others: &[Lease]) -> Result<Released> {
        self.applying
            .run(async {
                let rows = self.refresh(others, false).await?;
                let Some(row) = rows.into_iter().find(|r| r.udid.eq_ignore_ascii_case(udid)) else {
                    return Ok(Released::NotBooted);
                };
                if !row.booted {
                    return Ok(Released::NotBooted);
                }
                let mine = row.free
                    || (row.owner == "agent outside a lease"
                        && row.thread.as_deref() == Some(thread));
                if !mine {
                    return Ok(Released::Kept { why: row.why });
                }
                let udid = row.udid;
                let intent = udid.clone();
                self.change(move |saved| {
                    if let Some(entry) = saved.known.get_mut(&intent) {
                        entry.acting = Some(Acting {
                            action: Action::Shutdown,
                            at: now(),
                        });
                    }
                })
                .await?;
                let result = self
                    .simctl
                    .shutdown(&udid)
                    .await
                    .map_err(|e| format!("{e:#}"));
                let (settled, outcome) = (udid.clone(), result.clone());
                self.change(move |saved| {
                    policy::settle(&mut saved.known, &settled, Action::Shutdown, outcome, now())
                })
                .await?;
                result.map_err(|e| anyhow!(e))?;
                self.owner
                    .ask(move |s| {
                        s.idle_since.remove(&udid);
                    })
                    .await;
                Ok(Released::ShutDown)
            })
            .await
    }

    /// Shuts down and deletes what the policy says (idle waits included).
    pub async fn tick(&self, leases: &[Lease]) -> Result<Vec<Value>> {
        self.applying
            .run(async {
                let rows = self.refresh(leases, false).await?;
                Ok(self.apply(&rows, false).await)
            })
            .await
    }

    /// `sim cleanup`: the policy without idle waits; `dry_run` only reports.
    pub async fn cleanup(&self, leases: &[Lease], dry_run: bool) -> Result<Value> {
        self.applying
            .run(async {
                let rows = self.refresh(leases, true).await?;
                let planned: Vec<&Row> = rows.iter().filter(|r| r.action.is_some()).collect();
                let kept: Vec<&Row> = rows
                    .iter()
                    .filter(|r| r.booted && r.action.is_none())
                    .collect();
                let done = if dry_run {
                    Value::Null
                } else {
                    Value::Array(self.apply(&rows, true).await)
                };
                Ok(json!({"dry_run": dry_run, "would": planned, "kept": kept, "done": done}))
            })
            .await
    }

    /// `sim prune`: deletes what the policy deletes now (shut-down devices
    /// unused for the stale age, agent-created ones unused for a day);
    /// `dry_run` only reports them and the space they would free.
    pub async fn prune(&self, leases: &[Lease], dry_run: bool) -> Result<Value> {
        self.applying
            .run(async {
                let rows: Vec<Row> = self
                    .refresh(leases, false)
                    .await?
                    .into_iter()
                    .filter(|r| r.action == Some(Action::Delete))
                    .collect();
                let bytes: u64 = rows.iter().map(|r| r.bytes).sum();
                let keep = self.keep_list().await?;
                let done = if dry_run {
                    Value::Null
                } else {
                    Value::Array(self.apply(&rows, false).await)
                };
                Ok(
                    json!({"dry_run": dry_run, "would_delete": rows, "count": rows.len(),
                          "bytes": bytes, "freed": gigabytes(bytes), "kept_by_owner": keep,
                          "stale_days": self.policy.stale_after / 86400.0, "done": done}),
                )
            })
            .await
    }

    /// Every booted simulator with its owner, for `sim status`.
    pub async fn status(&self, leases: &[Lease]) -> Result<Value> {
        let rows = self.refresh(leases, false).await?;
        let cpu = self.simctl.cpu().await;
        let booted: Vec<Value> = rows
            .iter()
            .filter(|r| r.booted)
            .map(|r| {
                let mut value = serde_json::to_value(r).unwrap_or_default();
                value["apps_cpu_percent"] = json!(cpu.get(&r.udid).map(|c| c.round()));
                if let Some(title) = r.thread.as_deref().and_then(|t| self.world.title(t)) {
                    value["thread_title"] = json!(title);
                }
                value
            })
            .collect();
        Ok(
            json!({"booted": booted, "max_leases": self.policy.max_leases, "idle_minutes": self.policy.idle / 60.0,
                   "host_health": *self.health()}),
        )
    }

    /// This Mac's iOS simulators, as simctl lists them now.
    pub async fn devices(&self) -> Result<Vec<Device>> {
        self.simctl.devices().await
    }

    /// T3's open device sessions: (thread, device).
    pub async fn t3_sessions(&self) -> Result<Vec<(String, String)>> {
        self.world.t3_sessions().await
    }

    /// Applies the policy every minute until the service stops. simctl
    /// tells nobody when a simulator boots, shuts down or is last used, so
    /// the policy looks at its inventory at the cadence it promises.
    pub async fn run(self: Arc<Self>, sims: Arc<crate::sims::Sims>) {
        loop {
            crate::clock::after(Duration::from_secs(60)).await;
            match self.tick(&sims.leases()).await {
                Ok(done) => {
                    for item in done {
                        eprintln!(
                            "Simulator pool: {} {} ({}){}",
                            item["action"],
                            item["name"],
                            item["why"],
                            item["error"]
                                .as_str()
                                .map(|e| format!(": {e}"))
                                .unwrap_or_default()
                        );
                    }
                }
                Err(error) => eprintln!("Simulator pool not applied: {error:#}"),
            }
        }
    }
}

/// `12.3 GB`.
pub fn gigabytes(bytes: u64) -> String {
    format!("{:.1} GB", bytes as f64 / 1e9)
}

/// The model a created simulator gets, from `simctl list runtimes -j`:
/// the newest numbered iPhone Pro (not Max) on the newest available iOS
/// runtime that has one, else that runtime's first iPhone. Returns its
/// device type and runtime identifiers and its name.
pub fn default_model(runtimes: &Value) -> Option<(String, String, String)> {
    let version = |r: &Value| -> Vec<u64> {
        r["version"]
            .as_str()
            .unwrap_or("")
            .split('.')
            .map(|p| p.parse().unwrap_or(0))
            .collect()
    };
    let mut ios: Vec<&Value> = runtimes["runtimes"]
        .as_array()?
        .iter()
        .filter(|r| r["platform"] == "iOS" && r["isAvailable"] == true)
        .collect();
    ios.sort_by_key(|r| std::cmp::Reverse(version(r)));
    let types = |r: &&Value| -> Vec<(String, String)> {
        r["supportedDeviceTypes"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|t| t["productFamily"] == "iPhone")
            .filter_map(|t| Some((t["identifier"].as_str()?.into(), t["name"].as_str()?.into())))
            .collect()
    };
    let generation = |name: &str| -> Option<u64> {
        name.strip_prefix("iPhone ")?
            .strip_suffix(" Pro")?
            .parse()
            .ok()
    };
    let pick = |r: &&Value, best: bool| {
        let types = types(r);
        let chosen = if best {
            types
                .into_iter()
                .filter_map(|t| Some((generation(&t.1)?, t)))
                .max_by_key(|(n, _)| *n)
                .map(|(_, t)| t)
        } else {
            types.into_iter().next()
        };
        chosen.map(|(kind, name)| {
            (
                kind,
                r["identifier"].as_str().unwrap_or("").to_string(),
                name,
            )
        })
    };
    ios.iter()
        .find_map(|r| pick(r, true))
        .or_else(|| ios.iter().find_map(|r| pick(r, false)))
        .filter(|(_, runtime, _)| !runtime.is_empty())
}

/// The real simctl and ps.
pub struct Xcrun;

/// simctl's answer; dropping this (its caller is gone) stops it.
async fn simctl(args: &[&str]) -> Result<Vec<u8>> {
    let output = Command::new("xcrun")
        .arg("simctl")
        .args(args)
        .stdin(Stdio::null())
        .kill_on_drop(true)
        .output()
        .await
        .context("Cannot run xcrun simctl")?;
    ensure!(
        output.status.success(),
        "simctl {} failed: {}",
        args.join(" "),
        String::from_utf8_lossy(&output.stderr).trim()
    );
    Ok(output.stdout)
}

impl Simctl for Xcrun {
    fn devices(&self) -> Pending<'_, Result<Vec<Device>>> {
        Box::pin(async {
            let list: Value = serde_json::from_slice(&simctl(&["list", "devices", "-j"]).await?)
                .context("simctl list output")?;
            let mut devices = Vec::new();
            for (runtime, entries) in list["devices"].as_object().into_iter().flatten() {
                if !runtime.contains("SimRuntime.iOS") {
                    continue;
                }
                for d in entries.as_array().into_iter().flatten() {
                    let Some(udid) = d["udid"].as_str() else {
                        continue;
                    };
                    let plist = d["dataPath"]
                        .as_str()
                        .map(|p| Path::new(p).with_file_name("device.plist"));
                    let changed_at = plist
                        .and_then(|p| p.metadata().ok()?.modified().ok())
                        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                        .map_or(0.0, |d| d.as_secs_f64());
                    let size = |key: &str| d[key].as_u64().unwrap_or(0);
                    devices.push(Device {
                        udid: udid.to_ascii_uppercase(),
                        name: d["name"].as_str().unwrap_or("").into(),
                        state: d["state"].as_str().unwrap_or("").into(),
                        changed_at,
                        last_booted: d["lastUsedAt"]
                            .as_str()
                            .and_then(crate::t3::iso_parse)
                            .unwrap_or(0.0),
                        bytes: size("dataPathSize") + size("logPathSize"),
                    });
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

    fn create(&self) -> Pending<'_, Result<(String, String)>> {
        Box::pin(async {
            let runtimes: Value =
                serde_json::from_slice(&simctl(&["list", "runtimes", "-j"]).await?)
                    .context("simctl list runtimes output")?;
            let (kind, runtime, model) = default_model(&runtimes)
                .context("No iOS simulator runtime with an iPhone is installed; add one in Xcode's Components settings")?;
            let taken: Vec<String> = self.devices().await?.into_iter().map(|d| d.name).collect();
            let base = format!("Squircle {model}");
            let name = std::iter::once(base.clone())
                .chain((2..).map(|n| format!("{base} {n}")))
                .find(|n| !taken.contains(n))
                .unwrap_or(base);
            let out = simctl(&["create", &name, &kind, &runtime]).await?;
            let udid = uuids(&String::from_utf8_lossy(&out))
                .pop()
                .context("simctl create printed no UDID")?;
            // T3's device hub lists only simulators that have booted once.
            simctl(&["boot", &udid]).await?;
            Ok((udid, name))
        })
    }

    fn cpu(&self) -> Pending<'_, HashMap<String, f64>> {
        Box::pin(cpu())
    }
}

/// Each simulator's processes' summed CPU (%), by UDID, from `ps`.
async fn cpu() -> HashMap<String, f64> {
    let mut cpu = HashMap::new();
    let Ok(output) = Command::new("/bin/ps")
        .args(["-axww", "-o", "pcpu=,command="])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .output()
        .await
    else {
        return cpu;
    };
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let line = line.trim_start();
        let Some((percent, command)) = line.split_once(' ') else {
            continue;
        };
        let Some(after) = command.split("/CoreSimulator/Devices/").nth(1) else {
            continue;
        };
        if let (Some(udid), Ok(percent)) = (
            uuids(&after[..after.len().min(UUID_LEN)]).pop(),
            percent.parse::<f64>(),
        ) {
            *cpu.entry(udid).or_default() += percent;
        }
    }
    cpu
}

struct T3World(Arc<crate::agents::Agents>);

impl World for T3World {
    fn t3_sessions(&self) -> Pending<'_, Result<Vec<(String, String)>>> {
        Box::pin(async {
            // T3's cached state: sessions are its own, and unlike
            // `device.list` this doesn't make it re-list every host.
            let list = self
                .0
                .connection()
                .await?
                .snapshot("subscribeDeviceState", json!({}))
                .await?;
            Ok(list["sessions"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|s| {
                    Some((
                        s["threadId"].as_str()?.to_string(),
                        s["deviceId"].as_str()?.to_ascii_uppercase(),
                    ))
                })
                .collect())
        })
    }

    fn thread(&self, id: &str) -> ThreadInfo {
        ThreadInfo {
            seen: crate::sims::seen(&self.0, id),
            squircle: self.0.is_squircle_thread(id),
        }
    }

    fn title(&self, id: &str) -> Option<String> {
        self.0
            .worker_title(id)
            .or_else(|| self.0.thread_row(id)?["title"].as_str().map(str::to_string))
    }

    fn activity<'a>(&'a self, since: &'a str) -> Pending<'a, Result<Vec<Activity>>> {
        Box::pin(crate::t3steps::simulator_commands(since))
    }

    fn close<'a>(&'a self, thread: &'a str, device: &'a str) -> Pending<'a, Result<()>> {
        Box::pin(async move {
            self.0
                .connection()
                .await?
                .call(
                    "device.close",
                    json!({"threadId": thread, "hostId": "local", "deviceId": device, "platform": "ios"}),
                )
                .await
                .map(drop)
        })
    }
}

#[cfg(test)]
// Fakes record calls behind leaf locks; never held across a call.
#[allow(clippy::disallowed_types)]
mod tests {
    use super::*;
    use crate::fsm::sims::Seen;
    use std::sync::Mutex;

    const POLICY: Policy = Policy {
        max_leases: 3,
        idle: 600.0,
        delete_after: 24.0 * 3600.0,
        stale_after: 14.0 * 24.0 * 3600.0,
        hold_idle: 1800.0,
    };

    fn device(udid: &str, state: &str) -> Device {
        Device {
            udid: udid.into(),
            name: format!("sim {udid}"),
            state: state.into(),
            changed_at: 0.0,
            last_booted: 0.0,
            bytes: 0,
        }
    }

    #[test]
    fn agent_simulator_commands() {
        let created =
            "S=$(xcrun simctl create \"simsmooth-scratch\" $T $R) && xcrun simctl boot $S; echo $S";
        assert_eq!(
            parse_use(created, "5c5214a2-39cf-4937-b0cf-94764a34ea09\n"),
            Use {
                created: vec!["5C5214A2-39CF-4937-B0CF-94764A34EA09".into()],
                created_names: vec!["simsmooth-scratch".into()],
                ..Use::default()
            }
        );
        let used = "xcrun simctl boot 'iPhone 18 Pro Max'; xcrun simctl install 389DF2C3-2656-40AD-830A-A8A90667D730 /tmp/A.app \
                    && xcodebuild test -scheme S -destination 'platform=iOS Simulator,id=DFDF12FB-5C70-4B39-B85C-D5D82D6AB5F7'";
        assert_eq!(
            parse_use(used, "1F0C7E5A-0000-4000-8000-000000000000"),
            Use {
                touched: vec![
                    "389DF2C3-2656-40AD-830A-A8A90667D730".into(),
                    "DFDF12FB-5C70-4B39-B85C-D5D82D6AB5F7".into()
                ],
                booted_names: vec!["iPhone 18 Pro Max".into()],
                touched_names: vec!["iPhone 18 Pro Max".into()],
                ..Use::default()
            }
        );
        // Booting a booted device boots nothing.
        let again = parse_use(
            "xcrun simctl boot 389DF2C3-2656-40AD-830A-A8A90667D730",
            "An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405):\nUnable to boot device in current state: Booted",
        );
        assert!(again.booted.is_empty() && again.touched.len() == 1);
        // Driving it with T3's agent-device is a use.
        assert_eq!(
            parse_use(
                "~/.t3/userdata/device/bin/agent-device tap 10 20 --platform ios --udid 389df2c3-2656-40ad-830a-a8a90667d730 --session t3-x",
                ""
            )
            .touched,
            ["389DF2C3-2656-40AD-830A-A8A90667D730"]
        );
        // Listing, reading or recording is not a use; nor is the literal "booted".
        assert_eq!(
            parse_use(
                "xcrun simctl list devices; xcrun simctl io booted screenshot /tmp/a.png; simctl boot booted",
                "x"
            ),
            Use::default()
        );
    }

    /// A created simulator: the newest iPhone Pro on the newest iOS that
    /// has one (a newer runtime with only an odd model is passed over).
    #[test]
    fn created_simulators_default_model() {
        let iphone = |n: &str| json!({"name": n, "identifier": format!("type.{n}"), "productFamily": "iPhone"});
        let runtimes = json!({"runtimes": [
            {"identifier": "ios-26-4", "version": "26.4", "platform": "iOS", "isAvailable": true,
             "supportedDeviceTypes": [iphone("iPhone 17 Pro")]},
            {"identifier": "ios-27-0", "version": "27.0", "platform": "iOS", "isAvailable": true,
             "supportedDeviceTypes": [iphone("iPhone 17 Pro"), iphone("iPhone 18 Pro Max"), iphone("iPhone 18 Pro"), iphone("iPhone Air")]},
            {"identifier": "ios-27-1", "version": "27.1", "platform": "iOS", "isAvailable": true,
             "supportedDeviceTypes": [iphone("iPhone Duo")]},
            {"identifier": "ios-28-0", "version": "28.0", "platform": "iOS", "isAvailable": false,
             "supportedDeviceTypes": [iphone("iPhone 19 Pro")]},
            {"identifier": "watch", "version": "30.0", "platform": "watchOS", "isAvailable": true,
             "supportedDeviceTypes": [iphone("iPhone 20 Pro")]}]});
        assert_eq!(
            default_model(&runtimes),
            Some((
                "type.iPhone 18 Pro".into(),
                "ios-27-0".into(),
                "iPhone 18 Pro".into()
            ))
        );
        let odd = json!({"runtimes": [{"identifier": "ios-27-1", "version": "27.1", "platform": "iOS",
            "isAvailable": true, "supportedDeviceTypes": [iphone("iPhone Duo")]}]});
        assert_eq!(default_model(&odd).unwrap().2, "iPhone Duo");
        assert_eq!(default_model(&json!({"runtimes": []})), None);
    }

    #[derive(Default)]
    struct Fake {
        devices: Mutex<Vec<Device>>,
        calls: Mutex<Vec<String>>,
        /// T3 device sessions, changed by the next `devices` call (a race).
        sessions: Mutex<Vec<(String, String)>>,
        late_session: Mutex<Option<(String, String)>>,
    }

    impl Simctl for Fake {
        fn devices(&self) -> Pending<'_, Result<Vec<Device>>> {
            let devices = self.devices.lock().unwrap().clone();
            Box::pin(async move { Ok(devices) })
        }
        fn shutdown<'a>(&'a self, udid: &'a str) -> Pending<'a, Result<()>> {
            self.calls.lock().unwrap().push(format!("shutdown {udid}"));
            for d in self
                .devices
                .lock()
                .unwrap()
                .iter_mut()
                .filter(|d| d.udid == udid)
            {
                d.state = "Shutdown".into()
            }
            Box::pin(async { Ok(()) })
        }
        fn delete<'a>(&'a self, udid: &'a str) -> Pending<'a, Result<()>> {
            self.calls.lock().unwrap().push(format!("delete {udid}"));
            Box::pin(async { Ok(()) })
        }
        fn create(&self) -> Pending<'_, Result<(String, String)>> {
            Box::pin(async { Err(anyhow!("not in these tests")) })
        }
        fn cpu(&self) -> Pending<'_, HashMap<String, f64>> {
            Box::pin(async { HashMap::new() })
        }
    }

    struct Quiet(Arc<Fake>);
    impl World for Quiet {
        fn t3_sessions(&self) -> Pending<'_, Result<Vec<(String, String)>>> {
            let sessions = self.0.sessions.lock().unwrap().clone();
            if let Some(late) = self.0.late_session.lock().unwrap().take() {
                self.0.sessions.lock().unwrap().push(late);
            }
            Box::pin(async move { Ok(sessions) })
        }
        fn thread(&self, id: &str) -> ThreadInfo {
            ThreadInfo {
                seen: if id == "user" {
                    Seen::Idle { turn: None }
                } else {
                    Seen::Gone
                },
                squircle: id != "user",
            }
        }
        fn title(&self, _: &str) -> Option<String> {
            None
        }
        fn close<'a>(&'a self, _: &'a str, _: &'a str) -> Pending<'a, Result<()>> {
            Box::pin(async { Ok(()) })
        }
        fn activity<'a>(&'a self, since: &'a str) -> Pending<'a, Result<Vec<Activity>>> {
            let rows = if since.is_empty() {
                vec![Activity {
                    thread: "w".into(),
                    created_at: "2026-10-14T20:00:00.000Z".into(),
                    command: "xcrun simctl boot AAAAAAAA-0000-4000-8000-000000000000".into(),
                    output: String::new(),
                }]
            } else {
                vec![]
            };
            Box::pin(async move { Ok(rows) })
        }
    }

    /// The session owner's view: reservations, boots, and exclusions it grants.
    #[derive(Default)]
    struct Sessions {
        leases: Mutex<Vec<Lease>>,
        boots: Mutex<Vec<(String, BootReceipt)>>,
        excluded: Arc<Mutex<Vec<String>>>,
    }

    impl Holds for Sessions {
        fn leases(&self) -> Vec<Lease> {
            self.leases.lock().unwrap().clone()
        }
        fn boots(&self) -> Vec<(String, BootReceipt)> {
            self.boots.lock().unwrap().clone()
        }
        fn exclude<'a>(&'a self, udid: &'a str) -> Pending<'a, Option<Exclusion>> {
            let excluded = (!self
                .leases
                .lock()
                .unwrap()
                .iter()
                .any(|l| l.device_id == udid))
            .then(|| {
                self.excluded.lock().unwrap().push(udid.into());
                let excluded = self.excluded.clone();
                let udid = udid.to_string();
                Exclusion::new(move || excluded.lock().unwrap().retain(|d| *d != udid))
            });
            Box::pin(async move { excluded })
        }
    }

    const ADHOC: &str = "AAAAAAAA-0000-4000-8000-000000000000";
    const LEASED: &str = "BBBBBBBB-0000-4000-8000-000000000000";
    const USER: &str = "CCCCCCCC-0000-4000-8000-000000000000";

    fn pool(dir: &Path, fake: &Arc<Fake>, owner: &Arc<Sessions>) -> Arc<Pool> {
        let pool = Pool::with(
            dir,
            fake.clone(),
            Arc::new(Quiet(fake.clone())),
            POLICY,
            vec![],
        )
        .unwrap();
        let holds: Arc<dyn Holds> = owner.clone();
        pool.attach(Arc::downgrade(&holds));
        pool
    }

    /// A dry run touches nothing; a session's simulator stops when its
    /// release asks, but only if its boot is proven; the user's own booted
    /// simulator is never stopped; provenance survives a restart.
    #[tokio::test]
    async fn cleanup_and_release_apply_the_plan() {
        let dir = tempfile::tempdir().unwrap();
        let fake = Arc::new(Fake::default());
        *fake.devices.lock().unwrap() = vec![
            device(ADHOC, "Booted"),
            device(LEASED, "Booted"),
            device(USER, "Booted"),
        ];
        let owner = Arc::new(Sessions::default());
        *owner.leases.lock().unwrap() = vec![Lease {
            device_id: LEASED.into(),
            thread_id: "w2".into(),
        }];
        let pool = pool(dir.path(), &fake, &owner);

        let report = pool.cleanup(&owner.leases(), true).await.unwrap();
        assert_eq!(report["would"].as_array().unwrap().len(), 1);
        assert!(fake.calls.lock().unwrap().is_empty());

        // Leased but not booted by the session: the user's, kept.
        owner.leases.lock().unwrap().clear();
        assert!(matches!(
            pool.release(USER, "w2", &[]).await.unwrap(),
            Released::Kept { .. }
        ));
        *owner.boots.lock().unwrap() = vec![(
            LEASED.into(),
            BootReceipt {
                at: now(),
                thread: None,
                session: Some("s".into()),
            },
        )];
        assert_eq!(
            pool.release(LEASED, "w2", &[]).await.unwrap(),
            Released::ShutDown
        );
        assert_eq!(*fake.calls.lock().unwrap(), [format!("shutdown {LEASED}")]);
        // Within the idle time the ad-hoc one stays; cleanup takes it now.
        pool.tick(&[]).await.unwrap();
        assert_eq!(fake.calls.lock().unwrap().len(), 1);
        let reopened = super::tests::pool(dir.path(), &fake, &owner);
        reopened.cleanup(&[], false).await.unwrap();
        assert_eq!(
            *fake.calls.lock().unwrap(),
            [format!("shutdown {LEASED}"), format!("shutdown {ADHOC}")]
        );
        assert!(
            owner.excluded.lock().unwrap().is_empty(),
            "an exclusion outlived its cleanup"
        );
    }

    /// A cleanup is saved before it runs and revalidated right before:
    /// a session reserving the simulator or the user's T3 session appearing
    /// meanwhile stops it; one a crash left unanswered is settled by the next
    /// run's inventory, not assumed done.
    #[tokio::test]
    async fn stale_eligibility_never_executes() {
        let dir = tempfile::tempdir().unwrap();
        let fake = Arc::new(Fake::default());
        *fake.devices.lock().unwrap() = vec![device(ADHOC, "Booted")];
        let owner = Arc::new(Sessions::default());
        let pool = pool(dir.path(), &fake, &owner);
        // The user opens it in T3 between the plan and the shutdown.
        *fake.late_session.lock().unwrap() = Some(("user".into(), ADHOC.into()));
        let report = pool.cleanup(&[], false).await.unwrap();
        assert!(fake.calls.lock().unwrap().is_empty(), "{report}");
        assert!(
            report["done"][0]["error"]
                .as_str()
                .unwrap()
                .contains("no longer due")
        );
        fake.sessions.lock().unwrap().clear();
        // A session reserves it: no exclusion, no action.
        *owner.leases.lock().unwrap() = vec![Lease {
            device_id: ADHOC.into(),
            thread_id: "w".into(),
        }];
        let rows = pool.refresh(&[], true).await.unwrap();
        assert!(
            pool.apply(&rows, true).await[0]["error"]
                .as_str()
                .unwrap()
                .contains("took it")
        );
        assert!(fake.calls.lock().unwrap().is_empty());

        // A crash after the intent was saved: the next run reads the
        // inventory before deciding anything, and nothing is assumed done.
        owner.leases.lock().unwrap().clear();
        pool.change(|saved| {
            saved.known.get_mut(ADHOC).unwrap().acting = Some(Acting {
                action: Action::Shutdown,
                at: 1.0,
            })
        })
        .await
        .unwrap();
        drop(pool);
        let reopened = super::tests::pool(dir.path(), &fake, &owner);
        let rows = reopened.refresh(&[], true).await.unwrap();
        assert!(
            reopened
                .owner
                .ask(|s| s.gate.committed().known[ADHOC].acting.is_none())
                .await
        );
        assert_eq!(rows[0].action, Some(Action::Shutdown));
    }
}
