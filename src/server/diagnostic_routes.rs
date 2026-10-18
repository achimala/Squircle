use super::*;

#[derive(Deserialize, Default)]
pub(super) struct Page {
    #[serde(default)]
    pub(super) since: usize,
    pub(super) limit: Option<usize>,
    pub(super) kind: Option<DiagnosticKind>,
}

pub(super) async fn diagnostics(
    State(state): State<AppState>,
    Path(id): Path<String>,
    page: std::result::Result<Query<Page>, QueryRejection>,
) -> ApiResult<Json<Value>> {
    let page = parse_query(page)?;
    let files = state.files.clone();
    let data = in_lane(&state.diagnostics, move || {
        files.diagnostics(&id, page.since, page.limit.unwrap_or(100), page.kind)
    })
    .await
    .map_err(ApiError::internal)?
    .map_err(ApiError::bad)?;
    Ok(Json(success(data)))
}

#[derive(Deserialize)]
pub(super) struct CaptureQuery {
    pub(super) kind: String,
}

/// A screen or performance recording from the phone; the message that sends
/// it links the returned path. Authentication runs before this handler, the
/// body streams into its own private staging file (never memory), and the
/// staged file is removed on any failure or cancellation. Uploads don't wait
/// for each other: one that stalls (its app suspended mid-send) holds only
/// its own file.
pub(super) async fn upload_capture(
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
    let root = state.files.root.clone();
    let staged = crate::perf::staging_path(&root).map_err(ApiError::internal)?;
    let file = crate::store::create_private(&staged).map_err(ApiError::internal)?;
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

pub(super) struct StagedFile(Option<PathBuf>);

impl Drop for StagedFile {
    fn drop(&mut self) {
        if let Some(path) = self.0.take() {
            let _ = std::fs::remove_file(path);
        }
    }
}

/// Copies a request body into `file`, refusing more than `max` bytes.
pub(super) async fn write_bounded(
    body: Body,
    mut file: tokio::fs::File,
    max: u64,
) -> ApiResult<()> {
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

pub(super) async fn ingest(
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
    let (files, stored) = (state.files.clone(), event.clone());
    let inserted = in_lane(&state.diagnostics, move || files.append_diagnostic(&stored))
        .await
        .map_err(ApiError::internal)?
        .map_err(ApiError::bad)?;
    Ok(Json(success(
        json!({"event_id":event.event_id,"stored":inserted,"duplicate":!inserted}),
    )))
}
