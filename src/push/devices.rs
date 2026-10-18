use super::*;

// MARK: Devices

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Activity {
    pub id: String,
    pub token: String,
}

/// Where one phone's Live Activity for one app stands, as far as APNs has
/// accepted. Absent from the map: the phone has none we know of.
#[derive(Clone, Debug)]
pub(super) enum Stage {
    /// Nothing running; kept only while a failed start backs off.
    Absent,
    /// APNs accepted a push-to-start; the phone reports the new activity's token.
    Starting { at: Instant },
    /// A running activity. `acked` is the content APNs last accepted for it;
    /// its token is kept until an End is accepted or Apple says it is gone.
    Running {
        activity: Activity,
        acked: Option<(LiveState, Instant)>,
    },
}

/// The send for a link: none, one in flight (by generation), or a failure
/// waiting out its backoff.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) enum Flight {
    Idle,
    Sending(u64),
    Waiting { until: Instant, failures: u32 },
}

#[derive(Clone, Debug)]
pub(super) struct Link {
    pub(super) stage: Stage,
    pub(super) flight: Flight,
}

impl Link {
    pub(super) fn new(stage: Stage) -> Self {
        Self {
            stage,
            flight: Flight::Idle,
        }
    }
}

/// devices.json keeps each running activity's ID and token, as before;
/// everything else about a link lives only in memory.
mod persisted_links {
    use super::{Activity, Link, Stage};
    use serde::{Deserialize, Deserializer, Serialize, Serializer};
    use std::collections::BTreeMap;

    pub fn serialize<S: Serializer>(
        links: &BTreeMap<String, Link>,
        s: S,
    ) -> Result<S::Ok, S::Error> {
        let running: BTreeMap<&String, &Activity> = links
            .iter()
            .filter_map(|(project, link)| match &link.stage {
                Stage::Running { activity, .. } => Some((project, activity)),
                _ => None,
            })
            .collect();
        running.serialize(s)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(
        d: D,
    ) -> Result<BTreeMap<String, Link>, D::Error> {
        Ok(BTreeMap::<String, Activity>::deserialize(d)?
            .into_iter()
            .map(|(project, activity)| {
                (
                    project,
                    Link::new(Stage::Running {
                        activity,
                        acked: None,
                    }),
                )
            })
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
    pub(super) links: BTreeMap<String, Link>,
    pub updated_at: u64,
}

impl Device {
    pub(super) fn running(&self) -> usize {
        self.links
            .values()
            .filter(|l| matches!(l.stage, Stage::Running { .. }))
            .count()
    }
}

/// What a phone reported it shows. A report holds for `PRESENCE`, so a phone
/// that died with Squircle open doesn't silence a thread forever.
#[derive(Clone, Debug, PartialEq)]
pub(super) enum Shown {
    Background,
    Foreground { thread: Option<String> },
}

pub(super) struct Presence {
    pub(super) shown: Shown,
    pub(super) until: Instant,
}

impl Presence {
    pub(super) fn shown(&self) -> Shown {
        if Instant::now() < self.until {
            self.shown.clone()
        } else {
            Shown::Background
        }
    }
}

pub(super) fn shown(presence: &HashMap<String, Presence>, device: &str) -> Shown {
    presence
        .get(device)
        .map_or(Shown::Background, Presence::shown)
}

pub(super) fn valid_token(token: &str) -> bool {
    (16..=400).contains(&token.len()) && token.chars().all(|c| c.is_ascii_hexdigit())
}

pub(super) fn valid_id(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
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

impl Push {
    // MARK: Phone reports

    pub async fn register(&self, r: Registration) -> Result<()> {
        ensure!(valid_id(&r.device_id), "invalid device ID");
        ensure!(
            valid_id(&r.bundle_id) && r.bundle_id.contains('.'),
            "invalid bundle ID"
        );
        for token in [&r.token, &r.start_token].into_iter().flatten() {
            ensure!(valid_token(token), "a push token is hex");
        }
        self.owner
            .ask(move |s| {
                let device = s
                    .devices
                    .entry(r.device_id.clone())
                    .or_insert_with(|| Device {
                        id: r.device_id.clone(),
                        token: None,
                        environment: r.environment,
                        bundle_id: r.bundle_id.clone(),
                        start_token: None,
                        links: BTreeMap::new(),
                        updated_at: 0,
                    });
                if device.environment != r.environment || device.bundle_id != r.bundle_id {
                    // A different build: its activities belong to the old one.
                    device.links.clear();
                    device.token = None;
                    device.start_token = None;
                }
                device.environment = r.environment;
                device.bundle_id = r.bundle_id;
                if r.token.is_some() {
                    device.token = r.token;
                }
                if r.start_token.is_some() {
                    device.start_token = r.start_token;
                }
                device.updated_at = crate::model::now();
                s.save();
            })
            .await;
        self.wake.notify_one();
        Ok(())
    }

    pub async fn register_activity(&self, r: ActivityRegistration) -> Result<()> {
        ensure!(
            valid_id(&r.project_id) && valid_id(&r.activity_id),
            "invalid ID"
        );
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
        let shown = if r.foreground {
            Shown::Foreground {
                thread: r.thread_id,
            }
        } else {
            Shown::Background
        };
        self.owner
            .ask(move |s| {
                s.presence.insert(
                    r.device_id,
                    Presence {
                        shown,
                        until: Instant::now() + PRESENCE,
                    },
                );
            })
            .await;
        self.wake.notify_one();
        Ok(())
    }

    pub async fn status(&self) -> Value {
        let key = KeyConfig::load(&self.root).ok().flatten();
        let devices: Vec<Value> = self
            .owner
            .ask(|s| {
                s.devices.values().map(|d| json!({
            "id": d.id, "environment": d.environment, "bundle_id": d.bundle_id,
            "notifications": d.token.is_some(), "live_activity_start": d.start_token.is_some(),
            "live_activities": d.running(), "updated_at": d.updated_at,
        })).collect()
            })
            .await;
        json!({
            "configured": key.is_some() || self.fixed.is_some(),
            "key_id": key.as_ref().map(|k| k.key_id.clone()), "team_id": key.as_ref().map(|k| k.team_id.clone()),
            "transport": if self.fixed.is_some() { "test" } else { "apns" },
            "devices": devices,
        })
    }
}
