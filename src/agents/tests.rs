#![cfg(test)]
// Test fakes only: leaf locks never held across a call.
#![allow(clippy::disallowed_types)]

use super::*;
use std::sync::Mutex;

/// A protocol 2 shell row: `status` is `idle` or the latest run's.
fn thread(run: Option<&str>, status: &str, needs: bool) -> Value {
    json!({
        "latestRunId": run, "status": if needs { "waiting" } else { status },
        "pendingRuntimeRequest": if needs { json!({"id": "R", "kind": "user_input"}) } else { Value::Null },
    })
}

/// T3's protocol 2 shell: a snapshot naming resolved repository roots only
/// refreshes those projects' metadata (it carries no threads), and an
/// archived thread leaves the active shell.
#[tokio::test]
async fn a_metadata_snapshot_keeps_the_threads_and_archiving_removes_one() {
    let temp = tempfile::tempdir().unwrap();
    let (agents, _) = fake_agents(
        temp.path(),
        temp.path(),
        vec![
            row("a", "p", "auto", "t", "completed", false),
            row("b", "p", "auto", "t", "completed", false),
        ],
    )
    .await;
    agents.consume_shell(&json!({"kind": "snapshot", "resolvedRepositoryIdentityRoots": ["/x"],
        "snapshot": {"projects": [{"id": "p", "title": "Renamed"}], "threads": [], "archivedThreads": []}})).await;
    let shell = agents.shell();
    assert_eq!(
        (shell.threads.len(), shell.projects["p"]["title"].as_str()),
        (2, Some("Renamed"))
    );
    let mut archived = row("a", "p", "auto", "t", "completed", false);
    archived["archivedAt"] = json!("2026-10-19T00:00:00Z");
    agents
        .consume_shell(
            &json!({"kind": "thread.updated", "location": "archive", "thread": archived}),
        )
        .await;
    agents
        .consume_shell(&json!({"kind": "thread.removed", "location": "active", "threadId": "b"}))
        .await;
    assert!(agents.shell().threads.is_empty());
    assert_eq!(
        agents.observe("a"),
        Observed::Current {
            epoch: 0,
            value: None
        }
    );
}

fn event(key: &str) -> WorkerEvent {
    serde_json::from_value(json!(key)).unwrap()
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
type DetailHook = Box<dyn Fn(&str) -> Option<Value> + Send>;

/// T3 as the agents see it: records commands, shows created threads in
/// the shell (held back while `held` is set, until `release`), and
/// remembers the messages it accepted. Like
/// T3, it keeps a receipt per command ID: an accepted ID sent again is
/// answered from it and changes nothing.
#[derive(Default)]
struct Fake {
    /// The agents it shows new threads to: the latest opened.
    agents: Mutex<std::sync::Weak<Agents>>,
    log: Mutex<Vec<Value>>,
    receipts: Mutex<HashMap<String, bool>>,
    messages: Mutex<HashMap<String, Vec<String>>>,
    /// A thread's pending questions: its projection's `runtimeRequests` and `turnItems`.
    requests: Mutex<HashMap<String, Value>>,
    /// Threads whose provider session was detached.
    detached: Mutex<std::collections::HashSet<String>>,
    /// The next dispatch of this type fails; `true` if T3 applied it anyway (a lost acknowledgement).
    fail: Mutex<Vec<(&'static str, bool)>>,
    /// Created thread rows not shown yet; None shows them at once.
    held: Mutex<Option<Vec<Value>>>,
    /// Told when a thread is created.
    created: tokio::sync::Notify,
    on_dispatch: Mutex<Option<DispatchHook>>,
    /// A shell item T3 sends while a thread's detail is read.
    on_detail: Mutex<Option<DetailHook>>,
}

impl Fake {
    fn agents(&self) -> Arc<Agents> {
        self.agents.lock().unwrap().upgrade().unwrap()
    }
    /// Shows the held thread rows, and those created from now on at once.
    async fn release(&self) {
        let rows = self.held.lock().unwrap().take().unwrap_or_default();
        for row in rows {
            self.agents()
                .consume_shell(
                    &json!({"kind": "thread.updated", "location": "active", "thread": row}),
                )
                .await;
        }
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

impl Fake {
    /// A thread's projection, as `orchestration.getThreadProjection` answers.
    async fn projection(&self, id: &str) -> Value {
        let item = self
            .on_detail
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
        let requests = self
            .requests
            .lock()
            .unwrap()
            .get(id)
            .cloned()
            .unwrap_or(json!({}));
        let sessions = match self.detached.lock().unwrap().contains(id) {
            true => json!([]),
            false => json!([{"id": format!("s-{id}"), "status": "ready"}]),
        };
        json!({"thread": {"id": id}, "messages": messages, "providerSessions": sessions,
               "runtimeRequests": requests["runtimeRequests"], "turnItems": requests["turnItems"]})
    }

    fn message(&self, thread: &Value, id: &Value) {
        self.messages
            .lock()
            .unwrap()
            .entry(thread.as_str().unwrap().into())
            .or_default()
            .push(id.as_str().unwrap().into());
    }
}

impl Peer for Fake {
    fn call<'a>(
        &'a self,
        tag: &'a str,
        payload: Value,
    ) -> crate::push::BoxFuture<'a, Result<Value>> {
        Box::pin(async move {
            match tag {
                "server.getConfig" => Ok(
                    json!({"providers": [{"instanceId": INSTANCE, "status": "ready"},
                {"instanceId": "claudeAgent", "driver": "claudeAgent", "status": "ready", "models": [{"slug": "m"}]}]}),
                ),
                "orchestration.getThreadProjection" => {
                    Ok(self.projection(payload["threadId"].as_str().unwrap()).await)
                }
                _ => panic!("unexpected call {tag}"),
            }
        })
    }
    fn dispatch<'a>(&'a self, command: &'a Command) -> crate::push::BoxFuture<'a, Dispatched> {
        Box::pin(async move {
            let command = command.body().clone();
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
                Some(kind @ ("thread.create" | crate::fsm::coordinator::LAUNCH)) => {
                    if kind == crate::fsm::coordinator::LAUNCH {
                        self.message(
                            &command["threadId"],
                            &command["initialMessage"]["messageId"],
                        );
                    }
                    let row = json!({"id": command["threadId"], "projectId": command["projectId"], "runtimeMode": command["runtimeMode"],
                                     "modelSelection": command["modelSelection"], "status": "idle", "latestRunId": null,
                                     "pendingRuntimeRequest": null, "archivedAt": null});
                    let shown = match &mut *self.held.lock().unwrap() {
                        Some(held) => {
                            held.push(row);
                            None
                        }
                        None => Some(row),
                    };
                    if let Some(row) = shown {
                        let agents = self.agents();
                        tokio::spawn(async move {
                            agents
                                .consume_shell(&json!({"kind": "thread.updated", "location": "active", "thread": row}))
                                .await;
                        });
                    }
                    self.created.notify_one();
                }
                Some("message.dispatch") => {
                    self.message(&command["threadId"], &command["messageId"])
                }
                Some("provider-session.detach") => {
                    self.detached
                        .lock()
                        .unwrap()
                        .insert(command["threadId"].as_str().unwrap().into());
                }
                _ => {}
            }
            if failure == Some(true) {
                return Dispatched::Unknown("T3 did not answer".into());
            }
            Dispatched::Accepted(json!({"sequence": 1}))
        })
    }
    fn snapshot<'a>(&'a self, tag: &'a str, _: Value) -> crate::push::BoxFuture<'a, Result<Value>> {
        panic!("unexpected subscription {tag}")
    }
}

/// A protocol 2 shell row for thread `id` whose latest run is `run`.
fn row(id: &str, project: &str, mode: &str, run: &str, status: &str, needs: bool) -> Value {
    let mut row = thread(Some(run), status, needs);
    let fields = json!({"id": id, "projectId": project, "runtimeMode": mode, "archivedAt": null,
                        "activeRunId": run, "modelSelection": {"instanceId": INSTANCE, "model": "m"}});
    for (key, value) in fields.as_object().unwrap() {
        row[key] = value.clone();
    }
    row
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
        heard: None,
    }
}

#[tokio::test]
async fn first_use_creates_one_agent_in_the_chosen_mode() {
    let temp = tempfile::tempdir().unwrap();
    let (agents, fake) = fake_agents(temp.path(), temp.path(), vec![]).await;
    // The shell shows the new thread only once both requests have asked
    // and the thread was created.
    *fake.held.lock().unwrap() = Some(vec![]);
    let both = futures_util::future::join(
        agents.ensure("p", None, None, Some("approval-required")),
        agents.ensure("p", None, None, Some("approval-required")),
    );
    tokio::pin!(both);
    tokio::select! {
        _ = &mut both => panic!("ensured before T3 showed the thread"),
        _ = fake.created.notified() => {}
    }
    fake.release().await;
    let (a, b) = both.await;
    assert_eq!(a.unwrap().thread_id, b.unwrap().thread_id);
    let created = fake.sent("thread.create");
    assert_eq!(created.len(), 1);
    assert_eq!(created[0]["runtimeMode"], "approval-required");
    assert!(agents.ensure("p", None, None, Some("ask")).await.is_err());
}

#[tokio::test]
async fn worker_updates_are_sent_once() {
    let temp = tempfile::tempdir().unwrap();
    let (agents, fake) = fake_agents(
        temp.path(),
        temp.path(),
        vec![
            row("agent", "p", "full-access", "a", "completed", false),
            row("w1", "p", "full-access", "t", "completed", false),
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
    assert_eq!(fake.sent("message.dispatch").len(), 1);
    // A lost acknowledgement: the update waits, possibly sent, until its retry is due…
    agents.consume_shell(&json!({"kind": "thread.updated", "location": "active", "thread": row("w1", "p", "full-access", "t2", "completed", false)})).await;
    fake.fail.lock().unwrap().push(("message.dispatch", true));
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
    let sent = fake.sent("message.dispatch");
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

    // A worker's question waits on the user's phone; the agent isn't woken to relay it.
    let asking = row("w1", "p", "full-access", "t3", "running", true);
    fake.requests.lock().unwrap().insert(
        "w1".into(),
        json!({"runtimeRequests": [{"id": "A", "kind": "user_input", "status": "pending"}]}),
    );
    agents
        .consume_shell(&json!({"kind": "thread.updated", "location": "active", "thread": asking}))
        .await;
    agents.flush().await.unwrap();
    assert_eq!(fake.sent("message.dispatch").len(), 2);
}

#[tokio::test]
async fn an_update_that_cannot_be_saved_is_neither_seen_nor_sent() {
    let temp = tempfile::tempdir().unwrap();
    let (agents, fake) = fake_agents(
        temp.path(),
        temp.path(),
        vec![row("agent", "p", "full-access", "a", "completed", false)],
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
    assert!(fake.sent("message.dispatch").is_empty());
    // Once storage works again, the next change is saved and sent once.
    std::fs::remove_dir(&file).unwrap();
    agents.build_finished(&failed("b1")).await.unwrap();
    agents.flush().await.unwrap();
    assert_eq!(fake.sent("message.dispatch").len(), 1);
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
async fn a_compaction_whose_answer_is_lost_is_settled_by_the_same_command() {
    let temp = tempfile::tempdir().unwrap();
    let (agents, fake) = fake_agents(
        temp.path(),
        temp.path(),
        vec![row("agent", "p", "auto", "a", "completed", false)],
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
    fake.fail.lock().unwrap().push(("message.dispatch", true));
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
    agents.consume_shell(&json!({"kind": "snapshot", "snapshot": {"projects": [], "threads": [row("agent", "p", "auto", "a", "completed", false)]}})).await;
    let settled = agents
        .run_upkeep("p", checked("r2", m26::Decision::Compact))
        .await
        .unwrap();
    assert!(matches!(settled, Some(Dispatched::Accepted(_))));
    let sent = fake.sent("message.dispatch");
    assert_eq!(sent.len(), 1);
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

#[tokio::test]
async fn a_reset_never_stops_a_newer_turn() {
    let temp = tempfile::tempdir().unwrap();
    let idle = row("agent", "p", "full-access", "t1", "completed", false);
    let busy = row("agent", "p", "full-access", "t2", "running", false);
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
        let item = json!({"kind": "thread.updated", "location": "active", "thread": row});
        let agents = agents.clone();
        async move { agents.consume_shell(&item).await }
    };
    // The user started a turn while the restart waited to retry.
    upsert(&busy).await;
    assert_eq!(agents.perform("p").await.unwrap()["when"], "after-turn");
    assert!(fake.sent("provider-session.detach").is_empty());
    assert!(matches!(
        agents.list()[0].lifecycle,
        Lifecycle::ResetQueued { .. }
    ));
    upsert(&idle).await;
    assert_eq!(agents.perform("p").await.unwrap()["when"], "now");
    // Idle with a live session: the restart detaches it.
    assert_eq!(fake.sent("provider-session.detach").len(), 1);
    assert_eq!(
        agents.list()[0].lifecycle,
        Lifecycle::Ready { refresh: true }
    );

    // A turn that starts while the fresh start gathers its handoff.
    registered(&agents, move |r| {
        r.agents.get_mut("p").unwrap().lifecycle = queued(Reset::Fresh { note: None })
    })
    .await;
    *fake.on_detail.lock().unwrap() = Some(Box::new(move |_| {
        Some(json!({"kind": "thread.updated", "location": "active", "thread": busy.clone()}))
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
        vec![row("agent", "p", "full-access", "a", "completed", false)],
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
    fake.fail
        .lock()
        .unwrap()
        .push((crate::fsm::coordinator::LAUNCH, true));
    let first = spawn(agents.clone(), "one").await.unwrap();
    assert_eq!(
        agents.registry().workers[first["id"].as_str().unwrap()].stage,
        Stage::Active
    );

    // Rejected (or never arrived): the reservation stays, and the
    // service restarts before anything else happens.
    fake.fail
        .lock()
        .unwrap()
        .push((crate::fsm::coordinator::LAUNCH, false));
    assert!(spawn(agents.clone(), "two").await.is_err());
    drop(agents);
    let (agents, fake) = fake_agents(
        temp.path(),
        temp.path(),
        vec![row("agent", "p", "full-access", "a", "completed", false)],
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
    let sent = fake.sent(crate::fsm::coordinator::LAUNCH);
    assert_eq!(
        (sent.len(), sent[0]["threadId"].as_str()),
        (1, Some(reserved[0].as_str()))
    );
    assert_eq!(agents.registry().workers.len(), 2);

    // Unconfirmed, then T3's shell shows it finishing its first turn:
    // it is adopted and its coordinator woken.
    fake.fail
        .lock()
        .unwrap()
        .push((crate::fsm::coordinator::LAUNCH, false));
    assert!(spawn(agents.clone(), "three").await.is_err());
    let id = agents
        .registry()
        .workers
        .iter()
        .find(|(_, w)| w.branch == "three")
        .map(|(id, _)| id.clone())
        .unwrap();
    agents.consume_shell(&json!({"kind": "thread.updated", "location": "active", "thread": row(&id, "p", "full-access", "t", "completed", false)})).await;
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
        "provider-session.detach",
        "thread.metadata.update",
        "thread.create",
        "message.dispatch",
    ] {
        let temp = tempfile::tempdir().unwrap();
        let old = row("old", "p", "auto", "t", "completed", false);
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
            "provider-session.detach",
            "thread.metadata.update",
            "thread.create",
            "message.dispatch",
        ] {
            assert_eq!(fake.sent(kind).len(), 1, "{kind} after a cut at {step}");
        }
        assert_eq!(fake.sent("thread.create")[0]["runtimeMode"], "auto");
    }
}

/// A message whose answer is lost is sent again, when asked again, as
/// the same command: T3 shows it once.
#[tokio::test]
async fn a_send_asked_again_after_a_lost_answer_is_the_same_command() {
    let temp = tempfile::tempdir().unwrap();
    let (agents, fake) = fake_agents(
        temp.path(),
        temp.path(),
        vec![row("w1", "p", "auto", "t", "completed", false)],
    )
    .await;
    fake.fail.lock().unwrap().push(("message.dispatch", true));
    assert!(agents.message("w1", "go on").await.is_err());
    assert_eq!(agents.registry().intents.len(), 1);
    let agents = reopened(
        temp.path(),
        &fake,
        vec![row("w1", "p", "auto", "t", "completed", false)],
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
