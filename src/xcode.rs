use crate::process::{RunError, Sink, run_bounded};
use std::{
    ffi::{OsStr, OsString},
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, bail, ensure};
use serde::Deserialize;
use tokio::{process::Command, sync::watch};

use crate::{
    model::{BuildMode, BuildOutput, BuildRequest},
    overlay,
};

/// The app's own identity, read from the built product.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppMetadata {
    pub bundle_id: String,
    pub version: String,
    pub build_number: String,
    pub title: String,
}

/// What a successful build produced. An archive always has its signed IPA, a
/// simulator build its app bundle.
#[derive(Clone, Debug)]
pub enum BuildArtifacts {
    Archive {
        archive: PathBuf,
        ipa: PathBuf,
        app: PathBuf,
        dsyms: Vec<PathBuf>,
        metadata: AppMetadata,
    },
    Simulator {
        app: PathBuf,
        dsyms: Vec<PathBuf>,
        metadata: AppMetadata,
    },
}

impl BuildArtifacts {
    pub fn app(&self) -> &Path {
        match self {
            Self::Archive { app, .. } | Self::Simulator { app, .. } => app,
        }
    }

    pub fn metadata(&self) -> &AppMetadata {
        match self {
            Self::Archive { metadata, .. } | Self::Simulator { metadata, .. } => metadata,
        }
    }
}

/// The persisted job record's shape, until it holds `BuildArtifacts` itself.
impl From<BuildArtifacts> for BuildOutput {
    fn from(artifacts: BuildArtifacts) -> Self {
        let (archive, ipa, app, dsyms, metadata) = match artifacts {
            BuildArtifacts::Archive {
                archive,
                ipa,
                app,
                dsyms,
                metadata,
            } => (Some(archive), Some(ipa), app, dsyms, metadata),
            BuildArtifacts::Simulator {
                app,
                dsyms,
                metadata,
            } => (None, None, app, dsyms, metadata),
        };
        BuildOutput {
            archive_path: archive,
            ipa_path: ipa,
            app_path: Some(app),
            dsym_paths: dsyms,
            bundle_id: metadata.bundle_id,
            version: metadata.version,
            build_number: metadata.build_number,
            title: metadata.title,
        }
    }
}

/// `build`, in the job record's shape.
pub async fn run(
    request: &BuildRequest,
    job_dir: &Path,
    cancel: watch::Receiver<bool>,
) -> Result<BuildOutput> {
    build(request, job_dir, cancel).await.map(BuildOutput::from)
}

/// Build into an existing, unique job directory. Dropping this future terminates
/// the current xcodebuild process group, including on server task shutdown.
pub async fn build(
    request: &BuildRequest,
    job_dir: &Path,
    cancel: watch::Receiver<bool>,
) -> Result<BuildArtifacts> {
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
            run_command(&args, &log, None, cancel.clone()).await?;
            let archived = exactly_one(
                children_with_extension(&archive.join("Products/Applications"), "app", true)?,
                "archived application",
            )?;
            let overlay = !request.no_overlay
                && overlay::allowed_method(&export_method(&options)?)
                && !overlay::is_squircle(&archived)?;
            if overlay {
                let data_root = job_dir
                    .parent()
                    .and_then(Path::parent)
                    .context("job directory is not inside a Squircle data directory")?;
                let framework = overlay::framework(data_root, &log, cancel.clone()).await?;
                let build_id = job_dir
                    .file_name()
                    .and_then(|n| n.to_str())
                    .context("job directory must have a build ID as its final component")?;
                overlay::inject(&archived, &framework, build_id, &log, cancel.clone()).await?;
            }
            let args = export_args(
                &archive,
                &export,
                &options,
                request.allow_provisioning_updates,
            );
            run_command(&args, &log, None, cancel).await?;
            let ipa = exactly_one(
                children_with_extension(&export, "ipa", false)?,
                "exported IPA",
            )?;
            let app = exactly_one(
                children_with_extension(&archive.join("Products/Applications"), "app", true)?,
                "archived application",
            )?;
            Ok(BuildArtifacts::Archive {
                metadata: read_app_metadata(&app, &request.scheme)?,
                dsyms: children_with_extension(&archive.join("dSYMs"), "dSYM", true)?,
                archive,
                ipa,
                app,
            })
        }
        BuildMode::Simulator => {
            let args = build_args(request, &project, &job_dir)?;
            run_command(&args, &log, None, cancel.clone()).await?;
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
            run_command(&args, &log, Some(&settings_path), cancel).await?;
            let settings: Vec<TargetSettings> =
                serde_json::from_reader(File::open(&settings_path)?)
                    .context("xcodebuild did not return valid build settings JSON")?;
            let app = simulator_app(&settings)?;
            let metadata = read_app_metadata(&app, &request.scheme)?;
            let dsym = app.with_file_name(format!(
                "{}.dSYM",
                app.file_name()
                    .context("app has no name")?
                    .to_string_lossy()
            ));
            Ok(BuildArtifacts::Simulator {
                dsyms: if dsym.is_dir() {
                    vec![dsym]
                } else {
                    Vec::new()
                },
                app,
                metadata,
            })
        }
    }
}

/// What a finished build leaves that nothing reads again: an archive job's
/// DerivedData (its app and dSYMs are in the archive, the IPA in the export).
/// A simulator job keeps its own: its app and dSYM live there.
pub fn spent(job_dir: &Path, mode: Option<&BuildMode>) -> Vec<PathBuf> {
    let mut spent = Vec::new();
    if matches!(mode, Some(BuildMode::Archive)) {
        spent.push(job_dir.join("DerivedData"));
    }
    spent.retain(|p| p.is_dir());
    spent
}

/// Deletes `spent(job_dir, mode)`, logging what it can't.
pub async fn shed(job_dir: PathBuf, mode: Option<BuildMode>) {
    let _ = tokio::task::spawn_blocking(move || {
        for dir in spent(&job_dir, mode.as_ref()) {
            if let Err(error) = fs::remove_dir_all(&dir) {
                eprintln!("Cannot delete {}: {error}", dir.display());
            }
        }
    })
    .await;
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

pub(crate) async fn run_command(
    args: &[OsString],
    log_path: &Path,
    stdout_path: Option<&Path>,
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

fn read_app_metadata(app: &Path, fallback_title: &str) -> Result<AppMetadata> {
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
    Ok(AppMetadata {
        bundle_id: required("CFBundleIdentifier")?,
        version: required("CFBundleShortVersionString")?,
        build_number: required("CFBundleVersion")?,
        title,
    })
}
