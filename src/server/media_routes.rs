use super::*;

#[derive(Deserialize)]
pub(super) struct StepsQuery {
    pub(super) since: Option<String>,
}

/// Tool-call details T3 omits from its client stream; see `t3steps`.
pub(super) async fn t3_steps(
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
pub(super) async fn t3_project_screenshot(Path(project): Path<String>) -> ApiResult<Response> {
    let image = crate::t3steps::project_screenshot(&project)
        .await
        .map_err(|e| ApiError::bad(e.to_string()))?
        .ok_or_else(|| ApiError::missing("No screenshot in this project's threads"))?;
    Ok((private_headers(), Json(success(image))).into_response())
}

/// Recordings and images agents published into a thread (`squircle media add`).
pub(super) async fn thread_media(
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
pub(super) struct AddMedia {
    pub(super) file: PathBuf,
    pub(super) caption: Option<String>,
}

/// Publishes a file on this Mac into a thread (`squircle media add`).
pub(super) async fn add_thread_media(
    State(state): State<AppState>,
    Path(thread): Path<String>,
    payload: std::result::Result<Json<AddMedia>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    let root = state.files.root.clone();
    let media = tokio::task::spawn_blocking(move || {
        crate::media::add(&root, &thread, &r.file, r.caption.as_deref())
    })
    .await
    .map_err(ApiError::internal)?
    .map_err(ApiError::bad)?;
    Ok(Json(success(
        json!({"id":media.id,"thread_id":media.thread_id,"kind":media.kind,"caption":media.caption,"content_type":media.content_type,"bytes":media.bytes,"created_at":media.created_at}),
    )))
}

pub(super) async fn thread_media_file(
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
    response.headers_mut().insert(
        header::CONTENT_LENGTH,
        metadata.len().to_string().parse().unwrap(),
    );
    Ok(response)
}

pub(super) async fn thread_media_poster(
    State(state): State<AppState>,
    Path((thread, id)): Path<(String, String)>,
) -> ApiResult<Response> {
    let media = crate::media::get(&state.files.root, &thread, &id).map_err(ApiError::missing)?;
    let poster = crate::media::poster(&media).map_err(ApiError::missing)?;
    let bytes = tokio::fs::read(&poster).await.map_err(ApiError::internal)?;
    Ok((
        private_headers(),
        [(header::CONTENT_TYPE, "image/jpeg")],
        bytes,
    )
        .into_response())
}

pub(super) async fn t3_step_image(
    Path((thread, call, index)): Path<(String, String, usize)>,
) -> ApiResult<Response> {
    let image = crate::t3steps::image(&thread, &call, index)
        .await
        .map_err(|e| ApiError::bad(e.to_string()))?
        .ok_or_else(|| ApiError::missing("No such image"))?;
    Ok((private_headers(), Json(success(image))).into_response())
}
