#![cfg(test)]

use super::*;

#[test]
fn gzip_quality_zero_refuses_gzip() {
    assert!(
        accepts_gzip("gzip, deflate, br")
            && accepts_gzip("br;q=1.0, GZIP;q=0.5")
            && accepts_gzip("*")
    );
    assert!(
        !accepts_gzip("gzip;q=0") && !accepts_gzip("gzip; q=0.000, *") && !accepts_gzip("deflate")
    );
    assert!(!accepts_gzip("*;q=0") && !accepts_gzip("xgzip"));
}

#[tokio::test]
async fn polled_json_revalidates_and_compresses() {
    use tower::ServiceExt;
    let app = Router::new()
        .route(
            "/big",
            get(|| async { Json(json!({"rows": vec!["build"; 2000]})) }),
        )
        .route_layer(middleware::from_fn(compact_json));
    let call = |headers: &[(header::HeaderName, &str)]| {
        let mut request = axum::http::Request::get("/big");
        for (name, value) in headers {
            request = request.header(name, *value);
        }
        app.clone().oneshot(request.body(Body::empty()).unwrap())
    };
    let plain = call(&[]).await.unwrap();
    assert_eq!(plain.status(), StatusCode::OK);
    assert!(plain.headers().get(header::CONTENT_ENCODING).is_none());
    let etag = plain.headers()[header::ETAG].to_str().unwrap().to_string();
    let body = axum::body::to_bytes(plain.into_body(), usize::MAX)
        .await
        .unwrap();

    let same = call(&[(header::IF_NONE_MATCH, &etag)]).await.unwrap();
    assert_eq!(same.status(), StatusCode::NOT_MODIFIED);
    assert!(
        axum::body::to_bytes(same.into_body(), usize::MAX)
            .await
            .unwrap()
            .is_empty()
    );
    let stale = call(&[(header::IF_NONE_MATCH, "\"other\"")]).await.unwrap();
    assert_eq!(stale.status(), StatusCode::OK);

    let zipped = call(&[(header::ACCEPT_ENCODING, "br, gzip;q=0.9")])
        .await
        .unwrap();
    assert_eq!(zipped.headers()[header::CONTENT_ENCODING], "gzip");
    let bytes = axum::body::to_bytes(zipped.into_body(), usize::MAX)
        .await
        .unwrap();
    assert!(bytes.len() < body.len() / 10);
    let mut unzipped = Vec::new();
    std::io::Read::read_to_end(&mut flate2::read::GzDecoder::new(&bytes[..]), &mut unzipped)
        .unwrap();
    assert_eq!(unzipped, body);
}

#[test]
fn history_pages_are_stable_and_complete() {
    let at = |t: &(&'static str, u64)| HistoryCursor {
        archived_at: t.1,
        id: t.0.into(),
    };
    let history = || vec![("a", 5), ("b", 9), ("c", 5), ("d", 1), ("e", 7)];
    let mut seen = vec![];
    let mut cursor = None;
    loop {
        let (page, next) = history_page(history(), at, cursor.as_ref(), 2);
        seen.extend(page.into_iter().map(|t| t.0));
        match next {
            Some(next) => cursor = Some(HistoryCursor::parse(&next.to_string()).unwrap()),
            None => break,
        }
    }
    assert_eq!(seen, ["b", "e", "c", "a", "d"]);
    // A task leaving History doesn't shift the next page.
    let first = history_page(history(), at, None, 2).1.unwrap();
    let fewer: Vec<_> = history().into_iter().filter(|t| t.0 != "b").collect();
    assert_eq!(
        history_page(fewer, at, Some(&first), 2)
            .0
            .iter()
            .map(|t| t.0)
            .collect::<Vec<_>>(),
        ["c", "a"]
    );
    assert!(HistoryCursor::parse("x").is_err());
}

fn request(root: &std::path::Path) -> BuildRequest {
    let project = root.join("Probe.xcodeproj");
    std::fs::create_dir_all(&project).unwrap();
    BuildRequest {
        project,
        scheme: "Probe".into(),
        configuration: "Release".into(),
        mode: BuildMode::Simulator,
        export_options: None,
        request_id: Some("same-request".into()),
        allow_provisioning_updates: false,
        capture_preview: false,
        no_overlay: false,
        thread: None,
    }
}
fn test_ipa(path: &std::path::Path) -> Result<()> {
    let mut metadata = plist::Dictionary::new();
    metadata.insert("CFBundleIdentifier".into(), "dev.example.probe".into());
    metadata.insert("CFBundleVersion".into(), "1".into());
    let mut bytes = Vec::new();
    plist::Value::Dictionary(metadata).to_writer_xml(&mut bytes)?;
    let mut zip = zip::ZipWriter::new(std::fs::File::create(path)?);
    zip.start_file(
        "Payload/Probe.app/Info.plist",
        zip::write::SimpleFileOptions::default(),
    )?;
    zip.write_all(&bytes)?;
    zip.finish()?;
    Ok(())
}

#[tokio::test]
async fn swift_uppercase_diagnostic_uuids_are_accepted_and_lowercase_retries_deduplicate()
-> Result<()> {
    let dir = tempfile::tempdir()?;
    let source = dir.path().join("input.ipa");
    test_ipa(&source)?;
    let state = AppState::new(Store::open(dir.path().join("state"))?, None)?;
    let job = import_job(state.clone(), source.clone(), copy_and_inspect_ipa).await?;
    let diagnostic_token = state.files.settings.diagnostic_token.clone();
    let mut authorization = HeaderMap::new();
    authorization.insert(
        header::AUTHORIZATION,
        format!("Bearer {diagnostic_token}").parse()?,
    );
    let event_id = "a50f8213-88d3-4b6f-91d3-143aceef3f9d";
    let mut event = Diagnostic {
        event_id: event_id.to_uppercase(),
        build_id: job.id.to_uppercase(),
        kind: DiagnosticKind::Crash,
        message: "Swift crash report".into(),
        timestamp: 1,
        attributes: json!({}),
    };
    let Json(first) = ingest(State(state.clone()), Ok(Json(event.clone())))
        .await
        .unwrap();
    assert_eq!(first["data"]["event_id"], event_id);
    assert_eq!(first["data"]["stored"], true);
    event.event_id = event_id.into();
    event.build_id = job.id.clone();
    let Json(retry) = ingest(State(state.clone()), Ok(Json(event.clone())))
        .await
        .unwrap();
    assert_eq!(retry["data"]["duplicate"], true);
    let stored = state.files.diagnostics(&job.id, 0, 10, None)?;
    assert_eq!(stored["events"].as_array().unwrap().len(), 1);
    assert_eq!(stored["events"][0]["event_id"], event_id);
    assert_eq!(stored["events"][0]["build_id"], job.id);

    event.build_id = "../outside".into();
    let error = ingest(State(state), Ok(Json(event))).await.unwrap_err();
    assert_eq!(error.status, StatusCode::BAD_REQUEST);
    Ok(())
}

#[tokio::test]
async fn unauthorized_or_invalid_imports_publish_no_record() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let source = dir.path().join("input.ipa");
    test_ipa(&source)?;
    let state = AppState::new(Store::open(dir.path().join("state"))?, None)?;
    use tower::ServiceExt;
    let response = router(state.clone())
        .oneshot(
            axum::http::Request::post("/v1/import")
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(json!({"ipa": source}).to_string()))?,
        )
        .await?;
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    let jobs_directory = state.files.root.join("jobs");
    assert_eq!(std::fs::read_dir(&jobs_directory)?.count(), 0);

    std::fs::write(&source, b"not an IPA")?;
    assert!(import_ipa(&state, &source, copy_and_inspect_ipa).is_err());
    assert!(state.files.list_jobs()?.is_empty());
    assert_eq!(std::fs::read_dir(jobs_directory)?.count(), 0);
    Ok(())
}

#[tokio::test]
async fn queued_cancellation_does_not_wait_for_the_active_build_and_retries_deduplicate() {
    let dir = tempfile::tempdir().unwrap();
    let state = AppState::new(Store::open(dir.path().join("state")).unwrap(), None).unwrap();
    let _active = state.slots.clone().acquire_owned().await.unwrap();
    let request = request(dir.path());
    let Json(first) = start(State(state.clone()), Ok(Json(request.clone())))
        .await
        .unwrap();
    let id = first["data"]["job"]["id"].as_str().unwrap().to_owned();
    let Json(retry) = start(State(state.clone()), Ok(Json(request.clone())))
        .await
        .unwrap();
    assert_eq!(retry["data"]["job"]["id"], id);
    assert_eq!(retry["data"]["replayed"], true);
    let mut changed = request;
    changed.configuration = "Debug".into();
    assert_eq!(
        start(State(state.clone()), Ok(Json(changed)))
            .await
            .unwrap_err()
            .status,
        StatusCode::CONFLICT
    );
    let _ = cancel(State(state.clone()), Path(id.clone()))
        .await
        .unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(2), async {
        loop {
            if state.files.load_job(&id).unwrap().state() == BuildState::Cancelled {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("queued cancellation should be immediate");
    assert!(!state.files.job_dir(&id).unwrap().join("build.log").exists());
}
