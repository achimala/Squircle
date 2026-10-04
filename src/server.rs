use crate::{artifact, model::*, store::Store, xcode};
use anyhow::{Context, Result};
use axum::{
    Json, Router,
    body::Body,
    extract::{DefaultBodyLimit, Path, Query, State, rejection::JsonRejection},
    http::{HeaderMap, StatusCode, header},
    response::{Html, IntoResponse, Response},
    routing::{get, post},
};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    fs::OpenOptions,
    net::SocketAddr,
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};
use tokio::sync::{Semaphore, watch};
use tokio_util::io::ReaderStream;

#[derive(Clone)]
pub struct AppState {
    pub store: Arc<Mutex<Store>>,
    cancellations: Arc<Mutex<HashMap<String, watch::Sender<bool>>>>,
    slots: Arc<Semaphore>,
    public_url: Option<String>,
    draining: Arc<AtomicBool>,
    recovery_jobs: Arc<Mutex<HashMap<String, Job>>>,
}

impl AppState {
    pub fn new(store: Store, public_url: Option<String>) -> Self {
        Self {
            store: Arc::new(Mutex::new(store)),
            cancellations: Arc::default(),
            slots: Arc::new(Semaphore::new(1)),
            public_url,
            draining: Arc::new(AtomicBool::new(false)),
            recovery_jobs: Arc::default(),
        }
    }
}

#[derive(Debug)]
struct ApiError {
    status: StatusCode,
    code: &'static str,
    message: String,
    next: &'static str,
}
impl ApiError {
    fn bad(message: impl ToString) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            code: "invalid_request",
            message: message.to_string(),
            next: "Check the command help and supplied values.",
        }
    }
    fn missing(message: impl ToString) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            code: "not_found",
            message: message.to_string(),
            next: "Check the build ID or request a new install link.",
        }
    }
    fn internal(error: impl ToString) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            code: "operation_failed",
            message: error.to_string(),
            next: "Inspect the saved build log or run squircle doctor.",
        }
    }
    fn unavailable() -> Self {
        Self {
            status: StatusCode::SERVICE_UNAVAILABLE,
            code: "service_draining",
            message: "Service is shutting down or paused after a persistence error".into(),
            next: "Inspect service output and storage, then restart before submitting work.",
        }
    }
}
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(failure(self.code, self.message, self.next)),
        )
            .into_response()
    }
}
type ApiResult<T> = std::result::Result<T, ApiError>;

fn auth(state: &AppState, headers: &HeaderMap, diagnostics: bool) -> ApiResult<()> {
    let supplied = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .unwrap_or("");
    let store = state.store.lock().unwrap();
    let expected = if diagnostics {
        &store.settings.diagnostic_token
    } else {
        &store.settings.control_token
    };
    let a = Sha256::digest(supplied.as_bytes());
    let b = Sha256::digest(expected.as_bytes());
    if a.iter().zip(b).fold(0u8, |x, (a, b)| x | (a ^ b)) != 0 {
        return Err(ApiError {
            status: StatusCode::UNAUTHORIZED,
            code: "unauthorized",
            message: "A valid token for this operation is required".into(),
            next: "Use the control token for builds; the diagnostics token only permits uploads.",
        });
    }
    Ok(())
}
fn body<T>(value: std::result::Result<Json<T>, JsonRejection>) -> ApiResult<T> {
    value
        .map(|Json(v)| v)
        .map_err(|e| ApiError::bad(e.body_text()))
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route(
            "/health",
            get(|State(state): State<AppState>| async move {
                Json(success(
                    json!({"service":"squircle","version":env!("CARGO_PKG_VERSION"),"accepting_builds":!state.draining.load(Ordering::Acquire)}),
                ))
            }),
        )
        .route("/v1/builds", get(list).post(start))
        .route("/v1/builds/{id}", get(status))
        .route("/v1/builds/{id}/cancel", post(cancel))
        .route("/v1/builds/{id}/log", get(build_log))
        .route("/v1/builds/{id}/install-link", post(create_link))
        .route("/v1/builds/{id}/diagnostics", get(diagnostics))
        .route("/v1/import", post(import))
        .route("/v1/diagnostics", post(ingest))
        .route("/install/{token}", get(install_page))
        .route("/install/{token}/manifest.plist", get(download_manifest))
        .route("/install/{token}/app.ipa", get(download_ipa))
        .fallback(|| async { ApiError::missing("Unknown endpoint") })
        .layer(DefaultBodyLimit::max(1024 * 1024))
        .with_state(state)
}

pub async fn serve(root: PathBuf, listen: SocketAddr, public_url: Option<String>) -> Result<()> {
    let store = Store::open(root)?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(store.root.join("service.lock"))?;
    fs2::FileExt::try_lock_exclusive(&lock)
        .context("Another Squircle service owns this data directory")?;
    let public_url = public_url
        .as_deref()
        .map(artifact::validate_public_url)
        .transpose()?;
    let listener = tokio::net::TcpListener::bind(listen).await?;
    for mut job in store.list_jobs()? {
        if !job.state.terminal() {
            job.state = BuildState::Interrupted;
            job.updated_at = now();
            job.error = Some("Service stopped during this job. Inspect artifacts/processes before submitting new work; no automatic retry was made.".into());
            store.save_job(&job)?;
        }
    }
    let state = AppState::new(store, public_url);
    eprintln!(
        "Squircle listening on {}. Keep this process running; HTTPS/Tailscale is managed separately.",
        listener.local_addr()?
    );
    let shutdown = state.clone();
    axum::serve(listener, router(state))
        .with_graceful_shutdown(async move {
            #[cfg(unix)]
            {
                let mut terminate =
                    tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                        .expect("signal handler");
                tokio::select! { _ = tokio::signal::ctrl_c() => {}, _ = terminate.recv() => {} }
            }
            #[cfg(not(unix))]
            {
                let _ = tokio::signal::ctrl_c().await;
            }
            // Serialize the admission cutoff with start's registration of a job.
            {
                let _store = shutdown.store.lock().unwrap();
                shutdown.draining.store(true, Ordering::Release);
            }
            for sender in shutdown.cancellations.lock().unwrap().values() {
                let _ = sender.send(true);
            }
            // Let cancelled runners reap their children and persist terminal state.
            for _ in 0..100 {
                if shutdown.cancellations.lock().unwrap().is_empty() {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            }
        })
        .await?;
    drop(lock);
    Ok(())
}

async fn list(State(state): State<AppState>, headers: HeaderMap) -> ApiResult<Json<Value>> {
    auth(&state, &headers, false)?;
    let mut jobs = state
        .store
        .lock()
        .unwrap()
        .list_jobs()
        .map_err(ApiError::internal)?;
    for recovered in state.recovery_jobs.lock().unwrap().values() {
        jobs.retain(|job| job.id != recovered.id);
        jobs.push(recovered.clone());
    }
    Ok(Json(success(jobs)))
}
async fn status(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    auth(&state, &headers, false)?;
    let recovered = state.recovery_jobs.lock().unwrap().get(&id).cloned();
    let store = state.store.lock().unwrap();
    let job = match recovered {
        Some(job) => job,
        None => store.load_job(&id).map_err(ApiError::missing)?,
    };
    let launches = store
        .diagnostics(&id, 0, 1, Some(DiagnosticKind::Launch))
        .map_err(ApiError::internal)?;
    Ok(Json(success(
        json!({"job":job,"launch_observed":launches["events"].as_array().is_some_and(|a| !a.is_empty())}),
    )))
}
async fn start(
    State(state): State<AppState>,
    headers: HeaderMap,
    request: std::result::Result<Json<BuildRequest>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    auth(&state, &headers, false)?;
    let mut request = body(request)?;
    if request.scheme.trim().is_empty() || request.configuration.trim().is_empty() {
        return Err(ApiError::bad("Scheme and configuration are required"));
    }
    request.project = request.project.canonicalize().map_err(ApiError::bad)?;
    if !matches!(
        request.project.extension().and_then(|s| s.to_str()),
        Some("xcodeproj" | "xcworkspace")
    ) || !request.project.is_dir()
    {
        return Err(ApiError::bad(
            "Project must be an .xcodeproj or .xcworkspace directory",
        ));
    }
    if let Some(options) = &request.export_options {
        request.export_options = Some(options.canonicalize().map_err(ApiError::bad)?);
    }
    if request.mode == BuildMode::Archive && request.export_options.is_none() {
        return Err(ApiError::bad("Archive builds require --export-options"));
    }
    if let Some(key) = &request.request_id
        && (key.is_empty()
            || key.len() > 128
            || !key
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || "_-".contains(c)))
    {
        return Err(ApiError::bad(
            "Request ID must contain 1–128 letters, digits, underscores or hyphens",
        ));
    }
    let (source_revision, source_dirty) = source_provenance(&request.project).await;
    let (sender, receiver) = watch::channel(false);
    let (job, dir) = {
        let store = state.store.lock().unwrap();
        if state.draining.load(Ordering::Acquire) {
            return Err(ApiError::unavailable());
        }
        let jobs = store.list_jobs().map_err(ApiError::internal)?;
        if let Some(key) = &request.request_id
            && let Some(prior) = jobs
                .iter()
                .find(|j| j.request.as_ref().and_then(|r| r.request_id.as_ref()) == Some(key))
        {
            if prior.request.as_ref() != Some(&request) {
                return Err(ApiError {
                    status: StatusCode::CONFLICT,
                    code: "request_id_conflict",
                    message: "Request ID already belongs to different build arguments".into(),
                    next: "Use a new request ID for different work.",
                });
            }
            return Ok(Json(success(json!({"job":prior,"replayed":true}))));
        }
        if jobs.iter().filter(|j| !j.state.terminal()).count() >= 16 {
            return Err(ApiError::bad(
                "Build queue is full (16 jobs); wait or cancel a job",
            ));
        }
        let job = Job {
            id: uuid::Uuid::new_v4().to_string(),
            created_at: now(),
            updated_at: now(),
            state: BuildState::Queued,
            request: Some(request.clone()),
            output: None,
            error: None,
            source: "xcodebuild".into(),
            source_revision,
            source_dirty,
        };
        let dir = store.job_dir(&job.id).map_err(ApiError::internal)?;
        store.save_job(&job).map_err(ApiError::internal)?;
        state
            .cancellations
            .lock()
            .unwrap()
            .insert(job.id.clone(), sender);
        (job, dir)
    };
    let response = job.clone();
    tokio::spawn(async move {
        let mut job = job;
        let mut receiver = receiver;
        let permit = tokio::select! {
            result = state.slots.clone().acquire_owned() => result.ok(),
            _ = receiver.changed() => None,
        };
        if permit.is_none() || *receiver.borrow() {
            job.state = BuildState::Cancelled;
        } else {
            job.state = BuildState::Running;
            job.updated_at = now();
            let persisted = state.store.lock().unwrap().save_job(&job);
            let result = match persisted {
                Ok(()) => xcode::run(&request, &dir, receiver.clone()).await,
                Err(error) => {
                    state.draining.store(true, Ordering::Release);
                    Err(error.context("Could not persist Running state; Xcode was not started"))
                }
            };
            if *receiver.borrow() {
                job.state = BuildState::Cancelled;
            } else {
                match result {
                    Ok(output) => {
                        job.state = BuildState::Succeeded;
                        job.output = Some(output);
                    }
                    Err(error) => {
                        job.state = BuildState::Failed;
                        job.error = Some(format!("{error:#}"));
                    }
                }
            }
        }
        job.updated_at = now();
        let persisted = state.store.lock().unwrap().save_job(&job);
        if let Err(error) = persisted {
            eprintln!("Cannot persist job {}: {error}", job.id);
            state.draining.store(true, Ordering::Release);
            job.error = Some(format!(
                "{}; terminal result could not be persisted: {error}. Service paused; this result is retained in memory until shutdown.",
                job.error.as_deref().unwrap_or("Build finished")
            ));
            state
                .recovery_jobs
                .lock()
                .unwrap()
                .insert(job.id.clone(), job.clone());
        }
        state.cancellations.lock().unwrap().remove(&job.id);
        drop(permit);
    });
    Ok(Json(success(json!({"job":response,"replayed":false}))))
}

/// Best-effort submission-time observations. Builds still use the working tree;
/// these fields deliberately do not claim that queued work uses a Git snapshot.
async fn source_provenance(project: &std::path::Path) -> (Option<String>, Option<bool>) {
    let Some(directory) = project.parent() else {
        return (None, None);
    };
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
    let Some(revision) = git_output(
        directory,
        &["rev-parse", "--verify", "HEAD^{commit}"],
        128,
        deadline,
    )
    .await
    else {
        return (None, None);
    };
    let Ok(revision) = String::from_utf8(revision) else {
        return (None, None);
    };
    let revision = revision.trim();
    if !matches!(revision.len(), 40 | 64) || !revision.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return (None, None);
    }
    let dirty = git_output(
        directory,
        &[
            "status",
            "--porcelain=v1",
            "--untracked-files=normal",
            "--ignore-submodules=none",
        ],
        1024 * 1024,
        deadline,
    )
    .await
    .map(|output| !output.is_empty());
    (Some(revision.to_owned()), dirty)
}

async fn git_output(
    directory: &std::path::Path,
    arguments: &[&str],
    max_bytes: u64,
    deadline: tokio::time::Instant,
) -> Option<Vec<u8>> {
    use tokio::io::AsyncReadExt;
    tokio::time::timeout_at(deadline, async {
        let mut command = tokio::process::Command::new("/usr/bin/git");
        command
            .args(["-c", "core.fsmonitor=false"])
            .arg("-C")
            .arg(directory)
            .args(arguments)
            .env("GIT_OPTIONAL_LOCKS", "0")
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_INDEX_FILE")
            .env_remove("GIT_COMMON_DIR")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true);
        let mut child = command.spawn().ok()?;
        let mut bytes = Vec::new();
        child
            .stdout
            .take()?
            .take(max_bytes + 1)
            .read_to_end(&mut bytes)
            .await
            .ok()?;
        if bytes.len() as u64 > max_bytes {
            let _ = child.kill().await;
            return None;
        }
        if child.wait().await.ok()?.success() {
            Some(bytes)
        } else {
            None
        }
    })
    .await
    .ok()
    .flatten()
}

async fn cancel(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    auth(&state, &headers, false)?;
    let job = state
        .store
        .lock()
        .unwrap()
        .load_job(&id)
        .map_err(ApiError::missing)?;
    let requested = if let Some(sender) = state.cancellations.lock().unwrap().get(&id) {
        sender.send(true).is_ok()
    } else {
        false
    };
    Ok(Json(success(
        json!({"build_id":id,"cancel_requested":requested,"state":job.state}),
    )))
}

#[derive(Deserialize)]
struct ImportRequest {
    ipa: PathBuf,
}
async fn import(
    State(state): State<AppState>,
    headers: HeaderMap,
    input: std::result::Result<Json<ImportRequest>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    auth(&state, &headers, false)?;
    let input = body(input)?;
    // Copying, ZIP inspection and fsync stay off both the HTTP worker and the
    // global store lock, so an import cannot block authentication/cancellation.
    let job =
        tokio::task::spawn_blocking(move || import_ipa(&state, &input.ipa, copy_and_inspect_ipa))
            .await
            .map_err(ApiError::internal)?
            .map_err(ApiError::bad)?;
    Ok(Json(success(job)))
}

fn copy_and_inspect_ipa(
    source: &std::path::Path,
    destination: &std::path::Path,
) -> Result<BuildOutput> {
    std::fs::copy(source, destination)?;
    std::fs::File::open(destination)?.sync_all()?;
    artifact::inspect_ipa(destination)
}

fn import_ipa(
    state: &AppState,
    source: &std::path::Path,
    prepare: impl FnOnce(&std::path::Path, &std::path::Path) -> Result<BuildOutput>,
) -> Result<Job> {
    let source = source.canonicalize()?;
    let metadata = std::fs::metadata(&source)?;
    anyhow::ensure!(metadata.is_file(), "IPA must be a regular file");
    anyhow::ensure!(
        metadata.len() <= 4 * 1024 * 1024 * 1024u64,
        "IPA exceeds 4 GiB"
    );
    let id = uuid::Uuid::new_v4().to_string();
    let dir = {
        let store = state.store.lock().unwrap();
        anyhow::ensure!(
            !state.draining.load(Ordering::Acquire),
            "Service is shutting down or paused"
        );
        store.job_dir(&id)?
    };
    let mut builder = std::fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(&dir)?;
    let output = match prepare(&source, &dir.join("app.ipa")) {
        Ok(output) => output,
        Err(error) => {
            // No job record exists yet. Clean up only this import's staging
            // directory; never erase evidence after attempting publication.
            // Serialize directory removal with list_jobs directory traversal.
            let _store = state.store.lock().unwrap();
            let _ = std::fs::remove_dir_all(&dir);
            return Err(error);
        }
    };
    let job = Job {
        id,
        created_at: now(),
        updated_at: now(),
        state: BuildState::Succeeded,
        request: None,
        output: Some(output),
        error: None,
        source: "imported_ipa_signature_not_verified".into(),
        source_revision: None,
        source_dirty: None,
    };
    // Work admitted before shutdown may finish. Publication occurs only after
    // the copied IPA has been synced and its metadata validated.
    state.store.lock().unwrap().save_job(&job)?;
    Ok(job)
}

#[derive(Deserialize)]
struct LinkRequest {
    #[serde(default = "default_ttl")]
    ttl_seconds: u64,
}
fn default_ttl() -> u64 {
    3600
}
async fn create_link(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    input: std::result::Result<Json<LinkRequest>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    auth(&state, &headers, false)?;
    let input = body(input)?;
    if !(60..=86400).contains(&input.ttl_seconds) {
        return Err(ApiError::bad(
            "Install-link lifetime must be between 60 and 86400 seconds",
        ));
    }
    let base = state.public_url.as_ref().ok_or_else(|| {
        ApiError::bad(
            "Start serve with --public-url https://YOUR-MAC-HOSTNAME to create install links",
        )
    })?;
    let store = state.store.lock().unwrap();
    let job = store.load_job(&id).map_err(ApiError::missing)?;
    if job.state != BuildState::Succeeded
        || job
            .output
            .as_ref()
            .and_then(|o| o.ipa_path.as_ref())
            .is_none()
    {
        return Err(ApiError::bad(
            "Build has no exported IPA; simulator products cannot be installed this way",
        ));
    }
    let ticket = Ticket {
        token: token(),
        build_id: id.clone(),
        expires_at: now() + input.ttl_seconds,
        base_url: base.clone(),
    };
    store.save_ticket(&ticket).map_err(ApiError::internal)?;
    let page = format!("{base}/install/{}", ticket.token);
    Ok(Json(success(
        json!({"build_id":id,"page_url":page,"manifest_url":format!("{page}/manifest.plist"),"install_url":artifact::install_url(&format!("{page}/manifest.plist")),"expires_at":ticket.expires_at,"installation_confirmed":false}),
    )))
}
fn ticket_job(state: &AppState, token: &str) -> ApiResult<(Ticket, Job)> {
    let store = state.store.lock().unwrap();
    let ticket = store
        .load_ticket(token)
        .map_err(|_| ApiError::missing("Invalid install link"))?;
    if ticket.expires_at <= now() {
        return Err(ApiError {
            status: StatusCode::GONE,
            code: "link_expired",
            message: "Install link expired".into(),
            next: "Request a new install link for the same build.",
        });
    }
    let job = store
        .load_job(&ticket.build_id)
        .map_err(ApiError::missing)?;
    if job.state != BuildState::Succeeded
        || job
            .output
            .as_ref()
            .and_then(|o| o.ipa_path.as_ref())
            .is_none()
    {
        return Err(ApiError::missing("No IPA for this build"));
    }
    Ok((ticket, job))
}
fn private_headers() -> [(header::HeaderName, &'static str); 3] {
    [
        (header::CACHE_CONTROL, "no-store"),
        (header::REFERRER_POLICY, "no-referrer"),
        (header::X_CONTENT_TYPE_OPTIONS, "nosniff"),
    ]
}
async fn install_page(
    State(state): State<AppState>,
    Path(token): Path<String>,
) -> ApiResult<Response> {
    let (ticket, job) = ticket_job(&state, &token)?;
    let output = job.output.unwrap();
    let link = artifact::install_url(&format!(
        "{}/install/{}/manifest.plist",
        ticket.base_url, token
    ));
    let html = format!(
        "<!doctype html><html><head><meta name=viewport content=\"width=device-width,initial-scale=1\"><title>Install Squircle build</title><style>body{{font:17px system-ui;max-width:36rem;margin:4rem auto;padding:1.5rem;background:#10141c;color:#f0f3fa}}a{{display:inline-block;padding:1rem 1.4rem;background:#b4ccff;color:#111c30;border-radius:16px;text-decoration:none}}small{{color:#b2bacb}}</style></head><body><small>SQUIRCLE · TEST BUILD</small><h1>{}</h1><p>Version {} · Build {}</p><p><a href=\"{}\">Install on this iPhone</a></p><p>Confirm the iOS installation prompt, then open the app yourself.</p><small>Build ID: {}<br>This link does not confirm installation. Signed builds require an eligible registered device.</small></body></html>",
        artifact::escape_html(&output.title),
        artifact::escape_html(&output.version),
        artifact::escape_html(&output.build_number),
        artifact::escape_html(&link),
        job.id
    );
    Ok((private_headers(), Html(html)).into_response())
}
async fn download_manifest(
    State(state): State<AppState>,
    Path(token): Path<String>,
) -> ApiResult<Response> {
    let (ticket, job) = ticket_job(&state, &token)?;
    let bytes = artifact::manifest(
        &job.output.unwrap(),
        &format!("{}/install/{}/app.ipa", ticket.base_url, token),
    )
    .map_err(ApiError::internal)?;
    Ok((
        private_headers(),
        [(header::CONTENT_TYPE, "application/xml")],
        bytes,
    )
        .into_response())
}
async fn download_ipa(
    State(state): State<AppState>,
    Path(token): Path<String>,
) -> ApiResult<Response> {
    let (_, job) = ticket_job(&state, &token)?;
    let path = job.output.unwrap().ipa_path.unwrap();
    let file = tokio::fs::File::open(path)
        .await
        .map_err(ApiError::missing)?;
    let size = file.metadata().await.map_err(ApiError::internal)?.len();
    let mut response = (
        private_headers(),
        [(header::CONTENT_TYPE, "application/octet-stream")],
        Body::from_stream(ReaderStream::new(file)),
    )
        .into_response();
    response
        .headers_mut()
        .insert(header::CONTENT_LENGTH, size.to_string().parse().unwrap());
    Ok(response)
}

#[derive(Deserialize, Default)]
struct Page {
    #[serde(default)]
    since: usize,
    limit: Option<usize>,
    kind: Option<DiagnosticKind>,
}
async fn diagnostics(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Query(page): Query<Page>,
) -> ApiResult<Json<Value>> {
    auth(&state, &headers, false)?;
    let data = state
        .store
        .lock()
        .unwrap()
        .diagnostics(&id, page.since, page.limit.unwrap_or(100), page.kind)
        .map_err(ApiError::bad)?;
    Ok(Json(success(data)))
}
async fn ingest(
    State(state): State<AppState>,
    headers: HeaderMap,
    event: std::result::Result<Json<Diagnostic>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    auth(&state, &headers, true)?;
    let event = body(event)?;
    let inserted = state
        .store
        .lock()
        .unwrap()
        .append_diagnostic(&event)
        .map_err(ApiError::bad)?;
    Ok(Json(success(
        json!({"event_id":event.event_id,"stored":inserted,"duplicate":!inserted}),
    )))
}
#[derive(Deserialize, Default)]
struct LogPage {
    #[serde(default)]
    offset: u64,
    limit: Option<usize>,
}
async fn build_log(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Query(page): Query<LogPage>,
) -> ApiResult<Json<Value>> {
    auth(&state, &headers, false)?;
    let path = {
        let store = state.store.lock().unwrap();
        store.load_job(&id).map_err(ApiError::missing)?;
        store.job_dir(&id).map_err(ApiError::bad)?.join("build.log")
    };
    use tokio::io::{AsyncReadExt, AsyncSeekExt};
    let mut file = match tokio::fs::File::open(path).await {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Json(success(
                json!({"text":"","next_offset":0,"has_more":false}),
            )));
        }
        Err(e) => return Err(ApiError::internal(e)),
    };
    let size = file.metadata().await.map_err(ApiError::internal)?.len();
    if page.offset > size {
        return Err(ApiError::bad("Log offset exceeds file size"));
    }
    file.seek(std::io::SeekFrom::Start(page.offset))
        .await
        .map_err(ApiError::internal)?;
    let mut bytes = vec![0; page.limit.unwrap_or(32768).clamp(1, 262144)];
    let count = file.read(&mut bytes).await.map_err(ApiError::internal)?;
    bytes.truncate(count);
    Ok(Json(success(
        json!({"text":String::from_utf8_lossy(&bytes),"next_offset":page.offset+count as u64,"has_more":(page.offset+count as u64)<size}),
    )))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn non_repository_source_has_no_invented_provenance() {
        let directory = tempfile::tempdir().unwrap();
        let project = directory.path().join("Probe.xcodeproj");
        std::fs::create_dir(&project).unwrap();
        assert_eq!(source_provenance(&project).await, (None, None));
    }

    fn request(root: &std::path::Path) -> BuildRequest {
        let project = root.join("Probe.xcodeproj");
        std::fs::create_dir_all(&project).unwrap();
        BuildRequest {
            project,
            scheme: "Probe".into(),
            configuration: "Release".into(),
            mode: BuildMode::Simulator,
            export_options: None,
            request_id: Some("same-request".into()),
            allow_provisioning_updates: false,
        }
    }
    fn headers(state: &AppState) -> HeaderMap {
        let mut headers = HeaderMap::new();
        let token = state.store.lock().unwrap().settings.control_token.clone();
        headers.insert(
            header::AUTHORIZATION,
            format!("Bearer {token}").parse().unwrap(),
        );
        headers
    }

    fn test_ipa(path: &std::path::Path) -> Result<()> {
        use std::io::Write;
        let mut metadata = plist::Dictionary::new();
        metadata.insert("CFBundleIdentifier".into(), "dev.example.probe".into());
        metadata.insert("CFBundleVersion".into(), "1".into());
        let mut bytes = Vec::new();
        plist::Value::Dictionary(metadata).to_writer_xml(&mut bytes)?;
        let mut zip = zip::ZipWriter::new(std::fs::File::create(path)?);
        zip.start_file(
            "Payload/Probe.app/Info.plist",
            zip::write::SimpleFileOptions::default(),
        )?;
        zip.write_all(&bytes)?;
        zip.finish()?;
        Ok(())
    }

    #[test]
    fn import_leaves_store_available_and_publishes_only_after_validation() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let source = dir.path().join("input.ipa");
        test_ipa(&source)?;
        let state = AppState::new(Store::open(dir.path().join("state"))?, None);
        let authorization = headers(&state);
        let job = import_ipa(&state, &source, |source, destination| {
            // A nonblocking acquisition makes a regression fail immediately,
            // instead of hanging the test on the old global-lock behavior.
            let store = state
                .store
                .try_lock()
                .expect("copy must not hold store lock");
            assert!(store.list_jobs()?.is_empty());
            drop(store);
            auth(&state, &authorization, false).unwrap();
            let output = copy_and_inspect_ipa(source, destination)?;
            assert!(state.store.lock().unwrap().list_jobs()?.is_empty());
            Ok(output)
        })?;
        let stored = state.store.lock().unwrap().load_job(&job.id)?;
        assert_eq!(stored.state, BuildState::Succeeded);
        assert_eq!(stored.source, "imported_ipa_signature_not_verified");
        let output = stored.output.unwrap();
        assert_eq!(output.bundle_id, "dev.example.probe");
        assert_eq!(
            std::fs::read(output.ipa_path.unwrap())?,
            std::fs::read(source)?
        );
        Ok(())
    }

    #[tokio::test]
    async fn unauthorized_or_invalid_imports_publish_no_record() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let source = dir.path().join("input.ipa");
        test_ipa(&source)?;
        let state = AppState::new(Store::open(dir.path().join("state"))?, None);
        let error = import(
            State(state.clone()),
            HeaderMap::new(),
            Ok(Json(ImportRequest {
                ipa: source.clone(),
            })),
        )
        .await
        .unwrap_err();
        assert_eq!(error.status, StatusCode::UNAUTHORIZED);
        let jobs_directory = state.store.lock().unwrap().root.join("jobs");
        assert_eq!(std::fs::read_dir(&jobs_directory)?.count(), 0);

        std::fs::write(&source, b"not an IPA")?;
        assert!(import_ipa(&state, &source, copy_and_inspect_ipa).is_err());
        assert!(state.store.lock().unwrap().list_jobs()?.is_empty());
        assert_eq!(std::fs::read_dir(jobs_directory)?.count(), 0);
        Ok(())
    }

    #[tokio::test]
    async fn queued_cancellation_does_not_wait_for_the_active_build_and_retries_deduplicate() {
        let dir = tempfile::tempdir().unwrap();
        let state = AppState::new(Store::open(dir.path().join("state")).unwrap(), None);
        let _active = state.slots.clone().acquire_owned().await.unwrap();
        let request = request(dir.path());
        let Json(first) = start(
            State(state.clone()),
            headers(&state),
            Ok(Json(request.clone())),
        )
        .await
        .unwrap();
        let id = first["data"]["job"]["id"].as_str().unwrap().to_owned();
        let Json(retry) = start(
            State(state.clone()),
            headers(&state),
            Ok(Json(request.clone())),
        )
        .await
        .unwrap();
        assert_eq!(retry["data"]["job"]["id"], id);
        assert_eq!(retry["data"]["replayed"], true);
        let mut changed = request;
        changed.configuration = "Debug".into();
        assert_eq!(
            start(State(state.clone()), headers(&state), Ok(Json(changed)))
                .await
                .unwrap_err()
                .status,
            StatusCode::CONFLICT
        );
        let _ = cancel(State(state.clone()), headers(&state), Path(id.clone()))
            .await
            .unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                if state.store.lock().unwrap().load_job(&id).unwrap().state == BuildState::Cancelled
                {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("queued cancellation should be immediate");
        assert!(
            !state
                .store
                .lock()
                .unwrap()
                .job_dir(&id)
                .unwrap()
                .join("build.log")
                .exists()
        );
    }
    #[tokio::test]
    async fn draining_refuses_new_side_effects() {
        let dir = tempfile::tempdir().unwrap();
        let state = AppState::new(Store::open(dir.path().join("state")).unwrap(), None);
        state.draining.store(true, Ordering::Release);
        let error = start(
            State(state.clone()),
            headers(&state),
            Ok(Json(request(dir.path()))),
        )
        .await
        .unwrap_err();
        assert_eq!(error.status, StatusCode::SERVICE_UNAVAILABLE);
        assert!(state.store.lock().unwrap().list_jobs().unwrap().is_empty());
    }
}
