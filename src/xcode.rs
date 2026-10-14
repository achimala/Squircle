use std::{
    ffi::{OsStr, OsString},
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::{fs::OpenOptionsExt, process::CommandExt},
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};

use anyhow::{Context, Result, bail, ensure};
use serde::Deserialize;
use tokio::{process::Command, sync::watch, time::Instant};

use crate::{
    model::{BuildMode, BuildOutput, BuildRequest},
    overlay,
};

const BUILD_TIMEOUT: Duration = Duration::from_secs(30 * 60);

/// Build into an existing, unique job directory. Dropping this future terminates
/// the current xcodebuild process group, including on server task shutdown.
pub async fn run(
    request: &BuildRequest,
    job_dir: &Path,
    cancel: watch::Receiver<bool>,
) -> Result<BuildOutput> {
    validate_request(request)?;
    ensure!(!*cancel.borrow(), "build cancelled before starting");
    let project = request
        .project
        .canonicalize()
        .context("project does not exist")?;
    ensure!(
        project.is_dir(),
        "project must be an Xcode project or workspace directory"
    );
    let job_dir = job_dir
        .canonicalize()
        .context("job directory does not exist")?;
    ensure!(job_dir.is_dir(), "job directory must be a directory");
    let deadline = Instant::now() + BUILD_TIMEOUT;
    let log = job_dir.join("build.log");

    match &request.mode {
        BuildMode::Archive => {
            let options = request
                .export_options
                .as_ref()
                .context("archive requires export options")?
                .canonicalize()
                .context("export options do not exist")?;
            let options_bytes = validate_export_options(&options)?;
            // Export the validated configuration even if the source is edited
            // while Xcode archives. In particular, never switch to upload.
            let options = job_dir.join("ExportOptions.plist");
            fs::write(&options, options_bytes)?;
            let archive = job_dir.join("App.xcarchive");
            let export = job_dir.join("export");
            ensure!(
                !archive.exists() && !export.exists(),
                "job directory already contains archive/export output"
            );
            let args = build_args(request, &project, &job_dir)?;
            run_command(&args, &log, None, deadline, cancel.clone()).await?;
            let archived = exactly_one(
                children_with_extension(&archive.join("Products/Applications"), "app", true)?,
                "archived application",
            )?;
            let bundle_id = read_app_metadata(&archived, &request.scheme)?.bundle_id;
            let overlay = !request.no_overlay
                && overlay::allowed_method(&export_method(&options)?)
                && !overlay::skips_bundle(&bundle_id);
            if overlay {
                let data_root = job_dir
                    .parent()
                    .and_then(Path::parent)
                    .context("job directory is not inside a Squircle data directory")?;
                let framework =
                    overlay::framework(data_root, &log, deadline, cancel.clone()).await?;
                overlay::inject(&archived, &framework, &log, deadline, cancel.clone()).await?;
            }
            let args = export_args(
                &archive,
                &export,
                &options,
                request.allow_provisioning_updates,
            );
            run_command(&args, &log, None, deadline, cancel).await?;
            let ipa = exactly_one(
                children_with_extension(&export, "ipa", false)?,
                "exported IPA",
            )?;
            let app = exactly_one(
                children_with_extension(&archive.join("Products/Applications"), "app", true)?,
                "archived application",
            )?;
            let mut output = read_app_metadata(&app, &request.scheme)?;
            output.dsym_paths = children_with_extension(&archive.join("dSYMs"), "dSYM", true)?;
            output.archive_path = Some(archive);
            output.ipa_path = Some(ipa);
            output.app_path = Some(app);
            Ok(output)
        }
        BuildMode::Simulator => {
            let args = build_args(request, &project, &job_dir)?;
            run_command(&args, &log, None, deadline, cancel.clone()).await?;
            // Query the resolved product path: projects can override build output
            // directories, so guessing inside DerivedData can report a stale app.
            let settings_path = job_dir.join("build-settings.json");
            let mut args = common_args(request, &project, &job_dir)?;
            args.extend(
                [
                    "-destination",
                    "generic/platform=iOS Simulator",
                    "CODE_SIGNING_ALLOWED=NO",
                    "-showBuildSettings",
                    "-json",
                ]
                .map(OsString::from),
            );
            run_command(&args, &log, Some(&settings_path), deadline, cancel).await?;
            let settings: Vec<TargetSettings> =
                serde_json::from_reader(File::open(&settings_path)?)
                    .context("xcodebuild did not return valid build settings JSON")?;
            let app = simulator_app(&settings)?;
            let mut output = read_app_metadata(&app, &request.scheme)?;
            let dsym = app.with_file_name(format!(
                "{}.dSYM",
                app.file_name()
                    .context("app has no name")?
                    .to_string_lossy()
            ));
            if dsym.is_dir() {
                output.dsym_paths.push(dsym);
            }
            output.app_path = Some(app);
            Ok(output)
        }
    }
}

fn validate_request(request: &BuildRequest) -> Result<()> {
    project_flag(&request.project)?;
    ensure!(!request.scheme.trim().is_empty(), "scheme cannot be empty");
    ensure!(
        !request.configuration.trim().is_empty(),
        "configuration cannot be empty"
    );
    match &request.mode {
        BuildMode::Archive => ensure!(
            request.export_options.is_some(),
            "archive mode requires an export-options plist"
        ),
        BuildMode::Simulator => ensure!(
            request.export_options.is_none(),
            "export options are only valid for archive mode"
        ),
    }
    Ok(())
}

fn project_flag(path: &Path) -> Result<&'static str> {
    match path.extension().and_then(OsStr::to_str) {
        Some("xcodeproj") => Ok("-project"),
        Some("xcworkspace") => Ok("-workspace"),
        _ => bail!("project must end in .xcodeproj or .xcworkspace"),
    }
}

fn common_args(request: &BuildRequest, project: &Path, job_dir: &Path) -> Result<Vec<OsString>> {
    let mut build_id = OsString::from("SQUIRCLE_BUILD_ID=");
    build_id.push(
        job_dir
            .file_name()
            .context("job directory must have a build ID as its final component")?,
    );
    Ok(vec![
        project_flag(project)?.into(),
        project.as_os_str().into(),
        "-scheme".into(),
        request.scheme.clone().into(),
        "-configuration".into(),
        request.configuration.clone().into(),
        "-derivedDataPath".into(),
        job_dir.join("DerivedData").into_os_string(),
        build_id,
    ])
}

fn build_args(request: &BuildRequest, project: &Path, job_dir: &Path) -> Result<Vec<OsString>> {
    let mut args = common_args(request, project, job_dir)?;
    args.push("-destination".into());
    match &request.mode {
        BuildMode::Archive => {
            args.extend([
                "generic/platform=iOS".into(),
                "-archivePath".into(),
                job_dir.join("App.xcarchive").into_os_string(),
            ]);
            args.extend([
                "-resultBundlePath".into(),
                job_dir.join("archive.xcresult").into_os_string(),
                "archive".into(),
            ]);
            if request.allow_provisioning_updates {
                args.push("-allowProvisioningUpdates".into());
            }
        }
        BuildMode::Simulator => {
            args.extend([
                "generic/platform=iOS Simulator".into(),
                "-resultBundlePath".into(),
                job_dir.join("build.xcresult").into_os_string(),
            ]);
            args.extend(["build".into(), "CODE_SIGNING_ALLOWED=NO".into()]);
        }
    }
    Ok(args)
}

fn export_args(
    archive: &Path,
    export: &Path,
    options: &Path,
    allow_provisioning_updates: bool,
) -> Vec<OsString> {
    let mut args = vec![
        "-exportArchive".into(),
        "-archivePath".into(),
        archive.as_os_str().into(),
        "-exportPath".into(),
        export.as_os_str().into(),
        "-exportOptionsPlist".into(),
        options.as_os_str().into(),
    ];
    if allow_provisioning_updates {
        args.push("-allowProvisioningUpdates".into());
    }
    args
}

fn export_method(options: &Path) -> Result<String> {
    Ok(plist::Value::from_file(options)?
        .as_dictionary()
        .and_then(|d| d.get("method"))
        .and_then(plist::Value::as_string)
        .unwrap_or("development")
        .to_owned())
}

fn validate_export_options(path: &Path) -> Result<Vec<u8>> {
    const MAX_BYTES: u64 = 1024 * 1024;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(path)
        .context("cannot open export-options plist")?;
    let metadata = file.metadata()?;
    ensure!(
        metadata.is_file(),
        "export-options plist must be a regular file"
    );
    ensure!(
        metadata.len() <= MAX_BYTES,
        "export-options plist exceeds 1 MiB"
    );
    let mut bytes = Vec::new();
    file.take(MAX_BYTES + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() as u64 <= MAX_BYTES,
        "export-options plist exceeds 1 MiB"
    );
    let value = plist::Value::from_reader(std::io::Cursor::new(&bytes))
        .context("cannot read export-options plist")?;
    let dictionary = value
        .as_dictionary()
        .context("export-options plist must be a dictionary")?;
    if let Some(destination) = dictionary.get("destination") {
        ensure!(
            destination.as_string() == Some("export"),
            "only local export is supported; export-options destination must be 'export'"
        );
    }
    Ok(bytes)
}

/// Resolves when the build is cancelled or its supervisor is gone; never
/// without a receiver.
pub(crate) async fn cancelled(cancel: Option<watch::Receiver<bool>>) {
    let Some(mut cancel) = cancel else {
        return std::future::pending().await;
    };
    loop {
        if *cancel.borrow_and_update() {
            return;
        }
        // Losing the supervisor is also cancellation; do not leave an orphan.
        if cancel.changed().await.is_err() {
            return;
        }
    }
}

fn is_cancelled(cancel: &watch::Receiver<bool>) -> bool {
    *cancel.borrow() || cancel.has_changed().is_err()
}

struct ProcessGroup(libc::pid_t);

impl Drop for ProcessGroup {
    fn drop(&mut self) {
        if self.0 > 0 {
            // The child creates its own group before exec. A negative pid only
            // addresses that group, never the server's process group.
            unsafe {
                libc::kill(-self.0, libc::SIGKILL);
            }
        }
    }
}

/// Where a helper's output stream goes.
pub(crate) enum Sink {
    Discard,
    File(File),
    /// Collected in memory; more than this many bytes is an error.
    Capture(usize),
}

impl Sink {
    fn stdio(&self) -> std::io::Result<(Stdio, Option<usize>)> {
        Ok(match self {
            Sink::Discard => (Stdio::null(), None),
            Sink::File(file) => (file.try_clone()?.into(), None),
            Sink::Capture(limit) => (Stdio::piped(), Some(*limit)),
        })
    }
}

pub(crate) struct Finished {
    pub status: std::process::ExitStatus,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

/// Why a helper produced no exit status. Callers word their own messages.
#[derive(Debug)]
pub(crate) enum RunError {
    Cancelled,
    TimedOut,
    Failed(anyhow::Error),
}

impl std::fmt::Display for RunError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RunError::Cancelled => write!(f, "cancelled"),
            RunError::TimedOut => write!(f, "exceeded its deadline"),
            RunError::Failed(error) => write!(f, "{error:#}"),
        }
    }
}

impl std::error::Error for RunError {}

async fn read_limited(
    pipe: Option<impl tokio::io::AsyncRead + Unpin>,
    limit: Option<usize>,
) -> Result<Vec<u8>> {
    use tokio::io::AsyncReadExt;
    let (Some(pipe), Some(limit)) = (pipe, limit) else {
        return Ok(Vec::new());
    };
    let mut bytes = Vec::new();
    pipe.take(limit as u64 + 1).read_to_end(&mut bytes).await?;
    ensure!(bytes.len() <= limit, "output exceeds {limit} bytes");
    Ok(bytes)
}

/// Runs one helper in its own process group, bounded by `deadline`, `cancel`
/// and output limits. Whatever stops it early, including dropping this future,
/// kills the whole group. A nonzero exit is returned, not an error.
pub(crate) async fn run_bounded(
    mut command: Command,
    stdout: Sink,
    stderr: Sink,
    deadline: Instant,
    cancel: Option<watch::Receiver<bool>>,
) -> Result<Finished, RunError> {
    if cancel.as_ref().is_some_and(is_cancelled) {
        return Err(RunError::Cancelled);
    }
    if Instant::now() >= deadline {
        return Err(RunError::TimedOut);
    }
    let program = command.as_std().get_program().to_owned();
    let failed = |error: std::io::Error| RunError::Failed(error.into());
    let (out, out_limit) = stdout.stdio().map_err(failed)?;
    let (err, err_limit) = stderr.stdio().map_err(failed)?;
    command
        .stdin(Stdio::null())
        .stdout(out)
        .stderr(err)
        .kill_on_drop(true);
    command.as_std_mut().process_group(0);
    let mut child = command.spawn().map_err(|error| {
        RunError::Failed(
            anyhow::Error::new(error)
                .context(format!("cannot start {}", Path::new(&program).display())),
        )
    })?;
    let Some(pid) = child.id() else {
        return Err(RunError::Failed(anyhow::anyhow!(
            "helper has no process id"
        )));
    };
    let mut group = ProcessGroup(pid as libc::pid_t);
    let (out, err) = (child.stdout.take(), child.stderr.take());
    let work = async {
        let (stdout, stderr) =
            tokio::try_join!(read_limited(out, out_limit), read_limited(err, err_limit))?;
        let status = child.wait().await?;
        Ok::<_, anyhow::Error>(Finished {
            status,
            stdout,
            stderr,
        })
    };
    let result = tokio::select! {
        biased;
        _ = cancelled(cancel) => Err(RunError::Cancelled),
        _ = tokio::time::sleep_until(deadline) => Err(RunError::TimedOut),
        result = work => result.map_err(RunError::Failed),
    };
    if matches!(child.try_wait(), Ok(Some(_))) {
        // The leader is reaped. Disarm to avoid ever signalling a reused
        // process id.
        group.0 = 0;
    } else {
        drop(group);
        let _ = child.start_kill();
        let _ = tokio::time::timeout(Duration::from_secs(5), child.wait()).await;
    }
    result
}

pub(crate) async fn run_command(
    args: &[OsString],
    log_path: &Path,
    stdout_path: Option<&Path>,
    deadline: Instant,
    cancel: watch::Receiver<bool>,
) -> Result<()> {
    let mut log = OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path)?;
    writeln!(log, "\n$ /usr/bin/xcodebuild {args:?}")?;
    let stdout = match stdout_path {
        Some(path) => File::create(path)?,
        None => log.try_clone()?,
    };
    let mut command = Command::new("/usr/bin/xcodebuild");
    command.args(args);
    let result = run_bounded(
        command,
        Sink::File(stdout),
        Sink::File(log.try_clone()?),
        deadline,
        Some(cancel),
    )
    .await;
    let reason = match result {
        Ok(finished) => {
            if let Some(path) = stdout_path {
                std::io::copy(&mut File::open(path)?, &mut log)?;
            }
            let status = finished.status;
            writeln!(log, "\nxcodebuild exited: {status}")?;
            ensure!(
                status.success(),
                "xcodebuild failed ({status}); see {}",
                log_path.display()
            );
            return Ok(());
        }
        Err(RunError::Failed(error)) => {
            return Err(error.context("cannot run /usr/bin/xcodebuild; check Xcode installation"));
        }
        Err(RunError::Cancelled) => "build cancelled",
        Err(RunError::TimedOut) => "build exceeded the 30-minute timeout",
    };
    let _ = writeln!(log, "\n{reason}; terminated xcodebuild process group");
    bail!("{reason}; see {}", log_path.display())
}

#[derive(Deserialize)]
struct TargetSettings {
    #[serde(rename = "buildSettings")]
    settings: std::collections::HashMap<String, String>,
}

fn simulator_app(targets: &[TargetSettings]) -> Result<PathBuf> {
    let mut apps = Vec::new();
    for target in targets {
        let Some(name) = target.settings.get("FULL_PRODUCT_NAME") else {
            continue;
        };
        if Path::new(name).extension() != Some(OsStr::new("app")) {
            continue;
        }
        let Some(directory) = target.settings.get("TARGET_BUILD_DIR") else {
            continue;
        };
        let path = Path::new(directory).join(name);
        if path.is_dir() && !apps.contains(&path) {
            apps.push(path);
        }
    }
    exactly_one(
        apps,
        "built simulator application (choose a scheme with one app)",
    )
}

fn children_with_extension(
    directory: &Path,
    extension: &str,
    directories: bool,
) -> Result<Vec<PathBuf>> {
    if !directory.exists() {
        return Ok(Vec::new());
    }
    let mut paths = Vec::new();
    for entry in
        fs::read_dir(directory).with_context(|| format!("cannot read {}", directory.display()))?
    {
        let entry = entry?;
        let kind = entry.file_type()?;
        if entry.path().extension() == Some(OsStr::new(extension))
            && ((directories && kind.is_dir()) || (!directories && kind.is_file()))
        {
            paths.push(entry.path());
        }
    }
    paths.sort();
    Ok(paths)
}

fn exactly_one(mut paths: Vec<PathBuf>, description: &str) -> Result<PathBuf> {
    ensure!(
        paths.len() == 1,
        "expected exactly one {description}, found {}",
        paths.len()
    );
    Ok(paths.remove(0))
}

fn read_app_metadata(app: &Path, fallback_title: &str) -> Result<BuildOutput> {
    let info = app.join("Info.plist");
    let value = plist::Value::from_file(&info)
        .with_context(|| format!("cannot read {}", info.display()))?;
    let dictionary = value
        .as_dictionary()
        .context("app Info.plist must be a dictionary")?;
    let required = |key: &str| -> Result<String> {
        dictionary
            .get(key)
            .and_then(plist::Value::as_string)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .with_context(|| format!("app Info.plist is missing {key}"))
    };
    let title = ["CFBundleDisplayName", "CFBundleName"]
        .into_iter()
        .find_map(|key| {
            dictionary
                .get(key)
                .and_then(plist::Value::as_string)
                .filter(|s| !s.is_empty())
        })
        .unwrap_or(fallback_title)
        .to_owned();
    Ok(BuildOutput {
        preview_path: None,
        preview_state: None,
        preview_error: None,
        preview_captured_at: None,
        preview_source: None,
        archive_path: None,
        ipa_path: None,
        app_path: None,
        dsym_paths: Vec::new(),
        bundle_id: required("CFBundleIdentifier")?,
        version: required("CFBundleShortVersionString")?,
        build_number: required("CFBundleVersion")?,
        title,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(mode: BuildMode) -> BuildRequest {
        BuildRequest {
            project: "/tmp/My App;$(echo nope).xcodeproj".into(),
            scheme: "App ; $(touch nope)".into(),
            configuration: "Release Candidate".into(),
            mode,
            export_options: None,
            allow_provisioning_updates: false,
            capture_preview: false,
            request_id: None,
            no_overlay: false,
        }
    }

    #[test]
    fn shell_metacharacters_remain_single_literal_arguments() {
        let request = request(BuildMode::Simulator);
        let args = build_args(&request, &request.project, Path::new("/tmp/Job ; space")).unwrap();
        assert_eq!(args[1], request.project.as_os_str());
        assert_eq!(args[3], OsStr::new("App ; $(touch nope)"));
        assert_eq!(args[5], OsStr::new("Release Candidate"));
        assert_eq!(args[7], OsStr::new("/tmp/Job ; space/DerivedData"));
        assert!(args.contains(&OsString::from("SQUIRCLE_BUILD_ID=Job ; space")));
        assert!(args.contains(&OsString::from("CODE_SIGNING_ALLOWED=NO")));
        assert!(!args.iter().any(|arg| arg == "-allowProvisioningUpdates"));
    }

    #[test]
    fn provisioning_changes_require_explicit_opt_in_and_only_apply_to_archives() {
        let mut request = request(BuildMode::Archive);
        let directory = Path::new("/tmp/build-1");
        let options = Path::new("/tmp/Export.plist");
        let flag = OsString::from("-allowProvisioningUpdates");
        assert!(
            !build_args(&request, &request.project, directory)
                .unwrap()
                .contains(&flag)
        );
        assert!(!export_args(directory, directory, options, false).contains(&flag));
        request.allow_provisioning_updates = true;
        assert!(
            build_args(&request, &request.project, directory)
                .unwrap()
                .contains(&flag)
        );
        assert!(export_args(directory, directory, options, true).contains(&flag));
        request.mode = BuildMode::Simulator;
        assert!(
            !build_args(&request, &request.project, directory)
                .unwrap()
                .contains(&flag)
        );
    }

    #[test]
    fn existing_requests_default_to_no_provisioning_changes() {
        let request: BuildRequest = serde_json::from_value(serde_json::json!({
            "project": "/tmp/App.xcodeproj", "scheme": "App", "configuration": "Release",
            "mode": "archive", "export_options": "/tmp/Export.plist", "request_id": null,
        }))
        .unwrap();
        assert!(!request.allow_provisioning_updates);
    }

    #[test]
    fn rejects_incompatible_modes_and_invalid_project_types() {
        let mut request = request(BuildMode::Archive);
        assert!(validate_request(&request).is_err());
        request.export_options = Some("/tmp/Export.plist".into());
        assert!(validate_request(&request).is_ok());
        request.mode = BuildMode::Simulator;
        assert!(validate_request(&request).is_err());
        assert_eq!(
            project_flag(Path::new("a.xcworkspace")).unwrap(),
            "-workspace"
        );
        assert!(project_flag(Path::new("a.swift")).is_err());
    }

    #[test]
    fn refuses_ambiguous_or_missing_artifacts() {
        assert!(exactly_one(Vec::new(), "IPA").is_err());
        assert!(exactly_one(vec!["a.ipa".into(), "b.ipa".into()], "IPA").is_err());
        assert_eq!(
            exactly_one(vec!["a.ipa".into()], "IPA").unwrap(),
            PathBuf::from("a.ipa")
        );
    }

    #[tokio::test]
    async fn cancellation_wakes_when_supervisor_closes() {
        let (sender, receiver) = watch::channel(false);
        drop(sender);
        tokio::time::timeout(Duration::from_secs(1), cancelled(Some(receiver)))
            .await
            .unwrap();
    }

    #[test]
    fn reads_binary_app_metadata_and_falls_back_to_bundle_name() {
        let directory = tempfile::tempdir().unwrap();
        let mut info = plist::Dictionary::new();
        for (key, value) in [
            ("CFBundleIdentifier", "com.example.App"),
            ("CFBundleVersion", "42"),
            ("CFBundleShortVersionString", "1.2"),
            ("CFBundleName", "Example App"),
        ] {
            info.insert(key.into(), plist::Value::String(value.into()));
        }
        plist::Value::Dictionary(info)
            .to_file_binary(directory.path().join("Info.plist"))
            .unwrap();
        let result = read_app_metadata(directory.path(), "Fallback").unwrap();
        assert_eq!(result.bundle_id, "com.example.App");
        assert_eq!(result.build_number, "42");
        assert_eq!(result.title, "Example App");
        assert!(result.ipa_path.is_none());
    }

    #[test]
    fn refuses_export_options_that_upload_instead_of_exporting() {
        let file = tempfile::NamedTempFile::new().unwrap();
        let mut options = plist::Dictionary::new();
        options.insert("destination".into(), plist::Value::String("upload".into()));
        plist::Value::Dictionary(options.clone())
            .to_file_xml(file.path())
            .unwrap();
        assert!(validate_export_options(file.path()).is_err());
        options.insert("destination".into(), plist::Value::String("export".into()));
        plist::Value::Dictionary(options)
            .to_file_xml(file.path())
            .unwrap();
        assert!(validate_export_options(file.path()).is_ok());
    }

    #[test]
    fn export_options_reject_pipes_and_oversized_files_without_blocking() {
        use std::os::unix::ffi::OsStrExt;
        let directory = tempfile::tempdir().unwrap();
        let pipe = directory.path().join("options.plist");
        let name = std::ffi::CString::new(pipe.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
        let started = std::time::Instant::now();
        assert!(
            validate_export_options(&pipe)
                .unwrap_err()
                .to_string()
                .contains("regular file")
        );
        assert!(started.elapsed() < Duration::from_secs(1));
        let file = tempfile::NamedTempFile::new().unwrap();
        file.as_file().set_len(1024 * 1024 + 1).unwrap();
        assert!(
            validate_export_options(file.path())
                .unwrap_err()
                .to_string()
                .contains("1 MiB")
        );
    }

    #[test]
    fn validated_export_bytes_are_independent_of_later_source_edits() {
        let file = tempfile::NamedTempFile::new().unwrap();
        let mut options = plist::Dictionary::new();
        options.insert("destination".into(), plist::Value::String("export".into()));
        plist::Value::Dictionary(options.clone())
            .to_file_xml(file.path())
            .unwrap();
        let snapshot = validate_export_options(file.path()).unwrap();
        options.insert("destination".into(), plist::Value::String("upload".into()));
        plist::Value::Dictionary(options)
            .to_file_xml(file.path())
            .unwrap();
        assert!(validate_export_options(file.path()).is_err());
        let saved = plist::Value::from_reader(std::io::Cursor::new(snapshot)).unwrap();
        assert_eq!(
            saved.as_dictionary().unwrap()["destination"].as_string(),
            Some("export")
        );
    }

    #[tokio::test]
    async fn bounded_helpers_stop_on_cancellation_and_output_limits() {
        let (sender, cancel) = watch::channel(false);
        let started = Instant::now();
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "sleep 30 & wait"]);
        let run = tokio::spawn(run_bounded(
            command,
            Sink::Capture(1024),
            Sink::Discard,
            started + Duration::from_secs(30),
            Some(cancel),
        ));
        tokio::time::sleep(Duration::from_millis(200)).await;
        sender.send(true).unwrap();
        let result = tokio::time::timeout(Duration::from_secs(5), run)
            .await
            .unwrap()
            .unwrap();
        assert!(matches!(result, Err(RunError::Cancelled)));
        assert!(started.elapsed() < Duration::from_secs(5));

        let mut command = Command::new("/bin/sh");
        command.args(["-c", "yes | head -c 4096"]);
        let result = run_bounded(
            command,
            Sink::Capture(1024),
            Sink::Discard,
            Instant::now() + Duration::from_secs(10),
            None,
        )
        .await;
        assert!(matches!(result, Err(RunError::Failed(_))));

        let mut command = Command::new("/bin/sh");
        command.args(["-c", "echo out; echo err >&2; exit 3"]);
        let finished = run_bounded(
            command,
            Sink::Capture(1024),
            Sink::Capture(1024),
            Instant::now() + Duration::from_secs(10),
            None,
        )
        .await
        .unwrap();
        assert_eq!(finished.status.code(), Some(3));
        assert_eq!(finished.stdout, b"out\n");
        assert_eq!(finished.stderr, b"err\n");
    }

    #[tokio::test]
    async fn dropping_process_group_terminates_its_child() {
        use std::os::unix::process::ExitStatusExt;
        let mut command = Command::new("/bin/sleep");
        command.arg("30").kill_on_drop(true);
        command.as_std_mut().process_group(0);
        let mut child = command.spawn().unwrap();
        let group = ProcessGroup(child.id().unwrap() as libc::pid_t);
        drop(group);
        let status = tokio::time::timeout(Duration::from_secs(5), child.wait())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(status.signal(), Some(libc::SIGKILL));
    }
}
