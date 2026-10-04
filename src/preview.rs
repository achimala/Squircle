//! Real simulator pixels only. Captures run in the same single-worker lane as builds.
use crate::{
    model::{BuildMode, Job, now},
    xcode,
};
use anyhow::{Context, Result, bail, ensure};
use std::{
    ffi::OsString,
    fs::{self, OpenOptions},
    io::Write,
    os::unix::process::CommandExt,
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};
use tokio::{io::AsyncReadExt, process::Command, sync::watch, time::Instant};

pub struct Capture {
    pub path: PathBuf,
    pub captured_at: u64,
    pub source: String,
}

pub fn simulator_id(explicit: Option<&str>) -> Result<String> {
    let configured = std::env::var("SQUIRCLE_SIMULATOR_ID").ok();
    let id = explicit.or(configured.as_deref()).context("Preview needs a dedicated simulator: set SQUIRCLE_SIMULATOR_ID on the service or pass preview capture --simulator UUID")?;
    Ok(uuid::Uuid::parse_str(id)
        .context("Simulator ID must be a UUID; 'booted' is not accepted")?
        .to_string()
        .to_uppercase())
}

pub async fn capture(
    job: &Job,
    job_dir: &Path,
    simulator: &str,
    cancel: watch::Receiver<bool>,
) -> Result<Capture> {
    let simulator = simulator_id(Some(simulator))?;
    let request = job
        .request
        .as_ref()
        .context("Imported IPAs have no simulator build recipe; submit a project build first")?;
    let output = job.output.as_ref().context("Build has no product")?;
    ensure!(!*cancel.borrow(), "Preview cancelled");
    let log = job_dir.join("build.log");
    let deadline = Instant::now() + Duration::from_secs(180);
    let devices = command(
        &["list".into(), "devices".into(), "--json".into()],
        &log,
        deadline,
        cancel.clone(),
    )
    .await?;
    let devices: serde_json::Value =
        serde_json::from_slice(&devices).context("Invalid simulator inventory")?;
    let device = devices["devices"]
        .as_object()
        .into_iter()
        .flat_map(|map| map.values())
        .filter_map(|v| v.as_array())
        .flatten()
        .find(|device| {
            device["udid"]
                .as_str()
                .is_some_and(|id| id.eq_ignore_ascii_case(&simulator))
        })
        .context("Configured preview simulator does not exist")?;
    ensure!(
        device["isAvailable"] == true,
        "Configured preview simulator is unavailable"
    );
    // The selected device is explicit and owned by this workflow. Never use `booted`,
    // erase a device, or terminate an unrelated app.
    if device["state"] != "Booted" {
        command(
            &["boot".into(), simulator.clone().into()],
            &log,
            deadline,
            cancel.clone(),
        )
        .await?;
    }
    command(
        &["bootstatus".into(), simulator.clone().into(), "-b".into()],
        &log,
        deadline,
        cancel.clone(),
    )
    .await?;
    let (app, source) = if request.mode == BuildMode::Simulator {
        (
            output
                .app_path
                .clone()
                .context("Simulator build has no app path")?,
            "built_simulator_product",
        )
    } else {
        let mut simulator_request = request.clone();
        simulator_request.mode = BuildMode::Simulator;
        simulator_request.export_options = None;
        simulator_request.capture_preview = false;
        simulator_request.allow_provisioning_updates = false;
        // Keep the job UUID as the final component so xcode injects the original
        // SQUIRCLE_BUILD_ID, while retaining each recapture's independent evidence.
        let directory = job_dir
            .join("preview-builds")
            .join(uuid::Uuid::new_v4().to_string())
            .join(&job.id);
        fs::create_dir_all(&directory)?;
        let built = xcode::run(&simulator_request, &directory, cancel.clone()).await?;
        ensure!(
            built.bundle_id == output.bundle_id,
            "Preview simulator bundle ID differs from the archived app"
        );
        (
            built
                .app_path
                .context("Preview build has no simulator app")?,
            "current_working_tree",
        )
    };
    let info =
        plist::Value::from_file(app.join("Info.plist")).context("Cannot inspect preview app")?;
    let info = info
        .as_dictionary()
        .context("Preview app metadata is invalid")?;
    ensure!(
        info.get("CFBundleIdentifier")
            .and_then(plist::Value::as_string)
            == Some(&output.bundle_id),
        "Preview product bundle ID does not match build record"
    );
    let deadline = Instant::now() + Duration::from_secs(120);
    command(
        &[
            "install".into(),
            simulator.clone().into(),
            app.into_os_string(),
        ],
        &log,
        deadline,
        cancel.clone(),
    )
    .await?;
    let launch = command(
        &[
            "launch".into(),
            "--terminate-running-process".into(),
            simulator.clone().into(),
            output.bundle_id.clone().into(),
        ],
        &log,
        deadline,
        cancel.clone(),
    )
    .await?;
    let pid = launch_pid(&launch, &output.bundle_id)?;
    tokio::select! {
        _ = tokio::time::sleep(Duration::from_secs(3)) => {},
        _ = cancelled(cancel.clone()) => bail!("Preview cancelled"),
    }
    // A crashing launch must not silently publish a SpringBoard screenshot.
    let processes = command(
        &[
            "spawn".into(),
            simulator.clone().into(),
            "launchctl".into(),
            "list".into(),
        ],
        &log,
        deadline,
        cancel.clone(),
    )
    .await?;
    ensure!(
        target_is_running(&processes, pid, &output.bundle_id),
        "Preview app exited before capture; inspect simulator crash reports"
    );
    let temporary = job_dir.join(format!("preview-{}.png", uuid::Uuid::new_v4()));
    command(
        &[
            "io".into(),
            simulator.into(),
            "screenshot".into(),
            "--type=png".into(),
            temporary.clone().into_os_string(),
        ],
        &log,
        deadline,
        cancel,
    )
    .await?;
    let bytes = fs::read(&temporary)?;
    validate_png(&bytes)?;
    fs::File::open(&temporary)?.sync_all()?;
    let path = job_dir.join("preview.png");
    fs::rename(&temporary, &path)?;
    fs::File::open(job_dir)?.sync_all()?;
    Ok(Capture {
        path,
        captured_at: now(),
        source: source.into(),
    })
}

pub fn apply_result(output: &mut crate::model::BuildOutput, result: Result<Capture>) {
    match result {
        Ok(capture) => {
            output.preview_path = Some(capture.path);
            output.preview_captured_at = Some(capture.captured_at);
            output.preview_source = Some(capture.source);
            output.preview_state = Some("succeeded".into());
            output.preview_error = None;
        }
        Err(error) => {
            // Keep a previous valid screenshot and its provenance if recapture fails.
            output.preview_state = Some("failed".into());
            output.preview_error = Some(format!("{error:#}"));
        }
    }
}

fn launch_pid(bytes: &[u8], bundle: &str) -> Result<u32> {
    let text = std::str::from_utf8(bytes)?;
    text.lines()
        .find_map(|line| {
            line.strip_prefix(&format!("{bundle}: "))
                .and_then(|s| s.trim().parse::<u32>().ok())
                .filter(|pid| *pid > 0)
        })
        .context("simctl launch did not acknowledge the target app PID")
}
fn target_is_running(bytes: &[u8], pid: u32, bundle: &str) -> bool {
    String::from_utf8_lossy(bytes).lines().any(|line| {
        let mut fields = line.split_whitespace();
        fields.next().and_then(|s| s.parse::<u32>().ok()) == Some(pid)
            && fields
                .nth(1)
                .is_some_and(|label| label.starts_with(&format!("UIKitApplication:{bundle}[")))
    })
}
fn validate_png(bytes: &[u8]) -> Result<()> {
    ensure!(
        bytes.len() >= 33
            && bytes.len() <= 32 * 1024 * 1024
            && bytes.starts_with(b"\x89PNG\r\n\x1a\n")
            && &bytes[12..16] == b"IHDR",
        "Simulator did not produce a valid bounded PNG screenshot"
    );
    ensure!(
        u32::from_be_bytes(bytes[16..20].try_into()?) > 0
            && u32::from_be_bytes(bytes[20..24].try_into()?) > 0,
        "Screenshot has no pixels"
    );
    Ok(())
}
async fn cancelled(mut cancel: watch::Receiver<bool>) {
    loop {
        if *cancel.borrow_and_update() || cancel.changed().await.is_err() {
            return;
        }
    }
}
struct Group(libc::pid_t);
impl Drop for Group {
    fn drop(&mut self) {
        if self.0 > 0 {
            unsafe {
                libc::kill(-self.0, libc::SIGKILL);
            }
        }
    }
}

async fn command(
    args: &[OsString],
    log: &Path,
    deadline: Instant,
    cancel: watch::Receiver<bool>,
) -> Result<Vec<u8>> {
    ensure!(
        !*cancel.borrow() && cancel.has_changed().is_ok(),
        "Preview cancelled"
    );
    let mut log = OpenOptions::new().create(true).append(true).open(log)?;
    writeln!(log, "\n$ /usr/bin/xcrun simctl {args:?}")?;
    let mut command = Command::new("/usr/bin/xcrun");
    command
        .arg("simctl")
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(log.try_clone()?)
        .kill_on_drop(true);
    command.as_std_mut().process_group(0);
    let mut child = command.spawn().context("Cannot start xcrun simctl")?;
    let mut group = Group(child.id().context("simctl has no PID")? as libc::pid_t);
    let mut stdout = child.stdout.take().context("simctl has no output")?;
    let work = async {
        let mut bytes = Vec::new();
        (&mut stdout)
            .take(1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .await?;
        ensure!(
            bytes.len() <= 1024 * 1024,
            "Simulator command output exceeds 1 MiB"
        );
        let status = child.wait().await?;
        ensure!(
            status.success(),
            "simctl command failed ({status}); inspect build log"
        );
        Ok::<_, anyhow::Error>(bytes)
    };
    let result = tokio::select! {
        result = work => result,
        _ = cancelled(cancel) => Err(anyhow::anyhow!("Preview cancelled")),
        _ = tokio::time::sleep_until(deadline) => Err(anyhow::anyhow!("Simulator preview command timed out")),
    };
    if child.try_wait()?.is_some() {
        group.0 = 0;
    } else {
        drop(group);
        let _ = child.start_kill();
        let _ = tokio::time::timeout(Duration::from_secs(3), child.wait()).await;
    }
    if let Ok(bytes) = &result {
        log.write_all(bytes)?;
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn capture_requires_exact_simulator_and_target_process() {
        assert!(simulator_id(Some("booted")).is_err());
        assert!(simulator_id(Some("; rm -rf /")).is_err());
        assert_eq!(launch_pid(b"test.app: 123\n", "test.app").unwrap(), 123);
        assert!(launch_pid(b"other.app: 123\n", "test.app").is_err());
        assert!(target_is_running(
            b"PID Status Label\n123 0 UIKitApplication:test.app[abc][rb-1]\n",
            123,
            "test.app"
        ));
        assert!(!target_is_running(
            b"123 0 UIKitApplication:test.application[abc]\n",
            123,
            "test.app"
        ));
        assert!(!target_is_running(
            b"- 0 UIKitApplication:test.app[abc]\n",
            123,
            "test.app"
        ));
    }
    #[test]
    fn failed_capture_keeps_installable_artifacts_and_prior_image() {
        let mut output: crate::model::BuildOutput = serde_json::from_value(serde_json::json!({"archive_path":"/archive","ipa_path":"/app.ipa","app_path":null,"dsym_paths":[],"bundle_id":"test.app","version":"1","build_number":"1","title":"App","preview_path":"/preview.png","preview_captured_at":12})).unwrap();
        apply_result(&mut output, Err(anyhow::anyhow!("app crashed")));
        assert_eq!(output.ipa_path.unwrap(), PathBuf::from("/app.ipa"));
        assert_eq!(output.preview_path.unwrap(), PathBuf::from("/preview.png"));
        assert_eq!(output.preview_captured_at, Some(12));
        assert_eq!(output.preview_state.as_deref(), Some("failed"));
        assert_eq!(output.preview_error.as_deref(), Some("app crashed"));
        assert!(validate_png(b"not a screenshot").is_err());
    }
}
