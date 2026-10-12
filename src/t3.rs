//! The service's own connection to the user's T3 server: a paired session
//! (orchestration read/operate, never the phone's) and the Effect RPC JSON
//! framing T3 0.0.45 speaks over its `/ws` socket, the same protocol as the
//! phone's `T3Gateway`.

use crate::store::{atomic_json, read_json};
use anyhow::{Context, Result, bail};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    path::Path,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::sync::{mpsc, oneshot, watch};
use tokio_tungstenite::tungstenite::Message;

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
            bail!("Squircle is not paired with T3. Run: squircle t3 connect --url http://127.0.0.1:3773 (reads a T3 pairing token on stdin)");
        }
        read_json(&path)
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
    let url = url.trim_end_matches('/').to_string();
    let parsed = url::Url::parse(&url).context("Invalid T3 URL")?;
    if !matches!(parsed.scheme(), "http" | "https") || parsed.path() != "/" && !parsed.path().is_empty() {
        bail!("T3 URL must be an origin such as http://127.0.0.1:3773");
    }
    let response = http_client()?
        .post(format!("{url}/oauth/token"))
        .form(&[
            ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange"),
            ("subject_token", pairing_token.trim()),
            ("subject_token_type", "urn:t3:params:oauth:token-type:environment-bootstrap"),
            ("requested_token_type", "urn:ietf:params:oauth:token-type:access_token"),
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
        bail!("T3 refused the pairing token (HTTP {status}): {}", body["error_description"].as_str().or(body["error"].as_str()).unwrap_or("no detail"));
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
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let secs = now.as_secs() as i64;
    let (days, rem) = (secs.div_euclid(86400), secs.rem_euclid(86400));
    // Civil date from days since 1970-01-01 (Howard Hinnant's algorithm).
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + if month <= 2 { 1 } else { 0 };
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60,
        now.subsec_millis()
    )
}

type Pending = Arc<Mutex<HashMap<String, oneshot::Sender<Result<Value>>>>>;
type Subscriptions = Arc<Mutex<HashMap<String, mpsc::UnboundedSender<Value>>>>;

/// One live socket. When it drops, every waiting call fails and every
/// subscription ends; the owner reconnects with a fresh client.
pub struct T3 {
    pub config: T3Config,
    out: mpsc::UnboundedSender<Message>,
    pending: Pending,
    subscriptions: Subscriptions,
    closed: watch::Receiver<bool>,
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
        let ticket = ticket["ticket"].as_str().context("T3 returned no WebSocket ticket")?;
        let mut ws = url::Url::parse(&config.url)?;
        ws.set_scheme(if ws.scheme() == "https" { "wss" } else { "ws" }).ok();
        ws.set_path("/ws");
        ws.query_pairs_mut().append_pair("wsTicket", ticket);
        let (socket, _) = tokio_tungstenite::connect_async(ws.as_str())
            .await
            .context("Cannot open T3's WebSocket")?;
        let (mut sink, mut stream) = socket.split();
        let (out, mut outgoing) = mpsc::unbounded_channel::<Message>();
        let pending: Pending = Arc::default();
        let subscriptions: Subscriptions = Arc::default();
        let (closed_tx, closed) = watch::channel(false);

        tokio::spawn(async move {
            while let Some(message) = outgoing.recv().await {
                if sink.send(message).await.is_err() {
                    break;
                }
            }
        });
        let heartbeat = out.clone();
        let mut heartbeat_closed = closed.clone();
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_secs(20)) => {}
                    _ = heartbeat_closed.changed() => return,
                }
                if heartbeat.send(Message::text(json!({"_tag":"Ping"}).to_string())).is_err() {
                    return;
                }
            }
        });
        let (reader_out, reader_pending, reader_subs) = (out.clone(), pending.clone(), subscriptions.clone());
        tokio::spawn(async move {
            while let Some(Ok(message)) = stream.next().await {
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
                    receive(&frame, &reader_out, &reader_pending, &reader_subs);
                }
            }
            let _ = closed_tx.send(true);
            for (_, waiter) in reader_pending.lock().unwrap().drain() {
                let _ = waiter.send(Err(anyhow::anyhow!("T3 connection closed")));
            }
            reader_subs.lock().unwrap().clear();
        });
        Ok(Arc::new(Self { config, out, pending, subscriptions, closed }))
    }

    fn request(&self, id: &str, tag: &str, payload: Value) -> Result<()> {
        let frame = json!({"_tag":"Request","id":id,"tag":tag,"payload":payload,"headers":[]});
        self.out
            .send(Message::text(frame.to_string()))
            .map_err(|_| anyhow::anyhow!("T3 connection closed"))
    }

    pub async fn call(&self, tag: &str, payload: Value) -> Result<Value> {
        let id = uuid::Uuid::new_v4().to_string();
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(id.clone(), tx);
        if let Err(error) = self.request(&id, tag, payload) {
            self.pending.lock().unwrap().remove(&id);
            return Err(error);
        }
        match tokio::time::timeout(Duration::from_secs(45), rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => bail!("T3 connection closed"),
            Err(_) => {
                self.pending.lock().unwrap().remove(&id);
                bail!("T3 did not answer {tag} within 45 seconds")
            }
        }
    }

    /// Chunks of a streaming RPC, in order, until the socket closes.
    pub fn subscribe(&self, tag: &str, payload: Value) -> Result<(String, mpsc::UnboundedReceiver<Value>)> {
        let id = uuid::Uuid::new_v4().to_string();
        let (tx, rx) = mpsc::unbounded_channel();
        self.subscriptions.lock().unwrap().insert(id.clone(), tx);
        self.request(&id, tag, payload)?;
        Ok((id, rx))
    }

    pub fn unsubscribe(&self, id: &str) {
        self.subscriptions.lock().unwrap().remove(id);
        let _ = self.out.send(Message::text(json!({"_tag":"Interrupt","requestId":id}).to_string()));
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

    /// An orchestration command; T3 assigns order and answers with its sequence.
    pub async fn dispatch(&self, mut command: Value) -> Result<Value> {
        command["commandId"] = json!(uuid::Uuid::new_v4().to_string());
        command["createdAt"] = json!(iso_now());
        let result = self.call("orchestration.dispatchCommand", command).await?;
        if result["status"] == "rejected" {
            bail!("T3 rejected the command: {result}");
        }
        Ok(result)
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

fn receive(frame: &Value, out: &mpsc::UnboundedSender<Message>, pending: &Pending, subscriptions: &Subscriptions) {
    let id = match &frame["requestId"] {
        Value::String(id) => id.clone(),
        Value::Number(n) => n.to_string(),
        _ => String::new(),
    };
    match frame["_tag"].as_str() {
        Some("Chunk") => {
            if let Some(sender) = subscriptions.lock().unwrap().get(&id) {
                for value in frame["values"].as_array().into_iter().flatten() {
                    let _ = sender.send(value.clone());
                }
            }
            let _ = out.send(Message::text(json!({"_tag":"Ack","requestId":id}).to_string()));
        }
        Some("Exit") => {
            subscriptions.lock().unwrap().remove(&id);
            if let Some(waiter) = pending.lock().unwrap().remove(&id) {
                let exit = &frame["exit"];
                let _ = waiter.send(if exit["_tag"] == "Success" {
                    Ok(exit["value"].clone())
                } else {
                    let cause = exit["cause"].to_string();
                    Err(anyhow::anyhow!("T3 rejected the request: {}", &cause[..cause.len().min(700)]))
                });
            }
        }
        Some("Ping") => {
            let _ = out.send(Message::text(json!({"_tag":"Pong"}).to_string()));
        }
        _ => {}
    }
}
