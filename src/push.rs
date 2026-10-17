//! Notifications and the Live Activity on the phone. The service decides what
//! to say (`Push`) and hands each message to a `Transport`. Today that is
//! `Apns`: Apple's HTTP/2 API, signed with the user's own APNs auth key
//! (`squircle push setup`). A relay for App Store builds would be another
//! `Transport`; the phone's contract (registration endpoints, the `squircle`
//! payload key, the activity's content state) stays the same.

use crate::actor::Owner;
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
    sync::{Arc, atomic::{AtomicU64, Ordering}},
    time::{Duration, Instant, SystemTime},
};
use tokio::sync::Notify;

/// The Swift type name of the activity's attributes (`attributes-type`).
pub const ACTIVITY_TYPE: &str = "SquircleActivityAttributes";
const SANDBOX: &str = "https://api.sandbox.push.apple.com";
const PRODUCTION: &str = "https://api.push.apple.com";
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

/// Signs APNs provider tokens (ES256 JWT).
pub struct Signer {
    key: EcdsaKeyPair,
    key_id: String,
    team_id: String,
}

impl Signer {
    pub fn new(config: &KeyConfig) -> Result<Self> {
        let der = pem_der(&config.key_pem)?;
        let key = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &der, &ring::rand::SystemRandom::new())
            .map_err(|e| anyhow::anyhow!("invalid P-256 key: {e}"))?;
        Ok(Self { key, key_id: config.key_id.clone(), team_id: config.team_id.clone() })
    }

    pub fn jwt(&self, issued_at: u64) -> Result<String> {
        let header = b64url(json!({"alg": "ES256", "kid": self.key_id}).to_string().as_bytes());
        let claims = b64url(json!({"iss": self.team_id, "iat": issued_at}).to_string().as_bytes());
        let input = format!("{header}.{claims}");
        let signature = self.key.sign(&ring::rand::SystemRandom::new(), input.as_bytes())
            .map_err(|_| anyhow::anyhow!("signing failed"))?;
        Ok(format!("{input}.{}", b64url(signature.as_ref())))
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
    /// Apple won't take this message; trying it again won't help.
    Rejected(String),
    /// Apple is busy or unreachable; the same message may go through later.
    Retry(String),
}

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

pub trait Transport: Send + Sync {
    fn send<'a>(&'a self, delivery: &'a Delivery) -> BoxFuture<'a, Result<Outcome>>;
}

/// The signer and the provider token it last made. Apple accepts a token
/// for an hour and rejects refreshing more than every 20 minutes, so one is
/// reused for 40; one owner makes and hands it out, so concurrent sends
/// share it.
struct Tokens {
    signer: Signer,
    cached: Option<(u64, String)>,
}

impl Tokens {
    fn token(&mut self, refresh: bool) -> Result<String> {
        let now = crate::model::now();
        if let Some((at, token)) = self.cached.as_ref()
            && !refresh && now < at + 40 * 60
        {
            return Ok(token.clone());
        }
        let token = self.signer.jwt(now)?;
        self.cached = Some((now, token.clone()));
        Ok(token)
    }
}

/// Apple's push service, directly, with the user's key.
pub struct Apns {
    tokens: Owner<Tokens>,
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
        let tokens = Owner::spawn("APNs tokens", Tokens { signer: Signer::new(config)?, cached: None });
        Ok(Self { tokens, client: builder.build()?, sandbox: sandbox.into(), production: production.into() })
    }

    async fn post(&self, delivery: &Delivery, refresh: bool) -> Result<(u16, String)> {
        let host = match delivery.environment { Environment::Development => &self.sandbox, Environment::Production => &self.production };
        let (kind, topic) = match delivery.push_type {
            PushType::Alert => ("alert", delivery.bundle_id.clone()),
            PushType::LiveActivity => ("liveactivity", format!("{}.push-type.liveactivity", delivery.bundle_id)),
        };
        let token = self.tokens.ask(move |tokens| tokens.token(refresh)).await?;
        let mut request = self.client.post(format!("{host}/3/device/{}", delivery.token))
            .bearer_auth(token)
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
                (429 | 500..=599, reason) | (403, reason @ "ExpiredProviderToken") =>
                    Outcome::Retry(format!("HTTP {status} {reason}").trim().to_string()),
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
    /// The Mac catalog's app ID, for a build whose bundle isn't known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
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
        app: first.target.app.clone(),
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

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Activity {
    pub id: String,
    pub token: String,
}

/// Where one phone's Live Activity for one app stands, as far as APNs has
/// accepted. Absent from the map: the phone has none we know of.
#[derive(Clone, Debug)]
enum Stage {
    /// Nothing running; kept only while a failed start backs off.
    Absent,
    /// APNs accepted a push-to-start; the phone reports the new activity's token.
    Starting { at: Instant },
    /// A running activity. `acked` is the content APNs last accepted for it;
    /// its token is kept until an End is accepted or Apple says it is gone.
    Running { activity: Activity, acked: Option<(LiveState, Instant)> },
}

/// The send for a link: none, one in flight (by generation), or a failure
/// waiting out its backoff.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Flight {
    Idle,
    Sending(u64),
    Waiting { until: Instant, failures: u32 },
}

#[derive(Clone, Debug)]
struct Link {
    stage: Stage,
    flight: Flight,
}

impl Link {
    fn new(stage: Stage) -> Self {
        Self { stage, flight: Flight::Idle }
    }
}

/// devices.json keeps each running activity's ID and token, as before;
/// everything else about a link lives only in memory.
mod persisted_links {
    use super::{Activity, Link, Stage};
    use serde::{Deserialize, Deserializer, Serialize, Serializer};
    use std::collections::BTreeMap;

    pub fn serialize<S: Serializer>(links: &BTreeMap<String, Link>, s: S) -> Result<S::Ok, S::Error> {
        let running: BTreeMap<&String, &Activity> = links.iter().filter_map(|(project, link)| match &link.stage {
            Stage::Running { activity, .. } => Some((project, activity)),
            _ => None,
        }).collect();
        running.serialize(s)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<BTreeMap<String, Link>, D::Error> {
        Ok(BTreeMap::<String, Activity>::deserialize(d)?.into_iter()
            .map(|(project, activity)| (project, Link::new(Stage::Running { activity, acked: None })))
            .collect())
    }
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
    /// Live Activities by T3 project ID.
    #[serde(default, rename = "activities", with = "persisted_links")]
    links: BTreeMap<String, Link>,
    pub updated_at: u64,
}

impl Device {
    fn running(&self) -> usize {
        self.links.values().filter(|l| matches!(l.stage, Stage::Running { .. })).count()
    }
}

/// What a phone reported it shows. A report holds for `PRESENCE`, so a phone
/// that died with Squircle open doesn't silence a thread forever.
#[derive(Clone, Debug, PartialEq)]
enum Shown {
    Background,
    Foreground { thread: Option<String> },
}

struct Presence {
    shown: Shown,
    until: Instant,
}

impl Presence {
    fn shown(&self) -> Shown {
        if Instant::now() < self.until { self.shown.clone() } else { Shown::Background }
    }
}

fn shown(presence: &HashMap<String, Presence>, device: &str) -> Shown {
    presence.get(device).map_or(Shown::Background, Presence::shown)
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

/// The agent turn whose current step the activity shows.
#[derive(Clone, Debug, PartialEq)]
struct StepKey {
    thread: String,
    turn: Option<String>,
}

/// The step text read from T3 for one turn. Replaced whole when the turn
/// changes, so a lookup for an older turn finds nothing to write into.
struct Step {
    key: StepKey,
    text: Option<String>,
    checked: Option<Instant>,
    looking: bool,
}

/// What an app's activity should be, from T3's latest shell.
#[derive(Clone, Debug)]
enum Want {
    /// Work or a question: show this (the status before the step is applied).
    Show(LiveState),
    /// Just went idle; a pause between turns is not the end yet.
    Pausing { since: Instant, last: LiveState },
    /// Idle: running activities end with this.
    Hide(LiveState),
}

struct AppLive {
    name: String,
    want: Want,
    /// The working agent's turn, when its step is what the activity shows.
    stepping: Option<StepKey>,
    step: Option<Step>,
}

impl AppLive {
    /// Shown content with the current step applied, when the step belongs
    /// to the turn still running.
    fn stepped(&self, state: &LiveState) -> LiveState {
        let mut state = state.clone();
        if let (Some(key), Some(step)) = (&self.stepping, &self.step)
            && step.key == *key && let Some(text) = &step.text
        {
            state.status = text.clone();
        }
        state
    }
}

/// An app's activity content and the turn to step, from T3's shell row.
fn observe(app: &AppView) -> (LiveState, Option<StepKey>) {
    let agent = app.agent.as_ref().map(|(_, row)| phase(row));
    let workers: Vec<Phase> = app.workers.iter().map(|(_, _, row)| phase(row)).collect();
    let busy = workers.iter().filter(|p| **p == Phase::Working).count();
    let needs_you = agent == Some(Phase::NeedsYou) || workers.contains(&Phase::NeedsYou);
    let working = agent == Some(Phase::Working) || busy > 0;
    let status = if needs_you { "Needs you" } else if agent == Some(Phase::Working) { "Working" }
        else if busy > 0 { "Waiting on workers" } else { "Done" };
    let stepping = app.agent.as_ref().filter(|_| agent == Some(Phase::Working) && !needs_you).map(|(id, row)| StepKey {
        thread: id.clone(), turn: row["latestTurn"]["turnId"].as_str().map(str::to_string),
    });
    (LiveState { status: status.into(), workers: busy, needs_you, working }, stepping)
}

/// What one send to one phone's activity carries.
#[derive(Clone, Debug)]
enum Message {
    Start(LiveState),
    Update(LiveState),
    End(LiveState),
}

/// Lookups the hub needs from T3, provided by `Agents`.
pub trait Threads: Send + Sync {
    fn last_reply<'a>(&'a self, thread: &'a str) -> BoxFuture<'a, Option<String>>;
    fn question<'a>(&'a self, thread: &'a str) -> BoxFuture<'a, Option<String>>;
    fn current_step<'a>(&'a self, thread: &'a str) -> BoxFuture<'a, Option<String>>;
    /// Whether the turn that just ended was Squircle's own upkeep (a
    /// compaction while idle), which has nothing to tell the user.
    fn quiet<'a>(&'a self, thread: &'a str) -> BoxFuture<'a, bool>;
}

/// How long things wait; shorter in tests.
#[derive(Clone, Copy)]
pub struct Timing {
    /// Events this close together arrive as one notification.
    pub coalesce: Duration,
    /// The first retry after a transient failure; each further one waits 4×
    /// longer, up to `RETRY_CAP`.
    pub retry: Duration,
    /// Idle this long before a running activity ends.
    pub pause: Duration,
    /// Minor updates (the step text) go out at most this often per activity.
    pub throttle: Duration,
}

impl Default for Timing {
    fn default() -> Self {
        Self { coalesce: COALESCE, retry: Duration::from_secs(2), pause: Duration::from_secs(20),
               throttle: Duration::from_secs(10) }
    }
}

/// A push-to-start without a token reported back is retried after this.
const START_WAIT: Duration = Duration::from_secs(300);
/// The step text is read again after this, while the agent works.
const STEP_EVERY: Duration = Duration::from_secs(5);
/// A step lookup that takes longer is abandoned.
const STEP_DEADLINE: Duration = Duration::from_secs(5);
/// The reconciler runs at least this often.
const TICK: Duration = Duration::from_secs(8);
const RETRY_CAP: Duration = Duration::from_secs(300);
/// An alert that keeps failing transiently is dropped after this many tries.
const ALERT_ATTEMPTS: u32 = 4;

fn backoff(base: Duration, failures: u32) -> Duration {
    base.saturating_mul(4u32.saturating_pow(failures.saturating_sub(1))).min(RETRY_CAP)
}

/// Whether a send's outcome is worth trying again later.
fn transient(outcome: &Result<Outcome>) -> bool {
    matches!(outcome, Err(_) | Ok(Outcome::Retry(_)))
}

fn describe(outcome: &Result<Outcome>) -> String {
    match outcome {
        Ok(Outcome::Sent) => "sent".into(),
        Ok(Outcome::Unregistered) => "token no longer valid; forgotten".into(),
        Ok(Outcome::Rejected(reason) | Outcome::Retry(reason)) => reason.clone(),
        Err(error) => format!("{error:#}"),
    }
}

/// The push owner's state, reached only by its letters.
#[derive(Default)]
struct State {
    root: PathBuf,
    devices: BTreeMap<String, Device>,
    presence: HashMap<String, Presence>,
    apps: BTreeMap<String, AppLive>,
    generation: u64,
    /// The key file's modification time and the transport made from it.
    loaded: Option<(SystemTime, Arc<dyn Transport>)>,
    /// Notes waiting for the burst window to close.
    pending: Vec<Note>,
    /// Each thread's last turn and phase, once the first shell is seen.
    seen: Option<HashMap<String, (Option<String>, Phase)>>,
    threads: Option<Arc<dyn Threads>>,
}

impl State {
    /// A phone that could show this app's activity: one running or starting,
    /// or a start token while Squircle isn't open on it.
    fn has_recipient(&self, project: &str) -> bool {
        self.devices.values().any(|d| match d.links.get(project).map(|l| &l.stage) {
            Some(Stage::Running { .. } | Stage::Starting { .. }) => true,
            _ => d.start_token.is_some() && shown(&self.presence, &d.id) == Shown::Background,
        })
    }

    fn save(&self) {
        if let Err(error) = atomic_json(&self.root.join("push").join("devices.json"), &self.devices) {
            eprintln!("Push: cannot save devices: {error:#}");
        }
    }

    /// Forgets a token Apple says is gone, wherever this device used it.
    fn forget(&mut self, device: &str, token: &str) {
        let Some(d) = self.devices.get_mut(device) else { return };
        if d.token.as_deref() == Some(token) { d.token = None; }
        if d.start_token.as_deref() == Some(token) { d.start_token = None; }
        d.links.retain(|_, l| !matches!(&l.stage, Stage::Running { activity, .. } if activity.token == token));
        self.save();
    }

    /// One alert per device and app, leaving out what the phone is looking at.
    fn alerts(&self, notes: &[Note]) -> Vec<(String, Delivery)> {
        let mut out = vec![];
        for device in self.devices.values() {
            let Some(token) = &device.token else { continue };
            let here = shown(&self.presence, &device.id);
            let mut by_app: BTreeMap<&str, Vec<&Note>> = BTreeMap::new();
            for note in notes {
                if let (Some(t), Shown::Foreground { thread: Some(viewed) }) = (&note.target.thread, &here)
                    && t == viewed
                {
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

    /// Notes for finished turns and questions since the last shell.
    fn changes(&mut self, apps: &[AppView]) -> Vec<(String, String, String, Option<String>, Change)> {
        let mut changes = vec![];
        let first = self.seen.is_none();
        let seen = self.seen.get_or_insert_with(HashMap::new);
        for app in apps {
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
        changes
    }

    /// Moves each app's wanted activity to what the shell now says.
    fn observe(&mut self, apps: &[AppView]) {
        let now = Instant::now();
        for app in apps {
            let (observed, stepping) = observe(app);
            let active = observed.working || observed.needs_you;
            let entry = self.apps.entry(app.project_id.clone()).or_insert_with(|| AppLive {
                name: app.app.clone(), want: Want::Hide(observed.clone()), stepping: None, step: None,
            });
            entry.name = app.app.clone();
            entry.want = match (&entry.want, active) {
                (_, true) => Want::Show(observed),
                (Want::Show(_), false) => Want::Pausing { since: now, last: observed },
                (Want::Pausing { since, .. }, false) => Want::Pausing { since: *since, last: observed },
                (Want::Hide(_), false) => Want::Hide(observed),
            };
            if entry.step.as_ref().map(|s| &s.key) != stepping.as_ref() {
                entry.step = stepping.clone().map(|key| Step { key, text: None, checked: None, looking: false });
            }
            entry.stepping = stepping;
        }
    }

    /// One pass of the reconciler: the sends and step lookups due now, and
    /// when the next pass is due.
    fn reconcile(&mut self, timing: Timing) -> (Vec<(u32, Outgoing)>, Vec<(String, StepKey)>, Option<Instant>) {
        let now = Instant::now();
        let mut next: Option<Instant> = None;
        let mut due = |at: Instant| next = Some(next.map_or(at, |n: Instant| n.min(at)));
        let mut sends = vec![];
        let mut lookups = vec![];
        // The step is read only while it can reach someone.
        let recipients: Vec<String> = self.apps.keys().filter(|p| self.has_recipient(p)).cloned().collect();
        let State { devices, presence, apps, generation, .. } = self;
        for app in apps.values_mut() {
            if let Want::Pausing { since, last } = &app.want {
                if now.duration_since(*since) >= timing.pause {
                    app.want = Want::Hide(last.clone());
                } else {
                    due(*since + timing.pause);
                }
            }
        }
        for (project, app) in apps.iter_mut() {
            for device in devices.values_mut() {
                let here = shown(presence, &device.id);
                let link = device.links.get(project).cloned();
                if let Some(Link { flight, .. }) = &link {
                    match flight {
                        Flight::Sending(_) => continue,
                        Flight::Waiting { until, .. } if *until > now => { due(*until); continue }
                        _ => {}
                    }
                }
                let stage = link.as_ref().map(|l| &l.stage);
                let (message, token, priority) = match (&app.want, stage) {
                    (Want::Pausing { .. }, _) => continue,
                    (Want::Show(shown), Some(Stage::Running { activity, acked })) => {
                        let content = app.stepped(shown);
                        let important = acked.as_ref().is_none_or(|(s, _)| {
                            s.working != content.working || s.needs_you != content.needs_you || s.workers != content.workers
                        });
                        match acked {
                            Some((s, _)) if *s == content => continue,
                            Some((_, at)) if !important && now.duration_since(*at) < timing.throttle => {
                                due(*at + timing.throttle);
                                continue;
                            }
                            _ => {}
                        }
                        (Message::Update(content), activity.token.clone(), if important { 10 } else { 5 })
                    }
                    (Want::Show(_), Some(Stage::Starting { at })) if now.duration_since(*at) < START_WAIT => continue,
                    (Want::Show(shown), _) => {
                        let Some(token) = &device.start_token else { continue };
                        if here != Shown::Background { continue }
                        (Message::Start(app.stepped(shown)), token.clone(), 10)
                    }
                    (Want::Hide(last), Some(Stage::Running { activity, .. })) => (Message::End(last.clone()), activity.token.clone(), 10),
                    (Want::Hide(_), Some(Stage::Starting { .. } | Stage::Absent)) => {
                        // Nothing to end; the phone reports a late start's token, which then ends.
                        device.links.remove(project);
                        continue;
                    }
                    (Want::Hide(_), None) => continue,
                };
                *generation += 1;
                let (event, body) = match &message {
                    Message::Start(s) => (LiveEvent::Start, s.clone()),
                    Message::Update(s) => (LiveEvent::Update, s.clone()),
                    Message::End(s) => (LiveEvent::End, s.clone()),
                };
                let failures = match link.as_ref().map(|l| l.flight) { Some(Flight::Waiting { failures, .. }) => failures, _ => 0 };
                let entry = device.links.entry(project.clone()).or_insert_with(|| Link::new(Stage::Absent));
                entry.flight = Flight::Sending(*generation);
                sends.push((failures, Outgoing {
                    device: device.id.clone(), project: project.clone(), generation: *generation, message,
                    delivery: Delivery {
                        token, environment: device.environment, bundle_id: device.bundle_id.clone(),
                        push_type: PushType::LiveActivity, priority, collapse_id: None,
                        payload: activity_payload(event, &body, &app.name, project, crate::model::now()),
                    },
                }));
            }
        }
        // One lookup per turn at a time.
        for (project, app) in apps.iter_mut() {
            let (Want::Show(_), Some(step)) = (&app.want, app.step.as_mut()) else { continue };
            if step.looking || !recipients.contains(project) { continue }
            match step.checked {
                Some(at) if now.duration_since(at) < STEP_EVERY => due(at + STEP_EVERY),
                _ => {
                    step.looking = true;
                    lookups.push((project.clone(), step.key.clone()));
                }
            }
        }
        (sends, lookups, next)
    }

    /// Applies a send's result, if the link still waits for that send.
    fn settle(&mut self, send: Outgoing, failures: u32, outcome: Result<Outcome>, retry: Duration) {
        let now = Instant::now();
        let Some(device) = self.devices.get_mut(&send.device) else { return };
        let Some(link) = device.links.get_mut(&send.project) else { return };
        if link.flight != Flight::Sending(send.generation) {
            return; // superseded: a new activity token, or the link went away
        }
        link.flight = Flight::Idle;
        let mut save = false;
        match (&outcome, &send.message) {
            (Ok(Outcome::Sent | Outcome::Rejected(_)), Message::Start(_)) => link.stage = Stage::Starting { at: now },
            (Ok(Outcome::Sent | Outcome::Rejected(_)), Message::Update(content)) => {
                // A rejected update is not retried: the next change sends anew.
                if let Stage::Running { acked, .. } = &mut link.stage { *acked = Some((content.clone(), now)); }
            }
            (Ok(Outcome::Sent | Outcome::Rejected(_)), Message::End(_)) => {
                device.links.remove(&send.project);
                save = true;
            }
            (Ok(Outcome::Unregistered), message) => {
                device.links.remove(&send.project);
                if matches!(message, Message::Start(_)) && device.start_token.as_deref() == Some(&send.delivery.token) {
                    device.start_token = None;
                }
                save = true;
            }
            (Ok(Outcome::Retry(_)) | Err(_), _) => {
                link.flight = Flight::Waiting { until: now + backoff(retry, failures + 1), failures: failures + 1 };
            }
        }
        if save {
            self.save();
        }
    }
}

/// A send the reconciler decided on, with the generation its result must match.
struct Outgoing {
    device: String,
    project: String,
    generation: u64,
    message: Message,
    delivery: Delivery,
}

pub struct Push {
    root: PathBuf,
    /// Devices, presence, apps and pending notes; reached only by letters.
    owner: Owner<State>,
    fixed: Option<Arc<dyn Transport>>,
    timing: Timing,
    alerts_sent: AtomicU64,
    /// Wakes the reconciler after a shell change, a phone report or a result.
    wake: Notify,
}

impl Push {
    pub fn open(root: &Path) -> Result<Arc<Self>> {
        Self::build(root, None, Timing::default())
    }

    /// With a given transport and timing, for tests.
    pub fn with_transport(root: &Path, transport: Arc<dyn Transport>, timing: Timing) -> Result<Arc<Self>> {
        Self::build(root, Some(transport), timing)
    }

    fn build(root: &Path, fixed: Option<Arc<dyn Transport>>, timing: Timing) -> Result<Arc<Self>> {
        private_dir(&root.join("push"))?;
        let path = root.join("push").join("devices.json");
        let devices = if path.try_exists()? { read_json(&path)? } else { BTreeMap::new() };
        let owner = Owner::spawn("push", State { root: root.to_path_buf(), devices, ..State::default() });
        Ok(Arc::new(Self { root: root.to_path_buf(), owner, fixed, timing, alerts_sent: AtomicU64::new(0), wake: Notify::new() }))
    }

    pub fn set_threads(&self, threads: Arc<dyn Threads>) {
        self.owner.tell(move |s| s.threads = Some(threads));
    }

    /// The transport for the current key, reloaded when the key changes.
    async fn transport(&self) -> Result<Option<Arc<dyn Transport>>> {
        if let Some(fixed) = &self.fixed {
            return Ok(Some(fixed.clone()));
        }
        let path = key_path(&self.root);
        let Ok(modified) = std::fs::metadata(&path).and_then(|m| m.modified()) else {
            self.owner.ask(|s| s.loaded = None).await;
            return Ok(None);
        };
        let loaded = self.owner.ask(move |s| s.loaded.as_ref().filter(|(at, _)| *at == modified).map(|(_, t)| t.clone())).await;
        if let Some(transport) = loaded {
            return Ok(Some(transport));
        }
        let config = KeyConfig::load(&self.root)?.context("APNs key disappeared")?;
        let transport: Arc<dyn Transport> = Arc::new(Apns::new(&config)?);
        let made = transport.clone();
        self.owner.ask(move |s| s.loaded = Some((modified, made))).await;
        Ok(Some(transport))
    }

    // MARK: Phone reports

    pub async fn register(&self, r: Registration) -> Result<()> {
        ensure!(valid_id(&r.device_id), "invalid device ID");
        ensure!(valid_id(&r.bundle_id) && r.bundle_id.contains('.'), "invalid bundle ID");
        for token in [&r.token, &r.start_token].into_iter().flatten() {
            ensure!(valid_token(token), "a push token is hex");
        }
        self.owner.ask(move |s| {
            let device = s.devices.entry(r.device_id.clone()).or_insert_with(|| Device {
                id: r.device_id.clone(), token: None, environment: r.environment, bundle_id: r.bundle_id.clone(),
                start_token: None, links: BTreeMap::new(), updated_at: 0,
            });
            if device.environment != r.environment || device.bundle_id != r.bundle_id {
                // A different build: its activities belong to the old one.
                device.links.clear();
                device.token = None;
                device.start_token = None;
            }
            device.environment = r.environment;
            device.bundle_id = r.bundle_id;
            if r.token.is_some() { device.token = r.token; }
            if r.start_token.is_some() { device.start_token = r.start_token; }
            device.updated_at = crate::model::now();
            s.save();
        }).await;
        self.wake.notify_one();
        Ok(())
    }

    pub async fn register_activity(&self, r: ActivityRegistration) -> Result<()> {
        ensure!(valid_id(&r.project_id) && valid_id(&r.activity_id), "invalid ID");
        if let Some(token) = &r.token {
            ensure!(valid_token(token), "a push token is hex");
        }
        self.owner.ask(move |s| -> Result<()> {
            let device = s.devices.get_mut(&r.device_id).context("Register the device first")?;
            match r.token {
                Some(token) => {
                    // A new token supersedes whatever was in flight for the old one;
                    // the current content goes to it next. The phone repeats a known
                    // one each time Squircle opens, which changes nothing.
                    let activity = Activity { id: r.activity_id, token };
                    let known = device.links.get(&r.project_id)
                        .is_some_and(|l| matches!(&l.stage, Stage::Running { activity: a, .. } if *a == activity));
                    if !known {
                        device.links.insert(r.project_id, Link::new(Stage::Running { activity, acked: None }));
                    }
                }
                None => {
                    if device.links.get(&r.project_id)
                        .is_some_and(|l| matches!(&l.stage, Stage::Running { activity, .. } if activity.id == r.activity_id))
                    {
                        device.links.remove(&r.project_id);
                    }
                }
            }
            s.save();
            Ok(())
        }).await?;
        self.wake.notify_one();
        Ok(())
    }

    pub async fn report_presence(&self, r: PresenceReport) -> Result<()> {
        ensure!(valid_id(&r.device_id), "invalid device ID");
        let shown = if r.foreground { Shown::Foreground { thread: r.thread_id } } else { Shown::Background };
        self.owner.ask(move |s| { s.presence.insert(r.device_id, Presence { shown, until: Instant::now() + PRESENCE }); }).await;
        self.wake.notify_one();
        Ok(())
    }

    pub async fn status(&self) -> Value {
        let key = KeyConfig::load(&self.root).ok().flatten();
        let devices: Vec<Value> = self.owner.ask(|s| s.devices.values().map(|d| json!({
            "id": d.id, "environment": d.environment, "bundle_id": d.bundle_id,
            "notifications": d.token.is_some(), "live_activity_start": d.start_token.is_some(),
            "live_activities": d.running(), "updated_at": d.updated_at,
        })).collect()).await;
        json!({
            "configured": key.is_some() || self.fixed.is_some(),
            "key_id": key.as_ref().map(|k| k.key_id.clone()), "team_id": key.as_ref().map(|k| k.team_id.clone()),
            "transport": if self.fixed.is_some() { "test" } else { "apns" },
            "devices": devices,
        })
    }

    // MARK: Notifications

    /// Forgets a token Apple says is gone, wherever this device used it.
    async fn forget(&self, device: &str, token: &str) {
        let (device, token) = (device.to_string(), token.to_string());
        self.owner.ask(move |s| s.forget(&device, &token)).await
    }

    /// Queues a notification; notes within the burst window go out together.
    pub fn notify(self: &Arc<Self>, note: Note) {
        let this = self.clone();
        self.owner.tell(move |s| {
            s.pending.push(note);
            if s.pending.len() > 1 {
                return;
            }
            tokio::spawn(async move {
                tokio::time::sleep(this.timing.coalesce).await;
                this.flush().await;
            });
        });
    }

    /// Sends the batch; each alert retries transient failures on its own,
    /// under one collapse ID so a retry of a delivered alert replaces it.
    async fn flush(self: &Arc<Self>) {
        let deliveries = self.owner.ask(|s| {
            let notes = std::mem::take(&mut s.pending);
            s.alerts(&notes)
        }).await;
        for (device, mut delivery) in deliveries {
            let n = self.alerts_sent.fetch_add(1, Ordering::Relaxed);
            delivery.collapse_id = Some(format!("squircle-{}-{n}", crate::model::now()));
            let this = self.clone();
            tokio::spawn(async move { this.send_alert(device, delivery).await });
        }
    }

    async fn send_alert(&self, device: String, delivery: Delivery) {
        for attempt in 1..=ALERT_ATTEMPTS {
            let transport = match self.transport().await {
                Ok(Some(t)) => t,
                Ok(None) => return,
                Err(error) => { eprintln!("Push: {error:#}"); return }
            };
            let outcome = transport.send(&delivery).await;
            if matches!(outcome, Ok(Outcome::Unregistered)) {
                self.forget(&device, &delivery.token).await;
            }
            if !matches!(outcome, Ok(Outcome::Sent)) {
                eprintln!("Push to device {device} (try {attempt}): {}", describe(&outcome));
            }
            if !transient(&outcome) {
                return;
            }
            if attempt < ALERT_ATTEMPTS {
                tokio::time::sleep(backoff(self.timing.retry, attempt)).await;
            }
        }
    }

    /// `squircle push test`: a notification, and optionally a Live Activity,
    /// now, once each, reporting what Apple said.
    pub async fn test(&self, live: bool) -> Value {
        let note = Note { app: "Squircle".into(), line: "Notifications from your Mac work.".into(), target: Target::default() };
        let deliveries = self.owner.ask(move |s| {
            let mut deliveries = s.alerts(&[note]);
            if live {
                let content = LiveState { status: "Testing the Live Activity".into(), workers: 1, needs_you: false, working: true };
                for device in s.devices.values() {
                    let Some(token) = &device.start_token else { continue };
                    deliveries.push((device.id.clone(), Delivery {
                        token: token.clone(), environment: device.environment, bundle_id: device.bundle_id.clone(),
                        push_type: PushType::LiveActivity, priority: 10, collapse_id: None,
                        payload: activity_payload(LiveEvent::Start, &content, "Squircle", "test", crate::model::now()),
                    }));
                }
            }
            deliveries
        }).await;
        if deliveries.is_empty() {
            return json!({"sent": [], "note": "No phone has registered yet. Open Squircle on the phone and allow notifications."});
        }
        let transport = match self.transport().await {
            Ok(Some(t)) => t,
            Ok(None) => return json!({"sent": [{"error": "No APNs key. Run: squircle push setup --key-file PATH --key-id ID --team-id ID"}]}),
            Err(error) => return json!({"sent": [{"error": format!("{error:#}")}]}),
        };
        let mut results = vec![];
        for (device, delivery) in deliveries {
            let outcome = transport.send(&delivery).await;
            if matches!(outcome, Ok(Outcome::Unregistered)) {
                self.forget(&device, &delivery.token).await;
            }
            results.push(json!({"device": device, "result": describe(&outcome)}));
        }
        json!({"sent": results})
    }

    // MARK: Builds

    /// A finished device build. `app` is its catalog app, when the caller
    /// knows it, so even a failed build without output opens its app.
    pub fn build_finished(self: &Arc<Self>, job: &crate::model::Job, app: Option<&crate::apps::AppRecord>) {
        use crate::model::{BuildMode, BuildState};
        let Some(request) = job.request() else { return };
        if request.mode != BuildMode::Archive {
            return; // Agents' simulator builds are their own business.
        }
        let output = job.output();
        let record = app;
        let app = output.map(|o| o.title.clone()).filter(|t| !t.is_empty())
            .or_else(|| record.map(|r| r.name.clone())).unwrap_or_else(|| request.scheme.clone());
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
        let target = Target {
            app: record.map(|r| r.id.clone()), build: Some(job.id.clone()),
            bundle: output.map(|o| o.bundle_id.clone()).or_else(|| record.and_then(|r| r.bundle_id.clone())),
            ..Target::default()
        };
        self.notify(Note { app, line, target });
    }

    // MARK: Agents

    /// Called with each change to T3's shell: notes for finished turns and
    /// questions, and what each app's Live Activity should show.
    pub async fn apps_changed(self: &Arc<Self>, apps: Vec<AppView>) {
        let (changes, threads) = self.owner.ask(move |s| {
            let changes = s.changes(&apps);
            s.observe(&apps);
            (changes, s.threads.clone())
        }).await;
        self.wake.notify_one();
        for (app, project, thread, worker, change) in changes {
            let (this, threads) = (self.clone(), threads.clone());
            tokio::spawn(async move {
                if worker.is_none() && change == Change::Replied && let Some(t) = &threads && t.quiet(&thread).await {
                    return;
                }
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
    }

    /// Keeps every phone's activities in line with what each app wants, until
    /// the service stops. Runs on each change and at least every `TICK`.
    pub async fn run(self: Arc<Self>) {
        loop {
            let next = self.reconcile().await;
            let wait = next.map_or(TICK, |at| at.saturating_duration_since(Instant::now())).min(TICK);
            tokio::select! {
                _ = self.wake.notified() => {}
                _ = tokio::time::sleep(wait) => {}
            }
        }
    }

    /// One pass: decides the sends and step lookups due now, starts them, and
    /// returns when the next pass is due.
    async fn reconcile(self: &Arc<Self>) -> Option<Instant> {
        let transport = match self.transport().await {
            Ok(Some(t)) => t,
            Ok(None) => return None, // nobody to tell: no sends, no lookups
            Err(error) => { eprintln!("Push: {error:#}"); return None }
        };
        let timing = self.timing;
        let (sends, lookups, next) = self.owner.ask(move |s| s.reconcile(timing)).await;
        for (failures, send) in sends {
            let (this, transport) = (self.clone(), transport.clone());
            tokio::spawn(async move {
                let outcome = transport.send(&send.delivery).await;
                this.settle(send, failures, outcome).await;
            });
        }
        for (project, key) in lookups {
            let this = self.clone();
            tokio::spawn(async move { this.look_up(project, key).await });
        }
        next
    }

    /// Applies a send's result, if the link still waits for that send.
    async fn settle(&self, send: Outgoing, failures: u32, outcome: Result<Outcome>) {
        if !matches!(outcome, Ok(Outcome::Sent)) {
            eprintln!("Live Activity push to device {} ({}): {}", send.device, send.project, describe(&outcome));
        }
        let retry = self.timing.retry;
        self.owner.ask(move |s| s.settle(send, failures, outcome, retry)).await;
        self.wake.notify_one();
    }

    /// Reads the agent's current step for one turn; the text is kept only if
    /// that turn is still the one the activity shows.
    async fn look_up(&self, project: String, key: StepKey) {
        let threads = self.owner.ask(|s| s.threads.clone()).await;
        let text = match threads {
            Some(t) => tokio::time::timeout(STEP_DEADLINE, t.current_step(&key.thread)).await.ok().flatten(),
            None => None,
        };
        self.owner.ask(move |s| {
            let Some(step) = s.apps.get_mut(&project).and_then(|a| a.step.as_mut()).filter(|s| s.key == key) else { return };
            step.looking = false;
            step.checked = Some(Instant::now());
            if text.is_some() {
                step.text = text;
            }
        }).await;
        self.wake.notify_one();
    }
}

#[cfg(test)]
// Fakes record calls behind leaf locks; never held across a call.
#[allow(clippy::disallowed_types)]
mod tests {
    use super::*;
    use std::sync::Mutex;
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
        let timing = Timing { coalesce: Duration::from_millis(50), ..Timing::default() };
        let push = Push::with_transport(dir.path(), Arc::new(Apns::with_hosts(&config, &url, &url).unwrap()), timing).unwrap();
        push.register(Registration { device_id: "phone".into(), bundle_id: "ai.dreamslate.Squircle".into(),
            environment: Environment::Development, token: Some("ab".repeat(32)), start_token: None }).await.unwrap();
        push.register(Registration { device_id: "old".into(), bundle_id: "ai.dreamslate.Squircle".into(),
            environment: Environment::Production, token: Some(format!("dead{}", "0".repeat(28))), start_token: None }).await.unwrap();
        assert!(push.register(Registration { device_id: "x".into(), bundle_id: "ai.dreamslate.Squircle".into(),
            environment: Environment::Development, token: Some("../../x".into()), start_token: None }).await.is_err());
        push.report_presence(PresenceReport { device_id: "phone".into(), foreground: true, thread_id: Some("t1".into()) }).await.unwrap();
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
        let status = push.status().await;
        let old = status["devices"].as_array().unwrap().iter().find(|d| d["id"] == "old").unwrap();
        assert_eq!(old["notifications"], false, "a 410 forgets the token");
    }

    /// Answers each send of a kind from a script (then `Sent`), recording what went out.
    #[derive(Default)]
    struct Scripted {
        answers: Mutex<Vec<(PushType, Outcome)>>,
        sent: Mutex<Vec<Delivery>>,
    }

    impl Transport for Scripted {
        fn send<'a>(&'a self, delivery: &'a Delivery) -> BoxFuture<'a, Result<Outcome>> {
            self.sent.lock().unwrap().push(delivery.clone());
            let mut answers = self.answers.lock().unwrap();
            let next = answers.iter().position(|(kind, _)| *kind == delivery.push_type);
            let outcome = next.map_or(Outcome::Sent, |i| answers.remove(i).1);
            Box::pin(async move { Ok(outcome) })
        }
    }

    fn fast() -> Timing {
        Timing { coalesce: Duration::from_millis(10), retry: Duration::from_millis(30), pause: Duration::from_millis(40),
                 throttle: Duration::from_millis(20) }
    }

    fn app(agent: Value) -> Vec<AppView> {
        vec![AppView { project_id: "p".into(), app: "Notes".into(), agent: Some(("agent".into(), agent)), workers: vec![] }]
    }

    fn working(turn: &str) -> Value {
        json!({"latestTurn": {"turnId": turn, "state": "running"}})
    }

    async fn phone(push: &Push) {
        push.register(Registration { device_id: "phone".into(), bundle_id: "ai.dreamslate.Squircle".into(),
            environment: Environment::Development, token: Some("ab".repeat(32)), start_token: None }).await.unwrap();
        push.register_activity(ActivityRegistration { device_id: "phone".into(), project_id: "p".into(),
            activity_id: "a1".into(), token: Some("cd".repeat(32)) }).await.unwrap();
    }

    fn events(transport: &Scripted) -> Vec<String> {
        transport.sent.lock().unwrap().iter().filter(|d| d.push_type == PushType::LiveActivity)
            .map(|d| d.payload["aps"]["event"].as_str().unwrap().to_string()).collect()
    }

    #[tokio::test]
    async fn transient_failures_retry_and_an_end_keeps_its_token_until_accepted() {
        let dir = tempfile::tempdir().unwrap();
        let transport = Arc::new(Scripted::default());
        let push = Push::with_transport(dir.path(), transport.clone(), fast()).unwrap();
        tokio::spawn(push.clone().run());
        phone(&push).await;

        // An alert that APNs drops once arrives on the retry, under one collapse ID.
        transport.answers.lock().unwrap().push((PushType::Alert, Outcome::Retry("HTTP 503".into())));
        push.notify(Note { app: "Notes".into(), line: "Build failed".into(), target: Target::default() });
        tokio::time::sleep(Duration::from_millis(150)).await;
        let alerts: Vec<Delivery> = transport.sent.lock().unwrap().iter().filter(|d| d.push_type == PushType::Alert).cloned().collect();
        assert_eq!(alerts.len(), 2);
        transport.sent.lock().unwrap().clear();
        assert!(alerts[0].collapse_id.is_some() && alerts[0].collapse_id == alerts[1].collapse_id);

        push.apps_changed(app(working("t1"))).await;
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(events(&transport), ["update"]);

        // Idle past the pause: the End fails once, and the token survives it.
        transport.answers.lock().unwrap().push((PushType::LiveActivity, Outcome::Retry("HTTP 500".into())));
        push.apps_changed(app(json!({"latestTurn": {"turnId": "t1", "state": "completed"}}))).await;
        tokio::time::sleep(Duration::from_millis(60)).await;
        assert_eq!(events(&transport), ["update", "end"]);
        assert_eq!(push.status().await["devices"][0]["live_activities"], 1, "token kept for the retry");
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(events(&transport), ["update", "end", "end"]);
        assert_eq!(push.status().await["devices"][0]["live_activities"], 0, "forgotten once ended");
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(events(&transport).len(), 3, "nothing more once acknowledged");
    }

    /// The first lookup waits to be released; later ones answer at once.
    struct SlowSteps {
        calls: Mutex<Vec<String>>,
        release: tokio::sync::Notify,
    }

    impl Threads for SlowSteps {
        fn last_reply<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Option<String>> { Box::pin(async { None }) }
        fn quiet<'a>(&'a self, _: &'a str) -> BoxFuture<'a, bool> { Box::pin(async { false }) }
        fn question<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Option<String>> { Box::pin(async { None }) }
        fn current_step<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Option<String>> {
            let first = { let mut calls = self.calls.lock().unwrap(); calls.push("step".into()); calls.len() == 1 };
            Box::pin(async move {
                if first {
                    self.release.notified().await;
                    Some("Old turn's step".into())
                } else {
                    Some("New turn's step".into())
                }
            })
        }
    }

    #[tokio::test]
    async fn a_late_step_from_an_older_turn_is_dropped_and_steps_need_a_recipient() {
        let dir = tempfile::tempdir().unwrap();
        let transport = Arc::new(Scripted::default());
        let push = Push::with_transport(dir.path(), transport.clone(), fast()).unwrap();
        let steps = Arc::new(SlowSteps { calls: Mutex::default(), release: tokio::sync::Notify::new() });
        push.set_threads(steps.clone());
        tokio::spawn(push.clone().run());

        push.apps_changed(app(working("t1"))).await;
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(steps.calls.lock().unwrap().is_empty(), "no phone, no lookup");

        phone(&push).await;
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(steps.calls.lock().unwrap().len(), 1);
        push.apps_changed(app(working("t2"))).await;
        tokio::time::sleep(Duration::from_millis(50)).await;
        steps.release.notify_one();
        tokio::time::sleep(Duration::from_millis(50)).await;

        let statuses: Vec<String> = transport.sent.lock().unwrap().iter()
            .map(|d| d.payload["aps"]["content-state"]["status"].as_str().unwrap_or_default().to_string()).collect();
        assert!(statuses.contains(&"New turn's step".to_string()), "{statuses:?}");
        assert!(!statuses.contains(&"Old turn's step".to_string()), "{statuses:?}");
    }
}
