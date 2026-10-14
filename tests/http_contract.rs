use axum::{
    Router,
    body::Body,
    http::{Request, StatusCode, header},
    response::Response,
};
use http_body_util::BodyExt;
use serde_json::{Value, json};
use squircle::{
    model::{Ticket, now, token},
    server::{AppState, router},
    store::Store,
};
use std::{fs, io::Write, path::PathBuf};
use tempfile::TempDir;
use tower::ServiceExt;
use uuid::Uuid;
use zip::write::SimpleFileOptions;

struct Fixture {
    _directory: TempDir,
    state: AppState,
    app: Router,
    control: String,
    diagnostic: String,
    ipa: PathBuf,
    ipa_bytes: Vec<u8>,
}

impl Fixture {
    fn new() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let store = Store::open(directory.path().join("state")).unwrap();
        let control = store.settings.control_token.clone();
        let diagnostic = store.settings.diagnostic_token.clone();
        let ipa = directory.path().join("Probe.ipa");
        let mut metadata = plist::Dictionary::new();
        for (key, value) in [
            ("CFBundleIdentifier", "ai.dreamslate.SquircleProbe"),
            ("CFBundleVersion", "42"),
            ("CFBundleShortVersionString", "0.1.0"),
            ("CFBundleDisplayName", "Probe <&>"),
        ] {
            metadata.insert(key.into(), plist::Value::String(value.into()));
        }
        let mut plist_bytes = Vec::new();
        plist::Value::Dictionary(metadata)
            .to_writer_binary(&mut plist_bytes)
            .unwrap();
        let mut archive = zip::ZipWriter::new(fs::File::create(&ipa).unwrap());
        archive
            .start_file("Payload/Probe.app/Info.plist", SimpleFileOptions::default())
            .unwrap();
        archive.write_all(&plist_bytes).unwrap();
        archive
            .start_file("Payload/Probe.app/Probe", SimpleFileOptions::default())
            .unwrap();
        // This fixture has metadata, not an Apple signature or executable code.
        archive
            .write_all(b"test fixture: not a signed app")
            .unwrap();
        archive.finish().unwrap();
        let ipa_bytes = fs::read(&ipa).unwrap();
        let state = AppState::new(store, Some("https://mac.test".into()));
        let app = router(state.clone());
        Self {
            _directory: directory,
            state,
            app,
            control,
            diagnostic,
            ipa,
            ipa_bytes,
        }
    }

    async fn request(
        &self,
        method: &str,
        path: &str,
        bearer: Option<&str>,
        payload: Option<Value>,
    ) -> Response {
        let mut request = Request::builder().method(method).uri(path);
        if let Some(bearer) = bearer {
            request = request.header(header::AUTHORIZATION, format!("Bearer {bearer}"));
        }
        let body = if let Some(payload) = payload {
            request = request.header(header::CONTENT_TYPE, "application/json");
            Body::from(serde_json::to_vec(&payload).unwrap())
        } else {
            Body::empty()
        };
        self.app
            .clone()
            .oneshot(request.body(body).unwrap())
            .await
            .unwrap()
    }

    async fn json(
        &self,
        method: &str,
        path: &str,
        bearer: Option<&str>,
        payload: Option<Value>,
    ) -> (StatusCode, Value) {
        let response = self.request(method, path, bearer, payload).await;
        let status = response.status();
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let value: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(value["schema_version"], 1);
        (status, value)
    }

    async fn import(&self) -> String {
        let (status, value) = self
            .json(
                "POST",
                "/v1/import",
                Some(&self.control),
                Some(json!({"ipa": self.ipa})),
            )
            .await;
        assert_eq!(status, StatusCode::OK, "{value}");
        assert_eq!(value["ok"], true);
        assert_eq!(value["data"]["state"], "succeeded");
        assert_eq!(
            value["data"]["source"],
            "imported_ipa_signature_not_verified"
        );
        value["data"]["id"].as_str().unwrap().to_owned()
    }

    async fn install_link(&self, id: &str) -> Value {
        let (status, value) = self
            .json(
                "POST",
                &format!("/v1/builds/{id}/install-link"),
                Some(&self.control),
                Some(json!({"ttl_seconds": 3600})),
            )
            .await;
        assert_eq!(status, StatusCode::OK, "{value}");
        assert_eq!(value["ok"], true);
        value["data"].clone()
    }

    async fn status(&self, id: &str) -> Value {
        let (status, value) = self
            .json(
                "GET",
                &format!("/v1/builds/{id}"),
                Some(&self.control),
                None,
            )
            .await;
        assert_eq!(status, StatusCode::OK, "{value}");
        value["data"].clone()
    }
}

fn event(build_id: &str, kind: &str) -> Value {
    json!({
        "event_id": Uuid::new_v4().to_string(),
        "build_id": build_id,
        "kind": kind,
        "message": "Evidence from the probe",
        "timestamp": 1234567890,
        "attributes": {"source": "http-contract-test"}
    })
}

#[tokio::test]
async fn bearer_permissions_separate_control_from_diagnostic_uploads() {
    let fixture = Fixture::new();
    let id = fixture.import().await;
    for bearer in [None, Some("incorrect"), Some(fixture.diagnostic.as_str())] {
        for path in [
            "/v1/builds".to_owned(),
            format!("/v1/builds/{id}"),
            format!("/v1/builds/{id}/diagnostics"),
            format!("/v1/builds/{id}/log"),
            format!("/v1/builds/{id}/preview"),
        ] {
            let (status, value) = fixture.json("GET", &path, bearer, None).await;
            assert_eq!(status, StatusCode::UNAUTHORIZED, "{path}: {value}");
            assert_eq!(value["ok"], false);
            assert_eq!(value["error"]["code"], "unauthorized");
        }
    }
    for path in ["/v1/builds", "/v1/import"] {
        let (status, _) = fixture
            .json("POST", path, Some(&fixture.diagnostic), Some(json!({})))
            .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }
    for suffix in ["cancel", "install-link", "preview"] {
        let (status, _) = fixture
            .json(
                "POST",
                &format!("/v1/builds/{id}/{suffix}"),
                Some(&fixture.diagnostic),
                Some(json!({})),
            )
            .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }
    for bearer in [None, Some(fixture.control.as_str())] {
        let (status, value) = fixture
            .json("POST", "/v1/diagnostics", bearer, Some(event(&id, "log")))
            .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED, "{value}");
    }
    let (status, value) = fixture
        .json("GET", "/v1/builds", Some(&fixture.control), None)
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(value["data"].as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn preview_download_is_bound_to_its_job_and_control_token() {
    let fixture = Fixture::new();
    let id = fixture.import().await;
    let other = fixture.import().await;
    let path = format!("/v1/builds/{id}/preview");
    assert_eq!(
        fixture
            .request("GET", &path, Some(&fixture.control), None)
            .await
            .status(),
        StatusCode::NOT_FOUND
    );
    // Artifact transport fixture only; this is not a claimed simulator capture.
    let png = b"\x89PNG\r\n\x1a\npreview transport fixture";
    {
        let store = fixture.state.store.lock().unwrap();
        let mut job = store.load_job(&id).unwrap();
        let artifact = store.job_dir(&id).unwrap().join("preview.png");
        fs::write(&artifact, png).unwrap();
        job.output.as_mut().unwrap().preview_path = Some(artifact);
        job.output.as_mut().unwrap().preview_state = Some("succeeded".into());
        store.save_job(&job).unwrap();
    }
    let response = fixture
        .request("GET", &path, Some(&fixture.control), None)
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()[header::CONTENT_TYPE], "image/png");
    assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
    assert_eq!(
        response
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes()
            .as_ref(),
        png
    );
    assert_eq!(
        fixture
            .request(
                "GET",
                &format!("/v1/builds/{other}/preview"),
                Some(&fixture.control),
                None
            )
            .await
            .status(),
        StatusCode::NOT_FOUND
    );
    {
        let store = fixture.state.store.lock().unwrap();
        let mut job = store.load_job(&other).unwrap();
        job.output.as_mut().unwrap().preview_path =
            Some(store.job_dir(&id).unwrap().join("preview.png"));
        store.save_job(&job).unwrap();
    }
    assert_eq!(
        fixture
            .request(
                "GET",
                &format!("/v1/builds/{other}/preview"),
                Some(&fixture.control),
                None
            )
            .await
            .status(),
        StatusCode::INTERNAL_SERVER_ERROR
    );
    {
        let store = fixture.state.store.lock().unwrap();
        let artifact = store.job_dir(&id).unwrap().join("preview.png");
        fs::remove_file(&artifact).unwrap();
        std::os::unix::fs::symlink(&fixture.ipa, artifact).unwrap();
    }
    assert_ne!(
        fixture
            .request("GET", &path, Some(&fixture.control), None)
            .await
            .status(),
        StatusCode::OK
    );
}

#[tokio::test]
async fn preview_submission_rejects_imports_and_ambiguous_devices_without_running_tools() {
    let fixture = Fixture::new();
    let id = fixture.import().await;
    for simulator in ["booted", "00000000-0000-0000-0000-000000000000"] {
        let (status, value) = fixture
            .json(
                "POST",
                &format!("/v1/builds/{id}/preview"),
                Some(&fixture.control),
                Some(json!({"simulator":simulator})),
            )
            .await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{value}");
    }
    let status = fixture.status(&id).await;
    assert_eq!(status["job"]["state"], "succeeded");
    assert!(status["job"]["output"]["ipa_path"].is_string());
    assert!(status["job"]["output"]["preview_state"].is_null());
}

const SCREENSHOT_PNG: &[u8] = &[
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 4, 0,
    0, 0, 181, 28, 12, 2, 0, 0, 0, 11, 73, 68, 65, 84, 120, 218, 99, 100, 248, 15, 0, 1, 5, 1, 1,
    39, 24, 227, 102, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
];

#[tokio::test]
async fn remote_project_routes_require_control_before_inspecting_paths_or_query_fields() {
    let fixture = Fixture::new();
    for token in [None, Some("wrong"), Some(fixture.diagnostic.as_str())] {
        for (method, path) in [
            ("GET", "/v1/projects"),
            ("GET", "/v1/projects/inspect"),
            ("POST", "/v1/apps/import"),
        ] {
            let (status, value) = fixture.json(method, path, token, Some(json!({}))).await;
            assert_eq!(status, StatusCode::UNAUTHORIZED, "{value}");
        }
    }
    let (status, value) = fixture
        .json("GET", "/v1/projects/inspect", Some(&fixture.control), None)
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(value["ok"], false);
    let (status, value) = fixture
        .json(
            "POST",
            "/v1/apps/import",
            Some(&fixture.control),
            Some(json!({"project":"/does/not/exist.xcodeproj","scheme":"App","name":"App"})),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(value["ok"], false);
    assert!(
        fixture
            .state
            .store
            .lock()
            .unwrap()
            .list_jobs()
            .unwrap()
            .is_empty()
    );
    assert!(
        squircle::apps::list(&fixture.state.store.lock().unwrap())
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn remote_directory_listing_returns_only_shallow_visible_folders_and_xcode_packages() {
    let fixture = Fixture::new();
    let directory = fixture.ipa.parent().unwrap().join("Work & Apps");
    fs::create_dir(&directory).unwrap();
    for name in [
        "Beta.xcworkspace",
        "Alpha.xcodeproj",
        "Sources",
        ".hidden",
        "Tool.app",
    ] {
        fs::create_dir(directory.join(name)).unwrap();
    }
    fs::create_dir(directory.join("Alpha.xcodeproj/Nested")).unwrap();
    fs::write(directory.join("notes.txt"), "text").unwrap();
    let query = url::form_urlencoded::Serializer::new(String::new())
        .append_pair("path", directory.to_str().unwrap())
        .finish();
    let (status, value) = fixture
        .json(
            "GET",
            &format!("/v1/projects?{query}"),
            Some(&fixture.control),
            None,
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{value}");
    assert_eq!(
        value["data"]["path"],
        directory.canonicalize().unwrap().to_str().unwrap()
    );
    let entries = value["data"]["entries"].as_array().unwrap();
    assert_eq!(entries.len(), 3);
    assert_eq!(entries[0]["name"], "Alpha.xcodeproj");
    assert_eq!(entries[0]["kind"], "project");
    assert_eq!(entries[1]["kind"], "workspace");
    assert_eq!(entries[2]["kind"], "directory");
    let query = url::form_urlencoded::Serializer::new(String::new())
        .append_pair("path", directory.join("Alpha.xcodeproj").to_str().unwrap())
        .finish();
    assert_eq!(
        fixture
            .json(
                "GET",
                &format!("/v1/projects?{query}"),
                Some(&fixture.control),
                None
            )
            .await
            .0,
        StatusCode::BAD_REQUEST
    );
}

#[tokio::test]
async fn app_metadata_and_versioned_preview_survive_refresh_and_restart() {
    let fixture = Fixture::new();
    let project = fixture.ipa.parent().unwrap().join("Example.xcodeproj");
    fs::create_dir(&project).unwrap();
    let registration = json!({"name":"Example","project":project,"scheme":"Example","bundle_id":"test.example","summary":"Initial"});
    let (status, record) = fixture
        .json(
            "POST",
            "/v1/apps",
            Some(&fixture.control),
            Some(registration.clone()),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{record}");
    let id = record["data"]["id"].as_str().unwrap();
    let route = format!("/v1/apps/{id}");
    let preview_route = format!("{route}/preview");
    assert_eq!(
        fixture
            .request("GET", &preview_route, Some(&fixture.control), None)
            .await
            .status(),
        StatusCode::NOT_FOUND
    );
    let (_, record) = fixture
        .json(
            "PATCH",
            &route,
            Some(&fixture.control),
            Some(json!({"name":"Updated","summary":"Latest working interface"})),
        )
        .await;
    assert_eq!(record["data"]["name"], "Updated");
    let (_, reregistered) = fixture
        .json(
            "POST",
            "/v1/apps",
            Some(&fixture.control),
            Some(registration),
        )
        .await;
    assert_eq!(reregistered["data"], record["data"]);
    let source = fixture.ipa.parent().unwrap().join("actual.png");
    fs::write(&source, SCREENSHOT_PNG).unwrap();
    let publication = json!({"file":source,"caption":"Main screen","source_revision":"abc123"});
    let (status, published) = fixture
        .json(
            "POST",
            &preview_route,
            Some(&fixture.control),
            Some(publication.clone()),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{published}");
    assert!(published["data"]["preview"].get("path").is_none());
    assert_eq!(published["data"]["preview"]["source"], "agent");
    let first_version = published["data"]["preview"]["id"].as_str().unwrap();
    let response = fixture
        .request(
            "GET",
            &format!("{preview_route}?version={first_version}"),
            Some(&fixture.control),
            None,
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()[header::CONTENT_TYPE], "image/png");
    assert_eq!(
        response.headers()[header::ETAG],
        format!("\"{first_version}\"")
    );
    assert_eq!(
        response
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes()
            .as_ref(),
        SCREENSHOT_PNG
    );
    let (_, updated) = fixture
        .json(
            "POST",
            &preview_route,
            Some(&fixture.control),
            Some(publication),
        )
        .await;
    assert_ne!(updated["data"]["preview"]["id"], first_version);
    let (status, error) = fixture
        .json(
            "GET",
            &format!("{preview_route}?version={first_version}"),
            Some(&fixture.control),
            None,
        )
        .await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(error["error"]["code"], "preview_changed");
    fs::remove_file(&source).unwrap();
    let root = fixture.state.store.lock().unwrap().root.clone();
    let reopened = router(AppState::new(Store::open(root).unwrap(), None));
    let response = reopened
        .oneshot(
            Request::builder()
                .uri("/v1/apps")
                .header(header::AUTHORIZATION, format!("Bearer {}", fixture.control))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let records: Value =
        serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(records["data"], json!([updated["data"]]));
    assert_eq!(
        fixture
            .request("GET", &preview_route, Some(&fixture.control), None)
            .await
            .status(),
        StatusCode::OK
    );
    let (status, _) = fixture
        .json(
            "POST",
            &preview_route,
            Some(&fixture.control),
            Some(json!({"file":source})),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (_, unchanged) = fixture
        .json("GET", &route, Some(&fixture.control), None)
        .await;
    assert_eq!(unchanged["data"], updated["data"]);
}

#[tokio::test]
async fn app_catalog_requires_control_and_missing_artifacts_return_not_found() {
    let fixture = Fixture::new();
    let missing = Uuid::new_v4().to_string();
    for bearer in [None, Some("wrong"), Some(fixture.diagnostic.as_str())] {
        for (method, path) in [
            ("GET", "/v1/apps".to_owned()),
            ("POST", "/v1/apps".to_owned()),
            ("GET", format!("/v1/apps/{missing}")),
            ("PATCH", format!("/v1/apps/{missing}")),
            ("GET", format!("/v1/apps/{missing}/preview")),
            ("POST", format!("/v1/apps/{missing}/preview")),
        ] {
            assert_eq!(
                fixture
                    .request(method, &path, bearer, Some(json!({})))
                    .await
                    .status(),
                StatusCode::UNAUTHORIZED
            );
        }
    }
    assert_eq!(
        fixture
            .request(
                "GET",
                &format!("/v1/apps/{missing}"),
                Some(&fixture.control),
                None
            )
            .await
            .status(),
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        fixture
            .request(
                "GET",
                &format!("/v1/apps/{missing}/preview"),
                Some(&fixture.control),
                None
            )
            .await
            .status(),
        StatusCode::NOT_FOUND
    );
}

#[tokio::test]
async fn imported_ipa_downloads_unchanged_with_correct_manifest_and_no_installation_claim() {
    let fixture = Fixture::new();
    let id = fixture.import().await;
    assert_eq!(fixture.status(&id).await["launch_observed"], false);
    let link = fixture.install_link(&id).await;
    assert_eq!(link["build_id"], id);
    assert_eq!(link["installation_confirmed"], false);
    let page = url::Url::parse(link["page_url"].as_str().unwrap()).unwrap();
    let manifest = url::Url::parse(link["manifest_url"].as_str().unwrap()).unwrap();
    assert_eq!(page.origin().ascii_serialization(), "https://mac.test");
    assert_eq!(manifest.as_str(), format!("{page}/manifest.plist"));
    let installer = url::Url::parse(link["install_url"].as_str().unwrap()).unwrap();
    assert_eq!(installer.scheme(), "itms-services");
    let query: std::collections::HashMap<_, _> = installer.query_pairs().into_owned().collect();
    assert_eq!(query["action"], "download-manifest");
    assert_eq!(query["url"], manifest.as_str());

    let response = fixture.request("GET", page.path(), None, None).await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
    let html = String::from_utf8(
        response
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes()
            .to_vec(),
    )
    .unwrap();
    assert!(html.contains("Probe &lt;&amp;&gt;"));
    assert!(html.contains("does not confirm installation"));
    assert!(!html.contains(&fixture.control));
    assert!(!html.contains(&fixture.diagnostic));

    let response = fixture.request("GET", manifest.path(), None, None).await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()[header::CONTENT_TYPE], "application/xml");
    assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
    assert_eq!(response.headers()[header::REFERRER_POLICY], "no-referrer");
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    let plist = plist::Value::from_reader(std::io::Cursor::new(bytes)).unwrap();
    let item = &plist.as_dictionary().unwrap()["items"].as_array().unwrap()[0];
    let item = item.as_dictionary().unwrap();
    let metadata = item["metadata"].as_dictionary().unwrap();
    assert_eq!(
        metadata["bundle-identifier"].as_string(),
        Some("ai.dreamslate.SquircleProbe")
    );
    assert_eq!(metadata["bundle-version"].as_string(), Some("42"));
    assert_eq!(metadata["title"].as_string(), Some("Probe <&>"));
    let asset = item["assets"].as_array().unwrap()[0]
        .as_dictionary()
        .unwrap();
    assert_eq!(asset["kind"].as_string(), Some("software-package"));
    let ipa_url = url::Url::parse(asset["url"].as_string().unwrap()).unwrap();
    assert_eq!(ipa_url.as_str(), format!("{page}/app.ipa"));

    // Fetching the IPA is what records that installation was confirmed.
    let token = page.path_segments().unwrap().next_back().unwrap().to_owned();
    let status_path = format!("/v1/install-links/{token}");
    let (code, before) = fixture.json("GET", &status_path, Some(&fixture.control), None).await;
    assert_eq!(code, StatusCode::OK);
    assert!(before["data"]["downloaded_at"].is_null());
    assert_eq!(fixture.request("GET", &status_path, None, None).await.status(), StatusCode::UNAUTHORIZED);

    // Capability URLs work without either bearer token, as the iOS installer requires.
    let response = fixture.request("GET", ipa_url.path(), None, None).await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response.headers()[header::CONTENT_TYPE],
        "application/octet-stream"
    );
    assert_eq!(
        response.headers()[header::CONTENT_LENGTH].to_str().unwrap(),
        fixture.ipa_bytes.len().to_string()
    );
    assert_eq!(
        response
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes()
            .as_ref(),
        fixture.ipa_bytes
    );
    let (_, after) = fixture.json("GET", &status_path, Some(&fixture.control), None).await;
    assert!(after["data"]["downloaded_at"].as_u64().is_some());
    assert_eq!(fixture.status(&id).await["launch_observed"], false);
}

#[tokio::test]
async fn invalid_and_expired_tickets_cannot_fetch_any_installation_resource() {
    let fixture = Fixture::new();
    let id = fixture.import().await;
    let expired = Ticket {
        token: token(),
        build_id: id,
        expires_at: now() - 1,
        base_url: "https://mac.test".into(),
        download_started_at: None,
        downloaded_at: None,
    };
    fixture
        .state
        .store
        .lock()
        .unwrap()
        .save_ticket(&expired)
        .unwrap();
    for suffix in ["", "/manifest.plist", "/app.ipa"] {
        for invalid in ["invalid".to_owned(), token()] {
            let (status, value) = fixture
                .json("GET", &format!("/install/{invalid}{suffix}"), None, None)
                .await;
            assert_eq!(status, StatusCode::NOT_FOUND);
            assert_eq!(value["ok"], false);
        }
        let (status, value) = fixture
            .json(
                "GET",
                &format!("/install/{}{suffix}", expired.token),
                None,
                None,
            )
            .await;
        assert_eq!(status, StatusCode::GONE);
        assert_eq!(value["error"]["code"], "link_expired");
    }
}

#[tokio::test]
async fn diagnostics_acknowledge_retries_reject_conflicts_and_observe_only_launches() {
    let fixture = Fixture::new();
    let id = fixture.import().await;
    let original = event(&id, "log");
    for duplicate in [false, true] {
        let (status, value) = fixture
            .json(
                "POST",
                "/v1/diagnostics",
                Some(&fixture.diagnostic),
                Some(original.clone()),
            )
            .await;
        assert_eq!(status, StatusCode::OK, "{value}");
        assert_eq!(value["ok"], true);
        assert_eq!(value["data"]["event_id"], original["event_id"]);
        assert_eq!(value["data"]["duplicate"], duplicate);
        assert_eq!(value["data"]["stored"], !duplicate);
    }
    assert_eq!(fixture.status(&id).await["launch_observed"], false);

    let mut conflicting = original.clone();
    conflicting["message"] = json!("Changed payload with the same event ID");
    let (status, value) = fixture
        .json(
            "POST",
            "/v1/diagnostics",
            Some(&fixture.diagnostic),
            Some(conflicting),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(value["ok"], false);
    assert!(
        value["error"]["message"]
            .as_str()
            .unwrap()
            .contains("conflict")
    );

    let (status, value) = fixture
        .json(
            "POST",
            "/v1/diagnostics",
            Some(&fixture.diagnostic),
            Some(event(&Uuid::new_v4().to_string(), "launch")),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(value["ok"], false);
    assert_eq!(fixture.status(&id).await["launch_observed"], false);

    let launch = event(&id, "launch");
    let (status, value) = fixture
        .json(
            "POST",
            "/v1/diagnostics",
            Some(&fixture.diagnostic),
            Some(launch.clone()),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{value}");
    assert_eq!(fixture.status(&id).await["launch_observed"], true);
    let (status, value) = fixture
        .json(
            "GET",
            &format!("/v1/builds/{id}/diagnostics"),
            Some(&fixture.control),
            None,
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(value["data"]["events"], json!([original, launch]));
}
