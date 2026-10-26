use super::*;

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
    /// Something now waits on the user: the phone opens what waits on them.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub waiting: bool,
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
    let same =
        |f: fn(&Target) -> &Option<String>| notes.iter().all(|n| f(&n.target) == f(&first.target));
    let target = Target {
        project: first.target.project.clone(),
        thread: if same(|t| &t.thread) {
            first.target.thread.clone()
        } else {
            None
        },
        build: if same(|t| &t.build) {
            first.target.build.clone()
        } else {
            None
        },
        app: first.target.app.clone(),
        bundle: first.target.bundle.clone(),
        waiting: notes.iter().all(|n| n.target.waiting),
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

pub fn activity_payload(
    event: LiveEvent,
    state: &LiveState,
    app: &str,
    project: &str,
    now: u64,
) -> Value {
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
        LiveEvent::Update if state.needs_you => {
            aps["alert"] = json!({"title": app, "body": state.status})
        }
        LiveEvent::Update => {}
    }
    json!({"aps": aps})
}
