use crate::{apps, artifact, model::*, preview, projects, store::Store, xcode};
use anyhow::{Context, Result};
use axum::{
    Json, Router,
    body::Body,
    extract::{
        DefaultBodyLimit, Path, Query, State,
        rejection::{JsonRejection, QueryRejection},
    },
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
    inspection_slots: Arc<Semaphore>,
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
            inspection_slots: Arc::new(Semaphore::new(2)),
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
        .route("/v1/t3/threads/{thread}/media", get(thread_media))
        .route("/v1/t3/threads/{thread}/media/{id}", get(thread_media_file))
        .route("/v1/t3/threads/{thread}/steps/{call}/images/{index}", get(t3_step_image))
        .route("/v1/import", post(import))
        .route("/v1/diagnostics", post(ingest))
        .route("/v1/install-links/{token}", get(link_status))
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
            sync_job_app(&state, &job);
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
    headers: HeaderMap,
    Path(id): Path<String>,
    input: std::result::Result<Json<PreviewRequest>, JsonRejection>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    auth(&state, &headers, false)?;
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
            return Err(ApiError {
                status: StatusCode::CONFLICT,
                code: "preview_in_progress",
                message: "This build already has work in progress".into(),
                next: "Poll build status before recapturing.",
            });
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
            sync_job_app(&state, &job);
        }
        state.cancellations.lock().unwrap().remove(&id);
        drop(permit);
    });
    Ok((StatusCode::ACCEPTED, Json(success(json!({"job":response})))))
}

fn sync_job_app(state: &AppState, job: &Job) {
    if let Err(error) = apps::sync_build_preview(&state.store.lock().unwrap(), job) {
        // Catalog publication is ancillary: never invalidate an exported IPA.
        eprintln!(
            "Could not sync app metadata for build {}: {error:#}",
            job.id
        );
    }
}

fn public_app(app: apps::AppRecord) -> Value {
    let mut value = serde_json::to_value(app).expect("app metadata serializes");
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
    State(state): State<AppState>,
    headers: HeaderMap,
    query: std::result::Result<Query<BrowseQuery>, QueryRejection>,
) -> ApiResult<Json<Value>> {
    auth(&state, &headers, false)?;
    let Query(query) = query.map_err(|error| ApiError::bad(error.body_text()))?;
    let directory = tokio::task::spawn_blocking(move || projects::browse(query.path.as_deref()))
        .await
        .map_err(ApiError::internal)?
        .map_err(ApiError::bad)?;
    Ok(Json(success(directory)))
}
fn inspection_busy() -> ApiError {
    ApiError {
        status: StatusCode::TOO_MANY_REQUESTS,
        code: "inspection_busy",
        message: "Two Xcode inspections are already running".into(),
        next: "Wait for an existing inspection to finish, then retry.",
    }
}
async fn inspect_project(
    State(state): State<AppState>,
    headers: HeaderMap,
    query: std::result::Result<Query<InspectQuery>, QueryRejection>,
) -> ApiResult<Json<Value>> {
    auth(&state, &headers, false)?;
    let Query(query) = query.map_err(|error| ApiError::bad(error.body_text()))?;
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
    headers: HeaderMap,
    input: std::result::Result<Json<projects::ImportRequest>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    auth(&state, &headers, false)?;
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

async fn list_apps(State(state): State<AppState>, headers: HeaderMap) -> ApiResult<Json<Value>> {
    auth(&state, &headers, false)?;
    let apps = apps::list(&state.store.lock().unwrap()).map_err(ApiError::internal)?;
    Ok(Json(success(
        apps.into_iter().map(public_app).collect::<Vec<_>>(),
    )))
}

async fn get_app(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    auth(&state, &headers, false)?;
    let app = apps::get(&state.store.lock().unwrap(), &id).map_err(ApiError::missing)?;
    Ok(Json(success(public_app(app))))
}

async fn register_app(
    State(state): State<AppState>,
    headers: HeaderMap,
    input: std::result::Result<Json<apps::AppRegistration>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    auth(&state, &headers, false)?;
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
    headers: HeaderMap,
    Path(id): Path<String>,
    input: std::result::Result<Json<apps::AppUpdate>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    auth(&state, &headers, false)?;
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
    headers: HeaderMap,
    Path(id): Path<String>,
    input: std::result::Result<Json<apps::PreviewPublication>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    auth(&state, &headers, false)?;
    let input = body(input)?;
    let app = tokio::task::spawn_blocking(move || {
        let store = state.store.lock().unwrap();
        if state.draining.load(Ordering::Acquire) {
            return Err(ApiError::unavailable());
        }
        apps::get(&store, &id).map_err(ApiError::missing)?;
        apps::publish_preview(&store, &id, input).map_err(ApiError::bad)
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
    headers: HeaderMap,
    Path(thread): Path<String>,
    Query(query): Query<StepsQuery>,
) -> ApiResult<Json<Value>> {
    auth(&state, &headers, false)?;
    let steps = crate::t3steps::steps(&thread, query.since.as_deref())
        .await
        .map_err(|e| ApiError::bad(e.to_string()))?;
    Ok(Json(success(steps)))
}

/// The newest real screenshot captured in a project's threads; see `t3steps`.
async fn t3_project_screenshot(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(project): Path<String>,
) -> ApiResult<Response> {
    auth(&state, &headers, false)?;
    let image = crate::t3steps::project_screenshot(&project)
        .await
        .map_err(|e| ApiError::bad(e.to_string()))?
        .ok_or_else(|| ApiError::missing("No screenshot in this project's threads"))?;
    Ok((private_headers(), Json(success(image))).into_response())
}

/// Recordings and images agents published into a thread (`squircle media add`).
async fn thread_media(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(thread): Path<String>,
) -> ApiResult<Json<Value>> {
    auth(&state, &headers, false)?;
    let root = state.store.lock().unwrap().root.clone();
    let items = crate::media::list(&root, &thread).map_err(ApiError::bad)?;
    let items: Vec<Value> = items
        .into_iter()
        .map(|m| json!({"id":m.id,"kind":m.kind,"caption":m.caption,"content_type":m.content_type,"bytes":m.bytes,"created_at":m.created_at}))
        .collect();
    Ok(Json(success(json!({"thread_id":thread,"media":items}))))
}

async fn thread_media_file(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((thread, id)): Path<(String, String)>,
) -> ApiResult<Response> {
    auth(&state, &headers, false)?;
    let root = state.store.lock().unwrap().root.clone();
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
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((thread, call, index)): Path<(String, String, usize)>,
) -> ApiResult<Response> {
    auth(&state, &headers, false)?;
    let image = crate::t3steps::image(&thread, &call, index)
        .await
        .map_err(|e| ApiError::bad(e.to_string()))?
        .ok_or_else(|| ApiError::missing("No such image"))?;
    Ok((private_headers(), Json(success(image))).into_response())
}

async fn app_preview(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Query(query): Query<PreviewVersion>,
) -> ApiResult<Response> {
    auth(&state, &headers, false)?;
    let (file, preview_id) = {
        let store = state.store.lock().unwrap();
        let app = apps::get(&store, &id).map_err(ApiError::missing)?;
        let preview = app
            .preview
            .ok_or_else(|| ApiError::missing("App has no published preview"))?;
        if query
            .version
            .as_ref()
            .is_some_and(|version| version != &preview.id)
        {
            return Err(ApiError {
                status: StatusCode::CONFLICT,
                code: "preview_changed",
                message: "App preview has changed since metadata was read".into(),
                next: "Refresh app metadata and request its current preview version.",
            });
        }
        let file = crate::store::open_private_read(&preview.path).map_err(ApiError::missing)?;
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
    headers: HeaderMap,
    Path(id): Path<String>,
) -> ApiResult<Response> {
    auth(&state, &headers, false)?;
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
/// Whether iOS has started downloading a link's IPA, which happens only after
/// the person confirms the system install prompt.
async fn link_status(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(token): Path<String>,
) -> ApiResult<Json<Value>> {
    auth(&state, &headers, false)?;
    let ticket = state
        .store
        .lock()
        .unwrap()
        .load_ticket(&token)
        .map_err(|_| ApiError::missing("Unknown install link"))?;
    Ok(Json(success(
        json!({"build_id":ticket.build_id,"expires_at":ticket.expires_at,"downloaded_at":ticket.downloaded_at}),
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
    let (mut ticket, job) = ticket_job(&state, &token)?;
    if ticket.downloaded_at.is_none() {
        ticket.downloaded_at = Some(now());
        // Only informs the installing app; never blocks the download.
        let _ = state.store.lock().unwrap().save_ticket(&ticket);
    }
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
            authorization.clone(),
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
            authorization.clone(),
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
        let error = ingest(State(state), authorization, Ok(Json(event)))
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
