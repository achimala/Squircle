// A fake HTTP server on a plain thread records the CLI's requests behind a
// leaf lock; this is test scaffolding, not service state.
#![allow(clippy::disallowed_types)]

use serde_json::Value;
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    process::{Command, Output},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
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

/// A one-thread HTTP fake. Every connection is handled in accept order with
/// blocking I/O, and stopping queues a final wake-up connection behind them,
/// so once the server is stopped `paths` holds every request the CLI sent.
struct TestServer {
    url: String,
    address: std::net::SocketAddr,
    paths: Arc<Mutex<Vec<String>>>,
    stopping: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}

impl TestServer {
    fn new(reply: Option<&'static str>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let paths = Arc::new(Mutex::new(Vec::new()));
        let stopping = Arc::new(AtomicBool::new(false));
        let (observed, stop) = (paths.clone(), stopping.clone());
        let handle = thread::spawn(move || {
            let mut held_streams: Vec<TcpStream> = Vec::new();
            for stream in listener.incoming() {
                let mut stream = stream.unwrap();
                let request = read_request(&mut stream);
                if request.is_empty() && stop.load(Ordering::SeqCst) {
                    break;
                }
                if let Some(path) = request.split_whitespace().nth(1) {
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
        });
        Self {
            url: format!("http://{address}"),
            address,
            paths,
            stopping,
            thread: Some(handle),
        }
    }

    /// Every request path received, after all earlier connections were handled.
    fn stop(mut self) -> Vec<String> {
        self.finish();
        std::mem::take(&mut *self.paths.lock().unwrap())
    }

    fn finish(&mut self) {
        if let Some(thread) = self.thread.take() {
            self.stopping.store(true, Ordering::SeqCst);
            drop(TcpStream::connect(self.address).unwrap());
            thread.join().unwrap();
        }
    }
}

impl Drop for TestServer {
    fn drop(&mut self) {
        self.finish();
    }
}

/// Reads one request's headers and body; empty if the peer sent nothing.
fn read_request(stream: &mut TcpStream) -> String {
    // macOS hands out accepted sockets with the listener's flags; be explicit.
    stream.set_nonblocking(false).unwrap();
    let mut request = Vec::new();
    let mut buffer = [0; 8192];
    loop {
        let text = String::from_utf8_lossy(&request);
        if let Some(headers) = text.find("\r\n\r\n") {
            let length = text[..headers]
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().ok())?
                })
                .unwrap_or(0);
            if request.len() >= headers + 4 + length {
                break;
            }
        }
        match stream.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(count) => request.extend_from_slice(&buffer[..count]),
        }
    }
    String::from_utf8_lossy(&request).into_owned()
}

/// The CLI's own deadline is one or two seconds; reqwest's fallback timeout is
/// 60. Anything under this bound proves the deadline, not the fallback, ended
/// the command, without depending on how loaded the machine running tests is.
const DEADLINE_HONOURED: Duration = Duration::from_secs(30);

/// Runs the CLI against `server` and reports how long the command itself took.
fn run(server: &TestServer, arguments: &[&str]) -> (Output, Duration) {
    let directory = tempfile::tempdir().unwrap();
    // Time the HTTP deadline, not first-use credential fsync under concurrent
    // test/build disk load. Initialize before the command starts.
    squircle::store::Store::open(directory.path().to_owned()).unwrap();
    let started = Instant::now();
    let output = command()
        .arg("--data-dir")
        .arg(directory.path())
        .args(["--server", &server.url, "--json"])
        .args(arguments)
        .output()
        .unwrap();
    (output, started.elapsed())
}

fn wait_for(server: &TestServer, timeout: &str) -> (Output, Duration) {
    run(
        server,
        &[
            "build",
            "wait",
            "ed8c7cf6-45ac-4a0f-90ef-67e4901e9386",
            "--timeout",
            timeout,
        ],
    )
}

#[test]
fn wait_deadline_includes_a_hung_http_request_and_never_cancels_the_build() {
    let server = TestServer::new(None);
    let (output, elapsed) = wait_for(&server, "1");
    assert!(
        elapsed < DEADLINE_HONOURED,
        "one-second wait took {elapsed:?}"
    );
    assert_eq!(output.status.code(), Some(2));
    let result = json_result(&output);
    assert_eq!(result["error"]["code"], "wait_timeout");
    let paths = server.stop();
    assert!(!paths.is_empty());
    assert!(paths.iter().all(|path| !path.contains("cancel")));
}
