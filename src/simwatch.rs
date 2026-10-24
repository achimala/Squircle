//! What the pool's policy can't see from simctl's device list: an app inside
//! a simulator burning a core for good, and the simulator host itself
//! failing (2026-10-19, owner-requested, after an app hot-looped a core for
//! hours and SimRenderServer crashed until every `simctl launch` hung).
//!
//! Every minute the watch samples each simulator app's CPU time (`ps`): an
//! app above `HOT` of a core over every interval for `RUNAWAY` is killed,
//! noted in the simulator's session and told to the thread using it.
//! Every ten minutes, and before a simulator start, it checks the host:
//! SimRenderServer crash reports, and a probe of a booted simulator of
//! Squircle's that must answer within `PROBE_DEADLINE`. A failing host is
//! told to the app agent of each app with a simulator session (else straight
//! to the phone) with the fix; starts are refused until it is fixed. The
//! service never kills system processes itself.
//!
//! The watch's state lives in its one loop task: nothing else reads it but
//! the health it publishes through the pool.

use crate::agents::{Agents, Note};
use crate::simpool::{Pool, Row};
use crate::sims::Sims;
use anyhow::{Context, Result};
use serde::Serialize;
use serde_json::json;
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    process::Stdio,
    sync::Arc,
    time::{Duration, UNIX_EPOCH},
};
use tokio::process::Command;

/// Share of one core an app must use over every interval to count as hot.
pub const HOT: f64 = 0.9;
/// How long an app must stay hot without a break before it is killed.
pub const RUNAWAY: f64 = 20.0 * 60.0;
/// Samples further apart than this (the Mac slept, the service paused)
/// prove nothing about the time between: the app's clock starts again.
pub const MAX_GAP: f64 = 3.0 * 60.0;
const SAMPLE: Duration = Duration::from_secs(60);
const CHECK_EVERY: f64 = 10.0 * 60.0;
/// SimRenderServer crashing this often within `CRASH_WINDOW` is a crash loop.
const CRASHES: usize = 3;
const CRASH_WINDOW: f64 = 30.0 * 60.0;
/// A healthy simulator answers a launch or screenshot in a few seconds;
/// past this it is stuck, which is what the check looks for.
const PROBE_DEADLINE: Duration = Duration::from_secs(60);

use crate::clock::now;

// MARK: Runaway apps

/// One app process inside a simulator, as `ps` lists it.
#[derive(Clone, Debug, PartialEq)]
pub struct Proc {
    pub pid: u32,
    /// CPU time used so far, in seconds.
    pub cpu: f64,
    pub command: String,
    pub udid: String,
}

impl Proc {
    /// The app's name: its executable.
    pub fn app(&self) -> &str {
        self.command
            .split("/Bundle/Application/")
            .nth(1)
            .and_then(|rest| rest.split_once('/'))
            .and_then(|(_, bundle)| bundle.split_once(".app/"))
            .map_or(&self.command, |(name, _)| name)
    }
}

/// `ps`'s cumulative CPU time: `[days-][hours:]minutes:seconds.fraction`.
fn cpu_seconds(text: &str) -> Option<f64> {
    let (days, clock) = match text.split_once('-') {
        Some((d, rest)) => (d.parse::<f64>().ok()?, rest),
        None => (0.0, text),
    };
    let mut total = 0.0;
    for part in clock.split(':') {
        total = total * 60.0 + part.parse::<f64>().ok()?;
    }
    Some(days * 86400.0 + total)
}

/// Apps installed in a simulator (`…/CoreSimulator/Devices/UDID/data/
/// Containers/Bundle/Application/…`) from `ps -o pid=,time=,command=`; the
/// simulator's own system processes run from its runtime and aren't listed.
pub fn parse_ps(text: &str) -> Vec<Proc> {
    text.lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let pid = fields.next()?.parse().ok()?;
            let cpu = cpu_seconds(fields.next()?)?;
            let command = line
                .trim_start()
                .splitn(3, char::is_whitespace)
                .nth(2)?
                .trim_start()
                .to_string();
            let after = command.split("/CoreSimulator/Devices/").nth(1)?;
            let (udid, path) = after.split_once('/')?;
            if !path.starts_with("data/Containers/Bundle/Application/")
                || uuid::Uuid::parse_str(udid).is_err()
            {
                return None;
            }
            Some(Proc {
                pid,
                cpu,
                udid: udid.to_ascii_uppercase(),
                command,
            })
        })
        .collect()
}

struct Track {
    command: String,
    cpu: f64,
    at: f64,
    /// Hot over every interval since then.
    hot_since: Option<f64>,
}

/// Which apps have been hot without a break, from successive samples.
#[derive(Default)]
pub struct Runaways {
    tracks: HashMap<u32, Track>,
}

impl Runaways {
    /// Folds in a sample taken at `now`; returns the apps hot for `RUNAWAY`.
    /// A process is the same one only with the same command line and a CPU
    /// time that hasn't gone back (a reused PID is a new process).
    pub fn sample(&mut self, now: f64, procs: &[Proc]) -> Vec<Proc> {
        let mut tracks = HashMap::new();
        let mut runaway = Vec::new();
        for proc in procs {
            let hot_since = self.tracks.get(&proc.pid).and_then(|before| {
                let span = now - before.at;
                let same = before.command == proc.command && proc.cpu >= before.cpu;
                let hot =
                    same && span > 0.0 && span <= MAX_GAP && (proc.cpu - before.cpu) / span >= HOT;
                hot.then(|| before.hot_since.unwrap_or(before.at))
            });
            if hot_since.is_some_and(|since| now - since >= RUNAWAY) {
                runaway.push(proc.clone());
            }
            tracks.insert(
                proc.pid,
                Track {
                    command: proc.command.clone(),
                    cpu: proc.cpu,
                    at: now,
                    hot_since,
                },
            );
        }
        self.tracks = tracks;
        runaway
    }
}

async fn ps(args: &[&str]) -> Result<String> {
    let output = Command::new("/bin/ps")
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .output()
        .await
        .context("Cannot run ps")?;
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Kills `proc` if that PID is still the same process.
async fn kill(proc: &Proc) -> Result<()> {
    let now = ps(&[
        "-ww",
        "-o",
        "pid=,time=,command=",
        "-p",
        &proc.pid.to_string(),
    ])
    .await?;
    let current = parse_ps(&now);
    anyhow::ensure!(
        current
            .first()
            .is_some_and(|c| c.command == proc.command && c.cpu >= proc.cpu),
        "it has already exited"
    );
    anyhow::ensure!(
        unsafe { libc::kill(proc.pid as i32, libc::SIGKILL) } == 0,
        "{}",
        std::io::Error::last_os_error()
    );
    Ok(())
}

// MARK: Host health

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Health {
    /// When the host was last checked (0: not yet).
    pub checked_at: f64,
    /// What is wrong, if anything.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub problem: Option<Problem>,
    /// What the probe did, for `sim status`.
    pub probe: String,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Problem {
    pub what: String,
    pub fix: String,
}

impl Problem {
    pub fn text(&self) -> String {
        format!("{} Fix: {}", self.what, self.fix)
    }
}

/// What the probe found.
#[derive(Clone, Debug, PartialEq)]
pub enum Probe {
    /// No booted simulator of Squircle's to try.
    Skipped,
    Answered {
        device: String,
        what: &'static str,
    },
    /// simctl answered with an error: reported, not judged (the simulator
    /// may have been shutting down).
    Failed {
        device: String,
        error: String,
    },
    /// simctl didn't answer within the deadline.
    Hung {
        device: String,
        what: &'static str,
    },
}

const FIX: &str = "run `killall -9 SimRenderServer` on the Mac (macOS starts it again); if simulators still hang, reboot the Mac.";

/// Whether the host is failing, from SimRenderServer's crash times and the probe.
pub fn judge(crashes: &[f64], now: f64, probe: &Probe) -> Option<Problem> {
    if let Probe::Hung { device, what } = probe {
        return Some(Problem {
            what: format!(
                "Simulators on this Mac are stuck: a {what} on {device} got no answer in {} s, so app launches hang for every simulator.",
                PROBE_DEADLINE.as_secs()
            ),
            fix: FIX.into(),
        });
    }
    let recent = crashes
        .iter()
        .filter(|at| now - **at <= CRASH_WINDOW)
        .count();
    (recent >= CRASHES).then(|| Problem {
        what: format!(
            "SimRenderServer, which draws every simulator's screen, crashed {recent} times in the last {} minutes; simulator launches will hang or fail.",
            (CRASH_WINDOW / 60.0) as u64
        ),
        fix: FIX.into(),
    })
}

/// When each SimRenderServer crash report was written.
fn crash_times(dir: &Path) -> Vec<f64> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return vec![];
    };
    entries
        .flatten()
        .filter(|e| {
            e.file_name()
                .to_string_lossy()
                .starts_with("SimRenderServer")
        })
        .filter_map(|e| e.metadata().ok()?.modified().ok())
        .filter_map(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs_f64())
        .collect()
}

fn reports_dir() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_default()
        .join("Library/Logs/DiagnosticReports")
}

/// Runs simctl with the probe's deadline: None if it didn't answer.
async fn simctl_within(args: &[&str]) -> Option<Result<(), String>> {
    let output = Command::new("xcrun")
        .arg("simctl")
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .output();
    // The policy's hang rule: an answer past the deadline is a stuck host.
    let answered = tokio::select! {
        output = output => output,
        () = crate::clock::after(PROBE_DEADLINE) => return None,
    };
    match answered {
        Err(error) => Some(Err(error.to_string())),
        Ok(output) if output.status.success() => Some(Ok(())),
        Ok(output) => Some(Err(String::from_utf8_lossy(&output.stderr)
            .trim()
            .to_string())),
    }
}

/// Probes one booted simulator of Squircle's. A free one gets an app
/// launch (Settings), the call that hung; one a session is using gets a
/// screenshot instead, which goes through the same CoreSimulator service
/// and renderer without taking the screen from the agent's app.
async fn probe(rows: &[Row]) -> Probe {
    let free = rows.iter().find(|r| r.booted && r.free);
    let leased = rows.iter().find(|r| r.booted && r.owner == "lease");
    let (row, what) = match (free, leased) {
        (Some(row), _) => (row, "launch"),
        (None, Some(row)) => (row, "screenshot"),
        (None, None) => return Probe::Skipped,
    };
    let shot = std::env::temp_dir().join(format!("squircle-probe-{}.png", std::process::id()));
    let answer = if what == "launch" {
        let launched = simctl_within(&[
            "launch",
            "--terminate-running-process",
            &row.udid,
            "com.apple.Preferences",
        ])
        .await;
        if matches!(launched, Some(Ok(()))) {
            let _ = simctl_within(&["terminate", &row.udid, "com.apple.Preferences"]).await;
        }
        launched
    } else {
        let shot = shot.to_string_lossy();
        simctl_within(&["io", &row.udid, "screenshot", &shot]).await
    };
    let _ = std::fs::remove_file(&shot);
    let device = row.name.clone();
    match answer {
        None => Probe::Hung { device, what },
        Some(Ok(())) => Probe::Answered { device, what },
        Some(Err(error)) => Probe::Failed { device, error },
    }
}

/// Checks the host now: crash reports and, with the pool's rows, a probe.
pub async fn check(rows: &[Row]) -> Health {
    let probe = probe(rows).await;
    let at = now();
    Health {
        checked_at: at,
        problem: judge(&crash_times(&reports_dir()), at, &probe),
        probe: match &probe {
            Probe::Skipped => "no booted simulator of Squircle's to probe".into(),
            Probe::Answered { device, what } => format!("{what} on {device} answered"),
            Probe::Failed { device, error } => format!("probe on {device} failed: {error}"),
            Probe::Hung { device, what } => format!("{what} on {device} hung"),
        },
    }
}

/// Before a simulator start: why it can't work, if the host is failing.
/// A failing host is checked again first, so a fix takes effect at once;
/// a healthy one only has its crash reports read again.
pub async fn before_start(pool: &Pool, leases: &[crate::simpool::Lease]) -> Option<String> {
    let last = pool.health();
    let health = if last.problem.is_some() {
        let rows = pool.refresh(leases, false).await.unwrap_or_default();
        let health = check(&rows).await;
        pool.set_health(health.clone());
        health
    } else {
        let at = now();
        Health {
            problem: judge(&crash_times(&reports_dir()), at, &Probe::Skipped),
            ..(*last).clone()
        }
    };
    health.problem.map(|p| {
        format!(
            "Simulators can't start on this Mac right now. {} Tell the user; ask before running the fix yourself.",
            p.text()
        )
    })
}

// MARK: The loop

pub struct Watch {
    pub pool: Arc<Pool>,
    pub sims: Arc<Sims>,
    pub agents: Arc<Agents>,
}

impl Watch {
    /// Samples every minute and checks the host every ten, until the service stops.
    pub async fn run(self) {
        let mut runaways = Runaways::default();
        let mut checked = 0.0;
        loop {
            // CPU use has no event: the runaway rule is judged on samples.
            crate::clock::after(SAMPLE).await;
            match ps(&["-axww", "-o", "pid=,time=,command="]).await {
                Ok(text) => {
                    for proc in runaways.sample(now(), &parse_ps(&text)) {
                        self.stop_runaway(&proc).await;
                    }
                }
                Err(error) => eprintln!("Simulator watch: {error:#}"),
            }
            if now() - checked >= CHECK_EVERY {
                checked = now();
                self.check_host().await;
            }
        }
    }

    async fn stop_runaway(&self, proc: &Proc) {
        let name = self
            .pool
            .devices()
            .await
            .ok()
            .and_then(|d| d.into_iter().find(|d| d.udid == proc.udid))
            .map_or_else(|| "a simulator".to_string(), |d| d.name);
        if let Err(error) = kill(proc).await {
            eprintln!(
                "Simulator watch: {} on {name} not stopped: {error:#}",
                proc.app()
            );
            return;
        }
        let what = format!(
            "Squircle stopped {} on {name}: it used over {}% of a CPU core for {} minutes straight, which usually means a busy loop or an animation that never settles.",
            proc.app(),
            (HOT * 100.0) as u32,
            (RUNAWAY / 60.0) as u32
        );
        eprintln!("Simulator watch: {what}");
        // The session using the simulator, else a Squircle thread with it open in T3.
        let thread = match self.sims.note(&proc.udid, what.clone()).await {
            Some(thread) => Some(thread),
            None => self.pool.t3_sessions().await.ok().and_then(|sessions| {
                sessions
                    .into_iter()
                    .filter(|(t, d)| *d == proc.udid && self.agents.is_squircle_thread(t))
                    .map(|(t, _)| t)
                    .next()
            }),
        };
        let Some(thread) = thread else {
            self.agents.alert("Simulators", &what);
            return;
        };
        let text = format!("[simulator] {what} Find and fix the cause before you launch it again.");
        let id = format!("sim-runaway-{}-{}", proc.pid, now() as u64);
        let payload = json!({"thread": thread, "device": proc.udid, "app": proc.app()});
        if let Err(error) = self
            .agents
            .notify(&thread, &id, text, Note::SimHealth, payload)
            .await
        {
            eprintln!("Simulator watch: {thread} not told: {error:#}");
        }
    }

    async fn check_host(&self) {
        let leases = self.sims.leases();
        let rows = match self.pool.refresh(&leases, false).await {
            Ok(rows) => rows,
            Err(error) => {
                eprintln!("Simulator watch: no simulator list for the probe: {error:#}");
                vec![]
            }
        };
        let health = check(&rows).await;
        let before = self.pool.health();
        self.pool.set_health(health.clone());
        match (&before.problem, &health.problem) {
            (None, Some(problem)) => self.tell_host(problem, &leases, health.checked_at).await,
            (Some(_), None) => self
                .agents
                .alert("Simulators", "Simulators on the Mac work again."),
            _ => {}
        }
    }

    /// Tells the app agent of each app with a simulator session, else the phone.
    async fn tell_host(&self, problem: &Problem, leases: &[crate::simpool::Lease], at: f64) {
        eprintln!("Simulator watch: {}", problem.text());
        let mut agents: Vec<String> = leases
            .iter()
            .filter_map(|l| self.agents.app_agent_of(&l.thread_id))
            .collect();
        agents.sort();
        agents.dedup();
        if agents.is_empty() {
            self.agents.alert("Simulators", &problem.text());
            return;
        }
        let text = format!(
            "[simulator trouble] {} Simulator starts are refused until it is fixed. Tell the user plainly; the fix: {} Ask before running it yourself.",
            problem.what, problem.fix
        );
        for agent in agents {
            let id = format!("sim-health-{}", at as u64);
            if let Err(error) = self
                .agents
                .notify(
                    &agent,
                    &id,
                    text.clone(),
                    Note::SimHealth,
                    json!({"problem": problem.what}),
                )
                .await
            {
                eprintln!("Simulator watch: {agent} not told: {error:#}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const APP: &str = "/Users/u/Library/Developer/CoreSimulator/Devices/d5e7bc53-440e-4b45-b3d1-d131e8f6518f/data/Containers/Bundle/Application/ACB49A50-01C8-48AA-9248-D8EB6F951CA5/Letters Abroad.app/Letters Abroad --demo";

    /// Only apps installed in a simulator, with ps's CPU time in every form.
    #[test]
    fn reads_simulator_apps_from_ps() {
        let text = format!(
            "13690   0:15.99 launchd_sim /Users/u/Library/Developer/CoreSimulator/Devices/D5E7BC53-440E-4B45-B3D1-D131E8F6518F/data/var/run/launchd_bootstrap.plist\n\
             58093 61:02.50 {APP}\n\
             58094 1-02:00:01.00 {APP}\n\
             179   8:19.32 /System/Library/WindowServer -daemon\n"
        );
        let procs = parse_ps(&text);
        assert_eq!(
            procs.iter().map(|p| (p.pid, p.cpu)).collect::<Vec<_>>(),
            [(58093, 3662.5), (58094, 86400.0 + 7201.0)]
        );
        assert_eq!(procs[0].udid, "D5E7BC53-440E-4B45-B3D1-D131E8F6518F");
        assert_eq!(procs[0].app(), "Letters Abroad");
    }

    fn proc(pid: u32, cpu: f64) -> Proc {
        Proc {
            pid,
            cpu,
            command: APP.into(),
            udid: "D".into(),
        }
    }

    /// An app is a runaway only once hot over every interval for the whole
    /// time: a cool interval, a gap in sampling or a new process behind the
    /// same PID starts its clock again.
    #[test]
    fn runaway_needs_unbroken_heat() {
        let minute = 60.0;
        let mut watch = Runaways::default();
        // pid 1: 95% of a core every minute. pid 2: 50%. pid 3: hot, but one minute cool.
        let mut cpu = [0.0f64; 3];
        let mut found = vec![];
        for m in 0..=25 {
            let t = m as f64 * minute;
            if m > 0 {
                cpu[0] += 0.95 * minute;
                cpu[1] += 0.5 * minute;
                cpu[2] += if m == 10 { 0.1 } else { 0.95 } * minute;
            }
            let runaway = watch.sample(t, &[proc(1, cpu[0]), proc(2, cpu[1]), proc(3, cpu[2])]);
            found.extend(runaway.iter().map(|p| (m, p.pid)));
        }
        // pid 1 from minute 20; pid 3's clock restarted after minute 10, so not before 30.
        assert_eq!(found.first(), Some(&(20, 1)));
        assert!(found.iter().all(|(_, pid)| *pid == 1));

        // A gap longer than MAX_GAP proves nothing: the clock starts again.
        let mut watch = Runaways::default();
        let mut runaway = vec![];
        for (t, cpu) in [(0.0, 0.0), (600.0, 570.0), (1200.0, 1140.0)] {
            runaway = watch.sample(t, &[proc(1, cpu)]);
        }
        assert!(runaway.is_empty());

        // A new process behind the same PID (its CPU time went back) is new.
        let mut watch = Runaways::default();
        let mut runaway = vec![];
        for m in 0..=20 {
            let cpu = if m == 15 {
                1.0
            } else {
                m as f64 * 0.95 * minute
            };
            runaway = watch.sample(m as f64 * minute, &[proc(1, cpu)]);
        }
        assert!(runaway.is_empty());
    }
}
