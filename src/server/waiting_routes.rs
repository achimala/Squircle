use super::*;
use crate::agents::Note;

// MARK: What waits on the user

#[derive(Deserialize)]
pub(super) struct AskTask {
    /// The asking thread, which gets the answer.
    pub(super) thread: String,
    pub(super) question: String,
    #[serde(default)]
    pub(super) options: Vec<String>,
    /// Screenshots, clips and documents the question is about.
    #[serde(default)]
    pub(super) files: Vec<PathBuf>,
}

/// `squircle task ask`: a question to the user on a task, in the tracker
/// rather than in chat. The task waits at needs you, the phone shows it with
/// everything else waiting on the user and is notified, and the answer comes
/// back to the asking thread as a message.
pub(super) async fn ask_task(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<AskTask>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    let tasks = tasks_of(&state)?;
    let agents = agents(&state)?;
    let current = tasks.get(&id).map_err(ApiError::missing)?;
    if agents.project_of(&r.thread).as_deref() != Some(current.project_id.as_str()) {
        return Err(ApiError::bad(format!(
            "{} is no thread of this task's app; pass your own thread ID",
            r.thread
        )));
    }
    let (task, question) = tasks
        .ask(&id, &r.question, r.options, &r.files, &r.thread)
        .await
        .map_err(task_error)?;
    if let Some(push) = &state.push {
        push.notify(crate::push::Note {
            app: agents
                .app_title(&task.project_id)
                .unwrap_or_else(|| "Squircle".into()),
            line: crate::push::summary_line(&question.text),
            target: crate::push::Target {
                project: Some(task.project_id.clone()),
                waiting: true,
                ..Default::default()
            },
        });
    }
    Ok(Json(success(json!({
        "question": question, "task_id": task.id, "status": task.status,
        "next": "It waits on the user's phone with everything else waiting on them. End your turn unless other work needs no answer; \
                 the answer arrives as an [answer] message. Withdraw it with `task withdraw QUESTION_ID` if it stops mattering.",
    }))))
}

#[derive(Deserialize)]
pub(super) struct AnswerQuestion {
    pub(super) text: String,
}

/// The user's answer from the phone: saves it as answered and owed to the
/// thread that asked (and, for a worker, its app agent), which the task loop
/// then relays (`Agents::relay_answers`). The same answer again is accepted
/// and resumes a delivery not yet made.
pub(super) async fn answer_question(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<AnswerQuestion>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let text = body(payload)?.text;
    let (task, _) = tasks_of(&state)?
        .close_question(&id, Some(&text))
        .await
        .map_err(task_error)?;
    Ok(Json(success(json!({"answered": id, "task_id": task.id}))))
}

#[derive(Deserialize)]
pub(super) struct WithdrawQuestion {
    pub(super) thread: Option<String>,
}

pub(super) async fn withdraw_question(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<WithdrawQuestion>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let _ = body(payload)?.thread;
    let (task, _) = tasks_of(&state)?
        .close_question(&id, None)
        .await
        .map_err(task_error)?;
    Ok(Json(success(
        json!({"withdrawn": id, "task_id": task.id, "status": task.status}),
    )))
}

#[derive(Deserialize)]
pub(super) struct Respond {
    pub(super) thread_id: String,
    pub(super) request_id: String,
    pub(super) decision: Option<String>,
    pub(super) answers: Option<Value>,
}

/// The user answering a thread's own question or approval from the list of
/// what waits on them: straight to that thread, and its app agent is told.
pub(super) async fn respond_request(
    State(state): State<AppState>,
    payload: std::result::Result<Json<Respond>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    let agents = agents(&state)?;
    let said = agents
        .respond(&r.thread_id, &r.request_id, r.decision, r.answers)
        .await
        .map_err(agent_error)?;
    if let Some(coordinator) = agents.coordinator_of(&r.thread_id) {
        let title = agents.worker_title(&r.thread_id).unwrap_or_default();
        let text = format!(
            "[answer] The user answered “{title}” directly; it has the answer and goes on, nothing to relay:\n{said}"
        );
        agents
            .notify(
                &coordinator,
                &format!("{}.{}", r.thread_id, r.request_id),
                text,
                Note::Answer,
                json!({"worker": r.thread_id, "request": r.request_id}),
            )
            .await
            .map_err(agent_error)?;
    }
    Ok(Json(success(json!({"answered": r.request_id}))))
}

/// Everything waiting on the user across apps, for the phone: only what
/// blocks an agent until the user acts, open questions in the tracker and
/// threads' own questions and approvals in T3. A task at needs you with only
/// a note is not listed; it stays in the app's tasks. Per app, oldest first.
pub(super) async fn list_waiting(State(state): State<AppState>) -> ApiResult<Json<Value>> {
    let agents = agents(&state)?;
    let tasks = tasks_of(&state)?;
    let threads = agents.waiting_threads();
    let requests =
        futures_util::future::join_all(threads.iter().map(|t| agents.pending(&t.thread_id))).await;
    let mut apps: BTreeMap<String, Vec<(u64, Value)>> = BTreeMap::new();
    let all = tasks.all();
    // The most specific task linking a thread: a sub-task before its work item.
    let linking = |thread: &str| {
        all.iter()
            .filter(|t| t.status.open() && t.threads.iter().any(|x| x == thread))
            .max_by_key(|t| t.parent_id.is_some())
    };
    for (thread, pending) in threads.iter().zip(requests) {
        let Some((request, item)) = pending.ok().flatten() else {
            continue;
        };
        let task = linking(&thread.thread_id);
        apps.entry(thread.project_id.clone()).or_default().push((
            0,
            json!({
                "kind": "request", "thread_id": thread.thread_id, "request_id": request,
                "title": thread.title, "worker": thread.coordinator.is_some(),
                "task_id": task.map(|t| t.id.clone()), "ask": task.map(|t| t.ask.clone()),
                "item": item,
            }),
        ));
    }
    // Open questions wherever their task sits: aging into History does not
    // take back what the agent is still waiting on.
    for (task, question) in tasks.asking() {
        let task_media = if question.media.is_empty() {
            Vec::new()
        } else {
            tasks.media(&task.id)
        };
        let from = agents
            .coordinator_of(&question.thread_id)
            .and(agents.worker_title(&question.thread_id));
        let item_ask = task
            .parent_id
            .as_ref()
            .and_then(|p| all.iter().find(|t| &t.id == p))
            .map(|item| item.ask.clone());
        let media: Vec<Value> = question
            .media
            .iter()
            .filter_map(|id| task_media.iter().find(|m| &m.id == id))
            .map(super::task_routes::media_view)
            .collect();
        apps.entry(task.project_id.clone()).or_default().push((
            question.asked_at,
            json!({
                "kind": "question", "id": question.id, "task_id": task.id, "ask": task.ask,
                "item_ask": item_ask, "text": question.text, "options": question.options, "media": media,
                "from": from, "thread_id": question.thread_id, "asked_at": question.asked_at,
            }),
        ));
    }
    let count: usize = apps.values().map(Vec::len).sum();
    let apps: Vec<Value> = apps
        .into_iter()
        .map(|(project, mut items)| {
            items.sort_by_key(|(at, _)| *at);
            json!({
                "project_id": project,
                "app": agents.app_title(&project),
                "items": items.into_iter().map(|(_, v)| v).collect::<Vec<_>>(),
            })
        })
        .collect();
    Ok(Json(success(json!({"count": count, "apps": apps}))))
}
