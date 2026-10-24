//! Real simulator pixels only. Captures run in the same single-worker lane as builds.
use crate::{
    model::{BuildMode, Job, PreviewSource, now},
    xcode,
};
use anyhow::{Context, Result, bail, ensure};
use std::{
    ffi::OsString,
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    time::Duration,
};
use tokio::{process::Command, sync::watch, time::Instant};

pub struct Capture {
    pub path: PathBuf,
    pub captured_at: u64,
    pub source: PreviewSource,
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
        .request()
        .context("Imported IPAs have no simulator build recipe; submit a project build first")?;
    let output = job.output().context("Build has no product")?;
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
            PreviewSource::BuiltSimulatorProduct,
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
        let built = xcode::build(&simulator_request, &directory, cancel.clone()).await?;
        ensure!(
            built.metadata().bundle_id == output.bundle_id,
            "Preview simulator bundle ID differs from the archived app"
        );
        (built.app().to_path_buf(), PreviewSource::CurrentWorkingTree)
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
    let path = job_dir.join("preview.png");
    crate::store::publish_private(&temporary, &path)?;
    Ok(Capture {
        path,
        captured_at: now(),
        source,
    })
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
async fn cancelled(cancel: watch::Receiver<bool>) {
    crate::process::cancelled(Some(cancel)).await
}

async fn command(
    args: &[OsString],
    log: &Path,
    deadline: Instant,
    cancel: watch::Receiver<bool>,
) -> Result<Vec<u8>> {
    let mut log = OpenOptions::new().create(true).append(true).open(log)?;
    writeln!(log, "\n$ /usr/bin/xcrun simctl {args:?}")?;
    let mut command = Command::new("/usr/bin/xcrun");
    command.arg("simctl").args(args);
    let finished = crate::process::run_bounded(
        command,
        crate::process::Sink::Capture(1024 * 1024),
        crate::process::Sink::File(log.try_clone()?),
        deadline,
        Some(cancel),
    )
    .await
    .map_err(|error| match error {
        crate::process::RunError::Cancelled => anyhow::anyhow!("Preview cancelled"),
        crate::process::RunError::TimedOut => {
            anyhow::anyhow!("Simulator preview command timed out")
        }
        crate::process::RunError::Failed(error) => error.context("simctl command did not complete"),
    })?;
    ensure!(
        finished.status.success(),
        "simctl command failed ({}); inspect build log",
        finished.status
    );
    log.write_all(&finished.stdout)?;
    Ok(finished.stdout)
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
}
