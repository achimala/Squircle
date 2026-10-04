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
    for suffix in ["cancel", "install-link"] {
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
