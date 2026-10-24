#![cfg(test)]
// Test fakes only: leaf locks never held across a call.
#![allow(clippy::disallowed_types)]

use super::*;
use std::sync::Mutex;

// A throwaway P-256 key in Apple's .p8 format (PKCS#8 with public key).
fn key() -> KeyConfig {
    let rng = ring::rand::SystemRandom::new();
    let der = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
    let body = base64::engine::general_purpose::STANDARD.encode(der.as_ref());
    let lines: Vec<&str> = body
        .as_bytes()
        .chunks(64)
        .map(|c| std::str::from_utf8(c).unwrap())
        .collect();
    KeyConfig {
        key_id: "AB12CD34EF".into(),
        team_id: "2F26US4NAU".into(),
        key_pem: format!(
            "-----BEGIN PRIVATE KEY-----\n{}\n-----END PRIVATE KEY-----",
            lines.join("\n")
        ),
    }
}

fn verify(jwt: &str, public: &[u8]) -> (Value, Value) {
    let parts: Vec<&str> = jwt.split('.').collect();
    assert_eq!(parts.len(), 3);
    let decode = |s: &str| {
        base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(s)
            .unwrap()
    };
    ring::signature::UnparsedPublicKey::new(&ring::signature::ECDSA_P256_SHA256_FIXED, public)
        .verify(
            format!("{}.{}", parts[0], parts[1]).as_bytes(),
            &decode(parts[2]),
        )
        .expect("signature verifies");
    (
        serde_json::from_slice(&decode(parts[0])).unwrap(),
        serde_json::from_slice(&decode(parts[1])).unwrap(),
    )
}

#[test]
fn provider_token_is_es256_signed_by_the_key() {
    let signer = Signer::new(&key()).unwrap();
    let (header, claims) = verify(&signer.jwt(1_700_000_000).unwrap(), signer.public_key());
    assert_eq!(header, json!({"alg": "ES256", "kid": "AB12CD34EF"}));
    assert_eq!(
        claims,
        json!({"iss": "2F26US4NAU", "iat": 1_700_000_000u64})
    );
    assert!(
        Signer::new(&KeyConfig {
            key_pem: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----".into(),
            ..key()
        })
        .is_err()
    );
}

#[test]
fn turns_report_once_when_they_stop_or_ask() {
    let t = |s: &str| Some(s.to_string());
    let was = |turn: &str, p| (t(turn), p);
    assert_eq!(
        change(Some(&was("a", Phase::Working)), t("a"), Phase::Done),
        Some(Change::Replied)
    );
    assert_eq!(
        change(Some(&was("a", Phase::Done)), t("a"), Phase::Done),
        None
    );
    assert_eq!(
        change(Some(&was("a", Phase::Done)), t("b"), Phase::Done),
        Some(Change::Replied)
    );
    assert_eq!(
        change(Some(&was("a", Phase::Working)), t("a"), Phase::NeedsYou),
        Some(Change::Asks)
    );
    assert_eq!(
        change(Some(&was("a", Phase::NeedsYou)), t("a"), Phase::Done),
        None
    );
    assert_eq!(
        change(Some(&was("a", Phase::Working)), t("a"), Phase::Error),
        Some(Change::Failed)
    );
    assert_eq!(change(None, t("a"), Phase::Done), None);
    assert_eq!(change(Some(&(None, Phase::Done)), None, Phase::Done), None);
    assert_eq!(
        summary_line("\n## **Done.** Fixed `login` and pushed.\nMore"),
        "Done. Fixed login and pushed."
    );
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
        let next = answers
            .iter()
            .position(|(kind, _)| *kind == delivery.push_type);
        let outcome = next.map_or(Outcome::Sent, |i| answers.remove(i).1);
        Box::pin(async move { Ok(outcome) })
    }
}

fn fast() -> Timing {
    Timing {
        coalesce: Duration::from_millis(10),
        retry: Duration::from_millis(30),
        pause: Duration::from_millis(40),
        throttle: Duration::from_millis(20),
    }
}

fn app(agent: Value) -> Vec<AppView> {
    vec![AppView {
        project_id: "p".into(),
        app: "Notes".into(),
        agent: Some(("agent".into(), agent)),
        workers: vec![],
    }]
}

fn working(turn: &str) -> Value {
    json!({"latestRunId": turn, "status": "running"})
}

async fn phone(push: &Push) {
    push.register(Registration {
        device_id: "phone".into(),
        bundle_id: "ai.dreamslate.Squircle".into(),
        environment: Environment::Development,
        token: Some("ab".repeat(32)),
        start_token: None,
    })
    .await
    .unwrap();
    push.register_activity(ActivityRegistration {
        device_id: "phone".into(),
        project_id: "p".into(),
        activity_id: "a1".into(),
        token: Some("cd".repeat(32)),
    })
    .await
    .unwrap();
}

fn events(transport: &Scripted) -> Vec<String> {
    transport
        .sent
        .lock()
        .unwrap()
        .iter()
        .filter(|d| d.push_type == PushType::LiveActivity)
        .map(|d| d.payload["aps"]["event"].as_str().unwrap().to_string())
        .collect()
}

#[tokio::test]
async fn transient_failures_retry_and_an_end_keeps_its_token_until_accepted() {
    let dir = tempfile::tempdir().unwrap();
    let transport = Arc::new(Scripted::default());
    let push = Push::with_transport(dir.path(), transport.clone(), fast()).unwrap();
    tokio::spawn(push.clone().run());
    phone(&push).await;

    // An alert that APNs drops once arrives on the retry, under one collapse ID.
    transport
        .answers
        .lock()
        .unwrap()
        .push((PushType::Alert, Outcome::Retry("HTTP 503".into())));
    push.notify(Note {
        app: "Notes".into(),
        line: "Build failed".into(),
        target: Target::default(),
    });
    tokio::time::sleep(Duration::from_millis(150)).await;
    let alerts: Vec<Delivery> = transport
        .sent
        .lock()
        .unwrap()
        .iter()
        .filter(|d| d.push_type == PushType::Alert)
        .cloned()
        .collect();
    assert_eq!(alerts.len(), 2);
    transport.sent.lock().unwrap().clear();
    assert!(alerts[0].collapse_id.is_some() && alerts[0].collapse_id == alerts[1].collapse_id);

    push.apps_changed(app(working("t1"))).await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert_eq!(events(&transport), ["update"]);

    // Idle past the pause: the End fails once, and the token survives it.
    transport
        .answers
        .lock()
        .unwrap()
        .push((PushType::LiveActivity, Outcome::Retry("HTTP 500".into())));
    push.apps_changed(app(json!({"latestRunId": "t1", "status": "completed"})))
        .await;
    tokio::time::sleep(Duration::from_millis(60)).await;
    assert_eq!(events(&transport), ["update", "end"]);
    assert_eq!(
        push.status().await["devices"][0]["live_activities"],
        1,
        "token kept for the retry"
    );
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(events(&transport), ["update", "end", "end"]);
    assert_eq!(
        push.status().await["devices"][0]["live_activities"],
        0,
        "forgotten once ended"
    );
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(
        events(&transport).len(),
        3,
        "nothing more once acknowledged"
    );
}

/// The first lookup waits to be released; later ones answer at once.
struct SlowSteps {
    calls: Mutex<Vec<String>>,
    release: tokio::sync::Notify,
}

impl Threads for SlowSteps {
    fn last_reply<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Option<String>> {
        Box::pin(async { None })
    }
    fn quiet<'a>(&'a self, _: &'a str) -> BoxFuture<'a, bool> {
        Box::pin(async { false })
    }
    fn question<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Option<String>> {
        Box::pin(async { None })
    }
    fn current_step<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Option<String>> {
        let first = {
            let mut calls = self.calls.lock().unwrap();
            calls.push("step".into());
            calls.len() == 1
        };
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
    let steps = Arc::new(SlowSteps {
        calls: Mutex::default(),
        release: tokio::sync::Notify::new(),
    });
    push.set_threads(steps.clone());
    tokio::spawn(push.clone().run());

    push.apps_changed(app(working("t1"))).await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(
        steps.calls.lock().unwrap().is_empty(),
        "no phone, no lookup"
    );

    phone(&push).await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert_eq!(steps.calls.lock().unwrap().len(), 1);
    push.apps_changed(app(working("t2"))).await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    steps.release.notify_one();
    tokio::time::sleep(Duration::from_millis(50)).await;

    let statuses: Vec<String> = transport
        .sent
        .lock()
        .unwrap()
        .iter()
        .map(|d| {
            d.payload["aps"]["content-state"]["status"]
                .as_str()
                .unwrap_or_default()
                .to_string()
        })
        .collect();
    assert!(
        statuses.contains(&"New turn's step".to_string()),
        "{statuses:?}"
    );
    assert!(
        !statuses.contains(&"Old turn's step".to_string()),
        "{statuses:?}"
    );
}
