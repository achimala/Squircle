use super::*;

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
        Observed::Stale { value, .. } => Seen::Unknown {
            turn: value.and_then(|t| t.turn),
        },
        Observed::Unavailable => Seen::Unknown { turn: None },
    }
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
    /// One item each time what `seen` reads may have changed.
    fn changes(&self) -> futures_util::stream::BoxStream<'static, ()> {
        use futures_util::StreamExt;
        futures_util::stream::pending().boxed()
    }
    /// The squircle invocation agents are told to use.
    fn cli(&self) -> String;
    fn boot<'a>(&'a self, device: &'a str) -> Pending<'a, Result<()>>;
    /// Starts recording the device's screen into `path`.
    fn record(&self, device: &str, path: &Path, log: std::fs::File) -> Result<Child>;
    /// Makes a filed recording light in place.
    fn shrink<'a>(&'a self, file: &'a Path) -> Pending<'a, ()>;
    /// Booted simulators of Squircle's that nothing holds (`leases` do).
    fn free<'a>(&'a self, leases: &'a [Lease]) -> Pending<'a, Vec<String>>;
    /// `thread`'s session on `device` no longer uses it: the pool shuts it
    /// down unless its policy keeps it. `others`: what other sessions reserve.
    fn release<'a>(
        &'a self,
        device: &'a str,
        thread: &'a str,
        others: &'a [Lease],
    ) -> Pending<'a, Result<Released>>;
    /// Creates a simulator for `thread`, Squircle's from the start; returns its UDID.
    fn create<'a>(&'a self, thread: &'a str) -> Pending<'a, Result<String>>;
    /// How many simulators may be reserved at once.
    fn max_leases(&self) -> usize;
    fn title(&self, thread: &str) -> Option<String>;
    /// Queues a service message that starts a turn in `thread` (once per `id`).
    fn wake<'a>(&'a self, thread: &'a str, id: &'a str, text: String) -> Pending<'a, Result<()>>;
    /// The threads now waiting in line for a simulator (their ended turns wake nobody).
    fn waiting(&self, threads: Vec<String>);

    /// Why no simulator can start now, if this Mac's simulator host is failing.
    fn unhealthy<'a>(&'a self, _leases: &'a [Lease]) -> Pending<'a, Option<String>> {
        Box::pin(async { None })
    }

    /// Turns off the simulator's Apple Intelligence and Siri daemons.
    fn quiet<'a>(&'a self, _device: &'a str) -> Pending<'a, ()> {
        Box::pin(async {})
    }

    /// Saves the device's screen as a small JPEG at `path`, best effort:
    /// the recording's poster, so the phone needn't download the movie to
    /// show it.
    fn poster<'a>(&'a self, _device: &'a str, _path: &'a Path) -> Pending<'a, ()> {
        Box::pin(async {})
    }
}

pub(super) struct AgentsHost(pub(super) Arc<Agents>, pub(super) Arc<Pool>);

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

    fn changes(&self) -> futures_util::stream::BoxStream<'static, ()> {
        self.0.changes()
    }

    fn cli(&self) -> String {
        self.0.cli().to_string()
    }

    fn boot<'a>(&'a self, device: &'a str) -> Pending<'a, Result<()>> {
        Box::pin(async move {
            // Returns once the simulator has booted, or fails; dropping it
            // (the start was cancelled) stops it.
            let booted = Command::new("xcrun")
                .args(["simctl", "bootstatus", device, "-b"])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .kill_on_drop(true)
                .status()
                .await;
            ensure!(
                matches!(booted, Ok(status) if status.success()),
                "did not finish booting"
            );
            Ok(())
        })
    }

    fn record(&self, device: &str, path: &Path, log: std::fs::File) -> Result<Child> {
        Command::new("xcrun")
            .args([
                "simctl",
                "io",
                device,
                "recordVideo",
                "--codec=hevc",
                "--force",
            ])
            .arg(path)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(log)
            // Outlives a restart or crash so the next run can adopt it or end
            // it cleanly (SIGINT), and a signal to the service's process group
            // (a closed terminal) doesn't end it.
            .kill_on_drop(false)
            .process_group(0)
            .spawn()
            .context("Cannot start simctl recordVideo")
    }

    fn shrink<'a>(&'a self, file: &'a Path) -> Pending<'a, ()> {
        Box::pin(shrink(file))
    }

    fn free<'a>(&'a self, leases: &'a [Lease]) -> Pending<'a, Vec<String>> {
        Box::pin(async move {
            self.1
                .refresh(leases, false)
                .await
                .map(|rows| {
                    rows.into_iter()
                        .filter(|r| r.free)
                        .map(|r| r.udid)
                        .collect()
                })
                .unwrap_or_default()
        })
    }

    fn release<'a>(
        &'a self,
        device: &'a str,
        thread: &'a str,
        others: &'a [Lease],
    ) -> Pending<'a, Result<Released>> {
        Box::pin(self.1.release(device, thread, others))
    }

    fn create<'a>(&'a self, thread: &'a str) -> Pending<'a, Result<String>> {
        Box::pin(async move { Ok(self.1.create(thread).await?.0) })
    }

    fn max_leases(&self) -> usize {
        self.1.policy.max_leases
    }

    fn title(&self, thread: &str) -> Option<String> {
        self.0.worker_title(thread)
    }

    fn wake<'a>(&'a self, thread: &'a str, id: &'a str, text: String) -> Pending<'a, Result<()>> {
        Box::pin(self.0.notify(
            thread,
            id,
            text,
            crate::agents::Note::SimReady,
            json!({"thread": thread}),
        ))
    }

    fn waiting(&self, threads: Vec<String>) {
        self.0.set_sim_waiting(threads);
    }

    fn unhealthy<'a>(&'a self, leases: &'a [Lease]) -> Pending<'a, Option<String>> {
        Box::pin(crate::simwatch::before_start(&self.1, leases))
    }

    fn quiet<'a>(&'a self, device: &'a str) -> Pending<'a, ()> {
        Box::pin(quiet(device))
    }

    fn poster<'a>(&'a self, device: &'a str, path: &'a Path) -> Pending<'a, ()> {
        Box::pin(async move {
            let run = |program: &str, args: &[&std::ffi::OsStr]| {
                Command::new(program)
                    .args(args)
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .kill_on_drop(true)
                    .status()
            };
            let shot = path.with_extension("png");
            let taken = run(
                "xcrun",
                &[
                    "simctl".as_ref(),
                    "io".as_ref(),
                    device.as_ref(),
                    "screenshot".as_ref(),
                    shot.as_os_str(),
                ],
            )
            .await;
            if matches!(taken, Ok(s) if s.success()) {
                let _ = run(
                    "/usr/bin/sips",
                    &[
                        "-Z".as_ref(),
                        "900".as_ref(),
                        "-s".as_ref(),
                        "format".as_ref(),
                        "jpeg".as_ref(),
                        "-s".as_ref(),
                        "formatOptions".as_ref(),
                        "70".as_ref(),
                        shot.as_os_str(),
                        "--out".as_ref(),
                        path.as_os_str(),
                    ],
                )
                .await;
            }
            let _ = std::fs::remove_file(&shot);
        })
    }
}

/// Why agents can't drive T3's simulators: T3 withholds `device_open` and
/// `device_screenshot`, and only `device_open` prepares the agent-device
/// launcher and its host config.
pub(super) fn agent_access_off(inventory: &Value) -> Option<&'static str> {
    (inventory["agentAccessEnabled"] != true).then_some(
        "T3's Agent device access is off, so agents can't drive or screenshot simulators; \
        ask the user to turn it on in T3's Settings, Integrations, Agent device access",
    )
}

/// T3's device state after it re-lists every host. Its `subscribeDeviceState`
/// snapshot is only a cache that starts empty when T3 starts and fills only
/// when some client asks for a list, so read it through `device.list`.
pub(super) async fn inventory(host: &dyn Host) -> Result<Value> {
    host.device("device.list", json!({}))
        .await
        .context("T3 could not list its simulators")
}

pub(super) fn local_simulators(inventory: &Value) -> Vec<&Value> {
    inventory["devices"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|d| d["platform"] == "ios" && d["physical"] != true && d["hostId"] == "local")
        .collect()
}

/// Why T3 listed no simulators, from its own host status.
pub(super) fn no_simulators(inventory: &Value) -> String {
    let status = inventory["hostStatus"].as_str().unwrap_or("unknown");
    let detail = inventory["hostStatusDetail"]
        .as_str()
        .or_else(|| inventory["hostStatuses"]["local"]["detail"].as_str())
        .map(|d| format!(": {d}"))
        .unwrap_or_default();
    if status == "disabled" {
        return "T3 lists no simulators because its device support is off; turn it on in T3's Device panel".into();
    }
    format!(
        "T3 lists no iOS simulators on this Mac (T3 device host {status}{detail}); check `xcrun simctl list devices` and T3's Device panel"
    )
}

/// Apple Intelligence and Siri daemons that crash-loop on the iOS 27.0
/// simulator runtime, each pinning a core (five simulators held the Mac at
/// a load of 190; about 30 without them).
const NOISY: [&str; 13] = [
    "com.apple.intelligenceplatformd",
    "com.apple.intelligencetasksd",
    "com.apple.intelligenceflowd",
    "com.apple.intelligencecontextd",
    "com.apple.callintelligenced",
    "com.apple.fitnessintelligenced",
    "com.apple.siri.context.service",
    "com.apple.siri.acousticsignature",
    "com.apple.siriactionsd",
    "com.apple.siriknowledged",
    "com.apple.siriinferenced",
    "com.apple.sirittsd",
    "com.apple.nanosystemsettingsd",
];

/// Disables and stops the `NOISY` daemons inside a booted simulator. Done
/// for every session: a simulator forgets it when it boots again. A daemon
/// a runtime doesn't have is no matter.
async fn quiet(device: &str) {
    let launchctl = |verb: &'static str, label: &str| {
        Command::new("xcrun")
            .args(["simctl", "spawn", device, "launchctl", verb])
            .arg(format!("system/{label}"))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
    };
    let ran = futures_util::future::join_all(NOISY.map(|label| async move {
        launchctl("disable", label).await?;
        launchctl("bootout", label).await.map(drop)
    }))
    .await;
    if let Some(Err(error)) = ran.into_iter().find(|r| r.is_err()) {
        eprintln!("Simulator {device}: Apple Intelligence and Siri not turned off: {error}");
    }
}
