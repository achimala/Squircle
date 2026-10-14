use crate::{agents::Agents, apps, push::Push, sims::Sims, tasks::{self, Tasks}, artifact, model::*, preview, projects, store::Store, xcode};
use anyhow::{Context, Result};
use axum::{
    Json, Router,
    body::Body,
    extract::{
        DefaultBodyLimit, Path, Query, Request, State,
        rejection::{JsonRejection, QueryRejection},
    },
    http::{HeaderMap, StatusCode, header},
    middleware::{self, Next},
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
    /// Job, ticket and app-catalog records: held across their read/modify/write.
    pub store: Arc<Mutex<Store>>,
    /// The same store's immutable root and credentials, for authentication and
    /// paths without waiting behind record or catalog file I/O.
    files: Arc<Store>,
    /// Serializes per-build diagnostic appends and reads (append-only files).
    diagnostics: Arc<Mutex<()>>,
    cancellations: Arc<Mutex<HashMap<String, watch::Sender<bool>>>>,
    slots: Arc<Semaphore>,
    inspection_slots: Arc<Semaphore>,
    uploads: Arc<Semaphore>,
    public_url: Option<String>,
    draining: Arc<AtomicBool>,
    recovery_jobs: Arc<Mutex<HashMap<String, Job>>>,
    agents: Option<Arc<Agents>>,
    sims: Option<Arc<Sims>>,
    push: Option<Arc<Push>>,
    tasks: Option<Arc<Tasks>>,
}

impl AppState {
    pub fn new(store: Store, public_url: Option<String>) -> Self {
        Self {
            files: Arc::new(store.clone()),
            store: Arc::new(Mutex::new(store)),
            diagnostics: Arc::default(),
            cancellations: Arc::default(),
            slots: Arc::new(Semaphore::new(1)),
            inspection_slots: Arc::new(Semaphore::new(2)),
            uploads: Arc::new(Semaphore::new(1)),
            public_url,
            draining: Arc::new(AtomicBool::new(false)),
            recovery_jobs: Arc::default(),
            agents: None,
            sims: None,
            push: None,
            tasks: None,
        }
    }
}

#[derive(Debug)]
struct ApiError {
    status: StatusCode,
    code: &'static str,
    message: String,
    next: &'static str,
    /// Refused before any side effect; see `model::failure_with`.
    retryable: bool,
}
impl ApiError {
    fn new(status: StatusCode, code: &'static str, message: impl ToString, next: &'static str) -> Self {
        Self { status, code, message: message.to_string(), next, retryable: false }
    }
    fn bad(message: impl ToString) -> Self {
        Self::new(StatusCode::BAD_REQUEST, "invalid_request", message, "Check the command help and supplied values.")
    }
    fn missing(message: impl ToString) -> Self {
        Self::new(StatusCode::NOT_FOUND, "not_found", message, "Check the build ID or request a new install link.")
    }
    fn internal(error: impl ToString) -> Self {
        Self::new(StatusCode::INTERNAL_SERVER_ERROR, "operation_failed", error, "Inspect the saved build log or run squircle doctor.")
    }
    fn unavailable() -> Self {
        // Admission is refused before any work starts; retry after a restart.
        Self {
            retryable: true,
            ..Self::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "service_draining",
                "Service is shutting down or paused after a persistence error",
                "Inspect service output and storage, then restart before submitting work.",
            )
        }
    }
    fn too_large(message: impl ToString) -> Self {
        Self::new(StatusCode::PAYLOAD_TOO_LARGE, "payload_too_large", message, "Send a smaller request body.")
    }
    /// Axum's own rejections (query, path, body, size, method) in the same
    /// envelope as handler errors.
    fn rejection(status: StatusCode, message: String) -> Self {
        let (code, next) = match status {
            StatusCode::UNAUTHORIZED => ("unauthorized", "Use the control token for builds; the diagnostics token only permits uploads."),
            StatusCode::NOT_FOUND => ("not_found", "Check the endpoint and IDs."),
            StatusCode::METHOD_NOT_ALLOWED => ("method_not_allowed", "Check the HTTP method for this endpoint."),
            StatusCode::PAYLOAD_TOO_LARGE => ("payload_too_large", "Send a smaller request body."),
            StatusCode::UNSUPPORTED_MEDIA_TYPE => ("invalid_request", "Send JSON with Content-Type: application/json."),
            s if s.is_client_error() => ("invalid_request", "Check the command help and supplied values."),
            _ => ("operation_failed", "Inspect service output or run squircle doctor."),
        };
        let message = if message.is_empty() {
            status.canonical_reason().unwrap_or("Request failed").to_string()
        } else {
            message
        };
        Self {
            retryable: matches!(status, StatusCode::TOO_MANY_REQUESTS | StatusCode::SERVICE_UNAVAILABLE),
            ..Self::new(status, code, message, next)
        }
    }
}
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(failure_with(self.code, self.message, self.next, self.retryable)),
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
    let settings = &state.files.settings;
    let expected = if diagnostics {
        &settings.diagnostic_token
    } else {
        &settings.control_token
    };
    let a = Sha256::digest(supplied.as_bytes());
    let b = Sha256::digest(expected.as_bytes());
    if a.iter().zip(b).fold(0u8, |x, (a, b)| x | (a ^ b)) != 0 {
        return Err(ApiError::rejection(
            StatusCode::UNAUTHORIZED,
            "A valid token for this operation is required".into(),
        ));
    }
    Ok(())
}
fn body<T>(value: std::result::Result<Json<T>, JsonRejection>) -> ApiResult<T> {
    value
        .map(|Json(v)| v)
        .map_err(|e| ApiError::rejection(e.status(), e.body_text()))
}
fn parse_query<T>(value: std::result::Result<Query<T>, QueryRejection>) -> ApiResult<T> {
    value
        .map(|Query(v)| v)
        .map_err(|e| ApiError::rejection(e.status(), e.body_text()))
}

/// Runs before any extractor, so a rejected request's body is never read.
async fn require_control(State(state): State<AppState>, request: Request, next: Next) -> Response {
    match auth(&state, request.headers(), false) {
        Ok(()) => next.run(request).await,
        Err(error) => error.into_response(),
    }
}
async fn require_diagnostics(State(state): State<AppState>, request: Request, next: Next) -> Response {
    match auth(&state, request.headers(), true) {
        Ok(()) => next.run(request).await,
        Err(error) => error.into_response(),
    }
}

/// Wraps any error response that is not already Squircle JSON (Axum's plain
/// text extractor rejections, 405s, empty 413s) in the versioned envelope.
async fn envelope_errors(response: Response) -> Response {
    let status = response.status();
    let is_json = response
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.starts_with("application/json"));
    if !(status.is_client_error() || status.is_server_error()) || is_json {
        return response;
    }
    let text = axum::body::to_bytes(response.into_body(), 16 * 1024)
        .await
        .map(|bytes| String::from_utf8_lossy(&bytes).trim().to_string())
        .unwrap_or_default();
    ApiError::rejection(status, text).into_response()
}

pub fn router(state: AppState) -> Router {
    // Everything here requires the control token, checked before extraction.
    let control = Router::new()
        .route("/v1/builds", get(list).post(start))
        .route("/v1/apps", get(list_apps).post(register_app))
        .route("/v1/apps/import", post(import_app))
        .route("/v1/projects", get(browse_projects))
        .route("/v1/projects/inspect", get(inspect_project))
        .route("/v1/apps/{id}", get(get_app).patch(update_app))
        .route("/v1/apps/{id}/preview", get(app_preview).post(publish_app_preview))
        .route("/v1/builds/{id}", get(status))
        .route("/v1/builds/{id}/cancel", post(cancel))
        .route("/v1/builds/{id}/log", get(build_log))
        .route("/v1/builds/{id}/preview", get(download_preview).post(capture_preview))
        .route("/v1/builds/{id}/install-link", post(create_link))
        .route("/v1/builds/{id}/diagnostics", get(diagnostics))
        .route("/v1/t3/threads/{thread}/steps", get(t3_steps))
        .route("/v1/t3/projects/{project}/screenshot", get(t3_project_screenshot))
        .route("/v1/t3/threads/{thread}/media", get(thread_media).post(add_thread_media))
        .route("/v1/t3/threads/{thread}/media/{id}", get(thread_media_file))
        .route("/v1/t3/threads/{thread}/steps/{call}/images/{index}", get(t3_step_image))
        .route("/v1/sims", get(list_sims).post(start_sim))
        .route("/v1/sims/stop", post(stop_sim))
        .route("/v1/sims/devices", get(sim_devices))
        .route("/v1/agents", get(list_agents).post(ensure_agent))
        .route("/v1/agents/context", get(agent_context))
        .route("/v1/agents/restart", post(restart_agent))
        .route("/v1/agents/fresh", post(fresh_agent))
        .route("/v1/workers", get(list_workers).post(spawn_worker))
        .route("/v1/workers/{id}", get(read_worker))
        .route("/v1/workers/{id}/messages", post(message_worker))
        .route("/v1/workers/{id}/answer", post(answer_worker))
        .route("/v1/workers/{id}/archive", post(archive_worker))
        .route("/v1/workers/cleanup", post(cleanup_workers))
        .route("/v1/push", get(push_status))
        .route("/v1/push/devices", post(push_register))
        .route("/v1/push/activities", post(push_activity))
        .route("/v1/push/presence", post(push_presence))
        .route("/v1/push/test", post(push_test))
        .route("/v1/tasks", get(list_tasks).post(add_task))
        .route("/v1/tasks/{id}", get(show_task).patch(update_task))
        .route("/v1/tasks/{id}/link", post(link_task))
        .route("/v1/tasks/{id}/media", post(attach_task))
        .route("/v1/tasks/{id}/media/{media}", get(task_media_file))
        .route("/v1/import", post(import))
        .route("/v1/captures", post(upload_capture))
        .route("/v1/install-links/{token}", get(link_status))
        .route_layer(middleware::from_fn_with_state(state.clone(), require_control));
    let diagnostics = Router::new()
        .route("/v1/diagnostics", post(ingest))
        .route_layer(middleware::from_fn_with_state(state.clone(), require_diagnostics));
    // Install links carry their own unguessable, expiring token.
    let public = Router::new()
        .route(
            "/health",
            get(|State(state): State<AppState>| async move {
                Json(success(
                    json!({"service":"squircle","version":env!("CARGO_PKG_VERSION"),"accepting_builds":!state.draining.load(Ordering::Acquire)}),
                ))
            }),
        )
        .route("/install/{token}", get(install_page))
        .route("/install/{token}/manifest.plist", get(download_manifest))
        .route("/install/{token}/app.ipa", get(download_ipa));
    Router::new()
        .merge(control)
        .merge(diagnostics)
        .merge(public)
        .fallback(|| async { ApiError::rejection(StatusCode::NOT_FOUND, "Unknown endpoint".into()) })
        .layer(DefaultBodyLimit::max(1024 * 1024))
        .layer(middleware::map_response(envelope_errors))
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
        let mut changed = false;
        if let Some(output) = job.output.as_mut()
            && matches!(output.preview_state.as_deref(), Some("pending" | "running"))
        {
            output.preview_state = Some("failed".into());
            output.preview_error =
                Some("Service stopped during preview capture; no automatic retry was made".into());
            changed = true;
        }
        if !job.state.terminal() {
            job.state = BuildState::Interrupted;
            job.updated_at = now();
            job.error = Some("Service stopped during this job. Inspect artifacts/processes before submitting new work; no automatic retry was made.".into());
            changed = true;
        }
        if changed {
            job.updated_at = now();
            store.save_job(&job)?;
        }
    }
    let tasks = Arc::new(Tasks::open(&store.root)?);
    let agents = Agents::open(&store.root, &format!("http://{}", listener.local_addr()?), tasks.clone())?;
    let push = Push::open(&store.root)?;
    agents.attach_push(push.clone());
    let sims = Sims::open(&store.root, agents.clone())?;
    let mut state = AppState::new(store, public_url);
    state.agents = Some(agents.clone());
    state.sims = Some(sims.clone());
    state.push = Some(push.clone());
    state.tasks = Some(tasks.clone());
    // Service loops, stopped explicitly once requests have drained.
    let mut background = Vec::new();
    {
        // Linked workers and builds move tasks on; old ones age into History.
        let state = state.clone();
        background.push(tokio::spawn(async move {
            loop {
                if let Err(error) = tasks.tick(|task| task_signals(&state, task)) {
                    eprintln!("Tasks not updated: {error:#}");
                }
                tokio::time::sleep(std::time::Duration::from_secs(3)).await;
            }
        }));
    }
    eprintln!(
        "Squircle listening on {}. Keep this process running; HTTPS/Tailscale is managed separately.",
        listener.local_addr()?
    );
    // After the announcement, which is the first line supervisors read.
    background.push(tokio::spawn(agents.clone().run()));
    background.push(tokio::spawn(push.clone().run()));
    background.push(tokio::spawn(sims.clone().run()));
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
            // Refuses new simulator starts, then stops and files recordings and
            // closes their T3 device sessions. Anything cut off here is left in
            // the durable ledger for the next start to recover.
            if tokio::time::timeout(std::time::Duration::from_secs(10), sims.shutdown())
                .await
                .is_err()
            {
                eprintln!("Simulator shutdown timed out; the next start recovers it.");
            }
        })
        .await?;
    for task in background {
        task.abort();
    }
    drop(lock);
    Ok(())
}

async fn list(State(state): State<AppState>) -> ApiResult<Json<Value>> {
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
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    let recovered = state.recovery_jobs.lock().unwrap().get(&id).cloned();
    let job = match recovered {
        Some(job) => job,
        // job.json is replaced atomically, so reading it needs no record lock.
        None => state.files.load_job(&id).map_err(ApiError::missing)?,
    };
    let launches = {
        let (files, lock, id) = (state.files.clone(), state.diagnostics.clone(), id.clone());
        tokio::task::spawn_blocking(move || {
            let _serial = lock.lock().unwrap();
            files.diagnostics(&id, 0, 1, Some(DiagnosticKind::Launch))
        })
        .await
        .map_err(ApiError::internal)?
        .map_err(ApiError::internal)?
    };
    let log = state.files.job_dir(&id).ok().map(|dir| dir.join("build.log"));
    let failure = match (&job.state, log) {
        (BuildState::Failed | BuildState::Interrupted, Some(log)) => {
            let text = log_tail(&log, FAILURE_LOG_TAIL_BYTES).await;
            let root = job.request.as_ref().and_then(|r| r.project.parent()).map(|p| p.to_string_lossy().into_owned());
            let mut failure = crate::buildlog::failure(&String::from_utf8_lossy(&text), root.as_deref());
            failure.message = job.error.as_deref().map(|error| {
                error.rsplit_once("; see /").map_or(error, |(message, _)| message).to_string()
            });
            Some(failure)
        }
        _ => None,
    };
    Ok(Json(success(
        json!({"job":job,"launch_observed":launches["events"].as_array().is_some_and(|a| !a.is_empty()),"failure":failure}),
    )))
}
/// Failure summaries come from the end of a build log; logs can be very large.
const FAILURE_LOG_TAIL_BYTES: u64 = 1024 * 1024;

async fn log_tail(path: &std::path::Path, max: u64) -> Vec<u8> {
    use tokio::io::{AsyncReadExt, AsyncSeekExt};
    let Ok(mut file) = tokio::fs::File::open(path).await else {
        return Vec::new();
    };
    let Ok(size) = file.metadata().await.map(|m| m.len()) else {
        return Vec::new();
    };
    let start = size.saturating_sub(max);
    if file.seek(std::io::SeekFrom::Start(start)).await.is_err() {
        return Vec::new();
    }
    let mut bytes = Vec::new();
    let _ = file.take(max).read_to_end(&mut bytes).await;
    if start > 0 {
        // Start at a whole line, not mid-way through one.
        let first = bytes.iter().position(|b| *b == b'\n').map_or(0, |i| i + 1);
        bytes.drain(..first);
    }
    bytes
}

async fn start(
    State(state): State<AppState>,
    request: std::result::Result<Json<BuildRequest>, JsonRejection>,
) -> ApiResult<Json<Value>> {
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
                return Err(ApiError::new(StatusCode::CONFLICT, "request_id_conflict", "Request ID already belongs to different build arguments", "Use a new request ID for different work."));
            }
            return Ok(Json(success(json!({"job":prior,"replayed":true}))));
        }
        if state.cancellations.lock().unwrap().len() >= 16 {
            return Err(ApiError::bad(
                "Build/preview queue is full (16 jobs); wait or cancel a job",
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
            match result {
                Ok(output) => {
                    job.state = BuildState::Succeeded;
                    job.output = Some(output);
                    if request.capture_preview {
                        job.output.as_mut().unwrap().preview_state = Some("running".into());
                        job.updated_at = now();
                        let persisted = state.store.lock().unwrap().save_job(&job);
                        let capture = match persisted {
                            Ok(()) => match preview::simulator_id(None) {
                                Ok(simulator) => {
                                    preview::capture(&job, &dir, &simulator, receiver.clone()).await
                                }
                                Err(error) => Err(error),
                            },
                            Err(error) => {
                                state.draining.store(true, Ordering::Release);
                                Err(error.context("Could not persist preview state"))
                            }
                        };
                        preview::apply_result(job.output.as_mut().unwrap(), capture);
                    }
                }
                Err(error) => {
                    job.state = if *receiver.borrow() {
                        BuildState::Cancelled
                    } else {
                        BuildState::Failed
                    };
                    job.error = Some(format!("{error:#}"));
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
        } else if job.state == BuildState::Succeeded {
            sync_job_app(&state, &job).await;
        }
        if let Some(push) = &state.push {
            push.build_finished(&job);
        }
        state.cancellations.lock().unwrap().remove(&job.id);
        drop(permit);
    });
    Ok(Json(success(json!({"job":response,"replayed":false}))))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PreviewRequest {
    simulator: Option<String>,
}

async fn capture_preview(
    State(state): State<AppState>,
    Path(id): Path<String>,
    input: std::result::Result<Json<PreviewRequest>, JsonRejection>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    let input = body(input)?;
    let simulator = preview::simulator_id(input.simulator.as_deref()).map_err(ApiError::bad)?;
    let (sender, mut receiver) = watch::channel(false);
    let (mut job, directory) = {
        let store = state.store.lock().unwrap();
        if state.draining.load(Ordering::Acquire) {
            return Err(ApiError::unavailable());
        }
        let mut job = store.load_job(&id).map_err(ApiError::missing)?;
        if job.state != BuildState::Succeeded || job.request.is_none() || job.output.is_none() {
            return Err(ApiError::bad(
                "Preview requires a succeeded project build with a simulator build recipe",
            ));
        }
        let mut cancellations = state.cancellations.lock().unwrap();
        if cancellations.contains_key(&id) {
            return Err(ApiError::new(StatusCode::CONFLICT, "preview_in_progress", "This build already has work in progress", "Poll build status before recapturing."));
        }
        if cancellations.len() >= 16 {
            return Err(ApiError::bad("Build/preview queue is full (16 jobs)"));
        }
        let output = job.output.as_mut().unwrap();
        output.preview_state = Some("pending".into());
        output.preview_error = None;
        job.updated_at = now();
        store.save_job(&job).map_err(ApiError::internal)?;
        cancellations.insert(id.clone(), sender);
        let directory = store.job_dir(&id).map_err(ApiError::internal)?;
        (job, directory)
    };
    let response = job.clone();
    tokio::spawn(async move {
        let permit = tokio::select! {
            result = state.slots.clone().acquire_owned() => result.ok(),
            _ = receiver.changed() => None,
        };
        let result = if permit.is_none() || *receiver.borrow() {
            Err(anyhow::anyhow!("Preview cancelled before capture"))
        } else {
            job.output.as_mut().unwrap().preview_state = Some("running".into());
            job.updated_at = now();
            let persisted = state.store.lock().unwrap().save_job(&job);
            match persisted {
                Ok(()) => preview::capture(&job, &directory, &simulator, receiver).await,
                Err(error) => {
                    state.draining.store(true, Ordering::Release);
                    Err(error.context("Could not persist preview Running state"))
                }
            }
        };
        preview::apply_result(job.output.as_mut().unwrap(), result);
        job.updated_at = now();
        let persisted = state.store.lock().unwrap().save_job(&job);
        if let Err(error) = persisted {
            state.draining.store(true, Ordering::Release);
            job.output.as_mut().unwrap().preview_error =
                Some(format!("Preview result could not be persisted: {error}"));
            state.recovery_jobs.lock().unwrap().insert(id.clone(), job);
        } else {
            sync_job_app(&state, &job).await;
        }
        state.cancellations.lock().unwrap().remove(&id);
        drop(permit);
    });
    Ok((StatusCode::ACCEPTED, Json(success(json!({"job":response})))))
}

async fn sync_job_app(state: &AppState, job: &Job) {
    let (state, job) = (state.clone(), job.clone());
    // Copies the preview under the record lock; keep it off the async workers.
    let result = tokio::task::spawn_blocking(move || {
        apps::sync_build_preview(&state.store.lock().unwrap(), &job).map_err(|e| (job.id.clone(), e))
    })
    .await;
    if let Ok(Err((id, error))) = result {
        // Catalog publication is ancillary: never invalidate an exported IPA.
        eprintln!("Could not sync app metadata for build {id}: {error:#}");
    }
}

fn public_app(app: apps::AppRecord) -> Value {
    // A missing artifact is the app's preview being unavailable, not an error;
    // republishing repairs it.
    let available = app.preview.is_none() || apps::open_preview(&app).is_ok();
    let mut value = serde_json::to_value(app).expect("app metadata serializes");
    if !available {
        value["preview"] = Value::Null;
        value["preview_unavailable"] = json!(true);
    }
    if let Some(preview) = value["preview"].as_object_mut() {
        preview.remove("path");
    }
    value
}

#[derive(Deserialize)]
struct BrowseQuery {
    path: Option<String>,
}
#[derive(Deserialize)]
struct InspectQuery {
    project: String,
    scheme: Option<String>,
    configuration: Option<String>,
}

async fn browse_projects(
    query: std::result::Result<Query<BrowseQuery>, QueryRejection>,
) -> ApiResult<Json<Value>> {
    let query = parse_query(query)?;
    let directory = tokio::task::spawn_blocking(move || projects::browse(query.path.as_deref()))
        .await
        .map_err(ApiError::internal)?
        .map_err(ApiError::bad)?;
    Ok(Json(success(directory)))
}
fn inspection_busy() -> ApiError {
    ApiError {
        retryable: true,
        ..ApiError::new(StatusCode::TOO_MANY_REQUESTS, "inspection_busy", "Two Xcode inspections are already running", "Wait for an existing inspection to finish, then retry.")
    }
}
async fn inspect_project(
    State(state): State<AppState>,
    query: std::result::Result<Query<InspectQuery>, QueryRejection>,
) -> ApiResult<Json<Value>> {
    let query = parse_query(query)?;
    let _permit = state
        .inspection_slots
        .clone()
        .try_acquire_owned()
        .map_err(|_| inspection_busy())?;
    let result = projects::inspect(
        &query.project,
        query.scheme.as_deref(),
        query.configuration.as_deref(),
    )
    .await
    .map_err(ApiError::bad)?;
    Ok(Json(success(result)))
}
async fn import_app(
    State(state): State<AppState>,
    input: std::result::Result<Json<projects::ImportRequest>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let input = body(input)?;
    if input.name.trim().is_empty() || input.name.len() > 200 || input.name.contains('\0') {
        return Err(ApiError::bad("App name must contain 1–200 characters"));
    }
    if state.draining.load(Ordering::Acquire) {
        return Err(ApiError::unavailable());
    }
    let _permit = state
        .inspection_slots
        .clone()
        .try_acquire_owned()
        .map_err(|_| inspection_busy())?;
    let inspected = projects::inspect(
        &input.project,
        Some(&input.scheme),
        Some(&input.configuration),
    )
    .await
    .map_err(ApiError::bad)?;
    let app = tokio::task::spawn_blocking(move || {
        let store = state.store.lock().unwrap();
        if state.draining.load(Ordering::Acquire) {
            return Err(ApiError::unavailable());
        }
        projects::import_inspected(&store, &inspected, &input.name).map_err(ApiError::bad)
    })
    .await
    .map_err(ApiError::internal)??;
    Ok(Json(success(public_app(app))))
}

async fn list_apps(State(state): State<AppState>) -> ApiResult<Json<Value>> {
    let apps = apps::list(&state.store.lock().unwrap()).map_err(ApiError::internal)?;
    Ok(Json(success(
        apps.into_iter().map(public_app).collect::<Vec<_>>(),
    )))
}

async fn get_app(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    let app = apps::get(&state.store.lock().unwrap(), &id).map_err(ApiError::missing)?;
    Ok(Json(success(public_app(app))))
}

async fn register_app(
    State(state): State<AppState>,
    input: std::result::Result<Json<apps::AppRegistration>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let input = body(input)?;
    let app = tokio::task::spawn_blocking(move || {
        let store = state.store.lock().unwrap();
        if state.draining.load(Ordering::Acquire) {
            return Err(ApiError::unavailable());
        }
        apps::register(&store, input).map_err(ApiError::bad)
    })
    .await
    .map_err(ApiError::internal)??;
    Ok(Json(success(public_app(app))))
}

async fn update_app(
    State(state): State<AppState>,
    Path(id): Path<String>,
    input: std::result::Result<Json<apps::AppUpdate>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let input = body(input)?;
    let app = tokio::task::spawn_blocking(move || {
        let store = state.store.lock().unwrap();
        if state.draining.load(Ordering::Acquire) {
            return Err(ApiError::unavailable());
        }
        apps::get(&store, &id).map_err(ApiError::missing)?;
        apps::update(&store, &id, input).map_err(ApiError::bad)
    })
    .await
    .map_err(ApiError::internal)??;
    Ok(Json(success(public_app(app))))
}

async fn publish_app_preview(
    State(state): State<AppState>,
    Path(id): Path<String>,
    input: std::result::Result<Json<apps::PreviewPublication>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let input = body(input)?;
    let app = tokio::task::spawn_blocking(move || {
        // Copy and validate outside the record lock; only the commit holds it.
        let staged = apps::stage_preview(&state.files.root, &id, &input.file).map_err(|error| {
            if state.files.root.join("apps").join(&id).is_dir() {
                ApiError::bad(format!("{error:#}"))
            } else {
                ApiError::missing(format!("{error:#}"))
            }
        })?;
        let store = state.store.lock().unwrap();
        if state.draining.load(Ordering::Acquire) {
            return Err(ApiError::unavailable());
        }
        apps::get(&store, &id).map_err(ApiError::missing)?;
        apps::publish_staged(&store, &id, input, staged).map_err(ApiError::bad)
    })
    .await
    .map_err(ApiError::internal)??;
    Ok(Json(success(public_app(app))))
}

#[derive(Deserialize)]
struct PreviewVersion {
    version: Option<String>,
}

#[derive(Deserialize)]
struct StepsQuery {
    since: Option<String>,
}

/// Tool-call details T3 omits from its client stream; see `t3steps`.
async fn t3_steps(
    State(state): State<AppState>,
    Path(thread): Path<String>,
    query: std::result::Result<Query<StepsQuery>, QueryRejection>,
) -> ApiResult<Json<Value>> {
    let query = parse_query(query)?;
    let mut steps = crate::t3steps::steps(&thread, query.since.as_deref())
        .await
        .map_err(|e| ApiError::bad(e.to_string()))?;
    if let Ok(agents) = agents(&state) {
        steps["workers"] = json!(agents.all_workers());
    }
    Ok(Json(success(steps)))
}

/// The newest real screenshot captured in a project's threads; see `t3steps`.
async fn t3_project_screenshot(
    Path(project): Path<String>,
) -> ApiResult<Response> {
    let image = crate::t3steps::project_screenshot(&project)
        .await
        .map_err(|e| ApiError::bad(e.to_string()))?
        .ok_or_else(|| ApiError::missing("No screenshot in this project's threads"))?;
    Ok((private_headers(), Json(success(image))).into_response())
}

/// Recordings and images agents published into a thread (`squircle media add`).
async fn thread_media(
    State(state): State<AppState>,
    Path(thread): Path<String>,
) -> ApiResult<Json<Value>> {
    let root = state.files.root.clone();
    let items = crate::media::list(&root, &thread).map_err(ApiError::bad)?;
    let items: Vec<Value> = items
        .into_iter()
        .map(|m| json!({"id":m.id,"kind":m.kind,"caption":m.caption,"content_type":m.content_type,"bytes":m.bytes,"created_at":m.created_at,"simulator":m.simulator}))
        .collect();
    Ok(Json(success(json!({"thread_id":thread,"media":items}))))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AddMedia {
    file: PathBuf,
    caption: Option<String>,
}

/// Publishes a file on this Mac into a thread (`squircle media add`).
async fn add_thread_media(
    State(state): State<AppState>,
    Path(thread): Path<String>,
    payload: std::result::Result<Json<AddMedia>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    let root = state.files.root.clone();
    let media = tokio::task::spawn_blocking(move || crate::media::add(&root, &thread, &r.file, r.caption.as_deref()))
        .await
        .map_err(ApiError::internal)?
        .map_err(ApiError::bad)?;
    Ok(Json(success(json!({"id":media.id,"thread_id":media.thread_id,"kind":media.kind,"caption":media.caption,"content_type":media.content_type,"bytes":media.bytes,"created_at":media.created_at}))))
}

async fn thread_media_file(
    State(state): State<AppState>,
    Path((thread, id)): Path<(String, String)>,
) -> ApiResult<Response> {
    let root = state.files.root.clone();
    let media = crate::media::get(&root, &thread, &id).map_err(ApiError::missing)?;
    let file = tokio::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(&media.file)
        .await
        .map_err(ApiError::missing)?;
    let metadata = file.metadata().await.map_err(ApiError::internal)?;
    if !metadata.is_file() {
        return Err(ApiError::internal("Invalid media file"));
    }
    let mut response = (
        private_headers(),
        [(header::CONTENT_TYPE, media.content_type.clone())],
        Body::from_stream(ReaderStream::new(file)),
    )
        .into_response();
    response
        .headers_mut()
        .insert(header::CONTENT_LENGTH, metadata.len().to_string().parse().unwrap());
    Ok(response)
}

async fn t3_step_image(
    Path((thread, call, index)): Path<(String, String, usize)>,
) -> ApiResult<Response> {
    let image = crate::t3steps::image(&thread, &call, index)
        .await
        .map_err(|e| ApiError::bad(e.to_string()))?
        .ok_or_else(|| ApiError::missing("No such image"))?;
    Ok((private_headers(), Json(success(image))).into_response())
}

async fn app_preview(
    State(state): State<AppState>,
    Path(id): Path<String>,
    query: std::result::Result<Query<PreviewVersion>, QueryRejection>,
) -> ApiResult<Response> {
    let query = parse_query(query)?;
    let (file, preview_id) = {
        let store = state.store.lock().unwrap();
        let app = apps::get(&store, &id).map_err(ApiError::missing)?;
        let preview = app
            .preview
            .clone()
            .ok_or_else(|| ApiError::missing("App has no published preview"))?;
        if query
            .version
            .as_ref()
            .is_some_and(|version| version != &preview.id)
        {
            return Err(ApiError::new(StatusCode::CONFLICT, "preview_changed", "App preview has changed since metadata was read", "Refresh app metadata and request its current preview version."));
        }
        let file = apps::open_preview(&app).map_err(ApiError::missing)?;
        (file, preview.id)
    };
    let size = file.metadata().map_err(ApiError::internal)?.len();
    let file = tokio::fs::File::from_std(file);
    let mut response = (
        private_headers(),
        [(header::CONTENT_TYPE, "image/png")],
        Body::from_stream(ReaderStream::new(file)),
    )
        .into_response();
    response
        .headers_mut()
        .insert(header::CONTENT_LENGTH, size.to_string().parse().unwrap());
    response
        .headers_mut()
        .insert(header::ETAG, format!("\"{preview_id}\"").parse().unwrap());
    Ok(response)
}

async fn download_preview(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Response> {
    let path = {
        let store = state.store.lock().unwrap();
        let job = store.load_job(&id).map_err(ApiError::missing)?;
        let path = job
            .output
            .and_then(|output| output.preview_path)
            .ok_or_else(|| ApiError::missing("This build has no captured preview"))?;
        let expected = store
            .job_dir(&id)
            .map_err(ApiError::missing)?
            .join("preview.png");
        if path != expected {
            return Err(ApiError::internal(
                "Preview artifact is outside its build directory",
            ));
        }
        path
    };
    // Do not serve symlink substitutions or arbitrary paths from edited records.
    let file = tokio::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(&path)
        .await
        .map_err(ApiError::missing)?;
    let metadata = file.metadata().await.map_err(ApiError::internal)?;
    if !metadata.is_file() || metadata.len() > 32 * 1024 * 1024 {
        return Err(ApiError::internal("Invalid preview artifact"));
    }
    Ok((
        [
            (header::CONTENT_TYPE, "image/png"),
            (header::CACHE_CONTROL, "no-store"),
            (header::X_CONTENT_TYPE_OPTIONS, "nosniff"),
        ],
        Body::from_stream(ReaderStream::new(file)),
    )
        .into_response())
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
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
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
    input: std::result::Result<Json<ImportRequest>, JsonRejection>,
) -> ApiResult<Json<Value>> {
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
    Path(id): Path<String>,
    input: std::result::Result<Json<LinkRequest>, JsonRejection>,
) -> ApiResult<Json<Value>> {
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
        download_started_at: None,
        downloaded_at: None,
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
        return Err(ApiError::new(StatusCode::GONE, "link_expired", "Install link expired", "Request a new install link for the same build."));
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
/// Whether iOS has started (`download_started_at`) and finished (`downloaded_at`)
/// downloading a link's IPA; it fetches it only after the person confirms the
/// system install prompt. Neither confirms installation.
async fn link_status(
    State(state): State<AppState>,
    Path(token): Path<String>,
) -> ApiResult<Json<Value>> {
    let ticket = state
        .store
        .lock()
        .unwrap()
        .load_ticket(&token)
        .map_err(|_| ApiError::missing("Unknown install link"))?;
    Ok(Json(success(
        json!({"build_id":ticket.build_id,"expires_at":ticket.expires_at,"download_started_at":ticket.download_started_at,"downloaded_at":ticket.downloaded_at}),
    )))
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
    let (ticket, job) = ticket_job(&state, &token)?;
    let path = job.output.unwrap().ipa_path.unwrap();
    let file = tokio::fs::File::open(path)
        .await
        .map_err(ApiError::missing)?;
    let size = file.metadata().await.map_err(ApiError::internal)?.len();
    // Evidence only, recorded as it happens: the IPA was opened for a request,
    // then every byte was handed to the connection. Neither blocks the
    // download, and neither proves installation or launch.
    if ticket.download_started_at.is_none() {
        let _ = mark_ticket(&state, &token, |t| t.download_started_at.get_or_insert(now()));
    }
    let sent = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let counter = sent.clone();
    let finished = futures_util::stream::once(async move {
        if counter.load(Ordering::Acquire) == size {
            let _ = tokio::task::spawn_blocking(move || {
                mark_ticket(&state, &token, |t| t.downloaded_at.get_or_insert(now()))
            })
            .await;
        }
        Ok::<_, std::io::Error>(axum::body::Bytes::new())
    });
    use futures_util::StreamExt;
    let stream = ReaderStream::new(file)
        .inspect(move |chunk| {
            if let Ok(chunk) = chunk {
                sent.fetch_add(chunk.len() as u64, Ordering::AcqRel);
            }
        })
        .chain(finished);
    let mut response = (
        private_headers(),
        [(header::CONTENT_TYPE, "application/octet-stream")],
        Body::from_stream(stream),
    )
        .into_response();
    response
        .headers_mut()
        .insert(header::CONTENT_LENGTH, size.to_string().parse().unwrap());
    Ok(response)
}

/// Sets a ticket's evidence field once, under the record lock.
fn mark_ticket(state: &AppState, token: &str, mark: impl FnOnce(&mut Ticket) -> &mut u64) -> Result<()> {
    let store = state.store.lock().unwrap();
    let mut ticket = store.load_ticket(token)?;
    mark(&mut ticket);
    store.save_ticket(&ticket)
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
    Path(id): Path<String>,
    page: std::result::Result<Query<Page>, QueryRejection>,
) -> ApiResult<Json<Value>> {
    let page = parse_query(page)?;
    let (files, lock) = (state.files.clone(), state.diagnostics.clone());
    let data = tokio::task::spawn_blocking(move || {
        let _serial = lock.lock().unwrap();
        files.diagnostics(&id, page.since, page.limit.unwrap_or(100), page.kind)
    })
    .await
    .map_err(ApiError::internal)?
    .map_err(ApiError::bad)?;
    Ok(Json(success(data)))
}
#[derive(Deserialize)]
struct CaptureQuery {
    kind: String,
}

/// A screen or performance recording from the phone; the message that sends
/// it links the returned path. Authentication runs before this handler, the
/// body streams into a private staging file (never memory), one upload at a
/// time, and the staged file is removed on any failure or cancellation.
async fn upload_capture(
    State(state): State<AppState>,
    query: std::result::Result<Query<CaptureQuery>, QueryRejection>,
    request: Request,
) -> ApiResult<Json<Value>> {
    let query = parse_query(query)?;
    let max = crate::perf::MAX_UPLOAD_BYTES as u64;
    let declared = request
        .headers()
        .get(header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok());
    if declared.is_some_and(|length| length > max) {
        return Err(ApiError::too_large("A capture must be at most 300 MB"));
    }
    let _permit = state.uploads.clone().try_acquire_owned().map_err(|_| ApiError {
        retryable: true,
        ..ApiError::new(StatusCode::TOO_MANY_REQUESTS, "upload_busy", "Another capture is uploading", "Wait for it to finish, then retry.")
    })?;
    let root = state.files.root.clone();
    let staged = crate::perf::staging_path(&root).map_err(ApiError::internal)?;
    let file = crate::media::create_private(&staged).map_err(ApiError::internal)?;
    // Removes the staged file unless it was published; also on cancellation.
    let guard = StagedFile(Some(staged.clone()));
    write_bounded(request.into_body(), tokio::fs::File::from_std(file), max).await?;
    let kind = query.kind;
    let path = tokio::task::spawn_blocking(move || {
        let result = crate::perf::store_file(&root, &kind, &staged);
        if result.is_ok() {
            let mut guard = guard;
            guard.0 = None;
        }
        result
    })
    .await
    .map_err(ApiError::internal)?
    .map_err(ApiError::bad)?;
    Ok(Json(success(json!({"path": path}))))
}

struct StagedFile(Option<PathBuf>);
impl Drop for StagedFile {
    fn drop(&mut self) {
        if let Some(path) = self.0.take() {
            let _ = std::fs::remove_file(path);
        }
    }
}

/// Copies a request body into `file`, refusing more than `max` bytes.
async fn write_bounded(body: Body, mut file: tokio::fs::File, max: u64) -> ApiResult<()> {
    use futures_util::StreamExt;
    use tokio::io::AsyncWriteExt;
    let mut stream = body.into_data_stream();
    let mut written = 0u64;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| ApiError::bad(format!("Upload interrupted: {e}")))?;
        written += chunk.len() as u64;
        if written > max {
            return Err(ApiError::too_large("A capture must be at most 300 MB"));
        }
        file.write_all(&chunk).await.map_err(ApiError::internal)?;
    }
    file.sync_all().await.map_err(ApiError::internal)?;
    Ok(())
}

async fn ingest(
    State(state): State<AppState>,
    event: std::result::Result<Json<Diagnostic>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let mut event = body(event)?;
    // Foundation UUID.uuidString uses uppercase. Normalize valid UUIDs at the
    // wire boundary so storage paths and replay comparisons remain canonical.
    event.event_id = uuid::Uuid::parse_str(&event.event_id)
        .map_err(|_| ApiError::bad("event_id must be a valid UUID"))?
        .hyphenated()
        .to_string();
    event.build_id = uuid::Uuid::parse_str(&event.build_id)
        .map_err(|_| ApiError::bad("build_id must be a valid UUID"))?
        .hyphenated()
        .to_string();
    let (files, lock, stored) = (state.files.clone(), state.diagnostics.clone(), event.clone());
    let inserted = tokio::task::spawn_blocking(move || {
        let _serial = lock.lock().unwrap();
        files.append_diagnostic(&stored)
    })
    .await
    .map_err(ApiError::internal)?
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
    Path(id): Path<String>,
    page: std::result::Result<Query<LogPage>, QueryRejection>,
) -> ApiResult<Json<Value>> {
    let page = parse_query(page)?;
    state.files.load_job(&id).map_err(ApiError::missing)?;
    let path = state.files.job_dir(&id).map_err(ApiError::bad)?.join("build.log");
    use tokio::io::{AsyncReadExt, AsyncSeekExt};
    let mut file = match tokio::fs::File::open(path).await {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Json(success(
                json!({"text":"","next_offset":0,"has_more":false,"size":0}),
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
        json!({"text":String::from_utf8_lossy(&bytes),"next_offset":page.offset+count as u64,"has_more":(page.offset+count as u64)<size,"size":size}),
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
            capture_preview: false,
            no_overlay: false,
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
    async fn swift_uppercase_diagnostic_uuids_are_accepted_and_lowercase_retries_deduplicate()
    -> Result<()> {
        let dir = tempfile::tempdir()?;
        let source = dir.path().join("input.ipa");
        test_ipa(&source)?;
        let state = AppState::new(Store::open(dir.path().join("state"))?, None);
        let job = import_ipa(&state, &source, copy_and_inspect_ipa)?;
        let diagnostic_token = state
            .store
            .lock()
            .unwrap()
            .settings
            .diagnostic_token
            .clone();
        let mut authorization = HeaderMap::new();
        authorization.insert(
            header::AUTHORIZATION,
            format!("Bearer {diagnostic_token}").parse()?,
        );
        let event_id = "a50f8213-88d3-4b6f-91d3-143aceef3f9d";
        let mut event = Diagnostic {
            event_id: event_id.to_uppercase(),
            build_id: job.id.to_uppercase(),
            kind: DiagnosticKind::Crash,
            message: "Swift crash report".into(),
            timestamp: 1,
            attributes: json!({}),
        };
        let Json(first) = ingest(
            State(state.clone()),
            Ok(Json(event.clone())),
        )
        .await
        .unwrap();
        assert_eq!(first["data"]["event_id"], event_id);
        assert_eq!(first["data"]["stored"], true);
        event.event_id = event_id.into();
        event.build_id = job.id.clone();
        let Json(retry) = ingest(
            State(state.clone()),
            Ok(Json(event.clone())),
        )
        .await
        .unwrap();
        assert_eq!(retry["data"]["duplicate"], true);
        let stored = state
            .store
            .lock()
            .unwrap()
            .diagnostics(&job.id, 0, 10, None)?;
        assert_eq!(stored["events"].as_array().unwrap().len(), 1);
        assert_eq!(stored["events"][0]["event_id"], event_id);
        assert_eq!(stored["events"][0]["build_id"], job.id);

        event.build_id = "../outside".into();
        let error = ingest(State(state), Ok(Json(event)))
            .await
            .unwrap_err();
        assert_eq!(error.status, StatusCode::BAD_REQUEST);
        Ok(())
    }

    #[tokio::test]
    async fn unauthorized_or_invalid_imports_publish_no_record() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let source = dir.path().join("input.ipa");
        test_ipa(&source)?;
        let state = AppState::new(Store::open(dir.path().join("state"))?, None);
        use tower::ServiceExt;
        let response = router(state.clone())
            .oneshot(
                axum::http::Request::post("/v1/import")
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Body::from(json!({"ipa": source}).to_string()))?,
            )
            .await?;
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
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
            Ok(Json(request.clone())),
        )
        .await
        .unwrap();
        let id = first["data"]["job"]["id"].as_str().unwrap().to_owned();
        let Json(retry) = start(
            State(state.clone()),
            Ok(Json(request.clone())),
        )
        .await
        .unwrap();
        assert_eq!(retry["data"]["job"]["id"], id);
        assert_eq!(retry["data"]["replayed"], true);
        let mut changed = request;
        changed.configuration = "Debug".into();
        assert_eq!(
            start(State(state.clone()), Ok(Json(changed)))
                .await
                .unwrap_err()
                .status,
            StatusCode::CONFLICT
        );
        let _ = cancel(State(state.clone()), Path(id.clone()))
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
            Ok(Json(request(dir.path()))),
        )
        .await
        .unwrap_err();
        assert_eq!(error.status, StatusCode::SERVICE_UNAVAILABLE);
        // Refused before any side effect, so clients may send it again.
        assert!(error.retryable);
        assert!(state.store.lock().unwrap().list_jobs().unwrap().is_empty());
    }
}

// MARK: Simulator sessions

fn sims(state: &AppState) -> ApiResult<Arc<Sims>> {
    state.sims.clone().ok_or_else(|| sim_error(anyhow::anyhow!("Simulator sessions are not running in this service")))
}

fn sim_error(error: anyhow::Error) -> ApiError {
    ApiError::new(StatusCode::CONFLICT, "simulator_failed", format!("{error:#}"), "Read the message; run squircle sim --help.")
}

#[derive(Deserialize)]
struct SimQuery {
    thread: Option<String>,
}

async fn list_sims(
    State(state): State<AppState>,
    query: std::result::Result<Query<SimQuery>, QueryRejection>,
) -> ApiResult<Json<Value>> {
    let query = parse_query(query)?;
    Ok(Json(success(sims(&state)?.list(query.thread.as_deref()))))
}

#[derive(Deserialize)]
struct StartSim {
    thread_id: String,
    device: Option<String>,
}

async fn start_sim(
    State(state): State<AppState>,
    payload: std::result::Result<Json<StartSim>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let request = body(payload)?;
    let started = sims(&state)?.start(&request.thread_id, request.device.as_deref()).await.map_err(sim_error)?;
    Ok(Json(success(started)))
}

#[derive(Deserialize)]
struct StopSim {
    thread_id: Option<String>,
    id: Option<String>,
}

async fn stop_sim(
    State(state): State<AppState>,
    payload: std::result::Result<Json<StopSim>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let request = body(payload)?;
    let session = sims(&state)?.stop(request.thread_id.as_deref(), request.id.as_deref()).await.map_err(sim_error)?;
    let next = if session.media_id.is_some() { "The recording now shows in this turn on the phone." } else { "No recording was saved; see error." };
    Ok(Json(success(json!({"session": session, "next": next}))))
}

async fn sim_devices(State(state): State<AppState>) -> ApiResult<Json<Value>> {
    Ok(Json(success(sims(&state)?.devices().await.map_err(sim_error)?)))
}

// MARK: App agents

fn agent_error(error: anyhow::Error) -> ApiError {
    ApiError::new(StatusCode::CONFLICT, "agent_failed", format!("{error:#}"), "Read the message; run squircle agent --help or squircle thread --help.")
}

fn agents(state: &AppState) -> ApiResult<Arc<Agents>> {
    state.agents.clone().ok_or_else(|| agent_error(anyhow::anyhow!("App agents are not running in this service")))
}

async fn list_agents(State(state): State<AppState>) -> ApiResult<Json<Value>> {
    let agents = agents(&state)?;
    // How agents and the phone's worker prompts invoke this service's CLI.
    Ok(Json(success(json!({"agents": agents.list(), "t3": agents.status(), "cli": agents.cli()}))))
}

#[derive(Deserialize)]
struct EnsureAgent {
    project_id: String,
    message: Option<String>,
    model: Option<String>,
    /// T3's runtime mode for a new agent; None keeps the service default.
    runtime_mode: Option<String>,
}

const RUNTIME_MODES: [&str; 4] = ["approval-required", "auto-accept-edits", "auto", "full-access"];

async fn ensure_agent(
    State(state): State<AppState>,
    payload: std::result::Result<Json<EnsureAgent>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let request = body(payload)?;
    if let Some(mode) = &request.runtime_mode
        && !RUNTIME_MODES.contains(&mode.as_str())
    {
        return Err(ApiError::bad(format!("runtime_mode must be one of {}", RUNTIME_MODES.join(", "))));
    }
    let agent = agents(&state)?
        .ensure(&request.project_id, request.message.as_deref(), request.model.as_deref(), request.runtime_mode.as_deref())
        .await
        .map_err(agent_error)?;
    Ok(Json(success(json!({"agent": agent}))))
}

#[derive(Deserialize)]
struct ResetAgent {
    project_id: Option<String>,
    thread_id: Option<String>,
    handoff: Option<String>,
}

async fn restart_agent(
    State(state): State<AppState>,
    payload: std::result::Result<Json<ResetAgent>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let request = body(payload)?;
    let result = agents(&state)?
        .reset(request.project_id.as_deref(), request.thread_id.as_deref(), crate::agents::Reset::Restart)
        .await.map_err(agent_error)?;
    Ok(Json(success(result)))
}

async fn fresh_agent(
    State(state): State<AppState>,
    payload: std::result::Result<Json<ResetAgent>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let request = body(payload)?;
    let result = agents(&state)?
        .reset(request.project_id.as_deref(), request.thread_id.as_deref(), crate::agents::Reset::Fresh { note: request.handoff })
        .await.map_err(agent_error)?;
    Ok(Json(success(result)))
}

#[derive(Deserialize)]
struct ContextQuery {
    cwd: PathBuf,
}

async fn agent_context(
    State(state): State<AppState>,
    query: std::result::Result<Query<ContextQuery>, QueryRejection>,
) -> ApiResult<Json<Value>> {
    let query = parse_query(query)?;
    Ok(Json(success(json!({"context": agents(&state)?.context(&query.cwd)}))))
}

#[derive(Deserialize)]
struct WorkerQuery {
    coordinator: Option<String>,
}

async fn list_workers(
    State(state): State<AppState>,
    query: std::result::Result<Query<WorkerQuery>, QueryRejection>,
) -> ApiResult<Json<Value>> {
    let query = parse_query(query)?;
    Ok(Json(success(json!({"workers": agents(&state)?.workers(query.coordinator.as_deref())}))))
}

#[derive(Deserialize)]
struct SpawnWorker {
    coordinator: String,
    title: String,
    branch: String,
    base: Option<String>,
    prompt: String,
    provider: Option<String>,
    model: Option<String>,
    effort: Option<String>,
    /// A task to link the worker to.
    task: Option<String>,
}

async fn spawn_worker(
    State(state): State<AppState>,
    payload: std::result::Result<Json<SpawnWorker>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    if let Some(task) = &r.task {
        tasks_of(&state)?.get(task).map_err(ApiError::missing)?;
    }
    let worker = agents(&state)?
        .spawn(&r.coordinator, &r.title, &r.branch, r.base.as_deref(), &r.prompt, r.provider.as_deref(), r.model.as_deref(), r.effort.as_deref())
        .await
        .map_err(agent_error)?;
    if let (Some(task), Some(id)) = (&r.task, worker["id"].as_str()) {
        tasks_of(&state)?.link(task, Some(id), None, false).map_err(task_error)?;
    }
    Ok(Json(success(worker)))
}

async fn read_worker(State(state): State<AppState>, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    Ok(Json(success(agents(&state)?.read(&id).await.map_err(agent_error)?)))
}

#[derive(Deserialize)]
struct WorkerText {
    text: String,
}

async fn message_worker(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<WorkerText>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let text = body(payload)?.text;
    if text.trim().is_empty() {
        return Err(ApiError::bad("Message text is empty"));
    }
    agents(&state)?.message(&id, &text).await.map_err(agent_error)?;
    Ok(Json(success(json!({"sent": id}))))
}

async fn answer_worker(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<WorkerText>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let text = body(payload)?.text;
    agents(&state)?.answer(&id, &text).await.map_err(agent_error)?;
    Ok(Json(success(json!({"answered": id}))))
}

#[derive(Deserialize)]
struct ArchiveWorker {
    #[serde(default, alias = "force")]
    discard: bool,
}

async fn archive_worker(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<ArchiveWorker>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let discard = body(payload)?.discard;
    Ok(Json(success(agents(&state)?.archive(&id, discard).await.map_err(agent_error)?)))
}

#[derive(Deserialize)]
struct CleanupWorkers {
    coordinator: String,
    #[serde(default)]
    dry_run: bool,
}

async fn cleanup_workers(
    State(state): State<AppState>,
    payload: std::result::Result<Json<CleanupWorkers>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let request = body(payload)?;
    Ok(Json(success(agents(&state)?.cleanup(&request.coordinator, request.dry_run).await.map_err(agent_error)?)))
}

fn push(state: &AppState) -> ApiResult<Arc<Push>> {
    state.push.clone().ok_or_else(|| ApiError::internal("Notifications run only inside squircle serve"))
}

async fn push_status(State(state): State<AppState>) -> ApiResult<Json<Value>> {
    Ok(Json(success(push(&state)?.status())))
}

async fn push_register(
    State(state): State<AppState>,
    payload: std::result::Result<Json<crate::push::Registration>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    push(&state)?.register(body(payload)?).map_err(ApiError::bad)?;
    Ok(Json(success(json!({}))))
}

async fn push_activity(
    State(state): State<AppState>,
    payload: std::result::Result<Json<crate::push::ActivityRegistration>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    push(&state)?.register_activity(body(payload)?).map_err(ApiError::bad)?;
    Ok(Json(success(json!({}))))
}

async fn push_presence(
    State(state): State<AppState>,
    payload: std::result::Result<Json<crate::push::PresenceReport>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    push(&state)?.report_presence(body(payload)?).map_err(ApiError::bad)?;
    Ok(Json(success(json!({}))))
}

#[derive(Deserialize)]
struct PushTest {
    #[serde(default)]
    live_activity: bool,
}

async fn push_test(
    State(state): State<AppState>,
    payload: std::result::Result<Json<PushTest>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let request = body(payload)?;
    Ok(Json(success(push(&state)?.test(request.live_activity).await)))
}

// MARK: Tasks

fn task_error(error: anyhow::Error) -> ApiError {
    ApiError::new(StatusCode::BAD_REQUEST, "task_failed", format!("{error:#}"), "Read the message; run squircle task --help.")
}

fn tasks_of(state: &AppState) -> ApiResult<Arc<Tasks>> {
    state.tasks.clone().ok_or_else(|| task_error(anyhow::anyhow!("Tasks are not running in this service")))
}

/// A task's linked workers' and builds' states, and the status they imply.
fn task_signals(state: &AppState, task: &tasks::Task) -> (String, Option<tasks::Status>) {
    let threads: Vec<&str> = task.threads.iter().map(|id| {
        state.agents.as_ref().and_then(|a| a.thread_row(id)).map_or("missing", |row| crate::agents::worker_state(&row))
    }).collect();
    // Job records are replaced atomically; reading them needs no record lock.
    let store = &state.files;
    let builds: Vec<&str> = task.builds.iter().map(|id| match store.load_job(id).map(|j| j.state) {
        Ok(BuildState::Queued) => "queued",
        Ok(BuildState::Running) => "running",
        Ok(BuildState::Succeeded) => "succeeded",
        Ok(_) => "failed",
        Err(_) => "missing",
    }).collect();
    let signature = task.threads.iter().zip(&threads).chain(task.builds.iter().zip(&builds))
        .map(|(id, state)| format!("{id}:{state}")).collect::<Vec<_>>().join(" ");
    (signature, tasks::derive(&threads, &builds))
}

/// A task as the phone and the agent see it: linked threads and builds
/// with their titles and states, and its media.
fn task_view(state: &AppState, task: &tasks::Task) -> Value {
    let threads: Vec<Value> = task.threads.iter().map(|id| {
        let row = state.agents.as_ref().and_then(|a| a.thread_row(id));
        let title = row.as_ref().and_then(|r| r["title"].as_str()).map(str::to_string)
            .or_else(|| state.agents.as_ref().and_then(|a| a.worker_title(id)));
        json!({"id": id, "title": title,
               "state": row.as_ref().map_or("missing", crate::agents::worker_state)})
    }).collect();
    // Job records are replaced atomically; reading them needs no record lock.
    let store = &state.files;
    let builds: Vec<Value> = task.builds.iter().map(|id| match store.load_job(id) {
        Ok(job) => json!({"id": id, "state": job.state, "title": job.output.as_ref().map(|o| o.title.clone()),
            "version": job.output.as_ref().map(|o| o.version.clone()), "build_number": job.output.as_ref().map(|o| o.build_number.clone()),
            "installable": job.output.as_ref().is_some_and(|o| o.ipa_path.is_some())}),
        Err(_) => json!({"id": id, "state": "missing"}),
    }).collect();
    let media: Vec<Value> = state.tasks.as_ref().map(|t| t.media(&task.id)).unwrap_or_default().into_iter()
        .map(|m| json!({"id": m.id, "kind": m.kind, "caption": m.caption, "content_type": m.content_type, "created_at": m.created_at}))
        .collect();
    let mut value = serde_json::to_value(task).unwrap_or(Value::Null);
    value["threads"] = json!(threads);
    value["builds"] = json!(builds);
    value["media"] = json!(media);
    if let Some(object) = value.as_object_mut() { object.remove("seen"); }
    value
}

/// The app a request is about: a T3 project ID, or any of its threads.
fn task_project(state: &AppState, project: Option<String>, thread: Option<&str>) -> ApiResult<String> {
    if let Some(project) = project { return Ok(project); }
    let thread = thread.ok_or_else(|| ApiError::bad("Pass --thread (your thread ID) or --project"))?;
    agents(state)?.project_of(thread).ok_or_else(|| ApiError::bad(format!("T3 has no thread {thread} in any project")))
}

#[derive(Deserialize)]
struct TaskQuery {
    project: Option<String>,
    thread: Option<String>,
}

async fn list_tasks(
    State(state): State<AppState>,
    query: std::result::Result<Query<TaskQuery>, QueryRejection>,
) -> ApiResult<Json<Value>> {
    let query = parse_query(query)?;
    let project = task_project(&state, query.project, query.thread.as_deref())?;
    let mut all = tasks_of(&state)?.list(&project);
    all.sort_by(|a, b| a.order.total_cmp(&b.order));
    let (history, active): (Vec<_>, Vec<_>) = all.iter().partition(|t| t.archived_at.is_some());
    let mut history = history;
    history.sort_by(|a, b| b.archived_at.cmp(&a.archived_at));
    Ok(Json(success(json!({
        "project_id": project,
        "tasks": active.iter().map(|t| task_view(&state, t)).collect::<Vec<_>>(),
        "history": history.iter().map(|t| task_view(&state, t)).collect::<Vec<_>>(),
    }))))
}

#[derive(Deserialize)]
struct AddTask {
    project: Option<String>,
    thread: Option<String>,
    ask: String,
    status: Option<tasks::Status>,
    note: Option<String>,
    #[serde(default)]
    by_user: bool,
}

async fn add_task(
    State(state): State<AppState>,
    payload: std::result::Result<Json<AddTask>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    let project = task_project(&state, r.project, r.thread.as_deref())?;
    let source = match (&r.thread, &state.agents) {
        (Some(thread), Some(agents)) if !r.by_user => agents.source_message(thread).await,
        _ => None,
    };
    let by = if r.by_user { tasks::By::User } else { tasks::By::Agent };
    let task = tasks_of(&state)?
        .add(&project, &r.ask, r.status, r.note.as_deref(), by, source, vec![])
        .map_err(task_error)?;
    Ok(Json(success(json!({"task": task_view(&state, &task),
        "next": "Link its workers and builds as you start them; set its status when it changes."}))))
}

async fn show_task(State(state): State<AppState>, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    let task = tasks_of(&state)?.get(&id).map_err(ApiError::missing)?;
    Ok(Json(success(json!({"task": task_view(&state, &task)}))))
}

#[derive(Deserialize)]
struct UpdateTask {
    #[serde(flatten)]
    update: tasks::Update,
    #[serde(default)]
    by_user: bool,
}

async fn update_task(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<UpdateTask>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    let tasks = tasks_of(&state)?;
    let current = tasks.get(&id).map_err(ApiError::missing)?;
    let signature = task_signals(&state, &current).0;
    let by = if r.by_user { tasks::By::User } else { tasks::By::Agent };
    let task = tasks.update(&id, r.update, by, Some(signature)).map_err(task_error)?;
    Ok(Json(success(json!({"task": task_view(&state, &task)}))))
}

#[derive(Deserialize)]
struct LinkTask {
    thread: Option<String>,
    build: Option<String>,
    #[serde(default)]
    remove: bool,
}

async fn link_task(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<LinkTask>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    let task = tasks_of(&state)?.link(&id, r.thread.as_deref(), r.build.as_deref(), r.remove).map_err(task_error)?;
    Ok(Json(success(json!({"task": task_view(&state, &task)}))))
}

#[derive(Deserialize)]
struct AttachTask {
    file: PathBuf,
    caption: Option<String>,
}

async fn attach_task(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<AttachTask>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    let tasks = tasks_of(&state)?;
    let media = tasks.attach(&id, &r.file, r.caption.as_deref()).map_err(task_error)?;
    Ok(Json(success(json!({"id": media.id, "task_id": id, "kind": media.kind, "caption": media.caption,
        "next": "It shows on the task on the phone within a few seconds."}))))
}

async fn task_media_file(
    State(state): State<AppState>,
    Path((id, media)): Path<(String, String)>,
) -> ApiResult<Response> {
    let dir = tasks_of(&state)?.media_dir(&id).map_err(ApiError::bad)?;
    let media = crate::media::get_in(&dir, &media).map_err(ApiError::missing)?;
    let file = tokio::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(&media.file)
        .await
        .map_err(ApiError::missing)?;
    let metadata = file.metadata().await.map_err(ApiError::internal)?;
    if !metadata.is_file() {
        return Err(ApiError::internal("Invalid media file"));
    }
    let mut response = (
        private_headers(),
        [(header::CONTENT_TYPE, media.content_type.clone())],
        Body::from_stream(ReaderStream::new(file)),
    )
        .into_response();
    response
        .headers_mut()
        .insert(header::CONTENT_LENGTH, metadata.len().to_string().parse().unwrap());
    Ok(response)
}
