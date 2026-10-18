use super::*;

#[derive(Deserialize)]
pub(super) struct LinkRequest {
    #[serde(default = "default_ttl")]
    pub(super) ttl_seconds: u64,
}

pub(super) fn default_ttl() -> u64 {
    3600
}

pub(super) async fn create_link(
    State(state): State<AppState>,
    Path(id): Path<String>,
    input: std::result::Result<Json<LinkRequest>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let input = body(input)?;
    if !(60..=86400).contains(&input.ttl_seconds) {
        return Err(ApiError::bad(
            "Install-link lifetime must be between 60 and 86400 seconds",
        ));
    }
    let base = state.public_url.as_ref().ok_or_else(|| {
        ApiError::bad(
            "Start serve with --public-url https://YOUR-MAC-HOSTNAME to create install links",
        )
    })?;
    let job = state
        .jobs
        .get(&id)
        .ok_or_else(|| ApiError::missing(format!("No build {id}")))?
        .job;
    if job.ipa().is_none() {
        return Err(ApiError::bad(
            "Build has no exported IPA; simulator products cannot be installed this way",
        ));
    }
    let ticket = Ticket {
        token: token(),
        build_id: id.clone(),
        expires_at: now() + input.ttl_seconds,
        base_url: base.clone(),
        transfer: TransferEvidence::NotStarted,
    };
    let saved = ticket.clone();
    state
        .tickets
        .ask(move |store| store.save_ticket(&saved))
        .await
        .map_err(ApiError::internal)?;
    let page = format!("{base}/install/{}", ticket.token);
    Ok(Json(success(
        json!({"build_id":id,"page_url":page,"manifest_url":format!("{page}/manifest.plist"),"install_url":artifact::install_url(&format!("{page}/manifest.plist")),"expires_at":ticket.expires_at,"installation_confirmed":false}),
    )))
}

/// A ticket's build, which has an IPA: only that can be installed.
pub(super) async fn ticket_job(
    state: &AppState,
    token: &str,
) -> ApiResult<(Ticket, String, BuildOutput)> {
    let ticket = load_ticket(state, token)
        .await
        .map_err(|_| ApiError::missing("Invalid install link"))?;
    if ticket.expires_at <= now() {
        return Err(ApiError::new(
            StatusCode::GONE,
            "link_expired",
            "Install link expired",
            "Request a new install link for the same build.",
        ));
    }
    let job = state
        .jobs
        .get(&ticket.build_id)
        .ok_or_else(|| ApiError::missing("No IPA for this build"))?
        .job;
    match job.output() {
        Some(output) if output.ipa_path.is_some() => Ok((ticket, job.id.clone(), output.clone())),
        _ => Err(ApiError::missing("No IPA for this build")),
    }
}

/// Whether iOS has started (`download_started_at`) and finished (`downloaded_at`)
/// downloading a link's IPA; it fetches it only after the person confirms the
/// system install prompt. Neither confirms installation.
pub(super) async fn link_status(
    State(state): State<AppState>,
    Path(token): Path<String>,
) -> ApiResult<Json<Value>> {
    let ticket = load_ticket(&state, &token)
        .await
        .map_err(|_| ApiError::missing("Unknown install link"))?;
    let mut view = json!({"build_id":ticket.build_id,"expires_at":ticket.expires_at,
        "download_started_at":null,"downloaded_at":null});
    if let (Some(view), Value::Object(transfer)) = (view.as_object_mut(), json!(ticket.transfer)) {
        view.extend(transfer);
    }
    Ok(Json(success(view)))
}

pub(super) fn private_headers() -> [(header::HeaderName, &'static str); 3] {
    [
        (header::CACHE_CONTROL, "no-store"),
        (header::REFERRER_POLICY, "no-referrer"),
        (header::X_CONTENT_TYPE_OPTIONS, "nosniff"),
    ]
}

pub(super) async fn install_page(
    State(state): State<AppState>,
    Path(token): Path<String>,
) -> ApiResult<Response> {
    let (ticket, build_id, output) = ticket_job(&state, &token).await?;
    let link = artifact::install_url(&format!(
        "{}/install/{}/manifest.plist",
        ticket.base_url, token
    ));
    let html = format!(
        "<!doctype html><html><head><meta name=viewport content=\"width=device-width,initial-scale=1\"><title>Install Squircle build</title><style>body{{font:17px system-ui;max-width:36rem;margin:4rem auto;padding:1.5rem;background:#10141c;color:#f0f3fa}}a{{display:inline-block;padding:1rem 1.4rem;background:#b4ccff;color:#111c30;border-radius:16px;text-decoration:none}}small{{color:#b2bacb}}</style></head><body><small>SQUIRCLE · TEST BUILD</small><h1>{}</h1><p>Version {} · Build {}</p><p><a href=\"{}\">Install on this iPhone</a></p><p>Confirm the iOS installation prompt, then open the app yourself.</p><small>Build ID: {}<br>This link does not confirm installation. Signed builds require an eligible registered device.</small></body></html>",
        artifact::escape_html(&output.title),
        artifact::escape_html(&output.version),
        artifact::escape_html(&output.build_number),
        artifact::escape_html(&link),
        build_id
    );
    Ok((private_headers(), Html(html)).into_response())
}

pub(super) async fn download_manifest(
    State(state): State<AppState>,
    Path(token): Path<String>,
) -> ApiResult<Response> {
    let (ticket, _, output) = ticket_job(&state, &token).await?;
    let bytes = artifact::manifest(
        &output,
        &format!("{}/install/{}/app.ipa", ticket.base_url, token),
    )
    .map_err(ApiError::internal)?;
    Ok((
        private_headers(),
        [(header::CONTENT_TYPE, "application/xml")],
        bytes,
    )
        .into_response())
}

pub(super) async fn download_ipa(
    State(state): State<AppState>,
    Path(token): Path<String>,
) -> ApiResult<Response> {
    let (ticket, _, output) = ticket_job(&state, &token).await?;
    let path = output.ipa_path.expect("ticket_job checks the IPA");
    let file = tokio::fs::File::open(path)
        .await
        .map_err(ApiError::missing)?;
    let size = file.metadata().await.map_err(ApiError::internal)?.len();
    // Evidence only, recorded as it happens: the IPA was opened for a request,
    // then every byte was handed to the connection. Neither blocks the
    // download, and neither proves installation or launch.
    if ticket.transfer == TransferEvidence::NotStarted {
        mark_ticket(&state, &token, |t| t.opened(now())).await;
    }
    // Hyper stops polling a body once Content-Length bytes are out, so the
    // finish is recorded when it drops the body, not by a trailing chunk.
    let sent = Delivered {
        sent: 0,
        size,
        ticket: Some((state.tickets.clone(), token)),
    };
    use futures_util::StreamExt;
    let stream = ReaderStream::new(file).scan(sent, |sent, chunk| {
        if let Ok(chunk) = &chunk {
            sent.sent += chunk.len() as u64;
        }
        std::future::ready(Some(chunk))
    });
    let mut response = (
        private_headers(),
        [(header::CONTENT_TYPE, "application/octet-stream")],
        Body::from_stream(stream),
    )
        .into_response();
    response
        .headers_mut()
        .insert(header::CONTENT_LENGTH, size.to_string().parse().unwrap());
    Ok(response)
}

/// Bytes of an IPA response handed to the connection; records the ticket's
/// `downloaded_at` when the response is dropped with all of them sent, by
/// telling the tickets owner (a drop never writes or waits itself).
pub(super) struct Delivered {
    pub(super) sent: u64,
    pub(super) size: u64,
    pub(super) ticket: Option<(Owner<Store>, String)>,
}

impl Drop for Delivered {
    fn drop(&mut self) {
        if self.sent != self.size {
            return;
        }
        if let Some((tickets, token)) = self.ticket.take() {
            tickets.tell(move |store| {
                let _ = advance_ticket(store, &token, |t| t.completed(now()));
            });
        }
    }
}

/// Advances a ticket's transfer evidence in the tickets owner's turn.
/// Evidence only moves forward; a repeated mark keeps the first times.
/// A ticket as its owner has it, after every mark told before.
pub(super) async fn load_ticket(state: &AppState, token: &str) -> Result<Ticket> {
    let token = token.to_string();
    state
        .tickets
        .ask(move |store| store.load_ticket(&token))
        .await
}

pub(super) async fn mark_ticket(
    state: &AppState,
    token: &str,
    mark: impl FnOnce(TransferEvidence) -> TransferEvidence + Send + 'static,
) {
    let token = token.to_string();
    state
        .tickets
        .ask(move |store| {
            let _ = advance_ticket(store, &token, mark);
        })
        .await
}

pub(super) fn advance_ticket(
    store: &Store,
    token: &str,
    mark: impl FnOnce(TransferEvidence) -> TransferEvidence,
) -> Result<()> {
    let mut ticket = store.load_ticket(token)?;
    let next = mark(ticket.transfer);
    if next == ticket.transfer {
        return Ok(());
    }
    ticket.transfer = next;
    store.save_ticket(&ticket)
}
