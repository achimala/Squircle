use super::*;

// MARK: Tasks

pub(super) fn task_error(error: anyhow::Error) -> ApiError {
    ApiError::new(
        StatusCode::BAD_REQUEST,
        "task_failed",
        format!("{error:#}"),
        "Read the message; run squircle task --help.",
    )
}

pub(super) fn tasks_of(state: &AppState) -> ApiResult<Arc<Tasks>> {
    state
        .tasks
        .clone()
        .ok_or_else(|| task_error(anyhow::anyhow!("Tasks are not running in this service")))
}

/// What a task's linked workers and builds are doing, from memory only (the
/// shell's observations and the job index), so every tick can cover History
/// too. A thread T3 hasn't sent, or a shell that isn't current, is no fact
/// (`Missing`), never news.
pub(super) fn task_signals(state: &AppState, task: &tasks::Task) -> tasks::Signals {
    use crate::agents::Phase;
    use tasks::{BuildPhase, WorkerPhase};
    let workers = task
        .threads
        .iter()
        .map(|id| {
            // Only a current shell fact moves a task; stale or unknown is no fact.
            let observed = state
                .agents
                .as_ref()
                .and_then(|a| a.observe(id).current().flatten());
            let phase = match observed.as_ref().map(|o| o.phase()) {
                Some(Phase::NeedsYou) => WorkerPhase::NeedsYou,
                Some(Phase::Working) => WorkerPhase::Working,
                Some(Phase::Error) => WorkerPhase::Error,
                Some(Phase::Done) => WorkerPhase::Done,
                None => WorkerPhase::Missing,
            };
            tasks::WorkerSignal {
                thread: id.clone(),
                turn: observed.and_then(|o| o.turn),
                phase,
            }
        })
        .collect();
    let builds = task
        .builds
        .iter()
        .map(|id| {
            let phase = match state.jobs.state(id) {
                Some(BuildState::Queued) => BuildPhase::Queued,
                Some(BuildState::Running) => BuildPhase::Running,
                Some(BuildState::Succeeded) => BuildPhase::Succeeded,
                Some(BuildState::Failed | BuildState::Cancelled | BuildState::Interrupted) => {
                    BuildPhase::Failed
                }
                None => BuildPhase::Missing,
            };
            tasks::BuildSignal {
                build: id.clone(),
                phase,
            }
        })
        .collect();
    tasks::Signals {
        revision: Some(task.revision),
        workers,
        builds,
    }
}

/// A task as the phone and the agent see it: linked threads and builds
/// with their titles and states, and its media.
pub(super) fn task_view(state: &AppState, task: &tasks::Task) -> Value {
    let threads: Vec<Value> = task
        .threads
        .iter()
        .map(|id| {
            let row = state.agents.as_ref().and_then(|a| a.thread_row(id));
            let title = row
                .as_ref()
                .and_then(|r| r["title"].as_str())
                .map(str::to_string)
                .or_else(|| state.agents.as_ref().and_then(|a| a.worker_title(id)));
            json!({"id": id, "title": title,
               "state": row.as_ref().map_or("missing", crate::agents::worker_state)})
        })
        .collect();
    let builds: Vec<Value> = task.builds.iter().map(|id| match state.jobs.get(id) {
        Some(view) => {
            let output = view.job.output();
            json!({"id": id, "state": view.job.state(), "title": output.map(|o| o.title.clone()),
                "version": output.map(|o| o.version.clone()), "build_number": output.map(|o| o.build_number.clone()),
                "installable": view.job.ipa().is_some()})
        }
        None => json!({"id": id, "state": "missing"}),
    }).collect();
    let media: Vec<Value> = state.tasks.as_ref().map(|t| t.media(&task.id)).unwrap_or_default().into_iter()
        .map(|m| json!({"id": m.id, "kind": m.kind, "name": m.name, "caption": m.caption, "content_type": m.content_type,
                        "bytes": m.bytes, "created_at": m.created_at}))
        .collect();
    let mut value = serde_json::to_value(task).unwrap_or(Value::Null);
    value["subtasks"] = json!(
        task.subtasks
            .iter()
            .map(|t| task_view(state, t))
            .collect::<Vec<_>>()
    );
    value["threads"] = json!(threads);
    value["builds"] = json!(builds);
    value["media"] = json!(media);
    value
}

/// The app a request is about: a T3 project ID, or any of its threads.
pub(super) fn task_project(
    state: &AppState,
    project: Option<String>,
    thread: Option<&str>,
) -> ApiResult<String> {
    if let Some(project) = project {
        return Ok(project);
    }
    let thread =
        thread.ok_or_else(|| ApiError::bad("Pass --thread (your thread ID) or --project"))?;
    agents(state)?
        .project_of(thread)
        .ok_or_else(|| ApiError::bad(format!("T3 has no thread {thread} in any project")))
}

#[derive(Deserialize)]
pub(super) struct TaskQuery {
    pub(super) project: Option<String>,
    pub(super) thread: Option<String>,
    /// History entries per page (1–100, default 20).
    pub(super) history_limit: Option<usize>,
    /// The `history_next` cursor of the previous page.
    pub(super) history_before: Option<String>,
}

pub(super) const HISTORY_PAGE: usize = 20;

/// Active tasks, and one page of History, newest first. Only the returned
/// tasks are expanded (linked work, media), so a long History costs a poll
/// nothing beyond its first page.
pub(super) async fn list_tasks(
    State(state): State<AppState>,
    query: std::result::Result<Query<TaskQuery>, QueryRejection>,
) -> ApiResult<Json<Value>> {
    let query = parse_query(query)?;
    let limit = query.history_limit.unwrap_or(HISTORY_PAGE);
    if !(1..=100).contains(&limit) {
        return Err(ApiError::bad("history_limit must be between 1 and 100"));
    }
    let before = query
        .history_before
        .as_deref()
        .map(HistoryCursor::parse)
        .transpose()
        .map_err(ApiError::bad)?;
    let project = task_project(&state, query.project, query.thread.as_deref())?;
    let tasks = tasks_of(&state)?;
    let view = tokio::task::spawn_blocking(move || {
        let mut all = tasks.list(&project);
        all.sort_by(|a, b| a.order.total_cmp(&b.order));
        let (history, active): (Vec<_>, Vec<_>) =
            all.into_iter().partition(|t| t.archived_at.is_some());
        let (page, next) = history_page(history, HistoryCursor::of, before.as_ref(), limit);
        json!({
            "project_id": project,
            "tasks": active.iter().map(|t| task_view(&state, t)).collect::<Vec<_>>(),
            "history": page.iter().map(|t| task_view(&state, t)).collect::<Vec<_>>(),
            "history_next": next.map(|c| c.to_string()),
        })
    })
    .await
    .map_err(ApiError::internal)?;
    Ok(Json(success(view)))
}

/// A position in History: entries strictly older than (archived_at, id).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct HistoryCursor {
    pub(super) archived_at: u64,
    pub(super) id: String,
}

impl HistoryCursor {
    pub(super) fn of(task: &tasks::Task) -> Self {
        Self {
            archived_at: task.archived_at.unwrap_or_default(),
            id: task.id.clone(),
        }
    }
    pub(super) fn parse(value: &str) -> std::result::Result<Self, String> {
        let invalid = || format!("Invalid history cursor {value:?}");
        let (at, id) = value.split_once('.').ok_or_else(invalid)?;
        Ok(Self {
            archived_at: at.parse().map_err(|_| invalid())?,
            id: id.to_owned(),
        })
    }
    /// Newest first: later archive time, then higher ID.
    pub(super) fn key(&self) -> (std::cmp::Reverse<u64>, std::cmp::Reverse<&str>) {
        (
            std::cmp::Reverse(self.archived_at),
            std::cmp::Reverse(self.id.as_str()),
        )
    }
}

impl std::fmt::Display for HistoryCursor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}", self.archived_at, self.id)
    }
}

/// One page of History after `before`, newest first, and the cursor for the
/// next page if there is more. Stable while tasks enter History or leave it.
pub(super) fn history_page<T>(
    history: Vec<T>,
    position: impl Fn(&T) -> HistoryCursor,
    before: Option<&HistoryCursor>,
    limit: usize,
) -> (Vec<T>, Option<HistoryCursor>) {
    let mut history: Vec<(HistoryCursor, T)> =
        history.into_iter().map(|t| (position(&t), t)).collect();
    history.sort_by(|a, b| a.0.key().cmp(&b.0.key()));
    let mut page: Vec<(HistoryCursor, T)> = history
        .into_iter()
        .filter(|(at, _)| before.is_none_or(|b| at.key() > b.key()))
        .take(limit + 1)
        .collect();
    let more = page.len() > limit;
    page.truncate(limit);
    let next = if more {
        page.last().map(|(at, _)| at.clone())
    } else {
        None
    };
    (page.into_iter().map(|(_, t)| t).collect(), next)
}

#[derive(Deserialize)]
pub(super) struct AddTask {
    /// Add it as a sub-task of this work item (its app is taken from it).
    pub(super) parent: Option<String>,
    pub(super) project: Option<String>,
    pub(super) thread: Option<String>,
    pub(super) ask: String,
    pub(super) status: Option<tasks::Status>,
    pub(super) note: Option<String>,
    /// Earlier asks this one replaces; each is dropped as replaced by it.
    #[serde(default)]
    pub(super) replaces: Vec<String>,
    #[serde(default)]
    pub(super) by_user: bool,
}

pub(super) async fn add_task(
    State(state): State<AppState>,
    payload: std::result::Result<Json<AddTask>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    let tasks = tasks_of(&state)?;
    let project = match &r.parent {
        Some(parent) => tasks.get(parent).map_err(ApiError::missing)?.project_id,
        None => task_project(&state, r.project, r.thread.as_deref())?,
    };
    let source = match (&r.thread, &state.agents) {
        (Some(thread), Some(agents)) if !r.by_user => agents.source_message(thread).await,
        _ => None,
    };
    let by = if r.by_user {
        tasks::By::User
    } else {
        tasks::By::Agent
    };
    let task = tasks
        .add(
            &project,
            &r.ask,
            r.status,
            r.note.as_deref(),
            by,
            source,
            vec![],
            r.parent.as_deref(),
        )
        .await
        .map_err(task_error)?;
    for old in &r.replaces {
        let current = tasks.get(old).map_err(ApiError::missing)?;
        let update = tasks::Update {
            replaced_by: Some(task.id.clone()),
            ..Default::default()
        };
        let observed = task_signals(&state, &current);
        tasks
            .update(old, update, by, Some(observed))
            .await
            .map_err(task_error)?;
    }
    let mut next = if r.parent.is_some() {
        "Link its workers and builds as you start them; set its status when it changes (its work item follows).".to_string()
    } else {
        "Break it down with `task sub add` if it has parts; link workers and builds as you start them; set its status when it changes.".to_string()
    };
    // A new ask of the user's beside open ones: the old ones it changes must
    // stop reaching workers as rules.
    let others: Vec<String> = match (&task.source, &r.parent) {
        (Some(_), Some(parent)) => tasks
            .get(parent)
            .map(|item| {
                item.subtasks
                    .iter()
                    .filter(|s| {
                        s.id != task.id && s.source.is_some() && s.status != tasks::Status::Dropped
                    })
                    .map(|s| format!("{} \"{}\"", s.id, s.ask.replace('\n', " ")))
                    .collect()
            })
            .unwrap_or_default(),
        _ => vec![],
    };
    if !others.is_empty() && r.replaces.is_empty() {
        next.push_str(&format!(
            " If this changes or contradicts any of the user's earlier asks here, mark them replaced \
             (`task update ID --replaced-by {}`) so workers stop getting them as rules: {}",
            task.id,
            others.join("; ")
        ));
    }
    Ok(Json(success(
        json!({"task": task_view(&state, &task), "next": next}),
    )))
}

pub(super) async fn show_task(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    let task = tasks_of(&state)?.get(&id).map_err(ApiError::missing)?;
    Ok(Json(success(json!({"task": task_view(&state, &task)}))))
}

#[derive(Deserialize)]
pub(super) struct UpdateTask {
    #[serde(flatten)]
    pub(super) update: tasks::Update,
    #[serde(default)]
    pub(super) by_user: bool,
}

pub(super) async fn update_task(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<UpdateTask>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    let tasks = tasks_of(&state)?;
    let current = tasks.get(&id).map_err(ApiError::missing)?;
    let observed = task_signals(&state, &current);
    let by = if r.by_user {
        tasks::By::User
    } else {
        tasks::By::Agent
    };
    let task = tasks
        .update(&id, r.update, by, Some(observed))
        .await
        .map_err(task_error)?;
    Ok(Json(success(json!({"task": task_view(&state, &task)}))))
}

#[derive(Deserialize)]
pub(super) struct LinkTask {
    pub(super) thread: Option<String>,
    pub(super) build: Option<String>,
    #[serde(default)]
    pub(super) remove: bool,
}

pub(super) async fn link_task(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<LinkTask>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    let task = tasks_of(&state)?
        .link(&id, r.thread.as_deref(), r.build.as_deref(), r.remove)
        .await
        .map_err(task_error)?;
    // A build that finished before it was linked (a fast failure) still
    // reaches the agent; one that finished long ago is no news.
    if let Some(view) = r
        .build
        .as_deref()
        .filter(|_| !r.remove)
        .and_then(|b| state.jobs.get(b))
        && view.job.state().terminal()
        && now().saturating_sub(view.job.updated_at) < 600
    {
        let app = apps::list(&state.files)
            .ok()
            .and_then(|apps| apps::owner_of(&apps, &view.job).cloned());
        tell_agent(&state, &view.job, app.as_ref()).await;
    }
    Ok(Json(success(json!({"task": task_view(&state, &task)}))))
}

#[derive(Deserialize)]
pub(super) struct AttachTask {
    pub(super) file: PathBuf,
    pub(super) caption: Option<String>,
}

pub(super) async fn attach_task(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<AttachTask>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    let tasks = tasks_of(&state)?;
    let media = tasks
        .attach(&id, &r.file, r.caption.as_deref())
        .await
        .map_err(task_error)?;
    Ok(Json(success(
        json!({"id": media.id, "task_id": id, "kind": media.kind, "caption": media.caption,
        "next": "It shows on the task on the phone within a few seconds."}),
    )))
}

pub(super) async fn task_media_file(
    State(state): State<AppState>,
    Path((id, media)): Path<(String, String)>,
) -> ApiResult<Response> {
    let dir = tasks_of(&state)?.media_dir(&id).map_err(ApiError::bad)?;
    let media = crate::media::get_in(&dir, &media).map_err(ApiError::missing)?;
    super::media_routes::serve_file(&media.file, &media.content_type).await
}
