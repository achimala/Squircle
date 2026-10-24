//! Shallow Mac browsing and bounded Xcode metadata inspection; never builds.
use crate::{
    apps::{self, AppRecord, AppRegistration},
    model::{BuildMode, BuildRequest},
    store::{Store, private_dir},
};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    ffi::OsString,
    fs::{self, OpenOptions},
    io::{Read, Write},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
};
use tokio::process::Command;

#[derive(Serialize)]
pub struct Directory {
    pub path: PathBuf,
    pub parent_path: Option<PathBuf>,
    pub entries: Vec<Entry>,
}
#[derive(Serialize)]
pub struct Entry {
    pub name: String,
    pub path: PathBuf,
    pub kind: &'static str,
}

#[derive(Clone, Debug, Serialize)]
pub struct Inspection {
    pub project: PathBuf,
    pub name: String,
    pub schemes: Vec<String>,
    pub scheme: Option<String>,
    pub configuration: String,
    pub bundle_id: Option<String>,
    pub team_id: Option<String>,
    pub export_options: Option<PathBuf>,
    pub issue: Option<String>,
    pub can_import: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ImportRequest {
    pub project: String,
    pub scheme: String,
    pub name: String,
    #[serde(default = "release")]
    pub configuration: String,
}
pub fn release() -> String {
    "Release".into()
}

pub fn resolve_path(value: Option<&str>) -> Result<PathBuf> {
    let home = dirs::home_dir().context("Cannot determine the service user's home directory")?;
    let path = match value {
        None | Some("~") => home,
        Some(value) if value.starts_with("~/") => home.join(&value[2..]),
        Some(value) => {
            let path = PathBuf::from(value);
            ensure!(path.is_absolute(), "Use an absolute Mac path or ~/path");
            path
        }
    };
    ensure!(
        !path.as_os_str().as_encoded_bytes().contains(&0),
        "Path contains NUL"
    );
    path.canonicalize()
        .context("Mac path does not exist or is not accessible to the service")
}
fn kind(path: &Path) -> &'static str {
    match path.extension().and_then(|v| v.to_str()) {
        Some("xcodeproj") => "project",
        Some("xcworkspace") => "workspace",
        _ => "directory",
    }
}
fn other_package(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|v| v.to_str()),
        Some(
            "app"
                | "xcarchive"
                | "bundle"
                | "framework"
                | "xcframework"
                | "playground"
                | "xcassets"
                | "dSYM"
                | "photoslibrary"
                | "pages"
                | "numbers"
                | "key"
        )
    )
}
pub fn browse(value: Option<&str>) -> Result<Directory> {
    let path = resolve_path(value)?;
    ensure!(path.is_dir(), "Choose a directory on the Mac");
    ensure!(
        kind(&path) == "directory" && !other_package(&path),
        "Packages cannot be browsed; inspect an Xcode project or workspace instead"
    );
    let mut entries = Vec::new();
    for item in
        fs::read_dir(&path).context("Cannot list this Mac directory; check service permissions")?
    {
        let item = item?;
        let name = item.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') {
            continue;
        }
        let original = item.path();
        if !original.is_dir() || other_package(&original) {
            continue;
        }
        // Return resolved paths so aliases do not register duplicate projects.
        let Ok(resolved) = original.canonicalize() else {
            continue;
        };
        let entry_kind = kind(&resolved);
        if other_package(&resolved) {
            continue;
        }
        entries.push(Entry {
            name,
            path: resolved,
            kind: entry_kind,
        });
        ensure!(
            entries.len() <= 10_000,
            "Directory contains more than 10,000 visible folders; choose a more specific path"
        );
    }
    entries.sort_by(|a, b| {
        a.name
            .to_lowercase()
            .cmp(&b.name.to_lowercase())
            .then_with(|| a.name.cmp(&b.name))
    });
    Ok(Directory {
        parent_path: path.parent().map(Path::to_owned),
        path,
        entries,
    })
}

fn project_path(value: &str) -> Result<PathBuf> {
    let project = resolve_path(Some(value))?;
    ensure!(
        project.is_dir() && kind(&project) != "directory",
        "Choose an .xcodeproj or .xcworkspace directory"
    );
    Ok(project)
}
fn args(project: &Path) -> Vec<OsString> {
    vec![
        if kind(project) == "workspace" {
            "-workspace".into()
        } else {
            "-project".into()
        },
        project.as_os_str().into(),
        "-disableAutomaticPackageResolution".into(),
        "-skipPackageUpdates".into(),
    ]
}

pub async fn inspect(
    project: &str,
    scheme: Option<&str>,
    configuration: Option<&str>,
) -> Result<Inspection> {
    let project = project_path(project)?;
    let configuration = configuration.unwrap_or("Release").trim();
    ensure!(
        !configuration.is_empty() && configuration.len() <= 200 && !configuration.contains('\0'),
        "Configuration must contain 1–200 characters"
    );
    let mut result = Inspection {
        name: project
            .file_stem()
            .unwrap_or_default()
            .to_string_lossy()
            .into(),
        project: project.clone(),
        schemes: vec![],
        scheme: None,
        configuration: configuration.into(),
        bundle_id: None,
        team_id: None,
        export_options: None,
        issue: None,
        can_import: false,
    };
    let mut list_args = args(&project);
    list_args.extend(["-list".into(), "-json".into()]);
    let list = match xcode_json(&list_args)
        .await
        .and_then(|bytes| parse_schemes(&bytes))
    {
        Ok(list) => list,
        Err(error) => {
            result.issue = Some(format!("Cannot read Xcode schemes: {error:#}"));
            return Ok(result);
        }
    };
    result.schemes = list;
    result.scheme = match scheme {
        Some(scheme) if result.schemes.iter().any(|s| s == scheme) => Some(scheme.into()),
        Some(_) => {
            result.issue=Some("Selected scheme is not available. Open the project in Xcode and share an iOS app scheme.".into());
            return Ok(result);
        }
        None if result.schemes.len() == 1 => Some(result.schemes[0].clone()),
        _ => None,
    };
    let Some(selected) = &result.scheme else {
        result.issue = Some(
            if result.schemes.is_empty() {
                "No schemes are available. Open the project in Xcode and share an iOS app scheme."
            } else {
                "Choose an iOS app scheme."
            }
            .into(),
        );
        return Ok(result);
    };
    let mut settings_args = args(&project);
    settings_args.extend([
        "-scheme".into(),
        selected.into(),
        "-configuration".into(),
        configuration.into(),
        "-sdk".into(),
        "iphoneos".into(),
        "-destination".into(),
        "generic/platform=iOS".into(),
        "-showBuildSettings".into(),
        "-json".into(),
    ]);
    match xcode_json(&settings_args)
        .await
        .and_then(|bytes| parse_app_settings(&bytes))
    {
        Ok(settings) => apply_settings(&mut result, &settings),
        Err(error) => {
            result.issue = Some(format!(
                "Cannot inspect an iOS application target: {error:#}"
            ));
            return Ok(result);
        }
    }
    let parent = project
        .parent()
        .context("Project has no parent directory")?;
    let candidates = [
        parent.join(format!("ExportOptions-{configuration}.plist")),
        parent.join("ExportOptions.plist"),
    ];
    for candidate in candidates {
        if !candidate.exists() {
            continue;
        }
        match read_export_options(&candidate) {
            Ok(options) => {
                if result.team_id.is_none() {
                    result.team_id = options
                        .as_dictionary()
                        .and_then(|v| v.get("teamID"))
                        .and_then(plist::Value::as_string)
                        .filter(|v| !v.is_empty())
                        .map(str::to_owned);
                }
                result.export_options = Some(candidate);
                break;
            }
            Err(error) => add_issue(
                &mut result,
                format!(
                    "Existing export options were not used: {error:#}. Import will create a local release-testing template."
                ),
            ),
        }
    }
    if result.team_id.is_none() {
        add_issue(&mut result,"No signing team is configured. You can add this app, but configure its signing team in Xcode before building for your iPhone.".into());
    }
    Ok(result)
}

fn add_issue(result: &mut Inspection, issue: String) {
    result.issue = Some(match result.issue.take() {
        Some(existing) => format!("{existing} {issue}"),
        None => issue,
    });
}
pub(crate) fn parse_schemes(bytes: &[u8]) -> Result<Vec<String>> {
    let value:serde_json::Value=serde_json::from_slice(bytes).context("Xcode did not return valid JSON; open the project in Xcode to resolve package/setup errors")?;
    let container = value
        .get("workspace")
        .or_else(|| value.get("project"))
        .context("Xcode JSON contains neither project nor workspace")?;
    let mut schemes: Vec<String> = serde_json::from_value(
        container
            .get("schemes")
            .cloned()
            .unwrap_or(serde_json::json!([])),
    )
    .context("Xcode scheme list is invalid")?;
    schemes.retain(|v| !v.trim().is_empty());
    schemes.sort();
    schemes.dedup();
    Ok(schemes)
}
#[derive(Deserialize)]
struct TargetSettings {
    #[serde(rename = "buildSettings")]
    settings: HashMap<String, String>,
}
fn parse_app_settings(bytes: &[u8]) -> Result<HashMap<String, String>> {
    let targets: Vec<TargetSettings> =
        serde_json::from_slice(bytes).context("Xcode build settings are not valid JSON")?;
    let mut apps = targets.into_iter().filter(|target| {
        let s = &target.settings;
        s.get("PRODUCT_TYPE")
            .is_some_and(|v| v == "com.apple.product-type.application")
            && s.get("PLATFORM_NAME").is_some_and(|v| v == "iphoneos")
    });
    let app=apps.next().context("Scheme has no iPhoneOS application target; select the main iOS app scheme, not a framework, tests, or extension")?;
    ensure!(
        apps.next().is_none(),
        "Scheme builds more than one iOS app; choose a scheme with one main application"
    );
    let bundle = app
        .settings
        .get("PRODUCT_BUNDLE_IDENTIFIER")
        .context("iOS app has no PRODUCT_BUNDLE_IDENTIFIER")?;
    ensure!(
        !bundle.is_empty()
            && bundle
                .bytes()
                .all(|v| v.is_ascii_alphanumeric() || b".-".contains(&v)),
        "iOS app bundle identifier is empty or unresolved; configure it in Xcode"
    );
    Ok(app.settings)
}
fn apply_settings(result: &mut Inspection, settings: &HashMap<String, String>) {
    result.can_import = true;
    result.bundle_id = settings.get("PRODUCT_BUNDLE_IDENTIFIER").cloned();
    result.team_id = settings
        .get("DEVELOPMENT_TEAM")
        .filter(|v| !v.is_empty() && v.bytes().all(|c| c.is_ascii_alphanumeric()))
        .cloned();
    if let Some(name) = settings
        .get("INFOPLIST_KEY_CFBundleDisplayName")
        .or_else(|| settings.get("PRODUCT_NAME"))
        .filter(|v| !v.is_empty() && !v.contains("$("))
    {
        result.name = name.clone();
    }
    if settings
        .get("CODE_SIGN_STYLE")
        .is_some_and(|v| v == "Manual")
    {
        add_issue(result,"This project uses manual signing. Its existing Xcode provisioning must be valid before a device build can succeed.".into());
    }
}

fn read_export_options(path: &Path) -> Result<plist::Value> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    ensure!(
        file.metadata()?.is_file() && file.metadata()?.len() <= 1024 * 1024,
        "Export options must be a regular plist no larger than 1 MiB"
    );
    let mut bytes = Vec::new();
    file.take(1024 * 1024 + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= 1024 * 1024, "Export options exceed 1 MiB");
    let value = plist::Value::from_reader(std::io::Cursor::new(bytes))?;
    let dict = value
        .as_dictionary()
        .context("Export options must be a dictionary")?;
    ensure!(
        dict.get("destination")
            .is_none_or(|v| v.as_string() == Some("export")),
        "Only local export is supported; destination must be export"
    );
    ensure!(
        matches!(
            dict.get("method").and_then(plist::Value::as_string),
            Some("release-testing" | "debugging" | "ad-hoc" | "development" | "enterprise")
        ),
        "Export method must support direct iPhone installation (release-testing/debugging/ad-hoc/development/enterprise)"
    );
    Ok(value)
}

/// Called only after fresh server-side Xcode inspection. No source project is edited.
pub fn import_inspected(store: &Store, inspection: &Inspection, name: &str) -> Result<AppRecord> {
    ensure!(
        inspection.can_import,
        "{}",
        inspection
            .issue
            .as_deref()
            .unwrap_or("Choose a valid iOS application scheme")
    );
    let scheme = inspection
        .scheme
        .clone()
        .context("Choose a scheme before importing")?;
    if let Some(path) = &inspection.export_options {
        read_export_options(path)?;
    }
    let app = apps::register(
        store,
        AppRegistration {
            name: name.into(),
            project: inspection.project.clone(),
            scheme: scheme.clone(),
            bundle_id: inspection.bundle_id.clone(),
            summary: String::new(),
        },
    )?;
    let export_options = if let Some(path) = &inspection.export_options {
        read_export_options(path)?;
        path.clone()
    } else {
        let directory = store.root.join("apps").join(&app.id);
        private_dir(&directory)?;
        let path = directory.join(format!("ExportOptions-{}.plist", uuid::Uuid::new_v4()));
        let mut dict = plist::Dictionary::new();
        dict.insert("method".into(), "release-testing".into());
        dict.insert("destination".into(), "export".into());
        dict.insert("signingStyle".into(), "automatic".into());
        dict.insert("manageAppVersionAndBuildNumber".into(), false.into());
        if let Some(team) = &inspection.team_id {
            dict.insert("teamID".into(), team.clone().into());
        }
        let mut bytes = Vec::new();
        plist::Value::Dictionary(dict).to_writer_xml(&mut bytes)?;
        crate::store::write_private(&path, false, |file| Ok(file.write_all(&bytes)?))?;
        path
    };
    apps::set_build_request(
        store,
        &app.id,
        BuildRequest {
            project: inspection.project.clone(),
            scheme,
            configuration: inspection.configuration.clone(),
            mode: BuildMode::Archive,
            export_options: Some(export_options),
            allow_provisioning_updates: true,
            capture_preview: true,
            request_id: None,
            no_overlay: false,
            thread: None,
        },
    )
}

/// xcodebuild's JSON answer; dropping this (the request that asked is
/// gone) stops it and whatever it started.
async fn xcode_json(args: &[OsString]) -> Result<Vec<u8>> {
    let mut command = Command::new("/usr/bin/xcodebuild");
    command.args(args);
    bounded_output(command).await
}

async fn bounded_output(command: Command) -> Result<Vec<u8>> {
    let finished = crate::process::run_bounded(
        command,
        crate::process::Sink::Capture(8 * 1024 * 1024),
        crate::process::Sink::Capture(1024 * 1024),
        None,
    )
    .await
    .map_err(|error| match error {
        crate::process::RunError::Cancelled => anyhow::anyhow!("Xcode inspection cancelled"),
        crate::process::RunError::Failed(error) => {
            error.context("Cannot run xcodebuild; select an installed Xcode on the Mac")
        }
    })?;
    ensure!(
        finished.status.success(),
        "xcodebuild inspection failed ({}): {}",
        finished.status,
        String::from_utf8_lossy(&finished.stderr)
            .chars()
            .take(1500)
            .collect::<String>()
    );
    Ok(finished.stdout)
}
