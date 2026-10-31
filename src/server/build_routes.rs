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

/// A build's status. Asked to wait past the ETag the client holds
/// (`waits_past`), it answers once the status differs, as the job, its
/// launch evidence or its agent change.
pub(super) async fn status(
    State(state): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> ApiResult<Json<Value>> {
    use futures_util::StreamExt;
    let Some(known) = waits_past(&headers) else {
        return status_now(&state, &id).await.map(Json);
    };
    // Listening before looking, so a change in between is not missed.
    let mut changes = state.build_changes();
    loop {
        let reply = status_now(&state, &id).await?;
        if !unchanged(&reply, &known) {
            return Ok(Json(reply));
        }
        if changes.next().await.is_none() {
            return Ok(Json(reply));
        }
    }
}

async fn status_now(state: &AppState, id: &str) -> ApiResult<Value> {
    let id = id.to_string();
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
    Ok(success(
        json!({"job":view,"launch_observed":launches["events"].as_array().is_some_and(|a| !a.is_empty()),"failure":failure}),
    ))
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

pub(super) async fn cancel(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    let (job_state, asked) = state
        .jobs
        .cancel(&id)
        .await
        .ok_or_else(|| ApiError::missing(format!("No build {id}")))?;
    Ok(Json(success(
        json!({"build_id":id,"cancel_requested":asked,"state":job_state}),
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
