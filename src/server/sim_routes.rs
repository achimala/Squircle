use super::*;

// MARK: Simulator sessions

pub(super) fn sims(state: &AppState) -> ApiResult<Arc<Sims>> {
    state.sims.clone().ok_or_else(|| {
        sim_error(anyhow::anyhow!(
            "Simulator sessions are not running in this service"
        ))
    })
}

pub(super) fn sim_error(error: anyhow::Error) -> ApiError {
    ApiError::new(
        StatusCode::CONFLICT,
        "simulator_failed",
        format!("{error:#}"),
        "Read the message; run squircle sim --help.",
    )
}

#[derive(Deserialize)]
pub(super) struct SimQuery {
    pub(super) thread: Option<String>,
    /// Also every booted simulator and its owner (the CLI; the phone polls without it).
    #[serde(default)]
    pub(super) simulators: bool,
}

pub(super) async fn list_sims(
    State(state): State<AppState>,
    query: std::result::Result<Query<SimQuery>, QueryRejection>,
) -> ApiResult<Json<Value>> {
    let query = parse_query(query)?;
    let sims = sims(&state)?;
    let mut list = sims.list(query.thread.as_deref());
    // Every booted simulator and who holds it; without T3 the sessions still show.
    if let Some(pool) = state.pool.as_ref().filter(|_| query.simulators) {
        list["simulators"] = pool
            .status(&sims.leases())
            .await
            .unwrap_or_else(|e| json!({"error": format!("{e:#}")}));
    }
    Ok(Json(success(list)))
}

#[derive(Deserialize)]
pub(super) struct CleanupSims {
    #[serde(default)]
    pub(super) dry_run: bool,
}

pub(super) async fn cleanup_sims(
    State(state): State<AppState>,
    payload: std::result::Result<Json<CleanupSims>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let request = body(payload)?;
    let sims = sims(&state)?;
    let pool = state.pool.clone().ok_or_else(|| {
        sim_error(anyhow::anyhow!(
            "The simulator pool is not running in this service"
        ))
    })?;
    Ok(Json(success(
        pool.cleanup(&sims.leases(), request.dry_run)
            .await
            .map_err(sim_error)?,
    )))
}

fn pool(state: &AppState) -> ApiResult<Arc<crate::simpool::Pool>> {
    state.pool.clone().ok_or_else(|| {
        sim_error(anyhow::anyhow!(
            "The simulator pool is not running in this service"
        ))
    })
}

pub(super) async fn prune_sims(
    State(state): State<AppState>,
    payload: std::result::Result<Json<CleanupSims>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let request = body(payload)?;
    let sims = sims(&state)?;
    Ok(Json(success(
        pool(&state)?
            .prune(&sims.leases(), request.dry_run)
            .await
            .map_err(sim_error)?,
    )))
}

pub(super) async fn sim_keep(State(state): State<AppState>) -> ApiResult<Json<Value>> {
    let keep = pool(&state)?.keep_list().await.map_err(sim_error)?;
    Ok(Json(success(json!({"keep": keep}))))
}

#[derive(Deserialize)]
pub(super) struct ChangeKeep {
    #[serde(default)]
    pub(super) add: Vec<String>,
    #[serde(default)]
    pub(super) remove: Vec<String>,
}

pub(super) async fn change_sim_keep(
    State(state): State<AppState>,
    payload: std::result::Result<Json<ChangeKeep>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let request = body(payload)?;
    let keep = pool(&state)?
        .keep(request.add, request.remove)
        .await
        .map_err(sim_error)?;
    Ok(Json(success(json!({"keep": keep}))))
}

#[derive(Deserialize)]
pub(super) struct StartSim {
    pub(super) thread_id: String,
    pub(super) device: Option<String>,
}

pub(super) async fn start_sim(
    State(state): State<AppState>,
    payload: std::result::Result<Json<StartSim>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let request = body(payload)?;
    let started = sims(&state)?
        .start(&request.thread_id, request.device.as_deref())
        .await
        .map_err(sim_error)?;
    Ok(Json(success(started)))
}

#[derive(Deserialize)]
pub(super) struct StopSim {
    pub(super) thread_id: Option<String>,
    pub(super) id: Option<String>,
}

pub(super) async fn stop_sim(
    State(state): State<AppState>,
    payload: std::result::Result<Json<StopSim>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let request = body(payload)?;
    let sims = sims(&state)?;
    // A thread in line for a simulator gives up its place.
    let left = match request.thread_id.as_deref() {
        Some(thread) => sims.leave(thread).await.map_err(sim_error)?,
        None => false,
    };
    if left && !sims.running(request.thread_id.as_deref().unwrap_or_default()) {
        return Ok(Json(success(
            json!({"left_queue": true, "next": "This thread is no longer waiting for a simulator."}),
        )));
    }
    // Filing a long recording takes minutes. A caller that gives up first
    // must not cancel it halfway: the session would stay "filing" until the
    // service restarts.
    let stop = tokio::spawn(async move {
        sims.stop(request.thread_id.as_deref(), request.id.as_deref())
            .await
    });
    let session = stop
        .await
        .map_err(|e| sim_error(anyhow::anyhow!(e)))?
        .map_err(sim_error)?;
    let next = if session.media_id.is_some() {
        "The recording now shows in this turn on the phone."
    } else {
        "No recording was saved; see error."
    };
    Ok(Json(success(json!({"session": session, "next": next}))))
}

pub(super) async fn sim_devices(State(state): State<AppState>) -> ApiResult<Json<Value>> {
    Ok(Json(success(
        sims(&state)?.devices().await.map_err(sim_error)?,
    )))
}
