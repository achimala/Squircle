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

    fn cli(&self) -> String {
        self.0.cli().to_string()
    }

    fn boot<'a>(&'a self, device: &'a str) -> Pending<'a, Result<()>> {
        Box::pin(async move {
            let status = Command::new("xcrun")
                .args(["simctl", "bootstatus", device, "-b"])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .kill_on_drop(true)
                .status();
            let booted = tokio::time::timeout(Duration::from_secs(180), status).await;
            ensure!(
                matches!(booted, Ok(Ok(status)) if status.success()),
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

    fn poster<'a>(&'a self, device: &'a str, path: &'a Path) -> Pending<'a, ()> {
        Box::pin(async move {
            let run = |program: &str, args: &[&std::ffi::OsStr]| {
                let status = Command::new(program)
                    .args(args)
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .kill_on_drop(true)
                    .status();
                tokio::time::timeout(Duration::from_secs(15), status)
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
            if matches!(taken, Ok(Ok(s)) if s.success()) {
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

/// The agent-device invocation T3's `device_open` tool gives agents for this
/// thread and simulator (same config file and session name as T3 0.0.45).
pub fn agent_device(thread: &str, host: &str, device: &str) -> Value {
    let base = dirs::home_dir()
        .unwrap_or_default()
        .join(".t3/userdata/device");
    let config = base.join("hosts").join(format!("{}.json", key(host)));
    let session = format!(
        "t3-{}",
        key(&serde_json::to_string(&[thread, host, device]).unwrap_or_default())
    );
    let args = vec![
        "--platform".to_string(),
        "ios".into(),
        "--udid".into(),
        device.into(),
        "--config".into(),
        config.display().to_string(),
        "--session".into(),
        session,
    ];
    json!({
        "command": base.join("bin/agent-device"),
        "target_args": args,
        "config_exists": config.is_file(),
    })
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
