#![cfg(unix)]

use serde_json::Value;
use squircle::{
    model::{BuildState, Job},
    store::Store,
};
use std::{path::Path, process::Stdio, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, BufReader, Lines},
    process::{Child, ChildStderr, Command},
    time::timeout,
};

const PROCESS_TIMEOUT: Duration = Duration::from_secs(5);

fn command(root: &Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_squircle"));
    command
        .env_remove("SQUIRCLE_DATA_DIR")
        .env_remove("SQUIRCLE_SERVER")
        .env("PATH", "")
        .arg("--data-dir")
        .arg(root)
        .args(["--json", "serve", "--listen", "127.0.0.1:0"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    command
}

struct Service {
    child: Child,
    // Keep the pipe open for the child's lifetime. A failing assertion drops
    // the owned child with kill_on_drop; no process-name matching is used.
    _stderr: Lines<BufReader<ChildStderr>>,
    url: String,
    client: reqwest::Client,
    token: String,
}

impl Service {
    async fn start(root: &Path) -> Self {
        let token = Store::open(root.to_owned()).unwrap().settings.control_token;
        let mut child = command(root).spawn().unwrap();
        let mut stderr = BufReader::new(child.stderr.take().unwrap()).lines();
        let line = timeout(PROCESS_TIMEOUT, stderr.next_line())
            .await
            .expect("service did not announce its listener before the deadline")
            .unwrap()
            .expect("service exited before announcing its listener");
        let address = line
            .strip_prefix("Squircle listening on ")
            .and_then(|line| line.split_once(". Keep this process running"))
            .map(|(address, _)| address)
            .unwrap_or_else(|| panic!("unexpected service startup output: {line}"));
        let service = Self {
            child,
            _stderr: stderr,
            url: format!("http://{address}"),
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(2))
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .unwrap(),
            token,
        };
        // Serving a request also ensures the graceful-shutdown signal future
        // has been polled before the test sends SIGTERM.
        assert_eq!(
            service.get("/health").await["data"]["accepting_builds"],
            true
        );
        service
    }

    async fn get(&self, path: &str) -> Value {
        let response = self
            .client
            .get(format!("{}{path}", self.url))
            .bearer_auth(&self.token)
            .send()
            .await
            .unwrap();
        let status = response.status();
        let body: Value = response.json().await.unwrap();
        assert!(status.is_success(), "HTTP {status}: {body}");
        assert_eq!(body["ok"], true, "{body}");
        body
    }

    async fn stop(mut self) {
        assert!(self.child.try_wait().unwrap().is_none());
        let pid = self.child.id().expect("owned service has no process ID");
        // Only signal the specific live child owned by this test.
        assert_eq!(unsafe { libc::kill(pid as i32, libc::SIGTERM) }, 0);
        let status = timeout(PROCESS_TIMEOUT, self.child.wait())
            .await
            .expect("idle service did not stop within five seconds")
            .unwrap();
        assert!(status.success(), "service exited unsuccessfully: {status}");
    }
}

fn fixture_job(root: &Path, state: BuildState) -> Job {
    let terminal_error = matches!(state, BuildState::Failed | BuildState::Cancelled | BuildState::Interrupted);
    let output = (state == BuildState::Succeeded).then(|| serde_json::json!({
        "archive_path": null, "ipa_path": null, "app_path": "/retained/App.app", "dsym_paths": [],
        "bundle_id": "test.app", "version": "1", "build_number": "1", "title": "App"
    }));
    serde_json::from_value(serde_json::json!({
        "id": uuid::Uuid::new_v4().to_string(),
        "created_at": 1,
        "updated_at": 2,
        "request": {
            // Deliberately nonexistent: even an accidental retry must fail
            // validation before starting an actual Xcode process.
            "project": root.join("NoSuchProject.xcodeproj"),
            "scheme": "LifecycleFixture",
            "configuration": "Debug",
            "mode": "simulator",
            "export_options": null,
            "allow_provisioning_updates": false,
            "capture_preview": false,
            "request_id": null
        },
        "output": output,
        "error": terminal_error.then_some("original fixture outcome"),
        "state": state,
        "source": "xcodebuild",
        "source_revision": "a".repeat(40),
        "source_dirty": true
    }))
    .unwrap()
}

#[tokio::test]
async fn restart_interrupts_unfinished_jobs_without_retrying_or_rewriting_terminal_jobs() {
    let directory = tempfile::tempdir().unwrap();
    let store = Store::open(directory.path().to_owned()).unwrap();
    let initial_tokens = serde_json::to_value(&store.settings).unwrap();
    let jobs: Vec<_> = [
        BuildState::Queued,
        BuildState::Running,
        BuildState::Succeeded,
        BuildState::Failed,
        BuildState::Cancelled,
        BuildState::Interrupted,
    ]
    .into_iter()
    .map(|state| fixture_job(directory.path(), state))
    .collect();
    for job in &jobs {
        store.save_job(job).unwrap();
        std::fs::write(
            store.job_dir(&job.id).unwrap().join("retained-artifact"),
            b"keep existing build artifacts",
        )
        .unwrap();
    }

    let service = Service::start(directory.path()).await;
    assert_eq!(
        service.get("/v1/builds").await["data"]
            .as_array()
            .unwrap()
            .len(),
        jobs.len()
    );
    let mut recovered_records = Vec::new();
    for original in &jobs {
        let observed = service.get(&format!("/v1/builds/{}", original.id)).await;
        let mut expected = serde_json::to_value(original).unwrap();
        let observed_job = {
            let mut job = observed["data"]["job"].clone();
            assert!(job.as_object_mut().unwrap().remove("revision").is_some());
            job
        };
        if !original.state().terminal() {
            assert_eq!(observed["data"]["job"]["state"], "interrupted");
            let error = observed["data"]["job"]["error"].as_str().unwrap();
            assert!(error.contains("no automatic retry"), "{error}");
            assert!(observed["data"]["job"]["updated_at"].as_u64().unwrap() > 2);
            expected["state"] = "interrupted".into();
            expected["error"] = observed["data"]["job"]["error"].clone();
            expected["updated_at"] = observed["data"]["job"]["updated_at"].clone();
        }
        assert_eq!(observed_job, expected);
        let persisted = serde_json::to_value(store.load_job(&original.id).unwrap()).unwrap();
        assert_eq!(persisted, expected, "recovery was not durably persisted");
        recovered_records.push(persisted);
        let job_dir = store.job_dir(&original.id).unwrap();
        assert_eq!(
            std::fs::read(job_dir.join("retained-artifact")).unwrap(),
            b"keep existing build artifacts"
        );
        assert!(!job_dir.join("build.log").exists(), "job was retried");
    }
    service.stop().await;

    // A second real process must observe the persisted outcomes without
    // changing timestamps or credentials on every restart.
    let restarted = Service::start(directory.path()).await;
    for expected in recovered_records {
        let id = expected["id"].as_str().unwrap();
        let mut observed = restarted.get(&format!("/v1/builds/{id}")).await["data"]["job"].take();
        observed.as_object_mut().unwrap().remove("revision");
        assert_eq!(observed, expected);
    }
    assert_eq!(
        serde_json::to_value(Store::open(directory.path().to_owned()).unwrap().settings).unwrap(),
        initial_tokens
    );
    restarted.stop().await;
}

#[tokio::test]
async fn only_one_service_owns_a_store_and_shutdown_releases_ownership() {
    let directory = tempfile::tempdir().unwrap();
    let first = Service::start(directory.path()).await;
    let rejected = timeout(PROCESS_TIMEOUT, command(directory.path()).output())
        .await
        .expect("competing service did not fail before the deadline")
        .unwrap();
    assert_eq!(rejected.status.code(), Some(2));
    let result: Value = serde_json::from_slice(&rejected.stdout).unwrap();
    assert_eq!(result["ok"], false);
    assert_eq!(result["error"]["code"], "operation_failed");
    assert!(
        result["error"]["message"]
            .as_str()
            .unwrap()
            .contains("Another Squircle service owns this data directory"),
        "{result}"
    );
    assert_eq!(first.get("/health").await["data"]["accepting_builds"], true);
    first.stop().await;

    // The persistent lock file may remain, but the kernel lock must be gone.
    let successor = Service::start(directory.path()).await;
    assert_eq!(
        successor.get("/v1/builds").await["data"],
        serde_json::json!([])
    );
    successor.stop().await;
}

#[tokio::test]
async fn restart_fails_unfinished_preview_without_invalidating_signed_build() {
    let directory = tempfile::tempdir().unwrap();
    let store = Store::open(directory.path().to_owned()).unwrap();
    let mut record = serde_json::to_value(fixture_job(directory.path(), BuildState::Succeeded)).unwrap();
    record["request"]["mode"] = "archive".into();
    record["output"] = serde_json::json!({
        "archive_path":null,"ipa_path":"/retained/app.ipa","app_path":null,"dsym_paths":[],
        "bundle_id":"test.app","version":"1","build_number":"2","title":"App",
        "preview_state":"running","preview_path":"/retained/preview.png","preview_captured_at":10
    });
    let job: Job = serde_json::from_value(record).unwrap();
    store.save_job(&job).unwrap();
    let service = Service::start(directory.path()).await;
    let observed = service.get(&format!("/v1/builds/{}", job.id)).await;
    assert_eq!(observed["data"]["job"]["state"], "succeeded");
    assert_eq!(
        observed["data"]["job"]["output"]["ipa_path"],
        "/retained/app.ipa"
    );
    assert_eq!(observed["data"]["job"]["output"]["preview_state"], "failed");
    assert_eq!(observed["data"]["job"]["output"]["preview_captured_at"], 10);
    assert!(
        observed["data"]["job"]["output"]["preview_error"]
            .as_str()
            .unwrap()
            .contains("no automatic retry")
    );
    assert_eq!(
        serde_json::to_value(store.load_job(&job.id).unwrap()).unwrap()["output"]["preview_state"],
        "failed"
    );
    assert!(!store.job_dir(&job.id).unwrap().join("build.log").exists());
    service.stop().await;
}
