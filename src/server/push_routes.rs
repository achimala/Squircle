use super::*;

pub(super) fn push(state: &AppState) -> ApiResult<Arc<Push>> {
    state
        .push
        .clone()
        .ok_or_else(|| ApiError::internal("Notifications run only inside squircle serve"))
}

pub(super) async fn push_status(State(state): State<AppState>) -> ApiResult<Json<Value>> {
    Ok(Json(success(push(&state)?.status().await)))
}

pub(super) async fn push_register(
    State(state): State<AppState>,
    payload: std::result::Result<Json<crate::push::Registration>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    push(&state)?
        .register(body(payload)?)
        .await
        .map_err(ApiError::bad)?;
    Ok(Json(success(json!({}))))
}

pub(super) async fn push_activity(
    State(state): State<AppState>,
    payload: std::result::Result<Json<crate::push::ActivityRegistration>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    push(&state)?
        .register_activity(body(payload)?)
        .await
        .map_err(ApiError::bad)?;
    Ok(Json(success(json!({}))))
}

pub(super) async fn push_presence(
    State(state): State<AppState>,
    payload: std::result::Result<Json<crate::push::PresenceReport>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    push(&state)?
        .report_presence(body(payload)?)
        .await
        .map_err(ApiError::bad)?;
    Ok(Json(success(json!({}))))
}

#[derive(Deserialize)]
pub(super) struct PushTest {
    #[serde(default)]
    pub(super) live_activity: bool,
}

pub(super) async fn push_test(
    State(state): State<AppState>,
    payload: std::result::Result<Json<PushTest>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let request = body(payload)?;
    Ok(Json(success(
        push(&state)?.test(request.live_activity).await,
    )))
}
