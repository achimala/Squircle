//! The phone's event stream: one long-lived reply (server-sent events) that
//! says what changed, so the phone fetches exactly that instead of asking
//! again every few seconds. Every notice follows a change an owner
//! published, a write this process made, or the kernel reporting a running
//! build's log growing; nothing here waits for a time.
//!
//! A notice is `{"topic": T}` or `{"topic": T, "id": ID}`:
//! - `builds`, `apps`, `agents`, `sims`, `waiting`: that list's reply
//!   (`GET /v1/builds`, `/v1/apps`, …) is no longer the one last noticed;
//! - `tasks` with a project ID: that app's `GET /v1/tasks?project=ID`;
//! - `media` with a thread ID, or without one when any thread's may have:
//!   `GET /v1/t3/threads/ID/media`;
//! - `log` with a build ID: that running build's log grew;
//! - `installs`: an install link's transfer moved on.
//!
//! The stream opens with a `ready` event, sent once it is listening: what
//! the phone fetches after it misses nothing. A list's notice is sent only
//! when its reply really differs (the same body the ETag is made of), so a
//! busy T3 doesn't turn into requests from the phone.

use super::*;
use axum::response::sse::{Event, Sse};
use futures_util::{
    FutureExt, StreamExt,
    stream::{BoxStream, FuturesUnordered},
};
use std::collections::{HashMap, HashSet};
use tokio::sync::{broadcast, mpsc};
use tokio_util::sync::CancellationToken;

/// `GET /v1/events`.
pub(super) async fn events(State(state): State<AppState>) -> Response {
    // Listening before looking, so a change while the first replies are
    // read is noticed.
    let mut sources = vec![state.jobs.changes(), counted(&state.catalog_changed)];
    sources.extend(state.agents.as_ref().map(|a| a.changes()));
    sources.extend(state.tasks.as_ref().map(|t| t.changes()));
    sources.extend(state.sims.as_ref().map(|s| s.changes()));
    let changes = futures_util::stream::select_all(sources).boxed();
    let installs = counted(&state.installs_changed);
    let media = crate::media::changes();
    let (notices, sent) = mpsc::channel::<Event>(64);
    tokio::spawn(feed(state, changes, installs, media, notices));
    let body = futures_util::stream::unfold(sent, |mut sent| async move {
        let event = sent.recv().await?;
        Some((Ok::<_, std::convert::Infallible>(event), sent))
    });
    let mut response = Sse::new(body).into_response();
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
}

/// Sends notices until the phone goes (its reply is dropped) or the service
/// stops.
async fn feed(
    state: AppState,
    mut changes: BoxStream<'static, ()>,
    mut installs: BoxStream<'static, ()>,
    mut media: broadcast::Receiver<String>,
    notices: mpsc::Sender<Event>,
) {
    let mut seen = HashMap::new();
    lists(&state, &mut seen).await;
    let mut logs = Logs::default();
    logs.follow(&state);
    if notices
        .send(Event::default().event("ready").data("{}"))
        .await
        .is_err()
    {
        return;
    }
    loop {
        let found: Vec<Value> = tokio::select! {
            () = notices.closed() => return,
            changed = changes.next() => {
                if changed.is_none() {
                    return;
                }
                // Changes already waiting are one look.
                while let Some(Some(())) = changes.next().now_or_never() {}
                logs.follow(&state);
                lists(&state, &mut seen).await
            }
            changed = installs.next() => {
                if changed.is_none() {
                    return;
                }
                vec![json!({"topic": "installs"})]
            }
            thread = media.recv() => match thread {
                Ok(thread) => vec![json!({"topic": "media", "id": thread})],
                Err(broadcast::error::RecvError::Lagged(_)) => vec![json!({"topic": "media"})],
                Err(broadcast::error::RecvError::Closed) => return,
            },
            Some(build) = logs.next() => vec![json!({"topic": "log", "id": build})],
        };
        for notice in found {
            if notices
                .send(Event::default().data(notice.to_string()))
                .await
                .is_err()
            {
                return;
            }
        }
    }
}

/// Reads every list the phone keeps and returns a notice for each whose
/// reply differs from the one `seen` holds (none the first time).
async fn lists(state: &AppState, seen: &mut HashMap<String, String>) -> Vec<Value> {
    let first = seen.is_empty();
    let mut now: Vec<(String, Option<String>, Value)> = Vec::new();
    let mut add = |topic: &str, id: Option<String>, reply: ApiResult<Json<Value>>| {
        if let Ok(Json(reply)) = reply {
            now.push((topic.to_string(), id, reply));
        }
    };
    add("builds", None, list(State(state.clone())).await);
    add("apps", None, list_apps(State(state.clone())).await);
    if state.agents.is_some() {
        add("agents", None, list_agents(State(state.clone())).await);
        add("waiting", None, list_waiting(State(state.clone())).await);
    }
    if let Some(sims) = &state.sims {
        add("sims", None, Ok(Json(sims.list(None)["active"].clone())));
    }
    if let Some(tasks) = &state.tasks {
        let projects: HashSet<String> = tasks.all().into_iter().map(|t| t.project_id).collect();
        for project in projects {
            let query = Query(TaskQuery {
                project: Some(project.clone()),
                thread: None,
                history_limit: None,
                history_before: None,
            });
            add(
                "tasks",
                Some(project),
                list_tasks(State(state.clone()), Ok(query)).await,
            );
        }
    }
    let mut changed = Vec::new();
    for (topic, id, reply) in now {
        let key = match &id {
            Some(id) => format!("{topic}:{id}"),
            None => topic.clone(),
        };
        let tag = etag(&serde_json::to_vec(&reply).unwrap_or_default());
        if seen.insert(key, tag.clone()).as_ref() != Some(&tag) && !first {
            changed.push(match id {
                Some(id) => json!({"topic": topic, "id": id}),
                None => json!({"topic": topic}),
            });
        }
    }
    changed
}

/// The logs of running builds, each watched by the kernel while it runs.
#[derive(Default)]
struct Logs {
    watching: HashMap<String, CancellationToken>,
    grew: FuturesUnordered<futures_util::future::BoxFuture<'static, Option<Grew>>>,
}

/// A watched log that changed: watched again (opened afresh, so a
/// replaced file is followed) unless its build stopped running meanwhile.
struct Grew {
    id: String,
    log: PathBuf,
    stop: CancellationToken,
}

impl Logs {
    /// Watches the log of every build running now, and stops watching the rest.
    fn follow(&mut self, state: &AppState) {
        let running: HashSet<String> = state
            .jobs
            .list()
            .iter()
            .filter(|v| matches!(v.job.state(), BuildState::Running))
            .map(|v| v.job.id.clone())
            .collect();
        self.watching.retain(|id, stop| {
            let keep = running.contains(id);
            if !keep {
                stop.cancel();
            }
            keep
        });
        for id in running {
            if self.watching.contains_key(&id) {
                continue;
            }
            let Ok(log) = state.files.job_dir(&id).map(|dir| dir.join("build.log")) else {
                continue;
            };
            let stop = CancellationToken::new();
            // Not written yet: the job's next change looks again.
            if self.watch(Grew {
                id: id.clone(),
                log,
                stop: stop.clone(),
            }) {
                self.watching.insert(id, stop);
            }
        }
    }

    fn watch(&mut self, log: Grew) -> bool {
        let Ok(changes) = crate::kq::Changes::watch(&log.log) else {
            return false;
        };
        self.grew.push(
            async move {
                tokio::select! {
                    () = log.stop.cancelled() => None,
                    grew = changes.next() => grew.ok().map(|()| log),
                }
            }
            .boxed(),
        );
        true
    }

    /// The next running build whose log grew; pending while none is watched.
    async fn next(&mut self) -> Option<String> {
        loop {
            match self.grew.next().await {
                Some(Some(grew)) => {
                    let id = grew.id.clone();
                    if !self.watch(grew) {
                        self.watching.remove(&id);
                    }
                    return Some(id);
                }
                Some(None) => continue,
                None => futures_util::future::pending().await,
            }
        }
    }
}
