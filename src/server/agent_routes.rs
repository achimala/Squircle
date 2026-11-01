use super::*;

// MARK: App agents

pub(super) fn agent_error(error: anyhow::Error) -> ApiError {
    ApiError::new(
        StatusCode::CONFLICT,
        "agent_failed",
        format!("{error:#}"),
        "Read the message; run squircle agent --help or squircle thread --help.",
    )
}

pub(super) fn agents(state: &AppState) -> ApiResult<Arc<Agents>> {
    state.agents.clone().ok_or_else(|| {
        agent_error(anyhow::anyhow!(
            "App agents are not running in this service"
        ))
    })
}

pub(super) async fn list_agents(State(state): State<AppState>) -> ApiResult<Json<Value>> {
    let agents = agents(&state)?;
    // How agents and the phone's worker prompts invoke this service's CLI.
    Ok(Json(success(
        json!({"agents": agents.list(), "t3": agents.status(), "cli": agents.cli()}),
    )))
}

#[derive(Deserialize)]
pub(super) struct EnsureAgent {
    pub(super) project_id: String,
    pub(super) message: Option<String>,
    pub(super) model: Option<String>,
    /// T3's runtime mode for a new agent; None keeps the service default.
    pub(super) runtime_mode: Option<String>,
}

pub(super) const RUNTIME_MODES: [&str; 4] = [
    "approval-required",
    "auto-accept-edits",
    "auto",
    "full-access",
];

pub(super) async fn ensure_agent(
    State(state): State<AppState>,
    payload: std::result::Result<Json<EnsureAgent>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let request = body(payload)?;
    if let Some(mode) = &request.runtime_mode
        && !RUNTIME_MODES.contains(&mode.as_str())
    {
        return Err(ApiError::bad(format!(
            "runtime_mode must be one of {}",
            RUNTIME_MODES.join(", ")
        )));
    }
    let agent = agents(&state)?
        .ensure(
            &request.project_id,
            request.message.as_deref(),
            request.model.as_deref(),
            request.runtime_mode.as_deref(),
        )
        .await
        .map_err(agent_error)?;
    Ok(Json(success(json!({"agent": agent}))))
}

#[derive(Deserialize)]
pub(super) struct ResetAgent {
    pub(super) project_id: Option<String>,
    pub(super) thread_id: Option<String>,
}

pub(super) async fn restart_agent(
    State(state): State<AppState>,
    payload: std::result::Result<Json<ResetAgent>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let request = body(payload)?;
    let result = agents(&state)?
        .restart(request.project_id.as_deref(), request.thread_id.as_deref())
        .await
        .map_err(agent_error)?;
    Ok(Json(success(result)))
}

pub(super) async fn compact_agent(
    State(state): State<AppState>,
    payload: std::result::Result<Json<ResetAgent>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let request = body(payload)?;
    let result = agents(&state)?
        .compact(request.project_id.as_deref(), request.thread_id.as_deref())
        .await
        .map_err(agent_error)?;
    Ok(Json(success(result)))
}

#[derive(Deserialize)]
pub(super) struct ContextQuery {
    pub(super) cwd: PathBuf,
}

pub(super) async fn t3_providers(State(state): State<AppState>) -> ApiResult<Json<Value>> {
    let providers = agents(&state)?.providers().await.map_err(agent_error)?;
    Ok(Json(success(json!({"providers": providers}))))
}

#[derive(Deserialize)]
pub(super) struct Heard {
    pub(super) thread: String,
}

pub(super) async fn agent_heard(
    State(state): State<AppState>,
    payload: std::result::Result<Json<Heard>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let thread = body(payload)?.thread;
    Ok(Json(success(
        agents(&state)?
            .mark_heard(&thread)
            .await
            .map_err(agent_error)?,
    )))
}

pub(super) async fn agent_context(
    State(state): State<AppState>,
    query: std::result::Result<Query<ContextQuery>, QueryRejection>,
) -> ApiResult<Json<Value>> {
    let query = parse_query(query)?;
    let builds: Vec<crate::agents::LiveBuild> = state
        .jobs
        .list()
        .into_iter()
        .filter(|view| !view.job.state().terminal())
        .filter_map(|view| {
            let request = view.job.request()?;
            Some(crate::agents::LiveBuild {
                id: view.job.id.clone(),
                scheme: request.scheme.clone(),
                thread: request.thread.clone(),
                running: view.job.state() == crate::model::BuildState::Running,
            })
        })
        .collect();
    Ok(Json(success(
        json!({"context": agents(&state)?.context(&query.cwd, &builds).await}),
    )))
}

#[derive(Deserialize)]
pub(super) struct WorkerQuery {
    pub(super) coordinator: Option<String>,
}

pub(super) async fn list_workers(
    State(state): State<AppState>,
    query: std::result::Result<Query<WorkerQuery>, QueryRejection>,
) -> ApiResult<Json<Value>> {
    let query = parse_query(query)?;
    Ok(Json(success(
        json!({"workers": agents(&state)?.workers(query.coordinator.as_deref())}),
    )))
}

#[derive(Deserialize)]
pub(super) struct SpawnWorker {
    pub(super) coordinator: String,
    pub(super) title: String,
    pub(super) branch: String,
    pub(super) base: Option<String>,
    pub(super) prompt: String,
    pub(super) provider: Option<String>,
    pub(super) model: Option<String>,
    pub(super) effort: Option<String>,
    /// T3 runtime mode; None inherits the coordinator's.
    pub(super) runtime_mode: Option<String>,
    /// A task to link the worker to.
    pub(super) task: Option<String>,
}

pub(super) async fn spawn_worker(
    State(state): State<AppState>,
    payload: std::result::Result<Json<SpawnWorker>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    let task = r.task.as_deref().ok_or_else(|| {
        ApiError::bad(
            "Pass --task: the work item or sub-task this worker serves. Put the user's ask in the tracker first (squircle task --help).",
        )
    })?;
    tasks_of(&state)?.get(task).map_err(ApiError::missing)?;
    let agents = agents(&state)?;
    agents
        .ensure_heard(&r.coordinator)
        .await
        .map_err(agent_error)?;
    let prompt = format!("{}{}", r.prompt, agents.asks_for(Some(task), None));
    let worker = agents
        .spawn(
            &r.coordinator,
            &r.title,
            &r.branch,
            r.base.as_deref(),
            &prompt,
            r.provider.as_deref(),
            r.model.as_deref(),
            r.effort.as_deref(),
            r.runtime_mode.as_deref(),
        )
        .await
        .map_err(agent_error)?;
    if let Some(id) = worker["id"].as_str() {
        tasks_of(&state)?
            .link(task, Some(id), None, false)
            .await
            .map_err(task_error)?;
    }
    Ok(Json(success(worker)))
}

pub(super) async fn read_worker(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    Ok(Json(success(
        agents(&state)?.read(&id).await.map_err(agent_error)?,
    )))
}

#[derive(Deserialize)]
pub(super) struct WorkerText {
    pub(super) text: String,
}

pub(super) async fn message_worker(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<WorkerText>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let text = body(payload)?.text;
    if text.trim().is_empty() {
        return Err(ApiError::bad("Message text is empty"));
    }
    let agents = agents(&state)?;
    if let Some(coordinator) = agents.coordinator_of(&id) {
        agents
            .ensure_heard(&coordinator)
            .await
            .map_err(agent_error)?;
    }
    let text = format!("{text}{}", agents.asks_for(None, Some(&id)));
    agents.message(&id, &text).await.map_err(agent_error)?;
    Ok(Json(success(json!({"sent": id}))))
}

pub(super) async fn answer_worker(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<WorkerText>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let text = body(payload)?.text;
    let agents = agents(&state)?;
    if let Some(coordinator) = agents.coordinator_of(&id) {
        agents
            .ensure_heard(&coordinator)
            .await
            .map_err(agent_error)?;
    }
    agents.answer(&id, &text).await.map_err(agent_error)?;
    Ok(Json(success(json!({"answered": id}))))
}

#[derive(Deserialize)]
pub(super) struct ArchiveWorker {
    #[serde(default, alias = "force")]
    pub(super) discard: bool,
}

pub(super) async fn archive_worker(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<ArchiveWorker>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let discard = body(payload)?.discard;
    Ok(Json(success(
        agents(&state)?
            .archive(&id, discard)
            .await
            .map_err(agent_error)?,
    )))
}

#[derive(Deserialize)]
pub(super) struct CleanupWorkers {
    pub(super) coordinator: String,
    #[serde(default)]
    pub(super) dry_run: bool,
}

pub(super) async fn cleanup_workers(
    State(state): State<AppState>,
    payload: std::result::Result<Json<CleanupWorkers>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let request = body(payload)?;
    Ok(Json(success(
        agents(&state)?
            .cleanup(&request.coordinator, request.dry_run)
            .await
            .map_err(agent_error)?,
    )))
}
