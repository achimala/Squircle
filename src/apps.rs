//! Persistent app identity and agent-published, immutable screenshot artifacts.
//! Callers hold the Store's outer mutex across these read/modify/write operations,
//! except `stage_preview`, which only writes a new, unreferenced artifact file.
//! A record stays readable when its preview bytes go missing: the artifact is
//! reported unavailable and a new publication repairs it.
use crate::{
    model::{BuildRequest, Job, PreviewArtifact, PreviewSource, PreviewState, now},
    store::{Store, atomic_json, check_dir, open_private_read, private_dir, read_json},
};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
};
use uuid::Uuid;

pub const MAX_PREVIEW_BYTES: u64 = 20 * 1024 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct AppRecord {
    pub id: String,
    pub name: String,
    pub project: PathBuf,
    pub scheme: String,
    pub bundle_id: Option<String>,
    pub summary: String,
    pub updated_at: u64,
    pub preview: Option<AppPreview>,
    #[serde(default)]
    pub build_request: Option<BuildRequest>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct AppPreview {
    pub id: String,
    /// Internal private copy. HTTP clients receive an authenticated image route,
    /// not a path they can use to request arbitrary files from the Mac.
    pub path: PathBuf,
    /// Simulator capture completion, or server acceptance time for agent files.
    pub captured_at: u64,
    pub build_id: Option<String>,
    pub source_revision: Option<String>,
    pub caption: String,
    /// `agent` or `simulator`; supplied provenance is not image attestation.
    pub source: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AppRegistration {
    pub name: String,
    pub project: PathBuf,
    pub scheme: String,
    pub bundle_id: Option<String>,
    #[serde(default)]
    pub summary: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AppUpdate {
    pub name: Option<String>,
    pub summary: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PreviewPublication {
    pub file: PathBuf,
    #[serde(default)]
    pub caption: String,
    pub build_id: Option<String>,
    pub source_revision: Option<String>,
    pub source: Option<String>,
}

pub fn list(store: &Store) -> Result<Vec<AppRecord>> {
    let root = catalog_dir(store)?;
    let mut apps = Vec::new();
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        let Some(id) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        if validate_id(&id).is_err() {
            continue;
        }
        check_dir(&entry.path())?;
        // A failed initial atomic write may leave an empty directory.
        if entry.path().join("app.json").try_exists()? {
            apps.push(get(store, &id)?);
        }
    }
    apps.sort_by(|left, right| {
        right
            .updated_at
            .cmp(&left.updated_at)
            .then_with(|| left.id.cmp(&right.id))
    });
    Ok(apps)
}

/// The registered app a build belongs to: its project and scheme, or for an
/// imported IPA its bundle.
pub fn owner_of<'a>(apps: &'a [AppRecord], job: &Job) -> Option<&'a AppRecord> {
    match job.request() {
        Some(request) => apps.iter().find(|app| app.project == request.project && app.scheme == request.scheme),
        None => {
            let bundle = &job.output()?.bundle_id;
            apps.iter().find(|app| app.bundle_id.as_ref() == Some(bundle))
        }
    }
}

pub fn get(store: &Store, id: &str) -> Result<AppRecord> {
    let directory = app_dir(store, id)?;
    check_dir(&directory)?;
    let app: AppRecord = read_json(&directory.join("app.json"))?;
    ensure!(app.id == id, "app record ID does not match its directory");
    ensure!(
        app.project.is_absolute(),
        "stored app project must be absolute"
    );
    if let Some(preview) = &app.preview {
        validate_id(&preview.id)?;
        ensure!(
            preview.path == preview_path(&directory, &preview.id),
            "stored app preview path is outside its artifact directory"
        );
    }
    Ok(app)
}

/// Opens an app's current preview artifact. Fails when its bytes are missing
/// or invalid; the record itself stays usable (see `get`).
pub fn open_preview(app: &AppRecord) -> Result<File> {
    let preview = app.preview.as_ref().context("App has no published preview")?;
    let directory = preview.path.parent().context("preview has no directory")?;
    check_dir(directory)?;
    // Reuse the store's no-follow open rather than trusting persisted paths.
    let file = open_private_read(&preview.path)?;
    ensure!(
        file.metadata()?.len() <= MAX_PREVIEW_BYTES,
        "preview exceeds 20 MiB"
    );
    Ok(file)
}

/// Re-registration reconciles identity, not editorial metadata. Use `update`
/// explicitly to change an existing app's display name or summary.
pub fn register(store: &Store, registration: AppRegistration) -> Result<AppRecord> {
    let name = nonempty(&registration.name, "app name", 200)?;
    let scheme = nonempty(&registration.scheme, "scheme", 200)?;
    text_limit(&registration.summary, "summary", 16 * 1024)?;
    validate_bundle(registration.bundle_id.as_deref())?;
    let project = registration
        .project
        .canonicalize()
        .context("app project does not exist")?;
    ensure!(
        project.is_dir()
            && matches!(
                project.extension().and_then(|v| v.to_str()),
                Some("xcodeproj" | "xcworkspace")
            ),
        "app project must be an .xcodeproj or .xcworkspace directory"
    );
    if let Some(mut app) = list(store)?
        .into_iter()
        .find(|app| app.project == project && app.scheme == scheme)
    {
        if let Some(bundle) = registration.bundle_id {
            if let Some(existing) = &app.bundle_id {
                ensure!(
                    existing == &bundle,
                    "app bundle ID differs from its registered identity"
                );
            } else {
                app.bundle_id = Some(bundle);
                app.updated_at = now();
                save(store, &app)?;
            }
        }
        return Ok(app);
    }
    let app = AppRecord {
        id: Uuid::new_v4().to_string(),
        name,
        project,
        scheme,
        bundle_id: registration.bundle_id,
        summary: registration.summary,
        updated_at: now(),
        preview: None,
        build_request: None,
    };
    save(store, &app)?;
    Ok(app)
}

pub fn update(store: &Store, id: &str, update: AppUpdate) -> Result<AppRecord> {
    let mut app = get(store, id)?;
    if let Some(name) = update.name {
        app.name = nonempty(&name, "app name", 200)?;
    }
    if let Some(summary) = update.summary {
        text_limit(&summary, "summary", 16 * 1024)?;
        app.summary = summary;
    }
    app.updated_at = now();
    save(store, &app)?;
    Ok(app)
}

pub fn set_build_request(store: &Store, id: &str, request: BuildRequest) -> Result<AppRecord> {
    let mut app = get(store, id)?;
    ensure!(
        request.project == app.project && request.scheme == app.scheme,
        "Build recipe must match the registered project and scheme"
    );
    app.build_request = Some(request);
    app.updated_at = now();
    save(store, &app)?;
    Ok(app)
}

pub fn publish_preview(
    store: &Store,
    id: &str,
    publication: PreviewPublication,
) -> Result<AppRecord> {
    publish_at(store, id, publication, now())
}

/// Build metadata fills missing identity and imports only newer captures. This
/// never replaces agent-edited names/summaries or a more recent agent preview.
pub fn sync_build_preview(store: &Store, job: &Job) -> Result<AppRecord> {
    let request = job
        .request()
        .context("build has no project recipe to associate with an app")?;
    let output = job.output().context("build has no app metadata")?;
    let app = register(
        store,
        AppRegistration {
            name: if output.title.trim().is_empty() {
                request.scheme.clone()
            } else {
                output.title.clone()
            },
            project: request.project.clone(),
            scheme: request.scheme.clone(),
            bundle_id: Some(output.bundle_id.clone()),
            summary: String::new(),
        },
    )?;
    let Some(PreviewArtifact { path: file, captured_at, source }) = job.preview().and_then(PreviewState::artifact) else {
        return Ok(app);
    };
    let captured_at = *captured_at;
    if app
        .preview
        .as_ref()
        .is_some_and(|preview| preview.captured_at >= captured_at)
    {
        return Ok(app);
    }
    let from_current_tree = *source == Some(PreviewSource::CurrentWorkingTree);
    let from_built_product = *source == Some(PreviewSource::BuiltSimulatorProduct);
    publish_at(
        store,
        &app.id,
        PreviewPublication {
            file: file.clone(),
            caption: if from_current_tree {
                "Simulator capture of the current working tree; associated with this build".into()
            } else if from_built_product {
                "Simulator capture of this build's simulator product".into()
            } else {
                "Simulator capture associated with this build".into()
            },
            build_id: Some(job.id.clone()),
            // An archive's later simulator rebuild did not capture its submission
            // revision. Do not turn the old observation into false provenance.
            source_revision: if from_built_product {
                job.provenance().and_then(|p| p.revision.clone())
            } else {
                None
            },
            source: Some("simulator".into()),
        },
        captured_at,
    )
}

fn publish_at(
    store: &Store,
    id: &str,
    publication: PreviewPublication,
    captured_at: u64,
) -> Result<AppRecord> {
    let staged = stage_preview(&store.root, id, &publication.file)?;
    commit_preview(store, id, publication, staged, captured_at)
}

/// A validated, synced preview file that no record references yet. Dropping
/// it uncommitted removes the file.
pub struct StagedPreview {
    id: String,
    path: Option<PathBuf>,
}
impl Drop for StagedPreview {
    fn drop(&mut self) {
        if let Some(path) = self.path.take() {
            let _ = fs::remove_file(path);
        }
    }
}

/// Validates and copies a screenshot into an app's artifact directory without
/// touching its record, so callers can do this file I/O outside the store lock.
pub fn stage_preview(root: &Path, id: &str, file: &Path) -> Result<StagedPreview> {
    validate_id(id)?;
    let directory = root.join("apps").join(id);
    check_dir(&directory).context("app does not exist")?;
    let bytes = read_png(file)?;
    let previews = directory.join("previews");
    private_dir(&previews)?;
    let preview_id = Uuid::new_v4().to_string();
    let path = preview_path(&directory, &preview_id);
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let mut output = options.open(&path)?;
    let staged = StagedPreview { id: preview_id, path: Some(path) };
    output.write_all(&bytes)?;
    output.sync_all()?;
    File::open(&previews)?.sync_all()?;
    Ok(staged)
}

/// Points the app at a staged preview. Works when the previous preview's bytes
/// are missing, which is how a damaged catalog entry is repaired.
pub fn publish_staged(
    store: &Store,
    id: &str,
    publication: PreviewPublication,
    staged: StagedPreview,
) -> Result<AppRecord> {
    commit_preview(store, id, publication, staged, now())
}

fn commit_preview(
    store: &Store,
    id: &str,
    publication: PreviewPublication,
    mut staged: StagedPreview,
    captured_at: u64,
) -> Result<AppRecord> {
    let mut app = get(store, id)?;
    text_limit(&publication.caption, "preview caption", 4096)?;
    if let Some(revision) = &publication.source_revision {
        nonempty(revision, "source revision", 200)?;
    }
    let source = publication.source.unwrap_or_else(|| "agent".into());
    ensure!(
        matches!(source.as_str(), "agent" | "simulator"),
        "preview source must be agent or simulator"
    );
    if let Some(build_id) = &publication.build_id {
        validate_id(build_id)?;
        let job = store.load_job(build_id)?;
        let output = job
            .output()
            .context("associated build has no app output")?;
        if let Some(bundle) = &app.bundle_id {
            ensure!(
                &output.bundle_id == bundle,
                "preview build belongs to a different app bundle"
            );
        }
        if let Some(request) = job.request() {
            ensure!(
                request.project.canonicalize()? == app.project && request.scheme == app.scheme,
                "preview build belongs to a different project or scheme"
            );
        } else {
            ensure!(
                app.bundle_id.is_some(),
                "an imported build requires a registered bundle ID"
            );
        }
    }
    let directory = app_dir(store, id)?;
    let path = preview_path(&directory, &staged.id);
    ensure!(staged.path.as_ref() == Some(&path), "staged preview belongs to another app");
    app.preview = Some(AppPreview {
        id: staged.id.clone(),
        path,
        captured_at,
        build_id: publication.build_id,
        source_revision: publication.source_revision,
        caption: publication.caption,
        source,
    });
    app.updated_at = now();
    // A failed directory fsync can occur after app.json was atomically renamed.
    // Retain the complete image on uncertain publication rather than leave a
    // possibly published record pointing to a file we just removed.
    staged.path = None;
    save(store, &app)?;
    Ok(app)
}

fn read_png(path: &Path) -> Result<Vec<u8>> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = options
        .open(path)
        .context("could not open screenshot PNG")?;
    ensure!(
        file.metadata()?.is_file(),
        "screenshot must be a regular PNG file"
    );
    ensure!(
        file.metadata()?.len() <= MAX_PREVIEW_BYTES,
        "preview exceeds 20 MiB"
    );
    let mut bytes = Vec::new();
    file.take(MAX_PREVIEW_BYTES + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() as u64 <= MAX_PREVIEW_BYTES,
        "preview exceeds 20 MiB"
    );
    ensure!(
        bytes.len() >= 33 && bytes.starts_with(b"\x89PNG\r\n\x1a\n") && &bytes[12..16] == b"IHDR",
        "preview must contain a PNG image"
    );
    ensure!(
        u32::from_be_bytes(bytes[8..12].try_into()?) == 13,
        "PNG has an invalid image header"
    );
    ensure!(
        u32::from_be_bytes(bytes[16..20].try_into()?) > 0
            && u32::from_be_bytes(bytes[20..24].try_into()?) > 0,
        "PNG has no pixels"
    );
    let mut offset = 8;
    let mut has_data = false;
    let mut complete = false;
    while offset + 12 <= bytes.len() {
        let length = u32::from_be_bytes(bytes[offset..offset + 4].try_into()?) as usize;
        let end = offset
            .checked_add(length)
            .and_then(|v| v.checked_add(12))
            .context("PNG chunk is too large")?;
        ensure!(end <= bytes.len(), "PNG is truncated");
        match &bytes[offset + 4..offset + 8] {
            b"IDAT" => has_data |= length > 0,
            b"IEND" => {
                ensure!(
                    length == 0 && end == bytes.len(),
                    "PNG has an invalid end chunk"
                );
                complete = true;
                break;
            }
            _ => {}
        }
        offset = end;
    }
    ensure!(
        has_data && complete,
        "PNG is missing image data or its end chunk"
    );
    Ok(bytes)
}

fn catalog_dir(store: &Store) -> Result<PathBuf> {
    let path = store.root.join("apps");
    private_dir(&path)?;
    Ok(path)
}

fn app_dir(store: &Store, id: &str) -> Result<PathBuf> {
    validate_id(id)?;
    Ok(catalog_dir(store)?.join(id))
}

fn preview_path(directory: &Path, id: &str) -> PathBuf {
    directory.join("previews").join(format!("{id}.png"))
}

fn save(store: &Store, app: &AppRecord) -> Result<()> {
    let directory = app_dir(store, &app.id)?;
    private_dir(&directory)?;
    atomic_json(&directory.join("app.json"), app)
}

fn validate_id(id: &str) -> Result<()> {
    ensure!(
        Uuid::parse_str(id)
            .context("invalid app or preview UUID")?
            .to_string()
            == id,
        "UUID must use canonical lowercase hyphenated form"
    );
    Ok(())
}

fn nonempty(value: &str, label: &str, max: usize) -> Result<String> {
    let value = value.trim();
    ensure!(!value.is_empty(), "{label} is required");
    text_limit(value, label, max)?;
    Ok(value.into())
}

fn text_limit(value: &str, label: &str, max: usize) -> Result<()> {
    ensure!(
        value.len() <= max && !value.contains('\0'),
        "{label} exceeds its limit or contains NUL"
    );
    Ok(())
}

fn validate_bundle(bundle: Option<&str>) -> Result<()> {
    if let Some(bundle) = bundle {
        ensure!(
            !bundle.is_empty()
                && bundle.len() <= 255
                && bundle
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b".-".contains(&byte)),
            "bundle ID must contain letters, digits, dots, or hyphens"
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{BuildMode, BuildOrigin, BuildOutput, BuildRequest, JobPhase, Provenance};

    // A real 1×1 PNG. Publications copy its exact bytes rather than rendering a
    // stand-in screen from a project name or other metadata.
    const PNG: &[u8] = &[
        137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 4,
        0, 0, 0, 181, 28, 12, 2, 0, 0, 0, 11, 73, 68, 65, 84, 120, 218, 99, 100, 248, 15, 0, 1, 5,
        1, 1, 39, 24, 227, 102, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
    ];

    fn setup() -> Result<(tempfile::TempDir, Store, AppRegistration)> {
        let temp = tempfile::tempdir()?;
        let project = temp.path().join("Example.xcodeproj");
        fs::create_dir(&project)?;
        let store = Store::open(temp.path().join("store"))?;
        let registration = AppRegistration {
            name: "Example".into(),
            project,
            scheme: "Example".into(),
            bundle_id: Some("dev.example.app".into()),
            summary: "Original summary".into(),
        };
        Ok((temp, store, registration))
    }

    fn publication(file: PathBuf) -> PreviewPublication {
        PreviewPublication {
            file,
            caption: "Settings screen".into(),
            build_id: None,
            source_revision: Some("abc123".into()),
            source: None,
        }
    }

    fn build(registration: &AppRegistration) -> Job {
        Job {
            id: Uuid::new_v4().to_string(),
            created_at: 1,
            updated_at: 2,
            origin: BuildOrigin::Project {
                provenance: Provenance { revision: Some("submitted-revision".into()), dirty: Some(false) },
                request: BuildRequest {
                project: registration.project.clone(),
                scheme: registration.scheme.clone(),
                configuration: "Release".into(),
                mode: BuildMode::Simulator,
                export_options: None,
                allow_provisioning_updates: false,
                capture_preview: true,
                request_id: None,
                no_overlay: false,
                thread: None,
            }},
            phase: JobPhase::Succeeded { preview: PreviewState::Absent, output: BuildOutput {
                archive_path: None,
                ipa_path: None,
                app_path: Some("/Example.app".into()),
                dsym_paths: vec![],
                bundle_id: "dev.example.app".into(),
                version: "1".into(),
                build_number: "1".into(),
                title: "Build title".into(),
            }},
        }
    }

    #[test]
    fn registration_is_idempotent_and_metadata_survives_restart() -> Result<()> {
        let (_temp, store, mut registration) = setup()?;
        let first = register(&store, registration.clone())?;
        let edited = update(
            &store,
            &first.id,
            AppUpdate {
                name: Some("Agent-edited title".into()),
                summary: Some("Latest app description".into()),
            },
        )?;
        registration.project.push(".");
        registration.name = "Build title must not win".into();
        assert_eq!(register(&store, registration)?, edited);
        let root = store.root.clone();
        drop(store);
        let reopened = Store::open(root)?;
        assert_eq!(list(&reopened)?, vec![edited]);
        Ok(())
    }

    #[test]
    fn previews_are_private_immutable_copies_with_provenance() -> Result<()> {
        let (temp, store, registration) = setup()?;
        let app = register(&store, registration)?;
        let source = temp.path().join("capture.png");
        fs::write(&source, PNG)?;
        let first = publish_preview(&store, &app.id, publication(source.clone()))?;
        let original = first.preview.unwrap();
        let second = publish_preview(&store, &app.id, publication(source.clone()))?;
        let preview = second.preview.as_ref().unwrap();
        assert_ne!(original.id, preview.id);
        assert_ne!(original.path, preview.path);
        fs::remove_file(source)?;
        assert_eq!(fs::read(&original.path)?, PNG);
        assert_eq!(fs::read(&preview.path)?, PNG);
        assert_eq!(preview.source, "agent");
        assert_eq!(preview.source_revision.as_deref(), Some("abc123"));
        assert_eq!(preview.caption, "Settings screen");
        let renamed = update(
            &store,
            &app.id,
            AppUpdate {
                name: Some("Renamed".into()),
                summary: None,
            },
        )?;
        assert_eq!(renamed.preview, second.preview);
        assert_eq!(renamed.summary, "Original summary");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&preview.path)?.permissions().mode() & 0o777,
                0o600
            );
            assert_eq!(
                fs::metadata(preview.path.parent().unwrap())?
                    .permissions()
                    .mode()
                    & 0o777,
                0o700
            );
        }
        Ok(())
    }

    #[test]
    fn invalid_or_oversized_publications_preserve_existing_metadata() -> Result<()> {
        let (temp, store, registration) = setup()?;
        let app = register(&store, registration)?;
        let source = temp.path().join("capture.png");
        fs::write(&source, PNG)?;
        let original = publish_preview(&store, &app.id, publication(source.clone()))?;
        for bytes in [&b"not a PNG"[..], &PNG[..33], &PNG[..PNG.len() - 1]] {
            fs::write(&source, bytes)?;
            assert!(publish_preview(&store, &app.id, publication(source.clone())).is_err());
            assert_eq!(get(&store, &app.id)?, original);
        }
        File::create(&source)?.set_len(MAX_PREVIEW_BYTES + 1)?;
        assert!(publish_preview(&store, &app.id, publication(source)).is_err());
        assert_eq!(get(&store, &app.id)?, original);
        assert!(get(&store, "../outside").is_err());
        Ok(())
    }

    #[test]
    fn build_sync_imports_only_newer_captures_and_preserves_agent_edits() -> Result<()> {
        let (temp, store, registration) = setup()?;
        let app = register(&store, registration.clone())?;
        let edited = update(
            &store,
            &app.id,
            AppUpdate {
                name: Some("Curated title".into()),
                summary: Some("Agent's progress notes".into()),
            },
        )?;
        let source = temp.path().join("capture.png");
        fs::write(&source, PNG)?;
        let mut job = build(&registration);
        let shot = |captured_at, source| PreviewState::Ready(PreviewArtifact { path: temp.path().join("capture.png"), captured_at, source: Some(source) });
        job.set_preview(shot(100, PreviewSource::BuiltSimulatorProduct));
        store.save_job(&job)?;
        let captured = sync_build_preview(&store, &job)?;
        assert_eq!(captured.id, edited.id);
        assert_eq!(captured.name, edited.name);
        assert_eq!(captured.summary, edited.summary);
        assert_eq!(
            captured.preview.as_ref().unwrap().build_id.as_deref(),
            Some(job.id.as_str())
        );
        assert_eq!(
            captured
                .preview
                .as_ref()
                .unwrap()
                .source_revision
                .as_deref(),
            Some("submitted-revision")
        );
        assert_eq!(sync_build_preview(&store, &job)?, captured);
        job.set_preview(shot(99, PreviewSource::BuiltSimulatorProduct));
        assert_eq!(sync_build_preview(&store, &job)?, captured);
        job.set_preview(shot(101, PreviewSource::CurrentWorkingTree));
        store.save_job(&job)?;
        let rebuilt = sync_build_preview(&store, &job)?;
        assert_ne!(
            rebuilt.preview.as_ref().unwrap().id,
            captured.preview.as_ref().unwrap().id
        );
        assert_eq!(rebuilt.preview.as_ref().unwrap().source_revision, None);
        assert!(
            rebuilt
                .preview
                .as_ref()
                .unwrap()
                .caption
                .contains("current working tree")
        );
        let agent_preview = publish_preview(
            &store,
            &app.id,
            publication(source),
        )?;
        assert_eq!(agent_preview.preview.as_ref().unwrap().source, "agent");
        assert_eq!(sync_build_preview(&store, &job)?, agent_preview);
        Ok(())
    }

    #[test]
    fn build_links_must_belong_to_the_registered_app() -> Result<()> {
        let (temp, store, registration) = setup()?;
        let app = register(&store, registration.clone())?;
        let source = temp.path().join("capture.png");
        fs::write(&source, PNG)?;
        let mut job = build(&registration);
        if let JobPhase::Succeeded { output, .. } = &mut job.phase {
            output.bundle_id = "dev.other.app".into();
        }
        store.save_job(&job)?;
        let mut request = publication(source);
        request.build_id = Some(job.id);
        assert!(publish_preview(&store, &app.id, request).is_err());
        assert_eq!(get(&store, &app.id)?.preview, None);
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn stored_paths_and_symlinks_cannot_escape_the_app_directory() -> Result<()> {
        use std::os::unix::fs::symlink;
        let (temp, store, registration) = setup()?;
        let app = register(&store, registration)?;
        let source = temp.path().join("capture.png");
        fs::write(&source, PNG)?;
        let mut saved = publish_preview(&store, &app.id, publication(source.clone()))?;
        let copied_path = saved.preview.as_ref().unwrap().path.clone();
        fs::remove_file(&copied_path)?;
        symlink(&source, &copied_path)?;
        // The record stays readable; its substituted artifact is never served.
        assert!(open_preview(&get(&store, &app.id)?).is_err());
        fs::remove_file(&copied_path)?;
        fs::write(&copied_path, PNG)?;
        saved.preview.as_mut().unwrap().path = source;
        save(&store, &saved)?;
        assert!(get(&store, &app.id).is_err());
        Ok(())
    }

    #[test]
    fn a_missing_preview_leaves_the_catalog_listable_and_is_repaired_by_republishing() -> Result<()> {
        let (temp, store, registration) = setup()?;
        let damaged = register(&store, registration.clone())?;
        let other_project = temp.path().join("Other.xcodeproj");
        fs::create_dir(&other_project)?;
        let other = register(&store, AppRegistration { project: other_project, ..registration })?;
        let source = temp.path().join("capture.png");
        fs::write(&source, PNG)?;
        let published = publish_preview(&store, &damaged.id, publication(source.clone()))?;
        publish_preview(&store, &other.id, publication(source.clone()))?;
        fs::remove_file(&published.preview.as_ref().unwrap().path)?;

        let listed = list(&store)?;
        assert_eq!(listed.len(), 2);
        let broken = listed.iter().find(|app| app.id == damaged.id).unwrap();
        assert!(open_preview(broken).is_err());
        assert!(open_preview(listed.iter().find(|app| app.id == other.id).unwrap()).is_ok());

        let repaired = publish_preview(&store, &damaged.id, publication(source))?;
        assert_ne!(repaired.preview.as_ref().unwrap().id, published.preview.unwrap().id);
        assert!(open_preview(&get(&store, &damaged.id)?).is_ok());
        Ok(())
    }

    #[test]
    fn a_rejected_publication_leaves_no_staged_file() -> Result<()> {
        let (temp, store, registration) = setup()?;
        let app = register(&store, registration)?;
        let source = temp.path().join("capture.png");
        fs::write(&source, PNG)?;
        let mut request = publication(source);
        request.source = Some("forged".into());
        assert!(publish_preview(&store, &app.id, request).is_err());
        let previews = app_dir(&store, &app.id)?.join("previews");
        assert_eq!(fs::read_dir(previews)?.count(), 0);
        Ok(())
    }
}
