use serde_json::Value;
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    process::{Command, Output},
    sync::{Arc, Mutex, mpsc},
    thread,
    time::{Duration, Instant},
};

fn command() -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_squircle"));
    // Discovery and ordinary API requests must not depend on an installed agent
    // executable, shell startup file, or agent credentials.
    command.env("PATH", "");
    command.env_remove("SQUIRCLE_SERVER");
    command.env_remove("SQUIRCLE_DATA_DIR");
    command
}

fn json_result(output: &Output) -> Value {
    let result: Value = serde_json::from_slice(&output.stdout).unwrap_or_else(|error| {
        panic!(
            "invalid JSON result: {error}; stdout={:?}",
            String::from_utf8_lossy(&output.stdout)
        )
    });
    assert_eq!(result["schema_version"], 1);
    result
}

#[test]
fn capabilities_work_without_agents_service_or_initialized_state() {
    let directory = tempfile::tempdir().unwrap();
    let state = directory.path().join("not-initialized");
    let output = command()
        .arg("--data-dir")
        .arg(&state)
        .args(["capabilities", "--json"])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let result = json_result(&output);
    assert_eq!(result["ok"], true);
    assert!(
        result["data"]["operations"]
            .as_array()
            .unwrap()
            .iter()
            .any(|operation| operation == "build.start")
    );
    assert!(!state.exists(), "capability discovery created local state");
}

#[test]
fn argument_errors_are_one_machine_readable_result() {
    let output = command()
        .args(["--json", "not-a-command"])
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(2));
    let result = json_result(&output);
    assert_eq!(result["ok"], false);
    assert_eq!(result["error"]["code"], "invalid_arguments");
    assert!(
        result["error"]["next_step"]
            .as_str()
            .unwrap()
            .contains("--help")
    );
}

#[test]
fn workflow_help_covers_the_remote_loop() {
    let output = command().args(["help", "workflow"]).output().unwrap();
    assert!(output.status.success());
    let help = String::from_utf8(output.stdout).unwrap();
    for text in [
        "build start",
        "install-link",
        "logs BUILD_ID",
        "crashes BUILD_ID",
    ] {
        assert!(help.contains(text), "workflow is missing {text}");
    }
}

struct TestServer {
    url: String,
    paths: Arc<Mutex<Vec<String>>>,
    stop: mpsc::Sender<()>,
    thread: Option<thread::JoinHandle<()>>,
}

impl TestServer {
    fn new(reply: Option<&'static str>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let (stop, stopped) = mpsc::channel();
        let paths = Arc::new(Mutex::new(Vec::new()));
        let observed = paths.clone();
        let handle = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(5);
            let mut held_streams: Vec<TcpStream> = Vec::new();
            while Instant::now() < deadline {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream
                            .set_read_timeout(Some(Duration::from_millis(500)))
                            .unwrap();
                        let mut request = [0; 8192];
                        if let Ok(count) = stream.read(&mut request)
                            && let Some(path) = String::from_utf8_lossy(&request[..count])
                                .split_whitespace()
                                .nth(1)
                        {
                            observed.lock().unwrap().push(path.to_owned());
                        }
                        if let Some(reply) = reply {
                            let response = format!(
                                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{reply}",
                                reply.len()
                            );
                            let _ = stream.write_all(response.as_bytes());
                        } else {
                            // Keep the connection alive without returning headers.
                            // The CLI's wait deadline must cancel its pending GET.
                            held_streams.push(stream);
                        }
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                    Err(error) => panic!("test server accept failed: {error}"),
                }
                if stopped.recv_timeout(Duration::from_millis(5)).is_ok() {
                    break;
                }
            }
        });
        Self {
            url,
            paths,
            stop,
            thread: Some(handle),
        }
    }
}

impl Drop for TestServer {
    fn drop(&mut self) {
        let _ = self.stop.send(());
        self.thread.take().unwrap().join().unwrap();
    }
}

fn wait_for(server: &TestServer, timeout: &str) -> Output {
    let directory = tempfile::tempdir().unwrap();
    command()
        .arg("--data-dir")
        .arg(directory.path())
        .args([
            "--server",
            &server.url,
            "--json",
            "build",
            "wait",
            "ed8c7cf6-45ac-4a0f-90ef-67e4901e9386",
            "--timeout",
            timeout,
        ])
        .output()
        .unwrap()
}

#[test]
fn wait_deadline_includes_a_hung_http_request_and_never_cancels_the_build() {
    let server = TestServer::new(None);
    let started = Instant::now();
    let output = wait_for(&server, "1");
    let elapsed = started.elapsed();
    assert!(
        elapsed < Duration::from_secs(3),
        "one-second wait took {elapsed:?}"
    );
    assert_eq!(output.status.code(), Some(2));
    let result = json_result(&output);
    assert_eq!(result["error"]["code"], "wait_timeout");
    let paths = server.paths.lock().unwrap();
    assert!(!paths.is_empty());
    assert!(paths.iter().all(|path| !path.contains("cancel")));
}

#[test]
fn wait_reports_failed_and_successful_builds_with_distinct_exit_statuses() {
    let failed = TestServer::new(Some(
        r#"{"schema_version":1,"ok":true,"data":{"job":{"state":"failed","error":"compiler failed"}}}"#,
    ));
    let output = wait_for(&failed, "2");
    assert_eq!(output.status.code(), Some(2));
    let result = json_result(&output);
    assert_eq!(result["error"]["code"], "build_not_succeeded");
    assert_eq!(result["data"]["job"]["error"], "compiler failed");
    let succeeded = TestServer::new(Some(
        r#"{"schema_version":1,"ok":true,"data":{"job":{"state":"succeeded"}}}"#,
    ));
    let output = wait_for(&succeeded, "2");
    assert!(output.status.success());
    assert_eq!(json_result(&output)["data"]["job"]["state"], "succeeded");
}
