#![cfg(test)]

use super::*;

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
    // A build holds the lane until the test ends.
    let (entered, holding) = tokio::sync::oneshot::channel();
    let lane = state.builds.clone();
    tokio::spawn(async move {
        lane.run(async {
            let _ = entered.send(());
            std::future::pending::<()>().await
        })
        .await
    });
    holding.await.unwrap();
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
    let mut changes = state.jobs.changes();
    let _ = cancel(State(state.clone()), Path(id.clone()))
        .await
        .unwrap();
    // Recorded without the lane: the active build never lets it go.
    while state.files.load_job(&id).unwrap().state() != BuildState::Cancelled {
        futures_util::StreamExt::next(&mut changes).await.unwrap();
    }
    assert!(!state.files.job_dir(&id).unwrap().join("build.log").exists());
}
