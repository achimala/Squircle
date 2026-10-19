//! The service's own connection to the user's T3 server: a paired session
//! (orchestration read/operate, never the phone's) and the Effect RPC JSON
//! framing T3 speaks over its `/ws` socket. Since T3 0.1.0 the socket only
//! opens for a client that declares orchestration protocol 2
//! (`?orchestrationProtocol=2`); anything else gets HTTP 426.

use crate::fsm::coordinator::{Command, Dispatched};
use crate::store::{atomic_json, read_json};
use anyhow::{Context, Result, bail};
use futures_util::{Sink, SinkExt, Stream, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{collections::HashMap, path::Path, sync::Arc, time::Duration};
use tokio::sync::{mpsc, oneshot, watch};
use tokio_tungstenite::tungstenite::Message;
use tokio_util::sync::CancellationToken;

/// `<data dir>/t3.json`: where T3 is and the service's paired session.
#[derive(Clone, Serialize, Deserialize)]
pub struct T3Config {
    pub url: String,
    pub token: String,
    /// Unix seconds; T3 sessions expire and must be paired again.
    pub expires_at: Option<u64>,
}

impl T3Config {
    pub fn load(root: &Path) -> Result<Self> {
        let path = root.join("t3.json");
        if !path.try_exists()? {
            bail!(
                "Squircle is not paired with T3. Run: squircle t3 connect --url http://127.0.0.1:3773 (reads a T3 pairing token on stdin)"
            );
        }
        let config: Self = read_json(&path)?;
        crate::origin::credential_origin(&config.url, "T3 URL in t3.json")?;
        Ok(config)
    }
}

fn http_client() -> Result<reqwest::Client> {
    Ok(reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(30))
        .build()?)
}

/// Exchanges a one-time T3 pairing token for a session scoped to orchestration
/// read/operate, and saves it privately.
pub async fn pair(root: &Path, url: &str, pairing_token: &str) -> Result<T3Config> {
    let url = crate::origin::credential_origin(url, "T3 URL")?;
    let response = http_client()?
        .post(format!("{url}/oauth/token"))
        .form(&[
            (
                "grant_type",
                "urn:ietf:params:oauth:grant-type:token-exchange",
            ),
            ("subject_token", pairing_token.trim()),
            (
                "subject_token_type",
                "urn:t3:params:oauth:token-type:environment-bootstrap",
            ),
            (
                "requested_token_type",
                "urn:ietf:params:oauth:token-type:access_token",
            ),
            ("scope", "orchestration:read orchestration:operate"),
            ("client_label", "Squircle service"),
            ("client_device_type", "desktop"),
        ])
        .send()
        .await
        .context("Cannot reach T3")?;
    let status = response.status();
    let body: Value = response.json().await.context("T3 did not return JSON")?;
    let Some(token) = body["access_token"].as_str() else {
        bail!(
            "T3 refused the pairing token (HTTP {status}): {}",
            body["error_description"]
                .as_str()
                .or(body["error"].as_str())
                .unwrap_or("no detail")
        );
    };
    let config = T3Config {
        url,
        token: token.to_string(),
        expires_at: body["expires_in"].as_u64().map(|s| crate::model::now() + s),
    };
    atomic_json(&root.join("t3.json"), &config)?;
    Ok(config)
}

/// ISO 8601 UTC with milliseconds, as T3 commands expect.
pub fn iso_now() -> String {
    time::OffsetDateTime::now_utc()
        .format(time::macros::format_description!(
            "[year]-[month]-[day]T[hour]:[minute]:[second].[subsecond digits:3]Z"
        ))
        .unwrap_or_default()
}

/// `YYYY-MM-DDTHH:MM:SS` (UTC) for Unix seconds.
pub fn iso_utc(secs: i64) -> String {
    time::OffsetDateTime::from_unix_timestamp(secs)
        .unwrap_or(time::OffsetDateTime::UNIX_EPOCH)
        .format(time::macros::format_description!(
            "[year]-[month]-[day]T[hour]:[minute]:[second]"
        ))
        .unwrap_or_default()
}

/// An RFC 3339 time as T3 writes it (`2026-10-14T22:23:14.016Z`) as Unix
/// seconds; `None` for anything that isn't a real date and time.
pub fn iso_parse(text: &str) -> Option<f64> {
    let at =
        time::OffsetDateTime::parse(text, &time::format_description::well_known::Rfc3339).ok()?;
    Some(at.unix_timestamp_nanos() as f64 / 1e9)
}

/// How a request ended that did not succeed.
enum Ended {
    /// T3 answered with a failure; the cause, as T3 sent it.
    Failed(Value),
    /// The connection closed before an answer.
    Closed,
}

type Waiter = oneshot::Sender<Result<Value, Ended>>;

/// What one request got, as far as this connection can tell.
enum Reply {
    Answered(Result<Value, Value>),
    /// The frame never left: the connection was closed or stopped draining.
    NotSent(anyhow::Error),
    /// It went out (or may have), and no answer will come: the connection
    /// closed, or the caller's budget ran out.
    Lost(String),
}

/// The caller's budget for one request. Running out of it says nothing
/// about what T3 did.
const CALL_BUDGET: Duration = Duration::from_secs(45);

/// How long the connection may take or stay quiet before it counts as dead.
#[derive(Clone, Copy)]
struct Timing {
    /// A Ping goes out this often.
    heartbeat: Duration,
    /// Nothing heard from T3 for this long (not even a Pong) closes the socket.
    silence: Duration,
    /// One frame that cannot be written within this closes the socket.
    write: Duration,
}

const TIMING: Timing = Timing {
    heartbeat: Duration::from_secs(20),
    silence: Duration::from_secs(45),
    write: Duration::from_secs(10),
};
/// The orchestration protocol this client speaks (T3 0.1.0's "V2": runs,
/// runtime requests and turn items instead of 0.0.45's turns and activities).
pub const ORCHESTRATION_PROTOCOL: &str = "2";
const OPEN_TIMEOUT: Duration = Duration::from_secs(15);
/// Frames waiting for the socket. A full queue means the writer is stuck, so
/// the connection is closed rather than allowed to grow without bound.
const OUTBOX: usize = 1024;
const ERROR_DETAIL: usize = 700;

/// What a client hands the connection task, in order. A call's waiter
/// travels with its request, so its answer can't arrive before it.
enum Outbound {
    Frame(Message),
    Call {
        id: String,
        waiter: Waiter,
        frame: Message,
    },
    Subscribe {
        id: String,
        chunks: mpsc::UnboundedSender<Value>,
        frame: Message,
    },
    /// A call that ended without its answer (out of budget, or dropped).
    Forget(String),
    Unsubscribe(String),
    /// How many calls and subscriptions the task holds, for tests.
    #[cfg(test)]
    Count(oneshot::Sender<(usize, usize)>),
}

/// What the connection task and its client share: its queue and its stop.
/// The calls waiting for answers and the open subscriptions are the task's alone.
struct Link {
    out: mpsc::Sender<Outbound>,
    stop: CancellationToken,
}

impl Link {
    fn send(&self, outbound: Outbound) -> Result<()> {
        match self.out.try_send(outbound) {
            Ok(()) => Ok(()),
            Err(mpsc::error::TrySendError::Full(_)) => {
                self.stop.cancel();
                bail!("T3 connection stopped draining")
            }
            Err(mpsc::error::TrySendError::Closed(_)) => bail!("T3 connection closed"),
        }
    }
}

/// One live socket, owned by a single task that reads, writes and sends
/// heartbeats. When the socket fails, goes quiet or the last `Arc<T3>` drops,
/// that task ends: every waiting call fails and every subscription ends; the
/// owner reconnects with a fresh client.
pub struct T3 {
    pub config: T3Config,
    link: Arc<Link>,
    closed: watch::Receiver<bool>,
}

impl Drop for T3 {
    fn drop(&mut self) {
        self.link.stop.cancel();
    }
}

/// Tells the connection task to forget a call's waiter however the call
/// ends (answer, budget, or the caller dropping the future). It only queues.
struct PendingGuard<'a> {
    link: &'a Link,
    id: &'a str,
}

impl Drop for PendingGuard<'_> {
    fn drop(&mut self) {
        // A full queue stops the connection anyway, and with it every waiter.
        let _ = self
            .link
            .out
            .try_send(Outbound::Forget(self.id.to_string()));
    }
}

impl T3 {
    pub async fn connect(config: T3Config) -> Result<Arc<Self>> {
        let http = http_client()?;
        let ticket: Value = http
            .post(format!("{}/api/auth/websocket-ticket", config.url))
            .bearer_auth(&config.token)
            .json(&json!({}))
            .send()
            .await
            .context("Cannot reach T3")?
            .error_for_status()
            .context("T3 rejected Squircle's session; pair again with squircle t3 connect")?
            .json()
            .await?;
        let ticket = ticket["ticket"]
            .as_str()
            .context("T3 returned no WebSocket ticket")?;
        let mut ws = url::Url::parse(&config.url)?;
        ws.set_scheme(if ws.scheme() == "https" { "wss" } else { "ws" })
            .ok();
        ws.set_path("/ws");
        ws.query_pairs_mut()
            .append_pair("wsTicket", ticket)
            .append_pair("orchestrationProtocol", ORCHESTRATION_PROTOCOL);
        let (socket, _) =
            tokio::time::timeout(OPEN_TIMEOUT, tokio_tungstenite::connect_async(ws.as_str()))
                .await
                .context("T3's WebSocket did not open within 15 seconds")?
                .context("Cannot open T3's WebSocket")?;
        let (sink, stream) = socket.split();
        Ok(Self::start(config, sink, stream, TIMING))
    }

    fn start<W, R, E>(config: T3Config, sink: W, stream: R, timing: Timing) -> Arc<Self>
    where
        W: Sink<Message> + Unpin + Send + 'static,
        W::Error: Send,
        R: Stream<Item = Result<Message, E>> + Unpin + Send + 'static,
        E: Send + 'static,
    {
        let (out, outgoing) = mpsc::channel(OUTBOX);
        let link = Arc::new(Link {
            out,
            stop: CancellationToken::new(),
        });
        let (closed_tx, closed) = watch::channel(false);
        tokio::spawn(run(link.clone(), sink, stream, outgoing, closed_tx, timing));
        Arc::new(Self {
            config,
            link,
            closed,
        })
    }

    fn request(id: &str, tag: &str, payload: Value) -> Message {
        Message::text(
            json!({"_tag":"Request","id":id,"tag":tag,"payload":payload,"headers":[]}).to_string(),
        )
    }

    async fn exchange(&self, tag: &str, payload: Value) -> Reply {
        let id = uuid::Uuid::new_v4().to_string();
        let (waiter, rx) = oneshot::channel();
        let _guard = PendingGuard {
            link: &self.link,
            id: &id,
        };
        if let Err(error) = self.link.send(Outbound::Call {
            id: id.clone(),
            waiter,
            frame: Self::request(&id, tag, payload),
        }) {
            return Reply::NotSent(error);
        }
        match tokio::time::timeout(CALL_BUDGET, rx).await {
            Ok(Ok(Ok(value))) => Reply::Answered(Ok(value)),
            Ok(Ok(Err(Ended::Failed(cause)))) => Reply::Answered(Err(cause)),
            Ok(Ok(Err(Ended::Closed)) | Err(_)) => Reply::Lost("T3 connection closed".into()),
            Err(_) => Reply::Lost(format!(
                "T3 did not answer {tag} within {} seconds",
                CALL_BUDGET.as_secs()
            )),
        }
    }

    pub async fn call(&self, tag: &str, payload: Value) -> Result<Value> {
        match self.exchange(tag, payload).await {
            Reply::Answered(Ok(value)) => Ok(value),
            Reply::Answered(Err(cause)) => bail!(
                "T3 rejected the request: {}",
                clip(&cause.to_string(), ERROR_DETAIL)
            ),
            Reply::NotSent(error) => Err(error),
            Reply::Lost(detail) => bail!(detail),
        }
    }

    /// Chunks of a streaming RPC, in order, until the socket closes. Dropping
    /// the receiver interrupts the stream at its next chunk.
    pub fn subscribe(
        &self,
        tag: &str,
        payload: Value,
    ) -> Result<(String, mpsc::UnboundedReceiver<Value>)> {
        let id = uuid::Uuid::new_v4().to_string();
        let (chunks, rx) = mpsc::unbounded_channel();
        self.link.send(Outbound::Subscribe {
            id: id.clone(),
            chunks,
            frame: Self::request(&id, tag, payload),
        })?;
        Ok((id, rx))
    }

    pub fn unsubscribe(&self, id: &str) {
        let _ = self.link.send(Outbound::Unsubscribe(id.to_string()));
    }

    /// The first chunk of a subscription (T3 sends a snapshot first).
    pub async fn snapshot(&self, tag: &str, payload: Value) -> Result<Value> {
        let (id, mut rx) = self.subscribe(tag, payload)?;
        let first = tokio::time::timeout(Duration::from_secs(30), rx.recv()).await;
        self.unsubscribe(&id);
        match first {
            Ok(Some(value)) => Ok(value),
            Ok(None) => bail!("T3 closed {tag} before sending a snapshot"),
            Err(_) => bail!("T3 sent no snapshot for {tag} within 30 seconds"),
        }
    }

    /// An orchestration command, sent exactly as given: its identity was
    /// fixed when its intent was made. T3 assigns order and answers with its
    /// sequence; an attempt whose answer is lost is `Unknown`, never refused.
    pub async fn dispatch(&self, command: &Command) -> Dispatched {
        if command.id().is_none() || !command.body()["createdAt"].is_string() {
            return Dispatched::NotSent("A T3 command needs its commandId and createdAt".into());
        }
        match self
            .exchange(command.method(), command.body().clone())
            .await
        {
            Reply::Answered(Ok(result)) if result["status"] == "rejected" => {
                Dispatched::Refused(format!("T3 rejected the command: {result}"))
            }
            Reply::Answered(Ok(result)) => Dispatched::Accepted(result),
            Reply::Answered(Err(cause)) => {
                let detail = format!(
                    "T3 rejected the command: {}",
                    clip(&cause.to_string(), ERROR_DETAIL)
                );
                if refused(&cause) {
                    Dispatched::Refused(detail)
                } else {
                    Dispatched::Unknown(detail)
                }
            }
            Reply::NotSent(error) => Dispatched::NotSent(format!("{error:#}")),
            Reply::Lost(detail) => Dispatched::Unknown(detail),
        }
    }

    pub async fn closed(&self) {
        let mut closed = self.closed.clone();
        while !*closed.borrow() {
            if closed.changed().await.is_err() {
                return;
            }
        }
    }
}

/// Whether a failed dispatch provably did nothing. T3 commits a command's
/// events and its receipt in one transaction and answers every failure of
/// its own with a typed error; it reports defects and interruptions (say,
/// while it shuts down, when a queued command may still run) only as an
/// `InternalError`. So only a typed failure is a refusal.
fn refused(cause: &Value) -> bool {
    let reasons = match cause {
        Value::Array(reasons) => reasons.as_slice(),
        reason => std::slice::from_ref(reason),
    };
    reasons.iter().any(|reason| {
        reason["_tag"] == "Fail"
            && reason["error"]["_tag"]
                .as_str()
                .is_some_and(|tag| tag != "InternalError")
    })
}

fn interrupt(id: &str) -> Message {
    Message::text(json!({"_tag":"Interrupt","requestId":id}).to_string())
}

/// The connection's whole lifetime: reads, writes and heartbeats in one task,
/// so a failure of either half, silence or cancellation ends all of it.
async fn run<W, R, E>(
    link: Arc<Link>,
    mut sink: W,
    mut stream: R,
    mut outgoing: mpsc::Receiver<Outbound>,
    closed: watch::Sender<bool>,
    timing: Timing,
) where
    W: Sink<Message> + Unpin,
    R: Stream<Item = Result<Message, E>> + Unpin,
{
    let start = tokio::time::Instant::now();
    let mut heartbeat = tokio::time::interval_at(start + timing.heartbeat, timing.heartbeat);
    let mut heard = start;
    let mut open = Open::default();
    loop {
        tokio::select! {
            _ = link.stop.cancelled() => {
                let _ = tokio::time::timeout(timing.write, sink.send(Message::Close(None))).await;
                break;
            }
            Some(outbound) = outgoing.recv() => {
                let Some(message) = open.take(outbound) else { continue };
                if !matches!(tokio::time::timeout(timing.write, sink.send(message)).await, Ok(Ok(()))) {
                    break;
                }
            }
            _ = heartbeat.tick() => {
                if heard.elapsed() >= timing.silence {
                    break;
                }
                let ping = Message::text(json!({"_tag":"Ping"}).to_string());
                if !matches!(tokio::time::timeout(timing.write, sink.send(ping)).await, Ok(Ok(()))) {
                    break;
                }
            }
            incoming = stream.next() => {
                let Some(Ok(message)) = incoming else { break };
                heard = tokio::time::Instant::now();
                let text = match message {
                    Message::Text(text) => text.to_string(),
                    Message::Binary(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
                    Message::Close(_) => break,
                    _ => continue,
                };
                let Ok(frame) = serde_json::from_str::<Value>(&text) else { continue };
                let frames = match frame {
                    Value::Array(items) => items,
                    other => vec![other],
                };
                for frame in frames {
                    open.receive(&frame, &link);
                }
            }
        }
    }
    link.stop.cancel();
    // Close the queue first: a call that registers after the drain below
    // then fails to send instead of waiting for an answer that cannot come.
    drop(outgoing);
    let _ = closed.send(true);
    for (_, waiter) in open.pending.drain() {
        let _ = waiter.send(Err(Ended::Closed));
    }
}

/// The calls waiting for answers and the open subscriptions: the
/// connection task's own.
#[derive(Default)]
struct Open {
    pending: HashMap<String, Waiter>,
    subscriptions: HashMap<String, mpsc::UnboundedSender<Value>>,
}

impl Open {
    /// Records what `outbound` registers; the frame it sends, if any.
    fn take(&mut self, outbound: Outbound) -> Option<Message> {
        match outbound {
            Outbound::Frame(message) => Some(message),
            Outbound::Call { id, waiter, frame } => {
                self.pending.insert(id, waiter);
                Some(frame)
            }
            Outbound::Subscribe { id, chunks, frame } => {
                self.subscriptions.insert(id, chunks);
                Some(frame)
            }
            Outbound::Forget(id) => {
                self.pending.remove(&id);
                None
            }
            Outbound::Unsubscribe(id) => self.subscriptions.remove(&id).map(|_| interrupt(&id)),
            #[cfg(test)]
            Outbound::Count(reply) => {
                let _ = reply.send((self.pending.len(), self.subscriptions.len()));
                None
            }
        }
    }

    fn receive(&mut self, frame: &Value, link: &Link) {
        let id = match &frame["requestId"] {
            Value::String(id) => id.clone(),
            Value::Number(n) => n.to_string(),
            _ => String::new(),
        };
        let reply = |message: Message| {
            let _ = link.send(Outbound::Frame(message));
        };
        match frame["_tag"].as_str() {
            Some("Chunk") => {
                if let Some(sender) = self.subscriptions.get(&id) {
                    let gone = frame["values"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .any(|value| sender.send(value.clone()).is_err());
                    if gone {
                        self.subscriptions.remove(&id);
                        reply(interrupt(&id));
                        return;
                    }
                }
                reply(Message::text(
                    json!({"_tag":"Ack","requestId":id}).to_string(),
                ));
            }
            Some("Exit") => {
                self.subscriptions.remove(&id);
                if let Some(waiter) = self.pending.remove(&id) {
                    let exit = &frame["exit"];
                    let _ = waiter.send(if exit["_tag"] == "Success" {
                        Ok(exit["value"].clone())
                    } else {
                        Err(Ended::Failed(exit["cause"].clone()))
                    });
                }
            }
            Some("Ping") => reply(Message::text(json!({"_tag":"Pong"}).to_string())),
            _ => {}
        }
    }
}

/// The longest prefix of `text` within `max` bytes that ends on a character.
fn clip(text: &str, max: usize) -> &str {
    let mut end = text.len().min(max);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::DuplexStream;
    use tokio_tungstenite::WebSocketStream;

    const FAST: Timing = Timing {
        heartbeat: Duration::from_millis(40),
        silence: Duration::from_millis(100),
        write: Duration::from_millis(100),
    };

    #[test]
    fn iso_times_round_trip_and_reject_impossible_dates() {
        assert_eq!(
            iso_parse("2026-10-14T22:23:14.016Z").map(|s| s.round()),
            Some(1_792_016_594.0)
        );
        assert_eq!(
            iso_parse("2026-10-15T00:23:14+02:00").map(|s| s as i64),
            Some(1_792_016_594)
        );
        assert_eq!(iso_utc(1_792_016_594), "2026-10-14T22:23:14");
        assert_eq!(iso_parse("2026-02-30T00:00:00Z"), None);
        assert_eq!(iso_parse("2026-13-01T00:00:00Z"), None);
    }

    fn config() -> T3Config {
        T3Config {
            url: "http://t3.test".into(),
            token: String::new(),
            expires_at: None,
        }
    }

    /// A client wired to an in-memory WebSocket peer the test controls.
    async fn peer(timing: Timing) -> (Arc<T3>, WebSocketStream<DuplexStream>) {
        let (client_io, server_io) = tokio::io::duplex(1 << 16);
        let (client, server) = tokio::join!(
            tokio_tungstenite::client_async("ws://t3.test/ws", client_io),
            tokio_tungstenite::accept_async(server_io),
        );
        let (sink, stream) = client.unwrap().0.split();
        (T3::start(config(), sink, stream, timing), server.unwrap())
    }

    async fn next_request(server: &mut WebSocketStream<DuplexStream>) -> Value {
        loop {
            let Message::Text(text) = server.next().await.unwrap().unwrap() else {
                continue;
            };
            let frame: Value = serde_json::from_str(&text).unwrap();
            if frame["_tag"] == "Request" {
                return frame;
            }
        }
    }

    #[tokio::test]
    async fn multibyte_error_past_the_limit_fails_one_call_only() {
        let (client, mut server) = peer(TIMING).await;
        let answers = tokio::spawn(async move {
            let first = next_request(&mut server).await;
            let cause = json!({"_tag":"Die","message":"é".repeat(400)});
            let exit = json!({"_tag":"Exit","requestId":first["id"],"exit":{"_tag":"Failure","cause":cause}});
            server.send(Message::text(exit.to_string())).await.unwrap();
            let second = next_request(&mut server).await;
            let exit =
                json!({"_tag":"Exit","requestId":second["id"],"exit":{"_tag":"Success","value":7}});
            server.send(Message::text(exit.to_string())).await.unwrap();
            server
        });
        let error = client.call("a", json!({})).await.unwrap_err().to_string();
        assert!(error.starts_with("T3 rejected the request"), "{error}");
        assert_eq!(client.call("b", json!({})).await.unwrap(), json!(7));
        drop(answers.await.unwrap());
    }

    #[tokio::test]
    async fn a_dispatch_keeps_its_identity_and_only_a_typed_failure_is_a_refusal() {
        use crate::fsm::coordinator::Identity;
        use crate::fsm::core::CommandID;
        let (client, mut server) = peer(TIMING).await;
        let identity = Identity {
            id: CommandID::fresh(),
            created_at: "2026-10-16T00:00:00.000Z".into(),
        };
        let command = Command::new(&identity, json!({"type": "thread.turn.start"}));
        let answers = tokio::spawn(async move {
            let fail = |error: Value| json!([{"_tag": "Fail", "error": error}]);
            for cause in [
                fail(json!({"_tag": "OrchestrationDispatchCommandError", "message": "no"})),
                fail(json!({"_tag": "InternalError"})),
            ] {
                let request = next_request(&mut server).await;
                assert_eq!(
                    (
                        request["payload"]["commandId"].as_str(),
                        request["payload"]["createdAt"].as_str()
                    ),
                    (Some(identity.id.as_str()), Some("2026-10-16T00:00:00.000Z"))
                );
                let exit = json!({"_tag":"Exit","requestId":request["id"],"exit":{"_tag":"Failure","cause":cause}});
                server.send(Message::text(exit.to_string())).await.unwrap();
            }
            // Sent, then the connection drops before an answer.
            next_request(&mut server).await;
        });
        assert!(matches!(
            client.dispatch(&command).await,
            Dispatched::Refused(_)
        ));
        assert!(matches!(
            client.dispatch(&command).await,
            Dispatched::Unknown(_)
        ));
        let dropped = client.dispatch(&command);
        let (outcome, _) = tokio::join!(dropped, answers);
        assert!(matches!(outcome, Dispatched::Unknown(_)), "{outcome:?}");
        assert!(matches!(
            client.dispatch(&command).await,
            Dispatched::NotSent(_)
        ));
    }

    /// The dispatch answers shared with the app's tests: each means the
    /// same there and here.
    #[tokio::test]
    async fn dispatch_exits_mean_what_the_shared_fixtures_say() {
        use crate::fsm::coordinator::Identity;
        use crate::fsm::core::CommandID;
        let fixture: Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/t3/dispatch-exits.json"
        )))
        .unwrap();
        let cases = fixture["cases"].as_array().unwrap().clone();
        assert!(!cases.is_empty());
        let (client, mut server) = peer(TIMING).await;
        let exits: Vec<Value> = cases.iter().map(|c| c["exit"].clone()).collect();
        let answers = tokio::spawn(async move {
            for exit in exits {
                let request = next_request(&mut server).await;
                let frame = json!({"_tag":"Exit","requestId":request["id"],"exit":exit});
                server.send(Message::text(frame.to_string())).await.unwrap();
            }
            server
        });
        for case in &cases {
            let identity = Identity {
                id: CommandID::fresh(),
                created_at: "2026-10-18T00:00:00.000Z".into(),
            };
            let command = Command::new(&identity, json!({"type": "thread.turn.start"}));
            let outcome = match client.dispatch(&command).await {
                Dispatched::Accepted(value) if value == case["exit"]["value"] => "accepted",
                Dispatched::Accepted(_) => "accepted with another value",
                Dispatched::Refused(_) => "refused",
                Dispatched::Unknown(_) => "unknown",
                Dispatched::NotSent(_) => "not sent",
            };
            assert_eq!(Some(outcome), case["outcome"].as_str(), "{}", case["name"]);
        }
        answers.await.unwrap();
    }

    #[tokio::test]
    async fn silent_peer_closes_the_connection_and_fails_calls() {
        let (client, server) = peer(FAST).await;
        let error = tokio::time::timeout(Duration::from_secs(2), client.call("a", json!({})))
            .await
            .unwrap();
        assert_eq!(error.unwrap_err().to_string(), "T3 connection closed");
        tokio::time::timeout(Duration::from_secs(1), client.closed())
            .await
            .unwrap();
        drop(server);
    }

    #[tokio::test]
    async fn write_failure_closes_the_connection() {
        let sink = Box::pin(futures_util::sink::unfold((), |_, _: Message| async {
            Err::<(), _>(std::io::Error::other("broken pipe"))
        }));
        let stream = futures_util::stream::pending::<Result<Message, std::io::Error>>();
        let client = T3::start(config(), sink, stream, TIMING);
        let result = tokio::time::timeout(Duration::from_secs(1), client.call("a", json!({})))
            .await
            .unwrap();
        assert!(result.is_err());
        tokio::time::timeout(Duration::from_secs(1), client.closed())
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn dropping_the_client_closes_the_socket() {
        let (client, mut server) = peer(TIMING).await;
        drop(client);
        let ended = tokio::time::timeout(Duration::from_secs(1), async {
            while let Some(Ok(message)) = server.next().await {
                if message.is_close() {
                    break;
                }
            }
        });
        ended.await.unwrap();
    }

    #[tokio::test]
    async fn abandoned_call_forgets_its_waiter() {
        let (client, server) = peer(TIMING).await;
        assert!(
            tokio::time::timeout(Duration::from_millis(20), client.call("a", json!({})))
                .await
                .is_err()
        );
        let (reply, count) = oneshot::channel();
        client.link.send(Outbound::Count(reply)).unwrap();
        assert_eq!(count.await.unwrap(), (0, 0));
        drop(server);
    }
}
