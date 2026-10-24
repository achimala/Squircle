use super::*;

#[derive(Deserialize)]
pub(super) struct BrowseQuery {
    pub(super) path: Option<String>,
}

#[derive(Deserialize)]
pub(super) struct InspectQuery {
    pub(super) project: String,
    pub(super) scheme: Option<String>,
    pub(super) configuration: Option<String>,
}

pub(super) async fn browse_projects(
    query: std::result::Result<Query<BrowseQuery>, QueryRejection>,
) -> ApiResult<Json<Value>> {
    let query = parse_query(query)?;
    let directory = tokio::task::spawn_blocking(move || projects::browse(query.path.as_deref()))
        .await
        .map_err(ApiError::internal)?
        .map_err(ApiError::bad)?;
    Ok(Json(success(directory)))
}

pub(super) async fn inspect_project(
    State(state): State<AppState>,
    query: std::result::Result<Query<InspectQuery>, QueryRejection>,
) -> ApiResult<Json<Value>> {
    let query = parse_query(query)?;
    let _permit = state.inspection().ok_or_else(inspection_busy)?;
    let result = projects::inspect(
        &query.project,
        query.scheme.as_deref(),
        query.configuration.as_deref(),
    )
    .await
    .map_err(ApiError::bad)?;
    Ok(Json(success(result)))
}

pub(super) async fn import_app(
    State(state): State<AppState>,
    input: std::result::Result<Json<projects::ImportRequest>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    import_catalog_app(state, body(input)?).await.map(Json)
}

// App records are replaced atomically, so reads need no lane; the
// catalog scan and preview checks are file I/O, kept off the async workers.
pub(super) async fn list_apps(State(state): State<AppState>) -> ApiResult<Json<Value>> {
    let apps = tokio::task::spawn_blocking(move || {
        apps::list(&state.files).map(|apps| apps.into_iter().map(public_app).collect::<Vec<_>>())
    })
    .await
    .map_err(ApiError::internal)?
    .map_err(ApiError::internal)?;
    Ok(Json(success(apps)))
}

/// Home's order, as the user dragged it; answers the catalog in that order.
pub(super) async fn order_apps(
    State(state): State<AppState>,
    input: std::result::Result<Json<apps::AppOrder>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let input = body(input)?;
    let apps = in_lane(&state.catalog.clone(), move || {
        if state.draining.load(Ordering::Acquire) {
            return Err(ApiError::unavailable());
        }
        apps::set_order(&state.files, input).map_err(ApiError::bad)
    })
    .await
    .map_err(ApiError::internal)??;
    Ok(Json(success(
        apps.into_iter().map(public_app).collect::<Vec<_>>(),
    )))
}

pub(super) async fn get_app(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    let app = tokio::task::spawn_blocking(move || apps::get(&state.files, &id).map(public_app))
        .await
        .map_err(ApiError::internal)?
        .map_err(ApiError::missing)?;
    Ok(Json(success(app)))
}

pub(super) async fn register_app(
    State(state): State<AppState>,
    input: std::result::Result<Json<apps::AppRegistration>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let input = body(input)?;
    let app = in_lane(&state.catalog.clone(), move || {
        if state.draining.load(Ordering::Acquire) {
            return Err(ApiError::unavailable());
        }
        apps::register(&state.files, input).map_err(ApiError::bad)
    })
    .await
    .map_err(ApiError::internal)??;
    Ok(Json(success(public_app(app))))
}

pub(super) async fn update_app(
    State(state): State<AppState>,
    Path(id): Path<String>,
    input: std::result::Result<Json<apps::AppUpdate>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let input = body(input)?;
    let app = in_lane(&state.catalog.clone(), move || {
        if state.draining.load(Ordering::Acquire) {
            return Err(ApiError::unavailable());
        }
        apps::get(&state.files, &id).map_err(ApiError::missing)?;
        apps::update(&state.files, &id, input).map_err(ApiError::bad)
    })
    .await
    .map_err(ApiError::internal)??;
    Ok(Json(success(public_app(app))))
}

pub(super) async fn publish_app_preview(
    State(state): State<AppState>,
    Path(id): Path<String>,
    input: std::result::Result<Json<apps::PreviewPublication>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let input = body(input)?;
    // Copy and validate outside the catalog's lane; only the commit is in it.
    let (files, preview) = (state.files.clone(), id.clone());
    let source = input.file.clone();
    let staged = tokio::task::spawn_blocking(move || {
        apps::stage_preview(&files.root, &preview, &source).map_err(|error| {
            if files.root.join("apps").join(&preview).is_dir() {
                ApiError::bad(format!("{error:#}"))
            } else {
                ApiError::missing(format!("{error:#}"))
            }
        })
    })
    .await
    .map_err(ApiError::internal)??;
    let app = in_lane(&state.catalog.clone(), move || {
        if state.draining.load(Ordering::Acquire) {
            return Err(ApiError::unavailable());
        }
        apps::get(&state.files, &id).map_err(ApiError::missing)?;
        apps::publish_staged(&state.files, &id, input, staged).map_err(ApiError::bad)
    })
    .await
    .map_err(ApiError::internal)??;
    Ok(Json(success(public_app(app))))
}

#[derive(Deserialize)]
pub(super) struct PreviewVersion {
    pub(super) version: Option<String>,
}

pub(super) async fn app_preview(
    State(state): State<AppState>,
    Path(id): Path<String>,
    query: std::result::Result<Query<PreviewVersion>, QueryRejection>,
) -> ApiResult<Response> {
    let query = parse_query(query)?;
    // In the catalog's lane, so a publish can't replace the image between
    // reading the record and opening its file.
    let files = state.files.clone();
    let (file, preview_id) = in_lane(&state.catalog, move || {
        let app = apps::get(&files, &id).map_err(ApiError::missing)?;
        let preview = app
            .preview
            .clone()
            .ok_or_else(|| ApiError::missing("App has no published preview"))?;
        if query
            .version
            .as_ref()
            .is_some_and(|version| version != &preview.id)
        {
            return Err(ApiError::new(
                StatusCode::CONFLICT,
                "preview_changed",
                "App preview has changed since metadata was read",
                "Refresh app metadata and request its current preview version.",
            ));
        }
        let file = apps::open_preview(&app).map_err(ApiError::missing)?;
        Ok((file, preview.id))
    })
    .await
    .map_err(ApiError::internal)??;
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
