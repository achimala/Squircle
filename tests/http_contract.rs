use axum::{
    Router,
    body::Body,
    http::{Request, StatusCode, header},
    response::Response,
};
use http_body_util::BodyExt;
use serde_json::{Value, json};
use squircle::{
    model::{PreviewArtifact, PreviewState},
    server::{AppState, router},
    store::Store,
};
use std::{fs, io::Write, path::PathBuf};
use tempfile::TempDir;
use tower::ServiceExt;
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
        // Stored, so the IPA spans several response chunks.
        archive
            .start_file(
                "Payload/Probe.app/padding",
                SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored),
            )
            .unwrap();
        archive.write_all(&[7u8; 64 * 1024]).unwrap();
        archive.finish().unwrap();
        let ipa_bytes = fs::read(&ipa).unwrap();
        let state = AppState::new(store, Some("https://mac.test".into())).unwrap();
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

    /// A new service over the same data directory, which rereads its records.
    fn reopen(&mut self) {
        let root = self.state.files.root.clone();
        self.state =
            AppState::new(Store::open(root).unwrap(), Some("https://mac.test".into())).unwrap();
        self.app = router(self.state.clone());
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

#[tokio::test]
async fn preview_download_is_bound_to_its_job_and_control_token() {
    let mut fixture = Fixture::new();
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
        let store = fixture.state.files.clone();
        let mut job = store.load_job(&id).unwrap();
        let artifact = store.job_dir(&id).unwrap().join("preview.png");
        fs::write(&artifact, png).unwrap();
        job.set_preview(PreviewState::Ready(PreviewArtifact {
            path: artifact,
            captured_at: 1,
            source: None,
        }));
        store.save_job(&job).unwrap();
    }
    fixture.reopen();
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
        let store = fixture.state.files.clone();
        let mut job = store.load_job(&other).unwrap();
        let path = store.job_dir(&id).unwrap().join("preview.png");
        job.set_preview(PreviewState::Ready(PreviewArtifact {
            path,
            captured_at: 1,
            source: None,
        }));
        store.save_job(&job).unwrap();
    }
    fixture.reopen();
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
        let store = fixture.state.files.clone();
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

/// A body that records whether anything polled it.
fn watched_body(polled: std::sync::Arc<std::sync::atomic::AtomicBool>) -> Body {
    Body::from_stream(futures_util::stream::poll_fn(move |_| {
        polled.store(true, std::sync::atomic::Ordering::SeqCst);
        std::task::Poll::Ready(None::<Result<Vec<u8>, std::io::Error>>)
    }))
}

#[tokio::test]
async fn capture_uploads_authenticate_and_check_size_before_reading_the_body() {
    let fixture = Fixture::new();
    let polled = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    for bearer in [None, Some(fixture.diagnostic.as_str())] {
        let mut request = Request::post("/v1/captures?kind=video");
        if let Some(bearer) = bearer {
            request = request.header(header::AUTHORIZATION, format!("Bearer {bearer}"));
        }
        let response = fixture
            .app
            .clone()
            .oneshot(request.body(watched_body(polled.clone())).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }
    let oversized = Request::post("/v1/captures?kind=video")
        .header(header::AUTHORIZATION, format!("Bearer {}", fixture.control))
        .header(header::CONTENT_LENGTH, (400u64 * 1024 * 1024).to_string())
        .body(watched_body(polled.clone()))
        .unwrap();
    let response = fixture.app.clone().oneshot(oversized).await.unwrap();
    assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
    assert!(!polled.load(std::sync::atomic::Ordering::SeqCst));

    // An accepted upload lands as a private file; nothing is left staged.
    let mut video = vec![0, 0, 0, 24];
    video.extend_from_slice(b"ftypmp42");
    video.extend_from_slice(&[0; 16]);
    let accepted = Request::post("/v1/captures?kind=video")
        .header(header::AUTHORIZATION, format!("Bearer {}", fixture.control))
        .body(Body::from(video.clone()))
        .unwrap();
    let response = fixture.app.clone().oneshot(accepted).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let value: Value =
        serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes()).unwrap();
    let path = PathBuf::from(value["data"]["path"].as_str().unwrap());
    assert_eq!(fs::read(&path).unwrap(), video);
    let leftovers = fs::read_dir(path.parent().unwrap())
        .unwrap()
        .filter(|entry| {
            entry
                .as_ref()
                .unwrap()
                .file_name()
                .to_string_lossy()
                .ends_with(".partial")
        })
        .count();
    assert_eq!(leftovers, 0);
}

#[tokio::test]
async fn install_evidence_requires_a_complete_transfer() {
    let fixture = Fixture::new();
    let id = fixture.import().await;
    let evidence = |token: String| {
        let fixture = &fixture;
        async move {
            let (_, value) = fixture
                .json(
                    "GET",
                    &format!("/v1/install-links/{token}"),
                    Some(&fixture.control),
                    None,
                )
                .await;
            (
                value["data"]["download_started_at"].clone(),
                value["data"]["downloaded_at"].clone(),
            )
        }
    };
    let token_of = |link: &Value| {
        link["page_url"]
            .as_str()
            .unwrap()
            .rsplit('/')
            .next()
            .unwrap()
            .to_owned()
    };

    // Aborted after the first chunk: started, never finished.
    let aborted = token_of(&fixture.install_link(&id).await);
    let response = fixture
        .request("GET", &format!("/install/{aborted}/app.ipa"), None, None)
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let mut body = response.into_body();
    body.frame().await.unwrap().unwrap();
    drop(body);
    let (started, finished) = evidence(aborted).await;
    assert!(started.as_u64().is_some());
    assert!(finished.is_null());

    // Complete over a real HTTP/1.1 connection, as iOS fetches it: Hyper
    // stops polling the body at Content-Length, which in-process calls hide.
    let complete = token_of(&fixture.install_link(&id).await);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(axum::serve(listener, fixture.app.clone()).into_future());
    let mut socket = tokio::net::TcpStream::connect(address).await.unwrap();
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    socket
        .write_all(
            format!("GET /install/{complete}/app.ipa HTTP/1.1\r\nHost: mac.test\r\n\r\n")
                .as_bytes(),
        )
        .await
        .unwrap();
    let mut received = Vec::new();
    let mut buffer = [0u8; 16 * 1024];
    let head_end = loop {
        let read = socket.read(&mut buffer).await.unwrap();
        assert!(read > 0, "connection closed early");
        received.extend_from_slice(&buffer[..read]);
        if let Some(end) = received.windows(4).position(|w| w == b"\r\n\r\n")
            && received.len() >= end + 4 + fixture.ipa_bytes.len()
        {
            break end + 4;
        }
    };
    assert_eq!(&received[head_end..], fixture.ipa_bytes.as_slice());
    // The connection stays open (keep-alive). HTTP/1.1 answers in order, so
    // a second request answered on it means the first response's body was
    // let go, and with it the finish told to the tickets owner, which
    // `evidence` asks after.
    socket
        .write_all(b"GET /health HTTP/1.1\r\nHost: mac.test\r\n\r\n")
        .await
        .unwrap();
    let mut answer = Vec::new();
    while !answer.windows(4).any(|w| w == b"\r\n\r\n") {
        let read = socket.read(&mut buffer).await.unwrap();
        assert!(read > 0, "connection closed early");
        answer.extend_from_slice(&buffer[..read]);
    }
    assert!(answer.starts_with(b"HTTP/1.1 200"));
    assert!(
        !evidence(complete.clone()).await.1.is_null(),
        "downloaded_at not recorded while the connection stays open"
    );
    drop(socket);
    server.abort();

    // A missing IPA records nothing at all.
    let missing = token_of(&fixture.install_link(&id).await);
    let ipa = fixture.status(&id).await["job"]["output"]["ipa_path"]
        .as_str()
        .unwrap()
        .to_owned();
    fs::remove_file(ipa).unwrap();
    let response = fixture
        .request("GET", &format!("/install/{missing}/app.ipa"), None, None)
        .await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    let (started, finished) = evidence(missing).await;
    assert!(started.is_null() && finished.is_null());
}
