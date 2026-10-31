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
    serve_file(&media.file, &media.content_type).await
}

/// Streams a stored file (never through a symlink) with its length.
pub(super) async fn serve_file(path: &std::path::Path, content_type: &str) -> ApiResult<Response> {
    let file = tokio::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .await
        .map_err(ApiError::missing)?;
    let metadata = file.metadata().await.map_err(ApiError::internal)?;
    if !metadata.is_file() {
        return Err(ApiError::internal("Invalid media file"));
    }
    let mut response = (
        private_headers(),
        [(header::CONTENT_TYPE, content_type.to_string())],
        Body::from_stream(ReaderStream::new(file)),
    )
        .into_response();
    response.headers_mut().insert(
        header::CONTENT_LENGTH,
        metadata.len().to_string().parse().unwrap(),
    );
    Ok(response)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct DocumentQuery {
    pub(super) path: String,
}

/// A document (PDF or plain text) on this Mac that an agent linked in this
/// thread, for the phone's viewer: only a path an assistant message of the
/// thread names, only a document type, only a regular file.
pub(super) async fn thread_document(
    Path(thread): Path<String>,
    query: std::result::Result<Query<DocumentQuery>, QueryRejection>,
) -> ApiResult<Response> {
    let path = PathBuf::from(parse_query(query)?.path);
    let content_type = linked_document(&thread, &path).await?;
    serve_file(&path, content_type).await
}

#[derive(Deserialize)]
pub(super) struct FilesQuery {
    paths: Vec<String>,
}

/// What the phone needs to lay out files `thread` links before fetching
/// them: each one's size in bytes and, for a picture or clip, its pixel
/// size. Paths the thread doesn't link, or that are gone, are left out.
pub(super) async fn thread_files(
    Path(thread): Path<String>,
    Json(query): Json<FilesQuery>,
) -> ApiResult<Json<Value>> {
    if !crate::media::valid_thread(&thread) || query.paths.len() > 500 {
        return Err(ApiError::bad("Pass a T3 thread and at most 500 paths"));
    }
    let mut linked = Vec::new();
    for text in query.paths {
        let path = PathBuf::from(&text);
        if !path.is_absolute() {
            continue;
        }
        let rows = crate::t3db::query(
            crate::t3db::sql::THREAD_LINKS,
            crate::t3db::params![thread, text, text.replace(' ', "%20")],
        )
        .await
        .map_err(ApiError::internal)?;
        if !rows.is_empty() {
            linked.push((text, path));
        }
    }
    let facts = tokio::task::spawn_blocking(move || {
        let mut facts = serde_json::Map::new();
        for (text, path) in linked {
            // Every directory on the way as named: no symlink leads elsewhere.
            if std::fs::canonicalize(&path).ok().as_ref() != Some(&path) {
                continue;
            }
            let Ok(meta) = std::fs::metadata(&path) else {
                continue;
            };
            if !meta.is_file() {
                continue;
            }
            let mut fact = json!({"bytes": meta.len()});
            if let Some((width, height)) = crate::dimensions::read(&path) {
                fact["width"] = json!(width);
                fact["height"] = json!(height);
            }
            facts.insert(text, fact);
        }
        facts
    })
    .await
    .map_err(ApiError::internal)?;
    Ok(Json(success(Value::Object(facts))))
}

/// The content type of `path` if the phone may open it from `thread`.
async fn linked_document(thread: &str, path: &std::path::Path) -> ApiResult<&'static str> {
    let text = path
        .to_str()
        .filter(|_| path.is_absolute() && crate::media::valid_thread(thread))
        .ok_or_else(|| ApiError::bad("Pass an absolute file path and a T3 thread"))?;
    let content_type = crate::media::document_type(path)
        .ok_or_else(|| ApiError::bad("Only PDF and plain-text documents open here"))?;
    // The path as the agent wrote it; Markdown escapes a space as %20.
    let rows = crate::t3db::query(
        crate::t3db::sql::THREAD_LINKS,
        crate::t3db::params![thread, text, text.replace(' ', "%20")],
    )
    .await
    .map_err(ApiError::internal)?;
    if rows.is_empty() {
        return Err(ApiError::missing("This thread links no such file"));
    }
    // Every directory on the way as named: no symlink leads elsewhere.
    let canonical = tokio::fs::canonicalize(path)
        .await
        .map_err(ApiError::missing)?;
    if canonical != path {
        return Err(ApiError::missing("This thread links no such file"));
    }
    Ok(content_type)
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
