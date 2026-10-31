use super::*;

pub fn router(state: AppState) -> Router {
    // Everything here requires the control token, checked before extraction.
    let control = Router::new()
        .route("/v1/builds", get(list).post(start))
        .route("/v1/apps", get(list_apps).post(register_app))
        .route("/v1/apps/import", post(import_app))
        .route("/v1/apps/order", put(order_apps))
        .route("/v1/projects", get(browse_projects))
        .route("/v1/projects/inspect", get(inspect_project))
        .route("/v1/apps/{id}", get(get_app).patch(update_app))
        .route(
            "/v1/apps/{id}/preview",
            get(app_preview).post(publish_app_preview),
        )
        .route("/v1/builds/{id}", get(status))
        .route("/v1/builds/{id}/cancel", post(cancel))
        .route("/v1/builds/{id}/log", get(build_log))
        .route("/v1/builds/{id}/icon", get(build_icon))
        .route("/v1/builds/{id}/install-link", post(create_link))
        .route("/v1/builds/{id}/diagnostics", get(diagnostics))
        .route("/v1/t3/threads/{thread}/steps", get(t3_steps))
        .route(
            "/v1/t3/projects/{project}/screenshot",
            get(t3_project_screenshot),
        )
        .route(
            "/v1/t3/threads/{thread}/media",
            get(thread_media).post(add_thread_media),
        )
        .route("/v1/t3/threads/{thread}/media/{id}", get(thread_media_file))
        .route("/v1/t3/threads/{thread}/document", get(thread_document))
        .route("/v1/t3/threads/{thread}/files", post(thread_files))
        .route(
            "/v1/t3/threads/{thread}/media/{id}/poster",
            get(thread_media_poster),
        )
        .route(
            "/v1/t3/threads/{thread}/steps/{call}/images/{index}",
            get(t3_step_image),
        )
        .route("/v1/sims", get(list_sims).post(start_sim))
        .route("/v1/sims/stop", post(stop_sim))
        .route("/v1/sims/devices", get(sim_devices))
        .route("/v1/sims/cleanup", post(cleanup_sims))
        .route("/v1/sims/prune", post(prune_sims))
        .route("/v1/sims/keep", get(sim_keep).post(change_sim_keep))
        .route("/v1/agents", get(list_agents).post(ensure_agent))
        .route("/v1/agents/context", get(agent_context))
        .route("/v1/agents/heard", post(agent_heard))
        .route("/v1/t3/providers", get(t3_providers))
        .route("/v1/agents/restart", post(restart_agent))
        .route("/v1/agents/compact", post(compact_agent))
        .route("/v1/workers", get(list_workers).post(spawn_worker))
        .route("/v1/workers/{id}", get(read_worker))
        .route("/v1/workers/{id}/messages", post(message_worker))
        .route("/v1/workers/{id}/answer", post(answer_worker))
        .route("/v1/workers/{id}/archive", post(archive_worker))
        .route("/v1/workers/cleanup", post(cleanup_workers))
        .route("/v1/push", get(push_status))
        .route("/v1/push/devices", post(push_register))
        .route("/v1/push/activities", post(push_activity))
        .route("/v1/push/presence", post(push_presence))
        .route("/v1/push/test", post(push_test))
        .route("/v1/tasks", get(list_tasks).post(add_task))
        .route("/v1/tasks/{id}", get(show_task).patch(update_task))
        .route("/v1/tasks/{id}/link", post(link_task))
        .route("/v1/tasks/{id}/media", post(attach_task))
        .route("/v1/tasks/{id}/media/{media}", get(task_media_file))
        .route("/v1/tasks/{id}/questions", post(ask_task))
        .route("/v1/questions/{id}/answer", post(answer_question))
        .route("/v1/questions/{id}/withdraw", post(withdraw_question))
        .route("/v1/events", get(events))
        .route("/v1/waiting", get(list_waiting))
        .route("/v1/waiting/respond", post(respond_request))
        .route("/v1/import", post(import))
        .route("/v1/captures", post(upload_capture))
        .route("/v1/install-links/{token}", get(link_status))
        .route_layer(middleware::from_fn(compact_json))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            require_control,
        ));
    let diagnostics = Router::new()
        .route("/v1/diagnostics", post(ingest))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            require_diagnostics,
        ));
    // Install links carry their own unguessable, expiring token.
    let public = Router::new()
        .route(
            "/health",
            get(|State(state): State<AppState>| async move {
                Json(success(
                    json!({"service":"squircle","version":env!("CARGO_PKG_VERSION"),"accepting_builds":!state.draining.load(Ordering::Acquire)}),
                ))
            }),
        )
        .route("/install/{token}", get(install_page))
        .route("/install/{token}/manifest.plist", get(download_manifest))
        .route("/install/{token}/app.ipa", get(download_ipa));
    Router::new()
        .merge(control)
        .merge(diagnostics)
        .merge(public)
        .fallback(|| async {
            ApiError::rejection(StatusCode::NOT_FOUND, "Unknown endpoint".into())
        })
        .layer(DefaultBodyLimit::max(1024 * 1024))
        .layer(middleware::map_response(envelope_errors))
        .with_state(state)
}
