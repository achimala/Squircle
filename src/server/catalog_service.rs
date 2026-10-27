use super::*;

/// The catalog app a finished build belongs to. A succeeded build registers
/// its app and publishes a newer preview; any other build is matched to an
/// app already registered for its project and scheme (or bundle, for an
/// import), so its notification can still open the app.
pub(super) async fn build_app(state: &AppState, job: &Job) -> Option<apps::AppRecord> {
    let (store, job) = (state.files.clone(), job.clone());
    // Copies the preview in the catalog's lane, off the async workers.
    let result = in_catalog(state.catalog_writes(), move || {
        if job.output().is_some() && job.request().is_some() {
            apps::sync_build_preview(&store, &job)
                .map(Some)
                .map_err(|e| (job.id.clone(), e))
        } else {
            Ok(apps::list(&store)
                .ok()
                .and_then(|apps| apps::owner_of(&apps, &job).cloned()))
        }
    })
    .await;
    match result {
        Ok(Ok(app)) => app,
        Ok(Err((id, error))) => {
            // Catalog publication is ancillary: never invalidate an exported IPA.
            eprintln!("Could not sync app metadata for build {id}: {error:#}");
            None
        }
        Err(_) => None,
    }
}

pub(super) fn public_app(app: apps::AppRecord) -> Value {
    // A missing artifact is the app's preview being unavailable, not an error;
    // republishing repairs it.
    let available = app.preview.is_none() || apps::open_preview(&app).is_ok();
    let mut value = serde_json::to_value(app).expect("app metadata serializes");
    if !available {
        value["preview"] = Value::Null;
        value["preview_unavailable"] = json!(true);
    }
    if let Some(preview) = value["preview"].as_object_mut() {
        preview.remove("path");
    }
    value
}

pub(super) fn inspection_busy() -> ApiError {
    ApiError {
        retryable: true,
        ..ApiError::new(
            StatusCode::TOO_MANY_REQUESTS,
            "inspection_busy",
            "Two Xcode inspections are already running",
            "Wait for an existing inspection to finish, then retry.",
        )
    }
}

pub(super) async fn import_catalog_app(
    state: AppState,
    input: projects::ImportRequest,
) -> ApiResult<Value> {
    if input.name.trim().is_empty() || input.name.len() > 200 || input.name.contains('\0') {
        return Err(ApiError::bad("App name must contain 1–200 characters"));
    }
    if state.draining.load(Ordering::Acquire) {
        return Err(ApiError::unavailable());
    }
    let _permit = state.inspection().ok_or_else(inspection_busy)?;
    let inspected = projects::inspect(
        &input.project,
        Some(&input.scheme),
        Some(&input.configuration),
    )
    .await
    .map_err(ApiError::bad)?;
    let app = in_catalog(state.catalog_writes(), move || {
        if state.draining.load(Ordering::Acquire) {
            return Err(ApiError::unavailable());
        }
        projects::import_inspected(&state.files, &inspected, &input.name).map_err(ApiError::bad)
    })
    .await
    .map_err(ApiError::internal)??;
    Ok(success(public_app(app)))
}
