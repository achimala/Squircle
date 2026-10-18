use super::*;

pub(super) async fn list(State(state): State<AppState>) -> ApiResult<Json<Value>> {
    let jobs = state.jobs.list();
    let mut views = serde_json::to_value(&jobs).map_err(ApiError::internal)?;
    if let (Some(agents), Some(views)) = (&state.agents, views.as_array_mut()) {
        let owners = agents.build_owners(jobs.iter().map(|v| {
            (
                v.job.request().and_then(|r| r.thread.as_deref()),
                v.job.id.as_str(),
            )
        }));
        for (view, owner) in views.iter_mut().zip(owners) {
            if let Some(owner) = owner {
                view["agent_thread"] = json!(owner);
            }
        }
    }
    Ok(Json(success(views)))
}

pub(super) async fn status(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    let view = state
        .jobs
        .get(&id)
        .ok_or_else(|| ApiError::missing(format!("No build {id}")))?;
    let job = &view.job;
    let launches = {
        let (files, id) = (state.files.clone(), id.clone());
        in_lane(&state.diagnostics, move || {
            files.diagnostics(&id, 0, 1, Some(DiagnosticKind::Launch))
        })
        .await
        .map_err(ApiError::internal)?
        .map_err(ApiError::internal)?
    };
    let log = state
        .files
        .job_dir(&id)
        .ok()
        .map(|dir| dir.join("build.log"));
    let failure = match (job.state(), log) {
        (BuildState::Failed | BuildState::Interrupted, Some(log)) => {
            let text = log_tail(&log, FAILURE_LOG_TAIL_BYTES).await;
            let root = job
                .request()
                .and_then(|r| r.project.parent())
                .map(|p| p.to_string_lossy().into_owned());
            let mut failure =
                crate::buildlog::failure(&String::from_utf8_lossy(&text), root.as_deref());
            failure.message = job.error().map(|error| {
                error
                    .rsplit_once("; see /")
                    .map_or(error, |(message, _)| message)
                    .to_string()
            });
            Some(failure)
        }
        _ => None,
    };
    let mut view = serde_json::to_value(&view).map_err(ApiError::internal)?;
    if let Some(owner) = state
        .agents
        .as_ref()
        .and_then(|a| a.build_owner(job.request().and_then(|r| r.thread.as_deref()), &job.id))
    {
        view["agent_thread"] = json!(owner.thread_id);
    }
    Ok(Json(success(
        json!({"job":view,"launch_observed":launches["events"].as_array().is_some_and(|a| !a.is_empty()),"failure":failure}),
    )))
}

/// Failure summaries come from the end of a build log; logs can be very large.
pub(super) const FAILURE_LOG_TAIL_BYTES: u64 = 1024 * 1024;

pub(super) async fn log_tail(path: &std::path::Path, max: u64) -> Vec<u8> {
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

pub(super) async fn start(
    State(state): State<AppState>,
    request: std::result::Result<Json<BuildRequest>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    start_build(state, body(request)?).await.map(Json)
}

pub(super) async fn capture_preview(
    State(state): State<AppState>,
    Path(id): Path<String>,
    input: std::result::Result<Json<PreviewRequest>, JsonRejection>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    Ok((
        StatusCode::ACCEPTED,
        Json(start_preview(state, id, body(input)?).await?),
    ))
}

pub(super) async fn download_preview(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Response> {
    let path = {
        let job = state
            .jobs
            .get(&id)
            .ok_or_else(|| ApiError::missing(format!("No build {id}")))?
            .job;
        let path = job
            .preview()
            .and_then(|preview| preview.artifact())
            .map(|artifact| artifact.path.clone())
            .ok_or_else(|| ApiError::missing("This build has no captured preview"))?;
        let expected = state
            .files
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

pub(super) async fn cancel(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    let (job_state, operation) = state
        .jobs
        .cancel(&id)
        .await
        .ok_or_else(|| ApiError::missing(format!("No build {id}")))?;
    Ok(Json(success(
        json!({"build_id":id,"cancel_requested":operation.is_some(),"state":job_state}),
    )))
}

#[derive(Deserialize)]
pub(super) struct ImportRequest {
    pub(super) ipa: PathBuf,
}

pub(super) async fn import(
    State(state): State<AppState>,
    input: std::result::Result<Json<ImportRequest>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let input = body(input)?;
    let job = import_job(state, input.ipa, copy_and_inspect_ipa)
        .await
        .map_err(ApiError::bad)?;
    Ok(Json(success(job)))
}

#[derive(Deserialize, Default)]
pub(super) struct LogPage {
    #[serde(default)]
    pub(super) offset: u64,
    pub(super) limit: Option<usize>,
}

pub(super) async fn build_log(
    State(state): State<AppState>,
    Path(id): Path<String>,
    page: std::result::Result<Query<LogPage>, QueryRejection>,
) -> ApiResult<Json<Value>> {
    let page = parse_query(page)?;
    state
        .jobs
        .get(&id)
        .ok_or_else(|| ApiError::missing(format!("No build {id}")))?;
    let path = state
        .files
        .job_dir(&id)
        .map_err(ApiError::bad)?
        .join("build.log");
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
