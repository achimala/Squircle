#![cfg(test)]
// Test fakes only: leaf locks never held across a call.
#![allow(clippy::disallowed_types)]

use super::*;
use std::sync::Mutex;

fn thread(turn: Option<&str>, turn_state: &str, session: &str, needs: bool) -> Value {
    json!({
        "latestTurn": turn.map(|t| json!({"turnId": t, "state": turn_state})),
        "session": {"status": session}, "hasPendingApprovals": false, "hasPendingUserInput": needs,
    })
}

#[test]
fn worker_mode_inherits_its_coordinators_unless_asked() {
    let mode =
        |driver, coordinator, requested| worker_mode(driver, coordinator, requested).unwrap().0;
    assert_eq!(mode("claudeAgent", Some("auto"), None), "auto");
    assert_eq!(mode("codex", Some("auto"), None), "auto");
    assert_eq!(
        mode("claudeAgent", Some("approval-required"), None),
        "approval-required"
    );
    assert_eq!(mode("antigravity", Some("auto"), None), "auto-accept-edits");
    // Asked for explicitly, a mode is kept as is, even where it asks more.
    assert_eq!(mode("antigravity", Some("auto"), Some("auto")), "auto");
    assert_eq!(
        mode("claudeAgent", Some("auto"), Some("full-access")),
        "full-access"
    );
    // An agent mode T3 doesn't report, or that isn't known, is never assumed.
    assert!(worker_mode("claudeAgent", None, None).is_err());
    assert!(worker_mode("claudeAgent", Some("bogus"), None).is_err());
    assert!(worker_mode("claudeAgent", Some("auto"), Some("yolo")).is_err());
}

#[test]
fn wakes_once_per_turn_outcome() {
    let wake = |row: Value| ThreadObservation::decode(&row).wake();
    // Not started yet, and running, call for nothing.
    assert_eq!(wake(thread(None, "", "starting", false)), None);
    assert_eq!(wake(thread(Some("a"), "running", "running", false)), None);
    // A question mid-turn wakes; the same turn finishing wakes again.
    assert_eq!(
        wake(thread(Some("a"), "running", "running", true)),
        Some(event("a:needs-you"))
    );
    assert_eq!(
        wake(thread(Some("a"), "completed", "ready", false)),
        Some(event("a:done"))
    );
    // A session that stopped between turns is still the same outcome.
    assert_eq!(
        wake(thread(Some("a"), "completed", "stopped", false)),
        Some(event("a:done"))
    );
    assert_eq!(
        wake(thread(Some("b"), "error", "error", false)),
        Some(event("b:error"))
    );
}

#[test]
fn waiting_on_the_user_is_a_live_turn() {
    let observe = |turn: &str, session: &str, needs: bool| {
        ThreadObservation::decode(&thread(Some("a"), turn, session, needs))
    };
    // A question or approval keeps the turn, and its session, running.
    let asking = observe("running", "running", true);
    assert_eq!(
        (asking.phase(), asking.execution),
        (Phase::NeedsYou, Execution::Running)
    );
    assert!(observe("completed", "ready", true).busy());
    // Between turns the session is live but idle; only `stopped` is stopped.
    assert_eq!(
        observe("completed", "ready", false).execution,
        Execution::Idle
    );
    assert_eq!(observe("error", "error", false).execution, Execution::Idle);
    assert_eq!(
        observe("interrupted", "stopped", true).execution,
        Execution::Stopped
    );
    // A status this service doesn't know is not assumed stopped.
    assert!(observe("completed", "paused", false).busy());
}

#[test]
fn reads_the_registry_written_before_typed_states() {
    let registry: Registry = serde_json::from_value(json!({
        "agents": {
            "p": {"project_id": "p", "thread_id": "a", "created_at": 1, "pending": {"kind": "fresh", "note": null},
                  "replacing": {"previous": "a", "thread_id": "b", "model": "m", "runtime_mode": "auto",
                                "handoff": "h", "message_id": "m1", "handoff_sent": true}, "reset_error": "x"},
            "q": {"project_id": "q", "thread_id": "c", "created_at": 1, "refresh": true},
        },
        "workers": {"w": {"coordinator": "a", "project_id": "p", "title": "W", "branch": "w", "base": "main",
                          "created_at": 1, "notified": "t:needs-you:R", "archived": true}},
        "outbox": [{"coordinator": "a", "message_id": "m2", "workers": [["w", "t:done"]], "text": "", "record": null, "attempted": true}],
    })).unwrap();
    let Lifecycle::Replacing {
        replacement, error, ..
    } = &registry.agents["p"].lifecycle
    else {
        panic!()
    };
    assert_eq!(
        (replacement.delivery, error.as_deref()),
        (Delivery::OutcomeUnknown, Some("x"))
    );
    assert_eq!(
        registry.agents["q"].lifecycle,
        Lifecycle::Ready { refresh: true }
    );
    let worker = &registry.workers["w"];
    assert_eq!(
        (worker.stage.clone(), worker.notified.clone()),
        (
            Stage::Archived,
            Some(WorkerEvent {
                turn: "t".into(),
                kind: EventKind::NeedsYou,
                request: Some("R".into())
            })
        )
    );
    assert_eq!(
        (
            registry.outbox[0].outbound.delivery,
            &registry.outbox[0].workers[0].1
        ),
        (Delivery::OutcomeUnknown, &event("t:done"))
    );
    // Contradictory flags are reported, not guessed at.
    assert!(
        serde_json::from_value::<Agent>(
            json!({"project_id": "p", "thread_id": "a", "created_at": 1,
        "creating": true, "pending": {"kind": "restart"}})
        )
        .is_err()
    );
}

fn event(key: &str) -> WorkerEvent {
    serde_json::from_value(json!(key)).unwrap()
}

#[test]
fn a_second_question_in_a_turn_wakes_again() {
    let asking = ThreadObservation::decode(&thread(Some("t"), "running", "running", true));
    assert!(event("t:needs-you:A").covers(&asking.wake().unwrap()));
    // Answered: working again forgets the question, so the next is new.
    let working = ThreadObservation::decode(&thread(Some("t"), "running", "running", false));
    assert_eq!(
        working.progressed(Some(&event("t:needs-you:A"))),
        Some(event("t:working"))
    );
    assert!(!event("t:working").covers(&asking.wake().unwrap()));
    assert_eq!(working.progressed(Some(&event("t:done"))), None);
    let detail = |acts: Value| json!({"activities": acts});
    let ask = |kind: &str, id: &str| json!({"kind": kind, "payload": {"requestId": id}});
    assert_eq!(
        pending_request(&detail(json!([
            ask("user-input.requested", "A"),
            ask("user-input.resolved", "A"),
            ask("approval.requested", "B")
        ])))
        .as_deref(),
        Some("B")
    );
    assert_eq!(
        pending_request(&detail(json!([
            ask("approval.requested", "B"),
            ask("approval.resolved", "B")
        ]))),
        None
    );
}

#[test]
fn context_goes_to_the_deepest_project() {
    let temp = tempfile::tempdir().unwrap();
    let repo = temp.path().join("repo");
    let example = repo.join("examples/App");
    std::fs::create_dir_all(example.join("src")).unwrap();
    std::os::unix::fs::symlink(&example, temp.path().join("alias")).unwrap();
    let roots = [repo.as_path(), example.as_path()];
    assert_eq!(deepest_root(&roots, &example.join("src")), Ok(Some(1)));
    assert_eq!(
        deepest_root(&[example.as_path(), repo.as_path()], &example),
        Ok(Some(0))
    );
    assert_eq!(deepest_root(&roots, &repo.join("examples")), Ok(Some(0)));
    assert_eq!(
        deepest_root(&roots, &temp.path().join("alias/src")),
        Ok(Some(1))
    );
    assert_eq!(deepest_root(&roots, temp.path()), Ok(None));
    // `/repo-other` is not inside `/repo`.
    assert_eq!(
        deepest_root(&roots, &temp.path().join("repo-other")),
        Ok(None)
    );
    assert_eq!(
        deepest_root(&[repo.as_path(), example.as_path(), repo.as_path()], &repo),
        Err(vec![0, 2])
    );
}

type DispatchHook = Box<dyn Fn(&Value) + Send>;
type SnapshotHook = Box<dyn Fn(&str) -> Option<Value> + Send>;

/// T3 as the agents see it: records commands, creates thread rows in
/// the shell after a delay, and remembers the messages it accepted. Like
/// T3, it keeps a receipt per command ID: an accepted ID sent again is
/// answered from it and changes nothing.
#[derive(Default)]
struct Fake {
    /// The agents it shows new threads to: the latest opened.
    agents: Mutex<std::sync::Weak<Agents>>,
    log: Mutex<Vec<Value>>,
    receipts: Mutex<HashMap<String, bool>>,
    messages: Mutex<HashMap<String, Vec<String>>>,
    activities: Mutex<HashMap<String, Value>>,
    /// The next dispatch of this type fails; `true` if T3 applied it anyway (a lost acknowledgement).
    fail: Mutex<Vec<(&'static str, bool)>>,
    shell_delay: Mutex<Duration>,
    on_dispatch: Mutex<Option<DispatchHook>>,
    /// A shell item T3 sends while a thread's detail is read.
    on_snapshot: Mutex<Option<SnapshotHook>>,
}

impl Fake {
    fn agents(&self) -> Arc<Agents> {
        self.agents.lock().unwrap().upgrade().unwrap()
    }
    fn sent(&self, kind: &str) -> Vec<Value> {
        self.log
            .lock()
            .unwrap()
            .iter()
            .filter(|c| c["type"] == kind)
            .cloned()
            .collect()
    }
}

impl Peer for Fake {
    fn call<'a>(&'a self, tag: &'a str, _: Value) -> crate::push::BoxFuture<'a, Result<Value>> {
        assert_eq!(tag, "server.getConfig");
        Box::pin(async {
            Ok(
                json!({"providers": [{"instanceId": INSTANCE, "status": "ready"},
            {"instanceId": "claudeAgent", "driver": "claudeAgent", "status": "ready", "models": [{"slug": "m"}]}]}),
            )
        })
    }
    fn dispatch<'a>(&'a self, command: &'a Command) -> crate::push::BoxFuture<'a, Dispatched> {
        Box::pin(async move {
            let command = command.body().clone();
            tokio::time::sleep(Duration::from_millis(20)).await;
            let id = command["commandId"]
                .as_str()
                .expect("every command has its identity")
                .to_string();
            assert!(command["createdAt"].is_string());
            match self.receipts.lock().unwrap().get(&id) {
                Some(true) => return Dispatched::Accepted(json!({"sequence": 1})),
                Some(false) => return Dispatched::Refused("Previously rejected".into()),
                None => {}
            }
            self.log.lock().unwrap().push(command.clone());
            if let Some(hook) = &*self.on_dispatch.lock().unwrap() {
                hook(&command);
            }
            let failure = {
                let mut fail = self.fail.lock().unwrap();
                fail.iter()
                    .position(|(kind, _)| command["type"] == *kind)
                    .map(|i| fail.remove(i).1)
            };
            if failure == Some(false) {
                self.receipts.lock().unwrap().insert(id, false);
                return Dispatched::Refused("T3 rejected the command".into());
            }
            self.receipts.lock().unwrap().insert(id, true);
            match command["type"].as_str() {
                Some("thread.create") => {
                    let row = json!({"id": command["threadId"], "projectId": command["projectId"], "runtimeMode": command["runtimeMode"],
                                     "modelSelection": command["modelSelection"], "session": null, "archivedAt": null});
                    let (agents, delay) = (self.agents(), *self.shell_delay.lock().unwrap());
                    tokio::spawn(async move {
                        tokio::time::sleep(delay).await;
                        agents
                            .consume_shell(&json!({"kind": "thread-upserted", "thread": row}))
                            .await;
                    });
                }
                Some("thread.turn.start") => {
                    self.messages
                        .lock()
                        .unwrap()
                        .entry(command["threadId"].as_str().unwrap().into())
                        .or_default()
                        .push(command["message"]["messageId"].as_str().unwrap().into());
                }
                _ => {}
            }
            if failure == Some(true) {
                return Dispatched::Unknown("T3 did not answer".into());
            }
            Dispatched::Accepted(json!({"sequence": 1}))
        })
    }
    fn snapshot<'a>(
        &'a self,
        _: &'a str,
        payload: Value,
    ) -> crate::push::BoxFuture<'a, Result<Value>> {
        Box::pin(async move {
            let id = payload["threadId"].as_str().unwrap();
            let item = self
                .on_snapshot
                .lock()
                .unwrap()
                .as_ref()
                .and_then(|hook| hook(id));
            if let Some(item) = item {
                self.agents().consume_shell(&item).await;
            }
            let messages: Vec<Value> = self
                .messages
                .lock()
                .unwrap()
                .get(id)
                .into_iter()
                .flatten()
                .map(|m| json!({"id": m, "role": "user", "text": "x"}))
                .collect();
            let activities = self
                .activities
                .lock()
                .unwrap()
                .get(id)
                .cloned()
                .unwrap_or(json!([]));
            Ok(
                json!({"snapshot": {"thread": {"id": id, "messages": messages, "activities": activities}}}),
            )
        })
    }
}

fn row(
    id: &str,
    project: &str,
    mode: &str,
    turn: &str,
    turn_state: &str,
    session: &str,
    needs: bool,
) -> Value {
    json!({"id": id, "projectId": project, "runtimeMode": mode, "archivedAt": null,
           "modelSelection": {"instanceId": INSTANCE, "model": "m"},
           "latestTurn": {"turnId": turn, "state": turn_state}, "session": {"status": session},
           "hasPendingApprovals": false, "hasPendingUserInput": needs})
}

/// Agents on a fake T3 with one project, `p`, rooted at `workspace`.
async fn fake_agents(
    temp: &Path,
    workspace: &Path,
    threads: Vec<Value>,
) -> (Arc<Agents>, Arc<Fake>) {
    let tasks = Arc::new(Tasks::open(temp).unwrap());
    let agents = Agents::open(temp, "http://127.0.0.1:1", tasks).unwrap();
    let fake = Arc::new(Fake::default());
    assert!(agents.fake.set(fake.clone()).is_ok());
    *fake.agents.lock().unwrap() = Arc::downgrade(&agents);
    agents.consume_shell(&json!({"kind": "snapshot", "snapshot": {
        "projects": [{"id": "p", "title": "App", "workspaceRoot": workspace}], "threads": threads}})).await;
    (agents, fake)
}

async fn registered(agents: &Agents, f: impl FnOnce(&mut Registry) + Send + 'static) {
    agents.change(f).await.unwrap();
}

fn worker(coordinator: &str) -> Worker {
    Worker {
        coordinator: coordinator.into(),
        project_id: "p".into(),
        title: "W".into(),
        branch: "w".into(),
        base: "main".into(),
        created_at: 0,
        notified: None,
        stage: Stage::Active,
    }
}

fn agent(thread: &str) -> Agent {
    Agent {
        project_id: "p".into(),
        thread_id: thread.into(),
        created_at: 0,
        lifecycle: Lifecycle::Ready { refresh: false },
    }
}

#[tokio::test]
async fn first_use_creates_one_agent_in_the_chosen_mode() {
    let temp = tempfile::tempdir().unwrap();
    let (agents, fake) = fake_agents(temp.path(), temp.path(), vec![]).await;
    // The shell shows the new thread only after both requests have asked.
    *fake.shell_delay.lock().unwrap() = Duration::from_millis(300);
    let (a, b) = tokio::join!(
        agents.ensure("p", None, None, Some("approval-required")),
        agents.ensure("p", None, None, Some("approval-required"))
    );
    assert_eq!(a.unwrap().thread_id, b.unwrap().thread_id);
    let created = fake.sent("thread.create");
    assert_eq!(created.len(), 1);
    assert_eq!(created[0]["runtimeMode"], "approval-required");
    assert!(agents.ensure("p", None, None, Some("ask")).await.is_err());
}

#[tokio::test]
async fn an_unconfirmed_creation_is_finished_not_repeated() {
    let temp = tempfile::tempdir().unwrap();
    let (agents, fake) = fake_agents(temp.path(), temp.path(), vec![]).await;
    fake.fail.lock().unwrap().push(("thread.create", false));
    assert!(agents.ensure("p", None, None, None).await.is_err());
    let reserved = agents.list()[0].clone();
    assert_eq!(reserved.lifecycle, Lifecycle::Creating { command: None });
    let agent = agents.ensure("p", None, None, None).await.unwrap();
    assert_eq!(agent.thread_id, reserved.thread_id);
    assert_eq!(
        agents.list()[0].lifecycle,
        Lifecycle::Ready { refresh: false }
    );
    let created = fake.sent("thread.create");
    assert_eq!(created.len(), 2);
    assert!(
        created
            .iter()
            .all(|c| c["threadId"] == reserved.thread_id.as_str())
    );
}

#[tokio::test]
async fn a_fresh_start_survives_a_lost_acknowledgement_and_keeps_the_mode() {
    let temp = tempfile::tempdir().unwrap();
    let (agents, fake) = fake_agents(
        temp.path(),
        temp.path(),
        vec![row(
            "old",
            "p",
            "approval-required",
            "t",
            "completed",
            "ready",
            false,
        )],
    )
    .await;
    registered(&agents, |r| {
        r.agents.insert("p".into(), agent("old"));
        r.workers.insert("w1".into(), worker("old"));
    })
    .await;
    fake.fail.lock().unwrap().push(("thread.turn.start", true));
    let error = agents
        .reset(Some("p"), None, Reset::Fresh { note: None })
        .await
        .unwrap_err();
    assert!(format!("{error:#}").contains("did not answer"));
    let Lifecycle::Replacing {
        replacement: plan,
        error: Some(_),
        ..
    } = agents.list()[0].lifecycle.clone()
    else {
        panic!()
    };
    // The retry finds the handoff delivered and does not send it again.
    let done = agents
        .ops
        .run("p".into(), agents.perform("p"))
        .await
        .unwrap();
    assert_eq!(done["thread_id"], plan.thread_id.as_str());
    let saved = agents.list()[0].clone();
    assert!(
        saved.lifecycle == Lifecycle::Ready { refresh: false } && saved.thread_id == plan.thread_id
    );
    assert_eq!(agents.registry().workers["w1"].coordinator, plan.thread_id);
    let created = fake.sent("thread.create");
    assert_eq!(created.len(), 1);
    assert_eq!(created[0]["runtimeMode"], "approval-required");
    let turns = fake.sent("thread.turn.start");
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0]["runtimeMode"], "approval-required");
}

#[tokio::test]
async fn worker_updates_are_sent_once() {
    let temp = tempfile::tempdir().unwrap();
    let (agents, fake) = fake_agents(
        temp.path(),
        temp.path(),
        vec![
            row(
                "agent",
                "p",
                "full-access",
                "a",
                "completed",
                "ready",
                false,
            ),
            row("w1", "p", "full-access", "t", "completed", "ready", false),
        ],
    )
    .await;
    registered(&agents, |r| {
        r.agents.insert("p".into(), agent("agent"));
        r.workers.insert("w1".into(), worker("agent"));
    })
    .await;
    // Overlapping flushes.
    let (a, b) = tokio::join!(agents.flush(), agents.flush());
    a.unwrap();
    b.unwrap();
    assert_eq!(fake.sent("thread.turn.start").len(), 1);
    // A lost acknowledgement: the update waits, possibly sent, until its retry is due…
    agents.consume_shell(&json!({"kind": "thread-upserted", "thread": row("w1", "p", "full-access", "t2", "completed", "ready", false)})).await;
    fake.fail.lock().unwrap().push(("thread.turn.start", true));
    agents.flush().await.unwrap();
    let waiting = agents.registry().outbox[0].outbound.clone();
    assert!(waiting.delivery == Delivery::OutcomeUnknown && waiting.retry_at.is_some());
    agents.flush().await.unwrap();
    assert_eq!(agents.registry().outbox.len(), 1);
    // …and then, after a restart, goes again as the same command, which T3
    // answers from its receipt without a second message.
    registered(&agents, |r| r.outbox[0].outbound.retry_at = Some(0)).await;
    let shell = agents
        .shell()
        .threads
        .values()
        .map(|t| (**t).clone())
        .collect::<Vec<_>>();
    drop(agents);
    let agents = Agents::open(
        temp.path(),
        "http://127.0.0.1:1",
        Arc::new(Tasks::open(temp.path()).unwrap()),
    )
    .unwrap();
    assert!(agents.fake.set(fake.clone()).is_ok());
    agents.consume_shell(&json!({"kind": "snapshot", "snapshot": {"projects": [{"id": "p", "title": "App"}], "threads": shell}})).await;
    agents.flush().await.unwrap();
    let sent = fake.sent("thread.turn.start");
    assert_eq!(sent.len(), 2);
    assert_eq!(sent[1]["commandId"], json!(waiting.command.unwrap().id));
    assert!(!agents.has_due_wakes().await);
    // A restart reloads the same registry and has nothing to send.
    let reopened = Agents::open(
        temp.path(),
        "http://127.0.0.1:1",
        Arc::new(Tasks::open(temp.path()).unwrap()),
    )
    .unwrap();
    assert_eq!(
        reopened.registry().workers["w1"].notified,
        Some(event("t2:done"))
    );

    // Question A, answered (working), then question B in the same turn.
    let asking = row("w1", "p", "full-access", "t3", "running", "running", true);
    let ask = |id: &str| json!([{"kind": "user-input.requested", "payload": {"requestId": id}}]);
    fake.activities
        .lock()
        .unwrap()
        .insert("w1".into(), ask("A"));
    agents
        .consume_shell(&json!({"kind": "thread-upserted", "thread": asking}))
        .await;
    agents.flush().await.unwrap();
    agents.flush().await.unwrap();
    assert_eq!(fake.sent("thread.turn.start").len(), 3);
    agents.consume_shell(&json!({"kind": "thread-upserted", "thread": row("w1", "p", "full-access", "t3", "running", "running", false)})).await;
    agents.observe_workers().await;
    fake.activities
        .lock()
        .unwrap()
        .insert("w1".into(), ask("B"));
    agents.consume_shell(&json!({"kind": "thread-upserted", "thread": row("w1", "p", "full-access", "t3", "running", "running", true)})).await;
    agents.flush().await.unwrap();
    assert_eq!(fake.sent("thread.turn.start").len(), 4);
    assert_eq!(
        agents.registry().workers["w1"].notified,
        Some(event("t3:needs-you:B"))
    );
}

#[tokio::test]
async fn failed_builds_reach_their_agent_once() {
    let temp = tempfile::tempdir().unwrap();
    let (agents, fake) = fake_agents(
        temp.path(),
        temp.path(),
        vec![
            row(
                "agent",
                "p",
                "full-access",
                "a1",
                "running",
                "running",
                false,
            ),
            row("w1", "p", "full-access", "t", "running", "running", false),
        ],
    )
    .await;
    registered(&agents, |r| {
        r.agents.insert("p".into(), agent("agent"));
        r.workers.insert("w1".into(), worker("agent"));
    })
    .await;
    let finished = |id: &str, thread: Option<&str>| FinishedBuild {
        id: id.into(),
        thread: thread.map(str::to_string),
        app: "App".into(),
        succeeded: false,
        reason: Some("x".into()),
    };
    let updates = |fake: &Fake| {
        fake.sent("thread.turn.start")
            .into_iter()
            .map(|c| {
                c["message"]["context"]["records"][0]["payload"]["build"]
                    .as_str()
                    .unwrap()
                    .to_string()
            })
            .collect::<Vec<_>>()
    };
    let (by_worker, by_task, own, own_later, stranger) = (
        "b-worker",
        uuid::Uuid::new_v4().to_string(),
        "b-own",
        "b-own-later",
        "b-x",
    );

    // A worker's build, told twice (a link after it finished), goes once.
    agents.build_started(by_worker, Some("w1")).await.unwrap();
    agents
        .build_finished(&finished(by_worker, Some("w1")))
        .await
        .unwrap();
    agents
        .build_finished(&finished(by_worker, Some("w1")))
        .await
        .unwrap();
    // A build no thread claims, linked to one of the app's tasks.
    let task = agents
        .tasks
        .add(
            "p",
            "ship it",
            None,
            None,
            crate::tasks::By::Agent,
            None,
            vec![],
        )
        .await
        .unwrap();
    agents
        .tasks
        .link(&task.id, None, Some(&by_task), false)
        .await
        .unwrap();
    agents
        .build_finished(&finished(&by_task, None))
        .await
        .unwrap();
    // Nobody's build.
    agents
        .build_finished(&finished(stranger, Some("someone")))
        .await
        .unwrap();
    // The agent's own build, finishing in the turn that started it: already in its chat.
    agents.build_started(own, Some("agent")).await.unwrap();
    agents
        .build_finished(&finished(own, Some("agent")))
        .await
        .unwrap();
    // One it started, finishing after that turn ended.
    agents
        .build_started(own_later, Some("agent"))
        .await
        .unwrap();
    agents.consume_shell(&json!({"kind": "thread-upserted", "thread": row("agent", "p", "full-access", "a1", "completed", "ready", false)})).await;
    agents
        .build_finished(&finished(own_later, Some("agent")))
        .await
        .unwrap();
    agents.flush().await.unwrap();
    assert_eq!(
        updates(&fake),
        vec![
            by_worker.to_string(),
            by_task.clone(),
            own_later.to_string()
        ]
    );

    // A restart neither repeats nor loses them.
    let reopened = Agents::open(
        temp.path(),
        "http://127.0.0.1:1",
        Arc::new(Tasks::open(temp.path()).unwrap()),
    )
    .unwrap();
    reopened
        .build_finished(&finished(own_later, Some("agent")))
        .await
        .unwrap();
    assert!(reopened.registry().outbox.is_empty());
    assert_eq!(
        agents.build_owner(None, &by_task).map(|a| a.thread_id),
        Some("agent".into())
    );

    // A build that succeeded only shows its card: it wakes nobody.
    let done = FinishedBuild {
        id: "b-ok".into(),
        thread: Some("w1".into()),
        app: "App".into(),
        succeeded: true,
        reason: None,
    };
    agents.build_finished(&done).await.unwrap();
    agents.flush().await.unwrap();
    assert_eq!(updates(&fake).len(), 3);
}

#[tokio::test]
async fn an_update_that_cannot_be_saved_is_neither_seen_nor_sent() {
    let temp = tempfile::tempdir().unwrap();
    let (agents, fake) = fake_agents(
        temp.path(),
        temp.path(),
        vec![row(
            "agent",
            "p",
            "full-access",
            "a",
            "completed",
            "ready",
            false,
        )],
    )
    .await;
    registered(&agents, |r| {
        r.agents.insert("p".into(), agent("agent"));
    })
    .await;
    let failed = |id: &str| FinishedBuild {
        id: id.into(),
        thread: Some("agent".into()),
        app: "App".into(),
        succeeded: false,
        reason: None,
    };
    let file = temp.path().join("agents.json");
    std::fs::remove_file(&file).unwrap();
    std::fs::create_dir(&file).unwrap();
    assert!(agents.build_finished(&failed("b1")).await.is_err());
    assert!(agents.registry().outbox.is_empty() && agents.registry().builds.is_empty());
    agents.flush().await.unwrap();
    assert!(fake.sent("thread.turn.start").is_empty());
    // Once storage works again, the next change is saved and sent once.
    std::fs::remove_dir(&file).unwrap();
    agents.build_finished(&failed("b1")).await.unwrap();
    agents.flush().await.unwrap();
    assert_eq!(fake.sent("thread.turn.start").len(), 1);
    assert!(
        Agents::open(
            temp.path(),
            "x",
            Arc::new(Tasks::open(temp.path()).unwrap())
        )
        .unwrap()
        .registry()
        .outbox
        .is_empty()
    );
}

#[tokio::test]
async fn an_update_for_a_gone_agent_is_settled_as_undelivered_only_on_a_current_shell() {
    let temp = tempfile::tempdir().unwrap();
    let (agents, fake) = fake_agents(
        temp.path(),
        temp.path(),
        vec![row(
            "w1",
            "p",
            "full-access",
            "t",
            "completed",
            "ready",
            false,
        )],
    )
    .await;
    registered(&agents, |r| {
        r.agents.insert("p".into(), agent("gone"));
        r.workers.insert("w1".into(), worker("gone"));
    })
    .await;
    agents.queue(agents.due_wakes().await).await.unwrap();
    // Disconnected, the missing thread may just not have arrived yet.
    agents
        .owner
        .ask(|s| {
            s.shell_mut().link = Link::Offline { epoch: 1 };
            s.publish()
        })
        .await;
    agents.flush().await.unwrap();
    assert_eq!(agents.registry().outbox.len(), 1);
    agents
        .owner
        .ask(|s| {
            s.shell_mut().link = Link::Current { epoch: 2 };
            s.publish()
        })
        .await;
    agents.flush().await.unwrap();
    let registry = agents.registry();
    assert!(registry.outbox.is_empty() && fake.sent("thread.turn.start").is_empty());
    assert_eq!(registry.undelivered.len(), 1);
    assert_eq!(registry.workers["w1"].notified, Some(event("t:done")));
}

#[tokio::test]
async fn a_compaction_whose_answer_is_lost_is_settled_by_the_same_command() {
    let temp = tempfile::tempdir().unwrap();
    let (agents, fake) = fake_agents(
        temp.path(),
        temp.path(),
        vec![row("agent", "p", "auto", "a", "completed", "ready", false)],
    )
    .await;
    registered(&agents, |r| {
        r.agents.insert("p".into(), agent("agent"));
    })
    .await;
    let wanted = |at: &str, decision| {
        Some(Reading {
            origin: Origin::Automatic,
            decision,
            at: Some(at.into()),
            tokens: 300_000,
        })
    };
    let checked = |at: &str, decision| m26::Event::Checked {
        thread: "agent".into(),
        reading: wanted(at, decision),
        compact: agents.compact_command("agent", "Compacted", 0).unwrap(),
    };
    fake.fail.lock().unwrap().push(("thread.turn.start", true));
    let lost = agents
        .run_upkeep("p", checked("r1", m26::Decision::Compact))
        .await
        .unwrap();
    assert!(matches!(lost, Some(Dispatched::Unknown(_))));
    // Restarted, the next check that wants compaction sends that command again; T3 has it.
    let agents = Agents::open(
        temp.path(),
        "x",
        Arc::new(Tasks::open(temp.path()).unwrap()),
    )
    .unwrap();
    assert!(agents.fake.set(fake.clone()).is_ok());
    agents.consume_shell(&json!({"kind": "snapshot", "snapshot": {"projects": [], "threads": [row("agent", "p", "auto", "a", "completed", "ready", false)]}})).await;
    let settled = agents
        .run_upkeep("p", checked("r2", m26::Decision::Compact))
        .await
        .unwrap();
    assert!(matches!(settled, Some(Dispatched::Accepted(_))));
    let sent = fake.sent("thread.turn.start");
    assert_eq!(
        (sent.len(), sent[0]["runtimeMode"].as_str()),
        (1, Some("auto"))
    );
    assert!(
        matches!(&agents.registry().upkeep["p"].intent, m26::Intent::Applied { reading } if reading.at.as_deref() == Some("r1"))
    );
    // A fresh start is saved as the agent's queued reset, in the same change.
    assert_eq!(
        agents
            .run_upkeep("p", checked("r3", m26::Decision::Fresh { nightly: true }))
            .await
            .unwrap(),
        None
    );
    let registry = agents.registry();
    assert!(
        matches!(&registry.agents["p"].lifecycle, Lifecycle::ResetQueued { reset: Reset::Fresh { note: Some(note) }, .. } if note.contains("overnight"))
    );
    assert!(
        matches!(&registry.upkeep["p"].intent, m26::Intent::Applied { reading } if reading.at.as_deref() == Some("r3"))
    );
}

/// Every message the service sends in the user's place is marked, and
/// the marked ones are never taken for the user's own words.
#[test]
fn service_messages_are_marked() {
    for note in Note::ALL {
        let message = note.message("m", "[x] for the agent", json!({}));
        assert!(!users_own(&message), "{note:?}");
    }
    // A kind the service adds later is still Squircle's.
    let later =
        json!({"role": "user", "text": "t", "context": {"records": [{"kind": "squircle-later"}]}});
    assert!(!users_own(&later));
    assert!(users_own(&json!({"role": "user", "text": "hi"})));
    assert!(users_own(
        &json!({"role": "user", "text": "hi", "context": {"records": [{"kind": "file"}]}})
    ));
}

#[tokio::test]
async fn discarding_stops_a_worker_waiting_on_the_user_before_removing_its_files() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("repo");
    std::fs::create_dir(&root).unwrap();
    run(&root, &["init", "-q", "-b", "main"]).await;
    commit(&root, "a").await;
    let tree = temp.path().join("w");
    run(
        &root,
        &["worktree", "add", "-q", "-b", "w", tree.to_str().unwrap()],
    )
    .await;
    commit(&tree, "b").await;
    // Blocked on an approval: shown as needs-you, but its turn is live.
    let mut asking = row("w1", "p", "full-access", "t", "running", "running", true);
    asking["worktreePath"] = json!(tree);
    let data = temp.path().join("data");
    std::fs::create_dir(&data).unwrap();
    let (agents, fake) = fake_agents(&data, &root, vec![asking.clone()]).await;
    registered(&agents, |r| {
        r.workers.insert("w1".into(), worker("agent"));
    })
    .await;
    let refused = agents.archive("w1", false).await.unwrap_err();
    assert!(
        format!("{refused:#}").contains("waiting on a question"),
        "{refused:#}"
    );
    let (weak, checked) = (Arc::downgrade(&agents), tree.clone());
    *fake.on_dispatch.lock().unwrap() = Some(Box::new(move |command| {
        if command["type"] == "thread.session.stop" {
            // T3 first re-sends the waiting row, and only later the stop.
            let (agents, checked, asking) =
                (weak.upgrade().unwrap(), checked.clone(), asking.clone());
            tokio::spawn(async move {
                agents
                    .consume_shell(&json!({"kind": "thread-upserted", "thread": asking}))
                    .await;
                tokio::time::sleep(Duration::from_millis(300)).await;
                assert!(checked.exists(), "files removed before the worker stopped");
                let mut stopped = asking.clone();
                stopped["latestTurn"]["state"] = json!("interrupted");
                stopped["session"]["status"] = json!("stopped");
                agents
                    .consume_shell(&json!({"kind": "thread-upserted", "thread": stopped}))
                    .await;
            });
        } else if command["type"] == "thread.archive" {
            assert!(!checked.exists());
        }
    }));
    let result = agents.archive("w1", true).await.unwrap();
    assert_eq!(result["stopped"], true);
    let order: Vec<Value> = fake
        .log
        .lock()
        .unwrap()
        .iter()
        .map(|c| c["type"].clone())
        .collect();
    assert_eq!(
        order,
        [json!("thread.session.stop"), json!("thread.archive")]
    );
    assert!(!tree.exists() && agents.registry().workers["w1"].stage == Stage::Archived);
}

#[tokio::test]
async fn a_reset_never_stops_a_newer_turn() {
    let temp = tempfile::tempdir().unwrap();
    let idle = row(
        "agent",
        "p",
        "full-access",
        "t1",
        "completed",
        "ready",
        false,
    );
    let busy = row(
        "agent",
        "p",
        "full-access",
        "t2",
        "running",
        "running",
        false,
    );
    let (agents, fake) = fake_agents(temp.path(), temp.path(), vec![idle.clone()]).await;
    let queued = |reset: Reset| Lifecycle::ResetQueued {
        reset,
        error: Some("earlier failure".into()),
        failures: 1,
    };
    registered(&agents, move |r| {
        r.agents.insert(
            "p".into(),
            Agent {
                lifecycle: queued(Reset::Restart),
                ..agent("agent")
            },
        );
    })
    .await;
    let upsert = |row: &Value| {
        let item = json!({"kind": "thread-upserted", "thread": row});
        let agents = agents.clone();
        async move { agents.consume_shell(&item).await }
    };
    // The user started a turn while the restart waited to retry.
    upsert(&busy).await;
    assert_eq!(agents.perform("p").await.unwrap()["when"], "after-turn");
    assert!(fake.sent("thread.session.stop").is_empty());
    assert!(matches!(
        agents.list()[0].lifecycle,
        Lifecycle::ResetQueued { .. }
    ));
    upsert(&idle).await;
    assert_eq!(agents.perform("p").await.unwrap()["when"], "now");
    assert_eq!(fake.sent("thread.session.stop").len(), 1);
    assert_eq!(
        agents.list()[0].lifecycle,
        Lifecycle::Ready { refresh: true }
    );

    // A turn that starts while the fresh start gathers its handoff.
    registered(&agents, move |r| {
        r.agents.get_mut("p").unwrap().lifecycle = queued(Reset::Fresh { note: None })
    })
    .await;
    *fake.on_snapshot.lock().unwrap() = Some(Box::new(move |_| {
        Some(json!({"kind": "thread-upserted", "thread": busy.clone()}))
    }));
    assert_eq!(agents.perform("p").await.unwrap()["when"], "after-turn");
    assert_eq!(
        fake.log.lock().unwrap().len(),
        1,
        "only the earlier restart's stop"
    );
    assert!(matches!(
        agents.list()[0].lifecycle,
        Lifecycle::ResetQueued {
            reset: Reset::Fresh { .. },
            ..
        }
    ));
}

#[tokio::test]
async fn a_worker_is_reserved_before_its_bootstrap_is_sent() {
    let temp = tempfile::tempdir().unwrap();
    let (agents, fake) = fake_agents(
        temp.path(),
        temp.path(),
        vec![row(
            "agent",
            "p",
            "full-access",
            "a",
            "completed",
            "ready",
            false,
        )],
    )
    .await;
    registered(&agents, |r| {
        r.agents.insert("p".into(), agent("agent"));
    })
    .await;
    let spawn = |agents: Arc<Agents>, branch: &'static str| async move {
        agents
            .spawn(
                "agent",
                "W",
                branch,
                Some("main"),
                "do it",
                None,
                None,
                None,
                None,
            )
            .await
    };
    // T3 starts the worker but its acknowledgement is lost.
    fake.fail.lock().unwrap().push(("thread.turn.start", true));
    let first = spawn(agents.clone(), "one").await.unwrap();
    assert_eq!(
        agents.registry().workers[first["id"].as_str().unwrap()].stage,
        Stage::Active
    );

    // Rejected (or never arrived): the reservation stays, and the
    // service restarts before anything else happens.
    fake.fail.lock().unwrap().push(("thread.turn.start", false));
    assert!(spawn(agents.clone(), "two").await.is_err());
    drop(agents);
    let (agents, fake) = fake_agents(
        temp.path(),
        temp.path(),
        vec![row(
            "agent",
            "p",
            "full-access",
            "a",
            "completed",
            "ready",
            false,
        )],
    )
    .await;
    let reserved: Vec<String> = agents
        .registry()
        .workers
        .iter()
        .filter(|(_, w)| matches!(w.stage, Stage::Bootstrapping { .. }))
        .map(|(id, _)| id.clone())
        .collect();
    assert_eq!(reserved.len(), 1);
    // Asking again finishes that worker with the same identities.
    let again = spawn(agents.clone(), "two").await.unwrap();
    assert_eq!(
        (again["id"].as_str(), again["existing"].as_bool()),
        (Some(reserved[0].as_str()), Some(true))
    );
    let sent = fake.sent("thread.turn.start");
    assert_eq!(
        (sent.len(), sent[0]["threadId"].as_str()),
        (1, Some(reserved[0].as_str()))
    );
    assert_eq!(agents.registry().workers.len(), 2);

    // Unconfirmed, then T3's shell shows it finishing its first turn:
    // it is adopted and its coordinator woken.
    fake.fail.lock().unwrap().push(("thread.turn.start", false));
    assert!(spawn(agents.clone(), "three").await.is_err());
    let id = agents
        .registry()
        .workers
        .iter()
        .find(|(_, w)| w.branch == "three")
        .map(|(id, _)| id.clone())
        .unwrap();
    agents.consume_shell(&json!({"kind": "thread-upserted", "thread": row(&id, "p", "full-access", "t", "completed", "ready", false)})).await;
    agents.observe_workers().await;
    assert_eq!(agents.registry().workers[&id].stage, Stage::Active);
    assert!(
        agents
            .due_wakes()
            .await
            .iter()
            .any(|(due, _, _)| *due == id)
    );
}

/// The same agents, as a restarted service: the registry from disk, the
/// same fake T3 and its shell.
async fn reopened(
    temp: &Path,
    fake: &Arc<Fake>,
    threads: Vec<Value>,
    workspace: &Path,
) -> Arc<Agents> {
    let agents = Agents::open(
        temp,
        "http://127.0.0.1:1",
        Arc::new(Tasks::open(temp).unwrap()),
    )
    .unwrap();
    assert!(agents.fake.set(fake.clone()).is_ok());
    *fake.agents.lock().unwrap() = Arc::downgrade(&agents);
    agents.consume_shell(&json!({"kind": "snapshot", "snapshot": {
        "projects": [{"id": "p", "title": "App", "workspaceRoot": workspace}], "threads": threads}})).await;
    agents
}

/// A fresh start whose answer is lost at each step in turn, with the
/// service restarted right after: it resumes from the saved step, and T3
/// gets each command once (a resend is answered from its receipt). The
/// agent, its workers and its unsent update move to the new thread in
/// one save; an update that may have reached the old thread stays there.
#[tokio::test]
async fn a_fresh_start_resumes_after_a_crash_at_any_step() {
    for step in [
        "thread.session.stop",
        "thread.meta.update",
        "thread.create",
        "thread.turn.start",
    ] {
        let temp = tempfile::tempdir().unwrap();
        let old = row("old", "p", "auto", "t", "completed", "ready", false);
        let (agents, fake) = fake_agents(temp.path(), temp.path(), vec![old.clone()]).await;
        let wake = |id: &str, delivery| Wake {
            coordinator: "old".into(),
            message_id: id.into(),
            workers: vec![],
            text: "x".into(),
            record: json!({}),
            outbound: Outbound {
                delivery,
                ..Default::default()
            },
            build: None,
        };
        registered(&agents, move |r| {
            r.agents.insert("p".into(), agent("old"));
            r.workers.insert("w1".into(), worker("old"));
            r.outbox.push(wake("unsent", Delivery::Queued));
            r.outbox.push(wake("maybe", Delivery::OutcomeUnknown));
        })
        .await;
        fake.fail.lock().unwrap().push((step, true));
        assert!(
            agents
                .reset(
                    Some("p"),
                    None,
                    Reset::Fresh {
                        note: Some("n".into())
                    }
                )
                .await
                .is_err(),
            "{step}"
        );
        let threads: Vec<Value> = agents
            .shell()
            .threads
            .values()
            .map(|t| (**t).clone())
            .collect();
        drop(agents);
        let agents = reopened(temp.path(), &fake, threads, temp.path()).await;
        let done = agents
            .ops
            .run("p".into(), agents.perform("p"))
            .await
            .unwrap();
        assert_eq!(
            (done["when"].as_str(), done["previous_thread_id"].as_str()),
            (Some("now"), Some("old")),
            "{step}"
        );
        let registry = agents.registry();
        let new = registry.agents["p"].thread_id.clone();
        assert!(
            new != "old" && registry.agents["p"].lifecycle == Lifecycle::Ready { refresh: false },
            "{step}"
        );
        assert_eq!(registry.workers["w1"].coordinator, new);
        let by_id = |id: &str| {
            registry
                .outbox
                .iter()
                .find(|w| w.message_id == id)
                .unwrap()
                .coordinator
                .clone()
        };
        assert_eq!(
            (by_id("unsent"), by_id("maybe")),
            (new.clone(), "old".to_string()),
            "{step}"
        );
        for kind in [
            "thread.session.stop",
            "thread.meta.update",
            "thread.create",
            "thread.turn.start",
        ] {
            assert_eq!(fake.sent(kind).len(), 1, "{kind} after a cut at {step}");
        }
        assert_eq!(fake.sent("thread.turn.start")[0]["runtimeMode"], "auto");
    }
}

/// A fresh start never makes up a runtime mode for the new agent.
#[tokio::test]
async fn a_fresh_start_waits_for_a_known_runtime_mode() {
    let temp = tempfile::tempdir().unwrap();
    let mut old = row("old", "p", "auto", "t", "completed", "ready", false);
    old.as_object_mut().unwrap().remove("runtimeMode");
    let (agents, fake) = fake_agents(temp.path(), temp.path(), vec![old]).await;
    registered(&agents, |r| {
        r.agents.insert("p".into(), agent("old"));
    })
    .await;
    let error = agents
        .reset(Some("p"), None, Reset::Fresh { note: None })
        .await
        .unwrap_err();
    assert!(format!("{error:#}").contains("runtime mode"), "{error:#}");
    assert!(fake.log.lock().unwrap().is_empty());
    assert!(matches!(
        agents.list()[0].lifecycle,
        Lifecycle::ResetQueued { error: Some(_), .. }
    ));
    // Nor sends a message into a thread whose mode it doesn't know.
    assert!(agents.send("old", "hi").await.is_err());
    assert!(fake.log.lock().unwrap().is_empty());
}

/// A message whose answer is lost is sent again, when asked again, as
/// the same command: T3 shows it once.
#[tokio::test]
async fn a_send_asked_again_after_a_lost_answer_is_the_same_command() {
    let temp = tempfile::tempdir().unwrap();
    let (agents, fake) = fake_agents(
        temp.path(),
        temp.path(),
        vec![row("w1", "p", "auto", "t", "completed", "ready", false)],
    )
    .await;
    fake.fail.lock().unwrap().push(("thread.turn.start", true));
    assert!(agents.message("w1", "go on").await.is_err());
    assert_eq!(agents.registry().intents.len(), 1);
    let agents = reopened(
        temp.path(),
        &fake,
        vec![row("w1", "p", "auto", "t", "completed", "ready", false)],
        temp.path(),
    )
    .await;
    agents.message("w1", "go on").await.unwrap();
    assert_eq!(fake.messages.lock().unwrap()["w1"].len(), 1);
    assert!(agents.registry().intents.is_empty());
    // A new request is a new command.
    agents.message("w1", "go on").await.unwrap();
    assert_eq!(fake.messages.lock().unwrap()["w1"].len(), 2);
}

/// An archive cut after the stop and after T3's archive, each answer
/// lost and the service restarted: it resumes from the saved step,
/// sends each command once and removes files only once T3 shows the
/// worker stopped.
#[tokio::test]
async fn an_archive_resumes_after_lost_answers_and_a_restart() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("repo");
    std::fs::create_dir(&root).unwrap();
    run(&root, &["init", "-q", "-b", "main"]).await;
    commit(&root, "a").await;
    let tree = temp.path().join("w");
    run(
        &root,
        &["worktree", "add", "-q", "-b", "w", tree.to_str().unwrap()],
    )
    .await;
    let mut idle = row("w1", "p", "auto", "t", "completed", "ready", false);
    idle["worktreePath"] = json!(tree);
    let data = temp.path().join("data");
    std::fs::create_dir(&data).unwrap();
    let (agents, fake) = fake_agents(&data, &root, vec![idle.clone()]).await;
    registered(&agents, |r| {
        r.workers.insert("w1".into(), worker("agent"));
    })
    .await;
    let (weak, checked, stopped) = (Arc::downgrade(&agents), tree.clone(), {
        let mut stopped = idle.clone();
        stopped["session"]["status"] = json!("stopped");
        stopped
    });
    let shown = stopped.clone();
    *fake.on_dispatch.lock().unwrap() = Some(Box::new(move |command| {
        if command["type"] == "thread.session.stop" {
            assert!(checked.exists());
            // T3 shows the stop only after the (lost) answer.
            let (agents, stopped) = (weak.upgrade().unwrap(), shown.clone());
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(100)).await;
                agents
                    .consume_shell(&json!({"kind": "thread-upserted", "thread": stopped}))
                    .await;
            });
        }
    }));
    fake.fail
        .lock()
        .unwrap()
        .push(("thread.session.stop", true));
    let error = agents.archive("w1", false).await.unwrap_err();
    assert!(
        format!("{error:#}").contains("nothing was removed"),
        "{error:#}"
    );
    assert!(
        tree.exists()
            && matches!(
                agents.registry().workers["w1"].stage,
                Stage::Archiving(ArchiveStep::Stopping { .. })
            )
    );
    tokio::time::sleep(Duration::from_millis(200)).await;
    fake.fail.lock().unwrap().push(("thread.archive", true));
    assert!(agents.archive("w1", false).await.is_err());
    assert!(
        !tree.exists()
            && matches!(
                agents.registry().workers["w1"].stage,
                Stage::Archiving(ArchiveStep::Thread { .. })
            )
    );
    drop(agents);
    let agents = reopened(&data, &fake, vec![stopped], &root).await;
    let result = agents.archive("w1", false).await.unwrap();
    assert_eq!(result["archived"], "w1");
    assert_eq!(agents.registry().workers["w1"].stage, Stage::Archived);
    let order: Vec<Value> = fake
        .log
        .lock()
        .unwrap()
        .iter()
        .map(|c| c["type"].clone())
        .collect();
    assert_eq!(
        order,
        [json!("thread.session.stop"), json!("thread.archive")]
    );
}

async fn run(dir: &Path, args: &[&str]) {
    git(dir, args).await.unwrap();
}

async fn commit(dir: &Path, file: &str) {
    std::fs::write(dir.join(file), file).unwrap();
    run(dir, &["add", file]).await;
    run(
        dir,
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-qm",
            file,
        ],
    )
    .await;
}

#[tokio::test]
async fn archives_only_merged_clean_work() {
    let temp = tempfile::tempdir().unwrap();
    let root = &temp.path().join("repo");
    std::fs::create_dir(root).unwrap();
    run(root, &["init", "-q", "-b", "main"]).await;
    commit(root, "a").await;
    let tree = |name: &str| temp.path().join(name);
    for name in ["merged", "rebased", "open", "dirty"] {
        run(
            root,
            &[
                "worktree",
                "add",
                "-q",
                "-b",
                name,
                tree(name).to_str().unwrap(),
            ],
        )
        .await;
        commit(&tree(name), name).await;
    }
    // Fast-forward merge, and a rebase-style merge (same change, new commit).
    run(root, &["merge", "-q", "--ff-only", "merged"]).await;
    run(
        root,
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "cherry-pick",
            "rebased",
        ],
    )
    .await;
    std::fs::write(tree("dirty").join("scratch"), "x").unwrap();

    let state = |name: &'static str| {
        let t = tree(name);
        async move {
            inspect(root, Some(&t), Some(name), Some("main"))
                .await
                .unwrap()
        }
    };
    for name in ["merged", "rebased"] {
        let s = state(name).await;
        assert_eq!(s.blocker(), None, "{name}");
        remove(root, &s, false, &StopReceipt(())).await.unwrap();
        assert!(
            !tree(name).exists() && !state(name).await.branch_exists,
            "{name}"
        );
    }
    assert_eq!(
        state("open").await.blocker().as_deref(),
        Some("1 commit not merged")
    );
    assert_eq!(
        state("dirty").await.blocker().as_deref(),
        Some("1 commit not merged and 1 uncommitted file")
    );
    // Discarding drops unmerged commits and uncommitted changes.
    remove(root, &state("dirty").await, true, &StopReceipt(()))
        .await
        .unwrap();
    assert!(!tree("dirty").exists() && !state("dirty").await.branch_exists);
    // A branch already gone with no worktree leaves nothing to do.
    let gone = inspect(root, None, Some("merged"), Some("main"))
        .await
        .unwrap();
    assert!(gone.blocker().is_none() && !gone.branch_exists && gone.worktree.is_none());
}

#[tokio::test]
async fn keeps_a_unique_merge_resolution() {
    let temp = tempfile::tempdir().unwrap();
    let root = &temp.path().join("repo");
    std::fs::create_dir(root).unwrap();
    run(root, &["init", "-q", "-b", "main"]).await;
    commit(root, "a").await;
    let edit = |text: &'static str| async move {
        std::fs::write(root.join("value"), text).unwrap();
        run(root, &["add", "value"]).await;
        run(
            root,
            &[
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@t",
                "commit",
                "-qm",
                text,
            ],
        )
        .await;
    };
    for side in ["left", "right"] {
        run(root, &["checkout", "-q", "-b", side, "main"]).await;
        edit(side).await;
    }
    // Both main and the worker merge left and right, resolving differently.
    for (branch, resolution) in [("main", "main's"), ("worker", "worker's")] {
        if branch == "main" {
            run(root, &["checkout", "-q", "main"]).await
        } else {
            run(root, &["checkout", "-q", "-b", "worker", "left~1"]).await
        }
        run(root, &["merge", "-q", "left"]).await;
        let _ = git(
            root,
            &[
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@t",
                "merge",
                "-q",
                "right",
            ],
        )
        .await;
        edit(resolution).await;
    }
    run(root, &["checkout", "-q", "main"]).await;
    // `git cherry` alone sees nothing unmerged.
    assert!(
        !git(root, &["cherry", "main", "worker"])
            .await
            .unwrap()
            .contains('+')
    );
    let state = inspect(root, None, Some("worker"), Some("main"))
        .await
        .unwrap();
    assert!(state.blocker().is_some(), "{state:?}");
    // A branch that moved after inspection is not deleted.
    let tip = state.tip.clone();
    run(root, &["branch", "-f", "worker", "main"]).await;
    let merged = GitState {
        tip: tip.clone(),
        ..inspect(root, None, Some("worker"), Some("main"))
            .await
            .unwrap()
    };
    assert!(
        remove(root, &merged, false, &StopReceipt(()))
            .await
            .is_err()
    );
    assert!(
        git(root, &["rev-parse", "--verify", "worker"])
            .await
            .is_ok()
    );
}
