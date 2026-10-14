//! Notifications and the Live Activity on the phone. The service decides what
//! to say (`Push`) and hands each message to a `Transport`. Today that is
//! `Apns`: Apple's HTTP/2 API, signed with the user's own APNs auth key
//! (`squircle push setup`). A relay for App Store builds would be another
//! `Transport`; the phone's contract (registration endpoints, the `squircle`
//! payload key, the activity's content state) stays the same.

use crate::store::{atomic_json, private_dir, read_json};
use anyhow::{Context, Result, bail, ensure};
use base64::Engine;
use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap},
    future::Future,
    path::{Path, PathBuf},
    pin::Pin,
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime},
};

/// The Swift type name of the activity's attributes (`attributes-type`).
pub const ACTIVITY_TYPE: &str = "SquircleActivityAttributes";
const SANDBOX: &str = "https://api.sandbox.push.apple.com";
const PRODUCTION: &str = "https://api.push.apple.com";
/// Events this close together arrive as one notification.
const COALESCE: Duration = Duration::from_secs(3);
/// A phone's report that it shows a thread counts for this long.
const PRESENCE: Duration = Duration::from_secs(300);

// MARK: Key

/// `<data dir>/push/apns.json` (0600): the user's APNs auth key. The key never
/// appears in output or logs.
#[derive(Clone, Serialize, Deserialize)]
pub struct KeyConfig {
    pub key_id: String,
    pub team_id: String,
    pub key_pem: String,
}

fn key_path(root: &Path) -> PathBuf {
    root.join("push").join("apns.json")
}

impl KeyConfig {
    pub fn load(root: &Path) -> Result<Option<Self>> {
        let path = key_path(root);
        if !path.try_exists()? {
            return Ok(None);
        }
        read_json(&path).map(Some)
    }
}

fn valid_apple_id(id: &str) -> bool {
    id.len() == 10 && id.chars().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
}

/// Validates and stores the key; `squircle push setup`.
pub fn setup(root: &Path, key_file: Option<&Path>, key_id: Option<&str>, team_id: Option<&str>, remove: bool) -> Result<Value> {
    let path = key_path(root);
    if remove {
        if path.try_exists()? {
            std::fs::remove_file(&path)?;
        }
        return Ok(json!({"configured": false}));
    }
    let (Some(key_file), Some(key_id), Some(team_id)) = (key_file, key_id, team_id) else {
        bail!("Pass --key-file, --key-id and --team-id (or --remove)");
    };
    ensure!(valid_apple_id(key_id), "The key ID is the 10-character ID shown with the key (e.g. AB12CD34EF)");
    ensure!(valid_apple_id(team_id), "The team ID is the 10-character ID under Membership (e.g. 2F26US4NAU)");
    let pem = std::fs::read_to_string(key_file).with_context(|| format!("Cannot read {}", key_file.display()))?;
    let config = KeyConfig { key_id: key_id.into(), team_id: team_id.into(), key_pem: pem.trim().to_string() };
    Signer::new(&config).context("Not an APNs auth key (.p8)")?;
    private_dir(&root.join("push"))?;
    atomic_json(&path, &config)?;
    Ok(json!({"configured": true, "key_id": key_id, "team_id": team_id,
        "next": "The running service picks the key up on its next push. Send one: squircle push test"}))
}

fn pem_der(pem: &str) -> Result<Vec<u8>> {
    let body: String = pem.lines().filter(|l| !l.starts_with("-----")).map(str::trim).collect();
    ensure!(pem.contains("BEGIN PRIVATE KEY"), "expected a PKCS#8 PEM private key");
    Ok(base64::engine::general_purpose::STANDARD.decode(body)?)
}

fn b64url(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

/// Signs APNs provider tokens (ES256 JWT). Apple accepts a token for an hour
/// and rejects refreshing more than every 20 minutes, so one is reused for 40.
pub struct Signer {
    key: EcdsaKeyPair,
    key_id: String,
    team_id: String,
    cached: Mutex<Option<(u64, String)>>,
}

impl Signer {
    pub fn new(config: &KeyConfig) -> Result<Self> {
        let der = pem_der(&config.key_pem)?;
        let key = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &der, &ring::rand::SystemRandom::new())
            .map_err(|e| anyhow::anyhow!("invalid P-256 key: {e}"))?;
        Ok(Self { key, key_id: config.key_id.clone(), team_id: config.team_id.clone(), cached: Mutex::default() })
    }

    pub fn jwt(&self, issued_at: u64) -> Result<String> {
        let header = b64url(json!({"alg": "ES256", "kid": self.key_id}).to_string().as_bytes());
        let claims = b64url(json!({"iss": self.team_id, "iat": issued_at}).to_string().as_bytes());
        let input = format!("{header}.{claims}");
        let signature = self.key.sign(&ring::rand::SystemRandom::new(), input.as_bytes())
            .map_err(|_| anyhow::anyhow!("signing failed"))?;
        Ok(format!("{input}.{}", b64url(signature.as_ref())))
    }

    fn token(&self, refresh: bool) -> Result<String> {
        let now = crate::model::now();
        let mut cached = self.cached.lock().unwrap();
        if let Some((at, token)) = cached.as_ref()
            && !refresh && now < at + 40 * 60
        {
            return Ok(token.clone());
        }
        let token = self.jwt(now)?;
        *cached = Some((now, token.clone()));
        Ok(token)
    }

    pub fn public_key(&self) -> &[u8] {
        ring::signature::KeyPair::public_key(&self.key).as_ref()
    }
}

// MARK: Transport

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Environment {
    /// Xcode-run and development-signed builds (APNs sandbox).
    #[default]
    Development,
    /// Ad hoc, TestFlight and App Store builds.
    Production,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PushType {
    Alert,
    LiveActivity,
}

/// One message for one token, independent of how it reaches Apple.
#[derive(Clone, Debug)]
pub struct Delivery {
    pub token: String,
    pub environment: Environment,
    /// The app's bundle ID; Live Activity pushes add `.push-type.liveactivity`.
    pub bundle_id: String,
    pub push_type: PushType,
    /// 10 now, 5 when power allows (Live Activity updates at 5 do not count
    /// against the phone's update budget).
    pub priority: u8,
    pub collapse_id: Option<String>,
    pub payload: Value,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Sent,
    /// The token is no longer valid; forget it.
    Unregistered,
    Rejected(String),
}

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

pub trait Transport: Send + Sync {
    fn send<'a>(&'a self, delivery: &'a Delivery) -> BoxFuture<'a, Result<Outcome>>;
}

/// Apple's push service, directly, with the user's key.
pub struct Apns {
    signer: Signer,
    client: reqwest::Client,
    sandbox: String,
    production: String,
}

impl Apns {
    pub fn new(config: &KeyConfig) -> Result<Self> {
        Self::with_hosts(config, SANDBOX, PRODUCTION)
    }

    /// Other hosts, for a local fake (`http://` speaks HTTP/2 without TLS).
    pub fn with_hosts(config: &KeyConfig, sandbox: &str, production: &str) -> Result<Self> {
        let mut builder = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(20));
        if sandbox.starts_with("http://") {
            builder = builder.http2_prior_knowledge();
        }
        Ok(Self { signer: Signer::new(config)?, client: builder.build()?, sandbox: sandbox.into(), production: production.into() })
    }

    async fn post(&self, delivery: &Delivery, refresh: bool) -> Result<(u16, String)> {
        let host = match delivery.environment { Environment::Development => &self.sandbox, Environment::Production => &self.production };
        let (kind, topic) = match delivery.push_type {
            PushType::Alert => ("alert", delivery.bundle_id.clone()),
            PushType::LiveActivity => ("liveactivity", format!("{}.push-type.liveactivity", delivery.bundle_id)),
        };
        let mut request = self.client.post(format!("{host}/3/device/{}", delivery.token))
            .bearer_auth(self.signer.token(refresh)?)
            .header("apns-topic", topic)
            .header("apns-push-type", kind)
            .header("apns-priority", delivery.priority.to_string())
            .json(&delivery.payload);
        if let Some(id) = &delivery.collapse_id {
            request = request.header("apns-collapse-id", id);
        }
        let response = request.send().await.context("Cannot reach APNs")?;
        let status = response.status().as_u16();
        let body: Value = response.json().await.unwrap_or(Value::Null);
        Ok((status, body["reason"].as_str().unwrap_or("").to_string()))
    }
}

impl Transport for Apns {
    fn send<'a>(&'a self, delivery: &'a Delivery) -> BoxFuture<'a, Result<Outcome>> {
        Box::pin(async move {
            let (mut status, mut reason) = self.post(delivery, false).await?;
            if status == 403 && reason == "ExpiredProviderToken" {
                (status, reason) = self.post(delivery, true).await?;
            }
            Ok(match (status, reason.as_str()) {
                (200, _) => Outcome::Sent,
                (410, _) | (400, "BadDeviceToken" | "DeviceTokenNotForTopic") => Outcome::Unregistered,
                (_, reason) => Outcome::Rejected(format!("HTTP {status} {reason}").trim().to_string()),
            })
        })
    }
}

// MARK: Payloads

/// What a notification opens on the phone.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Target {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thread: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub build: Option<String>,
    /// The built app's bundle ID, to find its app on the phone.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bundle: Option<String>,
}

#[derive(Clone, Debug)]
pub struct Note {
    pub app: String,
    pub line: String,
    pub target: Target,
}

/// One alert for a burst of notes about one app: its name, then the lines.
pub fn alert_payload(notes: &[&Note]) -> Value {
    let first = notes[0];
    let mut lines: Vec<&str> = notes.iter().map(|n| n.line.as_str()).collect();
    lines.dedup();
    let body = if lines.len() > 4 {
        format!("{}\n+{} more", lines[..3].join("\n"), lines.len() - 3)
    } else {
        lines.join("\n")
    };
    let same = |f: fn(&Target) -> &Option<String>| notes.iter().all(|n| f(&n.target) == f(&first.target));
    let target = Target {
        project: first.target.project.clone(),
        thread: if same(|t| &t.thread) { first.target.thread.clone() } else { None },
        build: if same(|t| &t.build) { first.target.build.clone() } else { None },
        bundle: first.target.bundle.clone(),
    };
    json!({
        "aps": {"alert": {"title": first.app, "body": body}, "sound": "default",
                "thread-id": first.target.project.clone().unwrap_or_else(|| first.app.clone())},
        "squircle": target,
    })
}

/// The Live Activity's content state; the Swift `ContentState` decodes it.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveState {
    pub status: String,
    pub workers: usize,
    pub needs_you: bool,
    pub working: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum LiveEvent {
    Start,
    Update,
    End,
}

pub fn activity_payload(event: LiveEvent, state: &LiveState, app: &str, project: &str, now: u64) -> Value {
    let mut aps = json!({
        "timestamp": now,
        "event": match event { LiveEvent::Start => "start", LiveEvent::Update => "update", LiveEvent::End => "end" },
        "content-state": state,
        // A Mac that goes quiet shows as stale rather than stuck.
        "stale-date": now + 15 * 60,
    });
    match event {
        LiveEvent::Start => {
            aps["attributes-type"] = json!(ACTIVITY_TYPE);
            aps["attributes"] = json!({"appName": app, "projectID": project});
            aps["alert"] = json!({"title": app, "body": state.status});
        }
        LiveEvent::End => aps["dismissal-date"] = json!(now + 2 * 60),
        LiveEvent::Update if state.needs_you => aps["alert"] = json!({"title": app, "body": state.status}),
        LiveEvent::Update => {}
    }
    json!({"aps": aps})
}

// MARK: Devices

#[derive(Clone, Serialize, Deserialize)]
pub struct Activity {
    pub id: String,
    pub token: String,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Device {
    pub id: String,
    #[serde(default)]
    pub token: Option<String>,
    #[serde(default)]
    pub environment: Environment,
    pub bundle_id: String,
    /// Starts a Live Activity by push.
    #[serde(default)]
    pub start_token: Option<String>,
    /// Running Live Activities by T3 project ID.
    #[serde(default)]
    pub activities: BTreeMap<String, Activity>,
    pub updated_at: u64,
}

/// What the phone shows right now; kept in memory only.
#[derive(Clone, Default)]
struct Presence {
    foreground: bool,
    thread: Option<String>,
    at: Option<Instant>,
}

impl Presence {
    fn fresh(&self) -> bool {
        self.at.is_some_and(|at| at.elapsed() < PRESENCE)
    }
    fn viewing(&self, thread: &str) -> bool {
        self.fresh() && self.foreground && self.thread.as_deref() == Some(thread)
    }
    fn foreground(&self) -> bool {
        self.fresh() && self.foreground
    }
}

fn valid_token(token: &str) -> bool {
    (16..=400).contains(&token.len()) && token.chars().all(|c| c.is_ascii_hexdigit())
}

fn valid_id(id: &str) -> bool {
    (1..=128).contains(&id.len()) && id.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Registration {
    pub device_id: String,
    pub bundle_id: String,
    #[serde(default)]
    pub environment: Environment,
    #[serde(default)]
    pub token: Option<String>,
    #[serde(default)]
    pub start_token: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ActivityRegistration {
    pub device_id: String,
    pub project_id: String,
    pub activity_id: String,
    /// None: the activity ended on the phone.
    #[serde(default)]
    pub token: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PresenceReport {
    pub device_id: String,
    pub foreground: bool,
    #[serde(default)]
    pub thread_id: Option<String>,
}

// MARK: Apps

/// An app as the service sees it: its agent and workers from T3's shell.
pub struct AppView {
    pub project_id: String,
    pub app: String,
    pub agent: Option<(String, Value)>,
    pub workers: Vec<(String, String, Value)>,
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Phase {
    Working,
    NeedsYou,
    Error,
    Done,
}

fn phase(row: &Value) -> Phase {
    match crate::agents::worker_state(row) {
        "working" => Phase::Working,
        "needs-you" => Phase::NeedsYou,
        "error" => Phase::Error,
        _ => Phase::Done,
    }
}

/// A turn ended or started waiting: what to tell the user about it.
#[derive(Debug, PartialEq)]
enum Change {
    Replied,
    Asks,
    Failed,
}

fn change(before: Option<&(Option<String>, Phase)>, turn: Option<String>, now: Phase) -> Option<Change> {
    let (was_turn, was) = before?;
    if *was == now && *was_turn == turn || now == Phase::Working {
        return None;
    }
    // A thread that never ran a turn has nothing to report.
    turn.as_ref()?;
    Some(match now {
        Phase::NeedsYou => Change::Asks,
        Phase::Error => Change::Failed,
        _ if *was == Phase::NeedsYou && *was_turn == turn => return None, // answered, still idle
        _ => Change::Replied,
    })
}

/// A plain first line of an agent's reply for a notification body.
pub fn summary_line(text: &str) -> String {
    let line = text.lines().map(str::trim).find(|l| !l.is_empty() && !l.starts_with("```")).unwrap_or("");
    let line = line.trim_start_matches(['#', '>', '-', '*', ' ']).replace("**", "").replace('`', "");
    let mut out: String = line.chars().take(160).collect();
    if line.chars().count() > 160 {
        out.push('…');
    }
    out
}

#[derive(Default)]
struct Live {
    sent: Option<(LiveState, Instant)>,
    status: String,
    status_at: Option<Instant>,
    deferred: bool,
    idle_since: Option<Instant>,
    /// Push-to-start attempts per device, so a missed token doesn't start a second.
    started: HashMap<String, Instant>,
}

/// Lookups the hub needs from T3, provided by `Agents`.
pub trait Threads: Send + Sync {
    fn last_reply<'a>(&'a self, thread: &'a str) -> BoxFuture<'a, Option<String>>;
    fn question<'a>(&'a self, thread: &'a str) -> BoxFuture<'a, Option<String>>;
    fn current_step<'a>(&'a self, thread: &'a str) -> BoxFuture<'a, Option<String>>;
}

pub struct Push {
    root: PathBuf,
    devices: Mutex<BTreeMap<String, Device>>,
    presence: Mutex<HashMap<String, Presence>>,
    /// The key file's modification time and the transport made from it.
    loaded: Mutex<Option<(SystemTime, Arc<dyn Transport>)>>,
    fixed: Option<Arc<dyn Transport>>,
    pending: Mutex<Vec<Note>>,
    coalesce: Duration,
    seen: Mutex<Option<HashMap<String, (Option<String>, Phase)>>>,
    apps: Mutex<Vec<AppView>>,
    live: Mutex<HashMap<String, Live>>,
    threads: Mutex<Option<Arc<dyn Threads>>>,
}

impl Push {
    pub fn open(root: &Path) -> Result<Arc<Self>> {
        Self::build(root, None, COALESCE)
    }

    /// With a given transport and burst window, for tests.
    pub fn with_transport(root: &Path, transport: Arc<dyn Transport>, coalesce: Duration) -> Result<Arc<Self>> {
        Self::build(root, Some(transport), coalesce)
    }

    fn build(root: &Path, fixed: Option<Arc<dyn Transport>>, coalesce: Duration) -> Result<Arc<Self>> {
        private_dir(&root.join("push"))?;
        let path = root.join("push").join("devices.json");
        let devices = if path.try_exists()? { read_json(&path)? } else { BTreeMap::new() };
        Ok(Arc::new(Self {
            root: root.to_path_buf(), devices: Mutex::new(devices), presence: Mutex::default(),
            loaded: Mutex::default(), fixed, pending: Mutex::default(), coalesce, seen: Mutex::default(),
            apps: Mutex::default(), live: Mutex::default(), threads: Mutex::default(),
        }))
    }

    pub fn set_threads(&self, threads: Arc<dyn Threads>) {
        *self.threads.lock().unwrap() = Some(threads);
    }

    fn save(&self, devices: &BTreeMap<String, Device>) {
        if let Err(error) = atomic_json(&self.root.join("push").join("devices.json"), devices) {
            eprintln!("Push: cannot save devices: {error:#}");
        }
    }

    /// The transport for the current key, reloaded when the key changes.
    fn transport(&self) -> Result<Option<Arc<dyn Transport>>> {
        if let Some(fixed) = &self.fixed {
            return Ok(Some(fixed.clone()));
        }
        let path = key_path(&self.root);
        let Ok(modified) = std::fs::metadata(&path).and_then(|m| m.modified()) else {
            *self.loaded.lock().unwrap() = None;
            return Ok(None);
        };
        let mut loaded = self.loaded.lock().unwrap();
        if let Some((at, transport)) = loaded.as_ref()
            && *at == modified
        {
            return Ok(Some(transport.clone()));
        }
        let config = KeyConfig::load(&self.root)?.context("APNs key disappeared")?;
        let transport: Arc<dyn Transport> = Arc::new(Apns::new(&config)?);
        *loaded = Some((modified, transport.clone()));
        Ok(Some(transport))
    }

    // MARK: Phone reports

    pub fn register(&self, r: Registration) -> Result<()> {
        ensure!(valid_id(&r.device_id), "invalid device ID");
        ensure!(valid_id(&r.bundle_id) && r.bundle_id.contains('.'), "invalid bundle ID");
        for token in [&r.token, &r.start_token].into_iter().flatten() {
            ensure!(valid_token(token), "a push token is hex");
        }
        let mut devices = self.devices.lock().unwrap();
        let device = devices.entry(r.device_id.clone()).or_insert_with(|| Device {
            id: r.device_id.clone(), token: None, environment: r.environment, bundle_id: r.bundle_id.clone(),
            start_token: None, activities: BTreeMap::new(), updated_at: 0,
        });
        if device.environment != r.environment || device.bundle_id != r.bundle_id {
            // A different build: its activities belong to the old one.
            device.activities.clear();
            device.token = None;
            device.start_token = None;
        }
        device.environment = r.environment;
        device.bundle_id = r.bundle_id;
        if r.token.is_some() { device.token = r.token; }
        if r.start_token.is_some() { device.start_token = r.start_token; }
        device.updated_at = crate::model::now();
        self.save(&devices);
        Ok(())
    }

    pub fn register_activity(&self, r: ActivityRegistration) -> Result<()> {
        ensure!(valid_id(&r.project_id) && valid_id(&r.activity_id), "invalid ID");
        let mut devices = self.devices.lock().unwrap();
        let device = devices.get_mut(&r.device_id).context("Register the device first")?;
        match r.token {
            Some(token) => {
                ensure!(valid_token(&token), "a push token is hex");
                device.activities.insert(r.project_id.clone(), Activity { id: r.activity_id, token });
                if let Some(live) = self.live.lock().unwrap().get_mut(&r.project_id) {
                    live.started.remove(&r.device_id);
                    // Send the current state to the new activity soon.
                    live.sent = None;
                }
            }
            None => {
                if device.activities.get(&r.project_id).is_some_and(|a| a.id == r.activity_id) {
                    device.activities.remove(&r.project_id);
                }
            }
        }
        self.save(&devices);
        Ok(())
    }

    pub fn report_presence(&self, r: PresenceReport) -> Result<()> {
        ensure!(valid_id(&r.device_id), "invalid device ID");
        self.presence.lock().unwrap().insert(r.device_id, Presence { foreground: r.foreground, thread: r.thread_id, at: Some(Instant::now()) });
        Ok(())
    }

    pub fn status(&self) -> Value {
        let key = KeyConfig::load(&self.root).ok().flatten();
        let devices = self.devices.lock().unwrap();
        json!({
            "configured": key.is_some() || self.fixed.is_some(),
            "key_id": key.as_ref().map(|k| k.key_id.clone()), "team_id": key.as_ref().map(|k| k.team_id.clone()),
            "transport": if self.fixed.is_some() { "test" } else { "apns" },
            "devices": devices.values().map(|d| json!({
                "id": d.id, "environment": d.environment, "bundle_id": d.bundle_id,
                "notifications": d.token.is_some(), "live_activity_start": d.start_token.is_some(),
                "live_activities": d.activities.len(), "updated_at": d.updated_at,
            })).collect::<Vec<_>>(),
        })
    }

    // MARK: Sending

    /// Sends and forgets tokens Apple says are gone. Returns what happened per device.
    async fn deliver(&self, deliveries: Vec<(String, Delivery)>) -> Vec<Value> {
        let transport = match self.transport() {
            Ok(Some(t)) => t,
            Ok(None) => return vec![json!({"error": "No APNs key. Run: squircle push setup --key-file PATH --key-id ID --team-id ID"})],
            Err(error) => return vec![json!({"error": format!("{error:#}")})],
        };
        let mut results = vec![];
        for (device, delivery) in deliveries {
            let outcome = transport.send(&delivery).await;
            let result = match &outcome {
                Ok(Outcome::Sent) => "sent".to_string(),
                Ok(Outcome::Unregistered) => {
                    self.forget(&device, &delivery.token);
                    "token no longer valid; forgotten".into()
                }
                Ok(Outcome::Rejected(reason)) => reason.clone(),
                Err(error) => format!("{error:#}"),
            };
            if !matches!(outcome, Ok(Outcome::Sent)) {
                eprintln!("Push to device {device}: {result}");
            }
            results.push(json!({"device": device, "result": result}));
        }
        results
    }

    fn forget(&self, device: &str, token: &str) {
        let mut devices = self.devices.lock().unwrap();
        let Some(d) = devices.get_mut(device) else { return };
        if d.token.as_deref() == Some(token) { d.token = None; }
        if d.start_token.as_deref() == Some(token) { d.start_token = None; }
        d.activities.retain(|_, a| a.token != token);
        self.save(&devices);
    }

    /// Queues a notification; notes within the burst window go out together.
    pub fn notify(self: &Arc<Self>, note: Note) {
        let mut pending = self.pending.lock().unwrap();
        pending.push(note);
        if pending.len() > 1 {
            return;
        }
        let this = self.clone();
        tokio::spawn(async move {
            tokio::time::sleep(this.coalesce).await;
            this.flush().await;
        });
    }

    async fn flush(&self) {
        let notes = std::mem::take(&mut *self.pending.lock().unwrap());
        let deliveries = self.alerts(&notes);
        if !deliveries.is_empty() {
            self.deliver(deliveries).await;
        }
    }

    /// One alert per device and app, leaving out what the phone is looking at.
    fn alerts(&self, notes: &[Note]) -> Vec<(String, Delivery)> {
        let devices = self.devices.lock().unwrap();
        let presence = self.presence.lock().unwrap();
        let mut out = vec![];
        for device in devices.values() {
            let Some(token) = &device.token else { continue };
            let here = presence.get(&device.id).cloned().unwrap_or_default();
            let mut by_app: BTreeMap<&str, Vec<&Note>> = BTreeMap::new();
            for note in notes {
                if note.target.thread.as_deref().is_some_and(|t| here.viewing(t)) {
                    continue;
                }
                by_app.entry(note.app.as_str()).or_default().push(note);
            }
            for group in by_app.values() {
                out.push((device.id.clone(), Delivery {
                    token: token.clone(), environment: device.environment, bundle_id: device.bundle_id.clone(),
                    push_type: PushType::Alert, priority: 10, collapse_id: None, payload: alert_payload(group),
                }));
            }
        }
        out
    }

    /// `squircle push test`: a notification, and optionally a Live Activity, now.
    pub async fn test(&self, live: bool) -> Value {
        let note = Note { app: "Squircle".into(), line: "Notifications from your Mac work.".into(), target: Target::default() };
        let mut deliveries = self.alerts(&[note]);
        if live {
            let state = LiveState { status: "Testing the Live Activity".into(), workers: 1, needs_you: false, working: true };
            let devices = self.devices.lock().unwrap();
            for device in devices.values() {
                let Some(token) = &device.start_token else { continue };
                deliveries.push((device.id.clone(), Delivery {
                    token: token.clone(), environment: device.environment, bundle_id: device.bundle_id.clone(),
                    push_type: PushType::LiveActivity, priority: 10, collapse_id: None,
                    payload: activity_payload(LiveEvent::Start, &state, "Squircle", "test", crate::model::now()),
                }));
            }
        }
        if deliveries.is_empty() {
            return json!({"sent": [], "note": "No phone has registered yet. Open Squircle on the phone and allow notifications."});
        }
        json!({"sent": self.deliver(deliveries).await})
    }

    // MARK: Builds

    pub fn build_finished(self: &Arc<Self>, job: &crate::model::Job, app: Option<&crate::apps::AppRecord>) {
        use crate::model::{BuildMode, BuildState};
        let Some(request) = job.request() else { return };
        if request.mode != BuildMode::Archive {
            return; // Agents' simulator builds are their own business.
        }
        let output = job.output();
        let name = output.map(|o| o.title.clone()).filter(|t| !t.is_empty()).unwrap_or_else(|| request.scheme.clone());
        let line = match job.state() {
            BuildState::Succeeded => match output {
                Some(o) => format!("Build {} is ready to install", o.build_number),
                None => "Build is ready to install".into(),
            },
            BuildState::Failed => {
                let reason = job.error().map(summary_line).filter(|l| !l.is_empty());
                reason.map_or("Build failed".into(), |r| format!("Build failed: {r}"))
            }
            _ => return,
        };
        let bundle = output.map(|o| o.bundle_id.clone()).or_else(|| app.and_then(|a| a.bundle_id.clone()));
        let target = Target { build: Some(job.id.clone()), bundle, ..Target::default() };
        self.notify(Note { app: name, line, target });
    }

    // MARK: Agents

    /// Called with each change to T3's shell: notes for finished turns and
    /// questions, and the Live Activity for each app.
    pub fn apps_changed(self: &Arc<Self>, apps: Vec<AppView>) {
        let mut changes = vec![];
        {
            let mut seen = self.seen.lock().unwrap();
            let first = seen.is_none();
            let seen = seen.get_or_insert_with(HashMap::new);
            for app in &apps {
                let agent = app.agent.iter().map(|(id, row)| (id, None, row));
                let workers = app.workers.iter().map(|(id, title, row)| (id, Some(title), row));
                for (id, title, row) in agent.chain(workers) {
                    let turn = row["latestTurn"]["turnId"].as_str().map(str::to_string);
                    let now = phase(row);
                    if !first && let Some(change) = change(seen.get(id), turn.clone(), now) {
                        changes.push((app.app.clone(), app.project_id.clone(), id.clone(), title.cloned(), change));
                    }
                    seen.insert(id.clone(), (turn, now));
                }
            }
        }
        *self.apps.lock().unwrap() = apps;
        for (app, project, thread, worker, change) in changes {
            let this = self.clone();
            tokio::spawn(async move {
                let threads = this.threads.lock().unwrap().clone();
                let line = match (&worker, change) {
                    (Some(title), Change::Replied) => format!("“{title}” finished"),
                    (Some(title), Change::Asks) => format!("“{title}” needs you"),
                    (Some(title), Change::Failed) => format!("“{title}” stopped with an error"),
                    (None, Change::Replied) => match &threads {
                        Some(t) => t.last_reply(&thread).await.map(|r| summary_line(&r)).filter(|l| !l.is_empty())
                            .unwrap_or_else(|| "Replied".into()),
                        None => "Replied".into(),
                    },
                    (None, Change::Asks) => match &threads {
                        Some(t) => t.question(&thread).await.map(|q| summary_line(&q)).unwrap_or_else(|| "Needs your approval".into()),
                        None => "Needs you".into(),
                    },
                    (None, Change::Failed) => "Stopped with an error".into(),
                };
                this.notify(Note { app, line, target: Target { project: Some(project), thread: Some(thread), ..Target::default() } });
            });
        }
        self.refresh_activities(false);
    }

    /// Recomputes each app's Live Activity; `poll` also refreshes the agent's
    /// current step (the service ticks this while anything works).
    fn refresh_activities(self: &Arc<Self>, poll: bool) {
        let apps: Vec<(String, String, Option<String>, LiveState)> = self.apps.lock().unwrap().iter().map(|app| {
            let agent = app.agent.as_ref().map(|(_, row)| phase(row));
            let workers: Vec<Phase> = app.workers.iter().map(|(_, _, row)| phase(row)).collect();
            let busy = workers.iter().filter(|p| **p == Phase::Working).count();
            let needs_you = agent == Some(Phase::NeedsYou) || workers.contains(&Phase::NeedsYou);
            let working = agent == Some(Phase::Working) || busy > 0;
            let fallback = if needs_you { "Needs you" } else if agent == Some(Phase::Working) { "Working" }
                else if busy > 0 { "Waiting on workers" } else { "Done" };
            let thread = app.agent.as_ref().filter(|_| agent == Some(Phase::Working)).map(|(id, _)| id.clone());
            (app.project_id.clone(), app.app.clone(), thread,
             LiveState { status: fallback.into(), workers: busy, needs_you, working })
        }).collect();
        for (project, app, thread, mut state) in apps {
            let (cached, stale) = {
                let mut live = self.live.lock().unwrap();
                let entry = live.entry(project.clone()).or_default();
                let stale = entry.status_at.is_none_or(|at| at.elapsed() > Duration::from_secs(5));
                (entry.status.clone(), stale)
            };
            let stepping = state.working && !state.needs_you && thread.is_some();
            if stepping && !cached.is_empty() {
                state.status = cached;
            }
            self.update_activity(&project, &app, state.clone());
            let Some(thread) = thread.filter(|_| stepping && (poll || stale)) else { continue };
            let this = self.clone();
            tokio::spawn(async move {
                let threads = this.threads.lock().unwrap().clone();
                let Some(step) = (match threads { Some(t) => t.current_step(&thread).await, None => None }) else { return };
                {
                    let mut live = this.live.lock().unwrap();
                    let entry = live.entry(project.clone()).or_default();
                    entry.status_at = Some(Instant::now());
                    if entry.status == step { return }
                    entry.status = step.clone();
                }
                this.update_activity(&project, &app, LiveState { status: step, ..state });
            });
        }
    }

    /// Ticks the Live Activities' step while anything works.
    pub async fn run(self: Arc<Self>) {
        loop {
            tokio::time::sleep(Duration::from_secs(8)).await;
            self.refresh_activities(true);
        }
    }

    fn update_activity(self: &Arc<Self>, project: &str, app: &str, state: LiveState) {
        let active = state.working || state.needs_you;
        let event = {
            let mut live = self.live.lock().unwrap();
            let entry = live.entry(project.to_string()).or_default();
            if !active {
                let Some((sent, _)) = &entry.sent else { return };
                if !sent.working && !sent.needs_you {
                    return; // already ended
                }
                // A pause between turns is not the end: wait a little.
                let since = *entry.idle_since.get_or_insert_with(Instant::now);
                if since.elapsed() < Duration::from_secs(20) {
                    if !entry.deferred {
                        entry.deferred = true;
                        let (this, project) = (self.clone(), project.to_string());
                        tokio::spawn(async move {
                            tokio::time::sleep(Duration::from_secs(21)).await;
                            this.live.lock().unwrap().entry(project).or_default().deferred = false;
                            this.refresh_activities(false);
                        });
                    }
                    return;
                }
                entry.sent = Some((state.clone(), Instant::now()));
                entry.idle_since = None;
                entry.started.clear();
                LiveEvent::End
            } else {
                entry.idle_since = None;
                let important = entry.sent.as_ref().is_none_or(|(s, _)| {
                    s.working != state.working || s.needs_you != state.needs_you || s.workers != state.workers
                });
                match &entry.sent {
                    Some((s, _)) if *s == state => return,
                    Some((_, at)) if !important && at.elapsed() < Duration::from_secs(10) => {
                        if !entry.deferred {
                            entry.deferred = true;
                            let this = self.clone();
                            let wait = Duration::from_secs(10).saturating_sub(at.elapsed());
                            let project = project.to_string();
                            tokio::spawn(async move {
                                tokio::time::sleep(wait).await;
                                this.live.lock().unwrap().entry(project).or_default().deferred = false;
                                this.refresh_activities(false);
                            });
                        }
                        return;
                    }
                    _ => {}
                }
                entry.sent = Some((state.clone(), Instant::now()));
                if important { LiveEvent::Start } else { LiveEvent::Update }
            }
        };
        let deliveries = self.activity_deliveries(project, app, &state, event);
        if event == LiveEvent::End {
            // An ended activity takes no more updates; the next work starts a new one.
            let mut devices = self.devices.lock().unwrap();
            for device in devices.values_mut() { device.activities.remove(project); }
            self.save(&devices);
        }
        if !deliveries.is_empty() {
            let this = self.clone();
            tokio::spawn(async move { this.deliver(deliveries).await; });
        }
    }

    /// Updates running activities; `Start` also starts one by push on phones
    /// in the background that have none for this app.
    fn activity_deliveries(&self, project: &str, app: &str, state: &LiveState, event: LiveEvent) -> Vec<(String, Delivery)> {
        let now = crate::model::now();
        let devices = self.devices.lock().unwrap();
        let presence = self.presence.lock().unwrap();
        let mut live = self.live.lock().unwrap();
        let entry = live.entry(project.to_string()).or_default();
        let mut out = vec![];
        for device in devices.values() {
            let (token, event, priority) = match (device.activities.get(project), event) {
                (Some(activity), LiveEvent::Start) => (activity.token.clone(), LiveEvent::Update, 10),
                (Some(activity), LiveEvent::Update) => (activity.token.clone(), LiveEvent::Update, 5),
                (Some(activity), LiveEvent::End) => (activity.token.clone(), LiveEvent::End, 10),
                (None, LiveEvent::Start) => {
                    let Some(token) = &device.start_token else { continue };
                    let here = presence.get(&device.id).cloned().unwrap_or_default();
                    let recent = entry.started.get(&device.id).is_some_and(|at| at.elapsed() < Duration::from_secs(300));
                    if here.foreground() || recent { continue }
                    entry.started.insert(device.id.clone(), Instant::now());
                    (token.clone(), LiveEvent::Start, 10)
                }
                (None, _) => continue,
            };
            out.push((device.id.clone(), Delivery {
                token, environment: device.environment, bundle_id: device.bundle_id.clone(),
                push_type: PushType::LiveActivity, priority, collapse_id: None,
                payload: activity_payload(event, state, app, project, now),
            }));
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{Router, extract::State, http::HeaderMap, routing::post};

    // A throwaway P-256 key in Apple's .p8 format (PKCS#8 with public key).
    fn key() -> KeyConfig {
        let rng = ring::rand::SystemRandom::new();
        let der = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
        let body = base64::engine::general_purpose::STANDARD.encode(der.as_ref());
        let lines: Vec<&str> = body.as_bytes().chunks(64).map(|c| std::str::from_utf8(c).unwrap()).collect();
        KeyConfig { key_id: "AB12CD34EF".into(), team_id: "2F26US4NAU".into(),
                    key_pem: format!("-----BEGIN PRIVATE KEY-----\n{}\n-----END PRIVATE KEY-----", lines.join("\n")) }
    }

    fn verify(jwt: &str, public: &[u8]) -> (Value, Value) {
        let parts: Vec<&str> = jwt.split('.').collect();
        assert_eq!(parts.len(), 3);
        let decode = |s: &str| base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(s).unwrap();
        ring::signature::UnparsedPublicKey::new(&ring::signature::ECDSA_P256_SHA256_FIXED, public)
            .verify(format!("{}.{}", parts[0], parts[1]).as_bytes(), &decode(parts[2]))
            .expect("signature verifies");
        (serde_json::from_slice(&decode(parts[0])).unwrap(), serde_json::from_slice(&decode(parts[1])).unwrap())
    }

    #[test]
    fn provider_token_is_es256_signed_by_the_key() {
        let signer = Signer::new(&key()).unwrap();
        let (header, claims) = verify(&signer.jwt(1_700_000_000).unwrap(), signer.public_key());
        assert_eq!(header, json!({"alg": "ES256", "kid": "AB12CD34EF"}));
        assert_eq!(claims, json!({"iss": "2F26US4NAU", "iat": 1_700_000_000u64}));
        assert!(Signer::new(&KeyConfig { key_pem: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----".into(), ..key() }).is_err());
    }

    #[test]
    fn a_burst_becomes_one_alert_that_opens_the_common_target() {
        let note = |line: &str, thread: &str| Note { app: "Notes".into(), line: line.into(),
            target: Target { project: Some("p".into()), thread: Some(thread.into()), ..Target::default() } };
        let (a, b) = (note("“Login” finished", "w1"), note("“Search” finished", "w2"));
        let payload = alert_payload(&[&a, &b]);
        assert_eq!(payload["aps"]["alert"], json!({"title": "Notes", "body": "“Login” finished\n“Search” finished"}));
        assert_eq!(payload["aps"]["thread-id"], "p");
        assert_eq!(payload["squircle"], json!({"project": "p"}));
        let lines: Vec<Note> = (0..6).map(|i| note(&format!("line {i}"), "w1")).collect();
        let payload = alert_payload(&lines.iter().collect::<Vec<_>>());
        assert_eq!(payload["aps"]["alert"]["body"], "line 0\nline 1\nline 2\n+3 more");
        assert_eq!(payload["squircle"], json!({"project": "p", "thread": "w1"}));
    }

    #[test]
    fn activity_payloads_match_activitykit() {
        let state = LiveState { status: "Edited Theme.swift".into(), workers: 2, needs_you: false, working: true };
        let start = activity_payload(LiveEvent::Start, &state, "Notes", "p1", 100);
        assert_eq!(start["aps"]["event"], "start");
        assert_eq!(start["aps"]["attributes-type"], ACTIVITY_TYPE);
        assert_eq!(start["aps"]["attributes"], json!({"appName": "Notes", "projectID": "p1"}));
        assert_eq!(start["aps"]["content-state"], json!({"status": "Edited Theme.swift", "workers": 2, "needsYou": false, "working": true}));
        let end = activity_payload(LiveEvent::End, &state, "Notes", "p1", 100);
        assert_eq!((end["aps"]["event"].as_str(), end["aps"]["dismissal-date"].as_u64()), (Some("end"), Some(220)));
        assert!(end["aps"]["attributes"].is_null());
    }

    #[test]
    fn turns_report_once_when_they_stop_or_ask() {
        let t = |s: &str| Some(s.to_string());
        let was = |turn: &str, p| (t(turn), p);
        assert_eq!(change(Some(&was("a", Phase::Working)), t("a"), Phase::Done), Some(Change::Replied));
        assert_eq!(change(Some(&was("a", Phase::Done)), t("a"), Phase::Done), None);
        assert_eq!(change(Some(&was("a", Phase::Done)), t("b"), Phase::Done), Some(Change::Replied));
        assert_eq!(change(Some(&was("a", Phase::Working)), t("a"), Phase::NeedsYou), Some(Change::Asks));
        assert_eq!(change(Some(&was("a", Phase::NeedsYou)), t("a"), Phase::Done), None);
        assert_eq!(change(Some(&was("a", Phase::Working)), t("a"), Phase::Error), Some(Change::Failed));
        assert_eq!(change(None, t("a"), Phase::Done), None);
        assert_eq!(change(Some(&(None, Phase::Done)), None, Phase::Done), None);
        assert_eq!(summary_line("\n## **Done.** Fixed `login` and pushed.\nMore"), "Done. Fixed login and pushed.");
    }

    type Seen = Arc<Mutex<Vec<(HeaderMap, String, Value)>>>;

    /// A fake APNs over HTTP/2: records requests, answers like Apple.
    async fn fake_apns() -> (String, Seen) {
        let seen: Seen = Arc::default();
        let app = Router::new().route("/3/device/{token}", post(
            |State(seen): State<Seen>, axum::extract::Path(token): axum::extract::Path<String>, headers: HeaderMap, body: axum::Json<Value>| async move {
                let gone = token.starts_with("dead");
                seen.lock().unwrap().push((headers, token, body.0));
                if gone {
                    (axum::http::StatusCode::GONE, axum::Json(json!({"reason": "Unregistered"})))
                } else {
                    (axum::http::StatusCode::OK, axum::Json(json!({})))
                }
            })).with_state(seen.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        (url, seen)
    }

    #[tokio::test]
    async fn sends_over_http2_suppresses_the_viewed_thread_and_forgets_dead_tokens() {
        let (url, seen) = fake_apns().await;
        let dir = tempfile::tempdir().unwrap();
        let config = key();
        let public = Signer::new(&config).unwrap().public_key().to_vec();
        let push = Push::with_transport(dir.path(), Arc::new(Apns::with_hosts(&config, &url, &url).unwrap()), Duration::from_millis(50)).unwrap();
        push.register(Registration { device_id: "phone".into(), bundle_id: "ai.dreamslate.Squircle".into(),
            environment: Environment::Development, token: Some("ab".repeat(32)), start_token: None }).unwrap();
        push.register(Registration { device_id: "old".into(), bundle_id: "ai.dreamslate.Squircle".into(),
            environment: Environment::Production, token: Some(format!("dead{}", "0".repeat(28))), start_token: None }).unwrap();
        assert!(push.register(Registration { device_id: "x".into(), bundle_id: "ai.dreamslate.Squircle".into(),
            environment: Environment::Development, token: Some("../../x".into()), start_token: None }).is_err());
        push.report_presence(PresenceReport { device_id: "phone".into(), foreground: true, thread_id: Some("t1".into()) }).unwrap();
        let note = |line: &str, thread: &str| Note { app: "Notes".into(), line: line.into(),
            target: Target { project: Some("p".into()), thread: Some(thread.into()), ..Target::default() } };
        push.notify(note("Looked at it", "t1"));
        push.notify(note("“Login” finished", "w1"));
        tokio::time::sleep(Duration::from_millis(400)).await;

        let requests = seen.lock().unwrap();
        assert_eq!(requests.len(), 2, "one alert per device");
        let (headers, _, body) = requests.iter().find(|r| r.1.starts_with("abab")).unwrap();
        assert_eq!(body["aps"]["alert"]["body"], "“Login” finished", "the viewed thread is left out on that phone");
        assert_eq!(headers["apns-topic"], "ai.dreamslate.Squircle");
        assert_eq!(headers["apns-push-type"], "alert");
        let jwt = headers["authorization"].to_str().unwrap().strip_prefix("bearer ").or_else(|| headers["authorization"].to_str().unwrap().strip_prefix("Bearer ")).unwrap();
        verify(jwt, &public);
        let (_, _, other) = requests.iter().find(|r| r.1.starts_with("dead")).unwrap();
        assert_eq!(other["aps"]["alert"]["body"], "Looked at it\n“Login” finished");
        drop(requests);
        let status = push.status();
        let old = status["devices"].as_array().unwrap().iter().find(|d| d["id"] == "old").unwrap();
        assert_eq!(old["notifications"], false, "a 410 forgets the token");
    }
}
