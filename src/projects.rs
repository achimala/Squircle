//! Shallow Mac browsing and bounded Xcode metadata inspection; never builds.
use crate::{
    apps::{self, AppRecord, AppRegistration},
    model::{BuildMode, BuildRequest},
    store::{Store, private_dir},
    xcode,
};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    ffi::OsString,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    time::Duration,
};
use tokio::{process::Command, time::Instant};

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
    let deadline = Instant::now() + Duration::from_secs(45);
    let mut list_args = args(&project);
    list_args.extend(["-list".into(), "-json".into()]);
    let list = match xcode_json(&list_args, deadline)
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
    match xcode_json(&settings_args, deadline)
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
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        File::open(&directory)?.sync_all()?;
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
        },
    )
}

async fn xcode_json(args: &[OsString], deadline: Instant) -> Result<Vec<u8>> {
    let mut command = Command::new("/usr/bin/xcodebuild");
    command.args(args);
    bounded_output(command, deadline).await
}

async fn bounded_output(command: Command, deadline: Instant) -> Result<Vec<u8>> {
    let finished = xcode::run_bounded(
        command,
        xcode::Sink::Capture(8 * 1024 * 1024),
        xcode::Sink::Capture(1024 * 1024),
        deadline,
        None,
    )
    .await
    .map_err(|error| match error {
        xcode::RunError::TimedOut | xcode::RunError::Cancelled => anyhow::anyhow!(
            "Xcode inspection exceeded 45 seconds; resolve packages/setup in Xcode, then retry"
        ),
        xcode::RunError::Failed(error) => {
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fixture() -> (tempfile::TempDir, Store, Inspection) {
        let temp = tempfile::tempdir().unwrap();
        let project = temp.path().join("New App.xcodeproj");
        fs::create_dir(&project).unwrap();
        let store = Store::open(temp.path().join("state")).unwrap();
        let inspected = Inspection {
            project: project.canonicalize().unwrap(),
            name: "New App".into(),
            schemes: vec!["New App".into()],
            scheme: Some("New App".into()),
            configuration: "Release".into(),
            bundle_id: Some("dev.example.newapp".into()),
            team_id: None,
            export_options: None,
            issue: Some("No signing team is configured".into()),
            can_import: true,
        };
        (temp, store, inspected)
    }
    fn ios_settings() -> serde_json::Value {
        json!({"PRODUCT_TYPE":"com.apple.product-type.application","PLATFORM_NAME":"iphoneos","PRODUCT_BUNDLE_IDENTIFIER":"dev.example.app","PRODUCT_NAME":"Example","DEVELOPMENT_TEAM":""})
    }
    #[test]
    fn browse_is_shallow_sorted_and_keeps_packages_selectable() {
        let temp = tempfile::tempdir().unwrap();
        for name in [
            "zFolder",
            "A.xcodeproj",
            "b.xcworkspace",
            ".hidden",
            "Unrelated.app",
        ] {
            fs::create_dir(temp.path().join(name)).unwrap();
        }
        fs::write(temp.path().join("README.txt"), "text").unwrap();
        fs::create_dir(temp.path().join("A.xcodeproj/Internals")).unwrap();
        let directory = browse(temp.path().to_str()).unwrap();
        assert_eq!(
            directory
                .entries
                .iter()
                .map(|entry| (entry.name.as_str(), entry.kind))
                .collect::<Vec<_>>(),
            vec![
                ("A.xcodeproj", "project"),
                ("b.xcworkspace", "workspace"),
                ("zFolder", "directory")
            ]
        );
        assert!(browse(temp.path().join("A.xcodeproj").to_str()).is_err());
        assert!(browse(temp.path().join("b.xcworkspace").to_str()).is_err());
        assert!(browse(Some("relative/folder")).is_err());
        assert_eq!(
            resolve_path(Some("~")).unwrap(),
            dirs::home_dir().unwrap().canonicalize().unwrap()
        );
    }
    #[test]
    fn parses_project_and_workspace_schemes_without_inventing_choices() {
        assert_eq!(
            parse_schemes(br#"{"project":{"schemes":["Z","App","App"]}}"#).unwrap(),
            ["App", "Z"]
        );
        assert_eq!(
            parse_schemes(br#"{"workspace":{"schemes":["App"]}}"#).unwrap(),
            ["App"]
        );
        assert!(
            parse_schemes(br#"{"project":{"schemes":[]}}"#)
                .unwrap()
                .is_empty()
        );
        assert!(parse_schemes(b"not JSON").is_err());
        assert!(parse_schemes(br#"{"other":{}}"#).is_err());
    }
    #[test]
    fn settings_select_only_one_real_iphoneos_app_and_allow_missing_team() {
        let mut framework = ios_settings();
        framework["PRODUCT_TYPE"] = json!("com.apple.product-type.framework");
        let settings = parse_app_settings(
            &serde_json::to_vec(
                &json!([{"buildSettings":framework},{"buildSettings":ios_settings()}]),
            )
            .unwrap(),
        )
        .unwrap();
        let (_temp, _store, mut inspection) = fixture();
        apply_settings(&mut inspection, &settings);
        assert!(inspection.can_import);
        assert_eq!(inspection.team_id, None);
        assert_eq!(inspection.bundle_id.as_deref(), Some("dev.example.app"));
        assert!(
            parse_app_settings(&serde_json::to_vec(&json!([{"buildSettings":framework}])).unwrap())
                .is_err()
        );
        assert!(
            parse_app_settings(
                &serde_json::to_vec(
                    &json!([{"buildSettings":ios_settings()},{"buildSettings":ios_settings()}])
                )
                .unwrap()
            )
            .is_err()
        );
        let mut mac = ios_settings();
        mac["PLATFORM_NAME"] = json!("macosx");
        assert!(
            parse_app_settings(&serde_json::to_vec(&json!([{"buildSettings":mac}])).unwrap())
                .is_err()
        );
        let mut unresolved = ios_settings();
        unresolved["PRODUCT_BUNDLE_IDENTIFIER"] = json!("$(BUNDLE)");
        assert!(
            parse_app_settings(
                &serde_json::to_vec(&json!([{"buildSettings":unresolved}])).unwrap()
            )
            .is_err()
        );
    }
    #[test]
    fn import_without_build_history_persists_recipe_and_preserves_it_on_registration() {
        let (_temp, store, inspection) = fixture();
        assert!(store.list_jobs().unwrap().is_empty());
        let imported = import_inspected(&store, &inspection, "New App").unwrap();
        let recipe = imported.build_request.as_ref().unwrap();
        assert_eq!(recipe.mode, BuildMode::Archive);
        assert!(recipe.capture_preview);
        assert!(recipe.allow_provisioning_updates);
        assert!(recipe.request_id.is_none());
        let options = plist::Value::from_file(recipe.export_options.as_ref().unwrap()).unwrap();
        let options = options.as_dictionary().unwrap();
        assert_eq!(options["method"].as_string(), Some("release-testing"));
        assert_eq!(options["signingStyle"].as_string(), Some("automatic"));
        assert!(options.get("teamID").is_none());
        assert!(
            recipe
                .export_options
                .as_ref()
                .unwrap()
                .starts_with(&store.root)
        );
        let again = apps::register(
            &store,
            AppRegistration {
                name: "Do not replace".into(),
                project: inspection.project.clone(),
                scheme: inspection.scheme.clone().unwrap(),
                bundle_id: inspection.bundle_id.clone(),
                summary: "Do not replace".into(),
            },
        )
        .unwrap();
        assert_eq!(again.build_request, imported.build_request);
        assert_eq!(again.name, "New App");
        let root = store.root.clone();
        drop(store);
        let restarted = Store::open(root).unwrap();
        assert_eq!(
            apps::get(&restarted, &imported.id).unwrap().build_request,
            imported.build_request
        );
        assert!(restarted.list_jobs().unwrap().is_empty());
        assert_eq!(
            fs::read_dir(&inspection.project).unwrap().count(),
            0,
            "import edited the Xcode project"
        );
    }
    #[test]
    fn existing_export_options_are_reused_and_upload_templates_rejected() {
        let (_temp, store, mut inspection) = fixture();
        let path = inspection
            .project
            .parent()
            .unwrap()
            .join("ExportOptions.plist");
        let mut options = plist::Dictionary::new();
        options.insert("method".into(), "release-testing".into());
        options.insert("teamID".into(), "EXAMPLETEAM".into());
        plist::Value::Dictionary(options.clone())
            .to_file_xml(&path)
            .unwrap();
        let original = fs::read(&path).unwrap();
        inspection.export_options = Some(path.clone());
        let app = import_inspected(&store, &inspection, "Example").unwrap();
        assert_eq!(
            app.build_request.unwrap().export_options,
            Some(path.clone())
        );
        assert_eq!(fs::read(&path).unwrap(), original);
        options.insert("destination".into(), "upload".into());
        plist::Value::Dictionary(options)
            .to_file_xml(&path)
            .unwrap();
        assert!(read_export_options(&path).is_err());
    }
    #[test]
    fn legacy_app_records_default_to_metadata_only_and_invalid_targets_are_not_imported() {
        let (_temp, store, mut inspection) = fixture();
        inspection.can_import = false;
        assert!(import_inspected(&store, &inspection, "No app").is_err());
        assert!(apps::list(&store).unwrap().is_empty());
        let record:AppRecord=serde_json::from_value(json!({"id":uuid::Uuid::new_v4().to_string(),"name":"Legacy","project":"/tmp/Legacy.xcodeproj","scheme":"Legacy","bundle_id":null,"summary":"","updated_at":1,"preview":null})).unwrap();
        assert!(record.build_request.is_none());
    }
    #[tokio::test]
    async fn inspection_subprocess_deadline_kills_owned_child_group() {
        let mut command = Command::new("/bin/sleep");
        command.arg("30");
        let started = Instant::now();
        let error = bounded_output(command, started + Duration::from_millis(100))
            .await
            .unwrap_err();
        assert!(error.to_string().contains("exceeded"));
        assert!(started.elapsed() < Duration::from_secs(2));
    }
}
