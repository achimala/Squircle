use super::*;
use crate::gates;
use tasks::{Gate, GateEvent, Kind, Side, Track, Verdict};

// MARK: Visual gates (docs/task-tracking.md#gates)

/// A work item's gates as the phone draws them: its four-step bar, the one
/// thing it waits on, the current plan and review rounds, its films and the
/// user's words with the change answering each. Derived here so every
/// client shows the same thing.
pub(super) fn gate_view(state: &AppState, task: &tasks::Task) -> Value {
    let Some(track) = &task.track else {
        return Value::Null;
    };
    let questions = task.questions.iter().any(|q| q.open())
        || task
            .subtasks
            .iter()
            .any(|s| s.questions.iter().any(|q| q.open()));
    let closed = !task.status.open();
    // The user's words: the item's own ask, then their asks under it.
    let mut asks: Vec<&tasks::Task> = vec![task];
    let mut under: Vec<&tasks::Task> = task.subtasks.iter().filter(|s| s.users_words).collect();
    under.sort_by_key(|s| s.created_at);
    asks.extend(under);
    let plan = match track {
        Track::Code(code) => code.plan(),
        _ => None,
    };
    let change_of = |id: &str| {
        plan.and_then(|p| p.changes.iter().find(|c| c.asks.iter().any(|a| a == id)))
            .map(|c| c.n)
    };
    let asks: Vec<Value> = asks
        .iter()
        .map(|a| {
            json!({"id": a.id, "text": a.ask, "at": a.created_at, "open": a.status.open(),
                   "replaced": a.replaced_by.is_some(), "change": change_of(&a.id),
                   "covered": !task.uncovered.contains(&a.id)})
        })
        .collect();
    let mut view = json!({"kind": track.kind(), "asks": asks});
    let set = |view: &mut Value, step: usize, tone: &str, label: String, detail: String| {
        let steps: Vec<&str> = (0..4)
            .map(|i| match i.cmp(&step) {
                std::cmp::Ordering::Less => "done",
                std::cmp::Ordering::Equal => tone,
                std::cmp::Ordering::Greater => "todo",
            })
            .collect();
        view["step"] = json!(step);
        view["steps"] = json!(steps);
        view["tone"] = json!(tone);
        view["label"] = json!(label);
        view["detail"] = json!(detail);
    };
    match track {
        Track::NotPlanned => {
            let open = task.subtasks.iter().filter(|s| s.status.open()).count();
            view["label"] = json!("Not planned yet");
            view["detail"] = json!(format!("{open} asks"));
            view["group"] = json!(if closed { "closed" } else { "not_planned" });
        }
        Track::NoCode { answers } => {
            let latest_ask = task
                .subtasks
                .iter()
                .filter(|s| s.users_words)
                .map(|s| s.created_at)
                .fold(task.created_at, u64::max);
            let answered = answers.last().is_some_and(|a| a.at >= latest_ask);
            view["answers"] = json!(answers);
            view["label"] = json!(if closed {
                "Closed"
            } else if answered {
                "Answered"
            } else {
                "Asked"
            });
            view["group"] = json!(if closed {
                "closed"
            } else if questions {
                "needs_you"
            } else {
                "no_code"
            });
            let spawned: Vec<Value> = state
                .tasks
                .as_ref()
                .map(|t| t.list(&task.project_id))
                .unwrap_or_default()
                .iter()
                .filter(|t| t.from.as_deref() == Some(task.id.as_str()))
                .map(|t| {
                    let gate = match t.track {
                        Some(Track::Code(_)) => gate_view(state, t),
                        _ => Value::Null,
                    };
                    json!({"id": t.id, "title": t.name(), "steps": gate["steps"], "label": gate["label"]})
                })
                .collect();
            view["spawned"] = json!(spawned);
        }
        Track::Code(code) => {
            let reviews = code.reviews.len() as u32;
            match &code.gate {
                Gate::Planning => {
                    let detail = match code.plans.len() {
                        0 => "drawing".to_string(),
                        n => format!("round {}", n + 1),
                    };
                    set(&mut view, 0, "working", "Planning".into(), detail)
                }
                Gate::PlanWaiting if !task.uncovered.is_empty() => {
                    let n = task.uncovered.len();
                    set(
                        &mut view,
                        0,
                        "working",
                        "Planning".into(),
                        format!("{n} new {}", if n == 1 { "ask" } else { "asks" }),
                    )
                }
                Gate::PlanWaiting => {
                    let plan = code.plan().expect("waiting on a plan");
                    let detail = if plan.round == 1 && plan.pictures.len() == 1 {
                        "1 picture".to_string()
                    } else {
                        format!("round {}", plan.round)
                    };
                    set(&mut view, 0, "you", "Approve plan".into(), detail)
                }
                Gate::Building => {
                    let planned = code.approved().map_or(0, |p| p.changes.len());
                    let filmed = planned - code.unfilmed().len();
                    match code.review() {
                        Some(r) if !r.lapsed && r.verdict != Verdict::Pass => set(
                            &mut view,
                            1,
                            "working",
                            "Fixing".into(),
                            format!("review {}'s findings", r.round),
                        ),
                        _ => set(
                            &mut view,
                            1,
                            "working",
                            "Building".into(),
                            format!("{filmed} of {planned} changes filmed"),
                        ),
                    }
                }
                Gate::Reviewing { .. } => set(
                    &mut view,
                    2,
                    "working",
                    "Reviewing".into(),
                    format!("round {}", reviews + 1),
                ),
                Gate::Reviewed => {
                    let r = code.review().expect("reviewed");
                    match (r.verdict, r.approved) {
                        (Verdict::Pass, None) if code.merge_blocked().is_none() => set(
                            &mut view,
                            3,
                            "you",
                            "Approve merge".into(),
                            format!("review {} passed", r.round),
                        ),
                        (Verdict::Pass, Some(_)) => set(
                            &mut view,
                            3,
                            "working",
                            "Merging".into(),
                            "approved by you".into(),
                        ),
                        (Verdict::Pass, None) => set(
                            &mut view,
                            2,
                            "blocked",
                            "Review passed".into(),
                            code.merge_blocked().unwrap_or_default(),
                        ),
                        (v, _) => {
                            let n = r.findings.len();
                            set(
                                &mut view,
                                2,
                                "blocked",
                                if v == Verdict::Blocked {
                                    "Review blocked".into()
                                } else {
                                    "Review: revise".into()
                                },
                                format!("{n} to fix"),
                            )
                        }
                    }
                }
                Gate::Merged { .. } => {
                    set(&mut view, 4, "done", "Merged".into(), String::new());
                    view["steps"] = json!(["done", "done", "done", "done"]);
                    view["step"] = json!(3);
                }
            }
            if closed && !matches!(code.gate, Gate::Merged { .. }) {
                view["label"] = json!("Dropped");
            }
            view["group"] = json!(match (&code.gate, closed) {
                (Gate::Merged { .. }, _) => "merged",
                (_, true) => "closed",
                _ if view["tone"] == "you" || questions => "needs_you",
                _ => "working",
            });
            view["slug"] = json!(code.slug);
            view["branch"] = json!(code.branch);
            if let Gate::Merged { commit, at } = &code.gate {
                view["merged"] = json!({"commit": commit, "at": at});
            }
            let films = |n: u32| -> Vec<Value> {
                code.films
                    .iter()
                    .filter(|f| f.change == n)
                    .map(|f| json!({"side": f.side, "media": f.media, "stills": f.stills, "jumps": f.jumps, "caption": f.caption}))
                    .collect()
            };
            if let Some(p) = code.plan() {
                let changes: Vec<Value> = p
                    .changes
                    .iter()
                    .map(|c| json!({"n": c.n, "title": c.title, "asks": c.asks, "films": films(c.n)}))
                    .collect();
                view["plan"] = json!({"round": p.round, "digest": p.digest, "title": p.title, "summary": p.summary,
                    "pictures": p.pictures, "changes": changes, "approved_at": p.approved, "at": p.at});
            }
            view["plans"] = json!(
                code.plans
                    .iter()
                    .map(|p| json!({"round": p.round, "approved_at": p.approved, "at": p.at}))
                    .collect::<Vec<_>>()
            );
            if let Some(r) = code.review() {
                view["review"] = json!({"round": r.round, "plan": r.plan, "head": r.head, "verdict": r.verdict,
                    "summary": r.summary, "lines": r.lines, "findings": r.findings, "pictures": r.pictures,
                    "approved_at": r.approved, "lapsed": r.lapsed, "at": r.at, "thread": r.thread});
            }
            view["reviews"] = json!(
                code.reviews
                    .iter()
                    .map(
                        |r| json!({"round": r.round, "verdict": r.verdict, "lapsed": r.lapsed,
                        "approved_at": r.approved, "at": r.at, "findings": r.findings.len(),
                        "summary": r.summary})
                    )
                    .collect::<Vec<_>>()
            );
            // What the phone may send, and why it can't when it can't.
            match (&code.gate, code.plan()) {
                (Gate::PlanWaiting, Some(p)) if task.uncovered.is_empty() && !closed => {
                    view["approve_plan"] = json!({"round": p.round, "digest": p.digest});
                }
                (Gate::PlanWaiting | Gate::Planning, _) if !closed => {
                    view["plan_blocked"] = json!(if task.uncovered.is_empty() {
                        "The agent is drawing the plan"
                    } else {
                        "Your words aren't all in the plan yet"
                    });
                }
                _ => {}
            }
            if matches!(code.gate, Gate::Reviewed | Gate::Reviewing { .. }) && !closed {
                match (code.merge_blocked(), code.review()) {
                    (None, Some(r)) if r.approved.is_none() => {
                        view["approve_merge"] = json!({"round": r.round, "head": r.head});
                    }
                    (None, _) => {}
                    (Some(reason), _) => view["merge_blocked"] = json!(reason),
                }
            }
        }
    }
    view
}

fn gate_error(error: anyhow::Error) -> ApiError {
    ApiError::new(
        StatusCode::BAD_REQUEST,
        "gate_refused",
        format!("{error:#}"),
        "Read the message; run squircle help gates.",
    )
}

fn now_s() -> u64 {
    crate::model::now()
}

/// The app's folder for a work item, and the item.
fn item_and_repo(state: &AppState, id: &str) -> ApiResult<(tasks::Task, PathBuf)> {
    let task = tasks_of(state)?.get(id).map_err(ApiError::missing)?;
    let repo = agents(state)?
        .project_root(&task.project_id)
        .ok_or_else(|| ApiError::bad("T3 has no folder for this app's project"))?;
    Ok((task, repo))
}

fn code_of(task: &tasks::Task) -> ApiResult<&tasks::Code> {
    match &task.track {
        Some(Track::Code(code)) => Ok(code),
        _ => Err(ApiError::bad(format!(
            "{} is not a code work item (`squircle task kind {} code`)",
            task.id, task.id
        ))),
    }
}

async fn saved(state: &AppState, task: &tasks::Task, next: &str) -> ApiResult<Json<Value>> {
    Ok(Json(success(json!({
        "task": task_view(state, task), "gate": gate_view(state, task), "next": next,
    }))))
}

#[derive(Deserialize)]
pub(super) struct HandInPlan {
    /// The plan's folder (holding plan.md and its pictures).
    dir: PathBuf,
}

pub(super) async fn hand_in_plan(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<HandInPlan>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    let tasks = tasks_of(&state)?;
    let task = tasks.get(&id).map_err(ApiError::missing)?;
    code_of(&task)?;
    ensure_absolute(&r.dir)?;
    let slug = r
        .dir
        .file_name()
        .and_then(|n| n.to_str())
        .map(str::to_string)
        .ok_or_else(|| ApiError::bad("Pass the plan's folder, docs/plans/<slug>"))?;
    let mut open = vec![task.id.clone()];
    open.extend(
        task.subtasks
            .iter()
            .filter(|s| s.users_words && s.status.open())
            .map(|s| s.id.clone()),
    );
    let (dir, task_dir, item) = (
        r.dir.clone(),
        tasks.dir(&id).map_err(ApiError::bad)?,
        id.clone(),
    );
    let draft =
        tokio::task::spawn_blocking(move || gates::hand_in_plan(&dir, &item, &open, &task_dir))
            .await
            .map_err(ApiError::internal)?
            .map_err(gate_error)?;
    let pictures = draft.pictures.len();
    let task = tasks
        .gate(
            &id,
            GateEvent::Plan {
                id: id.clone(),
                slug,
                draft,
                now: now_s(),
            },
        )
        .await
        .map_err(task_error)?;
    let round = code_of(&task)?.plans.len();
    saved(
        &state,
        &task,
        &format!(
            "Plan round {round} ({pictures} pictures) waits on the user's Approve plan on their phone. \
             Say so in a sentence and end your turn: no code before they approve; you hear when they do, or what they want changed."
        ),
    )
    .await
}

fn ensure_absolute(path: &std::path::Path) -> ApiResult<()> {
    if path.is_absolute() {
        Ok(())
    } else {
        Err(ApiError::bad("Pass an absolute path"))
    }
}

#[derive(Deserialize)]
pub(super) struct ApprovePlan {
    round: u32,
    digest: String,
}

pub(super) async fn approve_plan(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<ApprovePlan>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    let tasks = tasks_of(&state)?;
    let task = tasks.get(&id).map_err(ApiError::missing)?;
    let news = format!(
        "[approved] The user approved plan round {} of “{}” ({}). Build it now: brief workers with it (`thread spawn --task {}` gives them the plan and their changes); \
         each films its changes with `squircle film`, then run `squircle review {} --thread <your thread id>`.",
        r.round,
        task.name(),
        task.id,
        task.id,
        task.id
    );
    let task = tasks
        .gate(
            &id,
            GateEvent::ApprovePlan {
                id: id.clone(),
                round: r.round,
                digest: r.digest,
                news,
                now: now_s(),
            },
        )
        .await
        .map_err(task_error)?;
    relay(&state).await;
    saved(&state, &task, "Approved; the agent starts building.").await
}

#[derive(Deserialize)]
pub(super) struct StartReview {
    /// The app agent's thread: the reviewer is its worker.
    thread: String,
    branch: Option<String>,
}

pub(super) async fn start_review(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<StartReview>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    let agents = agents(&state)?;
    let tasks = tasks_of(&state)?;
    let (task, repo) = item_and_repo(&state, &id)?;
    let code = code_of(&task)?;
    let plan = code
        .approved()
        .ok_or_else(|| {
            ApiError::bad(
                "The plan isn't approved: nothing is reviewed before the user approves its plan",
            )
        })?
        .clone();
    if matches!(code.gate, Gate::Reviewing { .. }) {
        return Err(ApiError::bad("A review is already running; wait for it"));
    }
    let unfilmed = code.unfilmed();
    if !unfilmed.is_empty() {
        return Err(ApiError::bad(format!(
            "Changes {unfilmed:?} have no film on the branch yet: film each with `squircle film {id} --change N --side branch --file CLIP` first"
        )));
    }
    // The branch: as given, as last reviewed, or the newest linked worker's.
    let branch = r
        .branch
        .clone()
        .or_else(|| code.branch.clone())
        .or_else(|| {
            task.threads
                .iter()
                .rev()
                .find_map(|t| agents.worker_branch(t))
        })
        .ok_or_else(|| ApiError::bad("Name the branch with --branch"))?;
    let head = gates::head(&repo, &branch)
        .await
        .map_err(gate_error)?
        .ok_or_else(|| ApiError::bad(format!("No branch {branch} in the app's repo")))?;
    let config = gates::config(&repo);
    let base = match &config.base {
        Some(base) => base.clone(),
        None => gates::current_branch(&repo).await.map_err(gate_error)?,
    };
    let round = code.reviews.len() + 1;
    let task_dir = tasks.dir(&id).map_err(ApiError::bad)?;
    let plan_dir = gates::plan_dir(&task_dir, &plan.digest);
    let media = tasks.media(&id);
    let path_of = |m: &str| {
        media
            .iter()
            .find(|x| x.id == m)
            .map(|x| x.file.display().to_string())
            .unwrap_or_default()
    };
    let films: String = code
        .films
        .iter()
        .map(|f| {
            let stills: Vec<String> = f.stills.iter().map(|s| path_of(s)).collect();
            format!(
                "\n- change {} on {}: {} (stills: {}; measured jumps at {:?} s)",
                f.change,
                if f.side == Side::Main {
                    "main"
                } else {
                    "the branch"
                },
                path_of(&f.media),
                stills.join(", "),
                f.jumps
            )
        })
        .collect();
    let rules = if config.rules.is_empty() {
        "the repository's AGENTS.md and the documents it points to".to_string()
    } else {
        config.rules.join(", ")
    };
    let slug = code.slug.clone().unwrap_or_else(|| "item".into());
    let changes: String = plan
        .changes
        .iter()
        .map(|c| format!("\n{}. {}", c.n, c.title))
        .collect();
    let earlier: String = code
        .reviews
        .iter()
        .map(|r| {
            format!(
                "\n- review {} of {}: {}{}",
                r.round,
                gates_short(&r.head),
                r.verdict.label(),
                if r.lapsed {
                    " (the branch moved after it)"
                } else {
                    ""
                }
            )
        })
        .collect();
    let prompt = format!(
        "You are the independent reviewer of “{title}” (review round {round}), for the user who approves the merge on their phone. \
         You change no code and merge nothing. Your worktree is at the branch {branch} as it is now, commit {head}.\n\n\
         The approved plan (round {plan_round}) is in {plan_dir}: read plan.md and look at its pictures. Its changes:{changes}\n\n\
         Review the diff `git diff {base}...{head}` against the plan and against the app's rules: {rules}. \
         Each change was filmed on the simulator; look at the films and their stills (and film more yourself with `squircle sim start` if one is missing or unclear):{films}\n\
         Earlier reviews:{earlier}\n\n\
         Write your review as docs/plans/{slug}/review-{round}.md in your worktree, in this format (`squircle help gates` has it in full):\n\
         # Review {round}: PASS | REVISE | BLOCKED\n\
         One or two sentences.\n\
         ## Plan vs actual\n\
         One numbered line per planned change: `N. ✓ what was built`, `N. ≠ what was built instead — why: …`, or `N. ✗ dropped — why: …`.\n\
         ## Findings\n\
         For each finding: `### What is wrong`, one picture (`![](frames/…png)`, a still or screenshot that shows it), then `- planned: …`, `- branch: …`, `- fix: …`.\n\n\
         PASS only if every change is built as planned or differs for a good reason and nothing is wrong. Then hand it in: \
         `{cli} review submit {id} --head {head} --file <absolute path of review-{round}.md>`. It refuses a review missing a change's line; fix it and submit again. Reply with the verdict in one line.",
        title = task.name(),
        plan_round = plan.round,
        plan_dir = plan_dir.display(),
        cli = "squircle",
    );
    let (provider, model, effort) = (
        config
            .reviewer_provider
            .clone()
            .unwrap_or(gates::REVIEWER.0.into()),
        config
            .reviewer_model
            .clone()
            .unwrap_or(gates::REVIEWER.1.into()),
        config
            .reviewer_effort
            .clone()
            .unwrap_or(gates::REVIEWER.2.into()),
    );
    let reviewer_branch = format!("{branch}-review-{round}");
    let spawned = agents
        .spawn(
            &r.thread,
            &format!("Review {round}: {}", task.name()),
            &reviewer_branch,
            Some(&head),
            &prompt,
            Some(&provider),
            Some(&model),
            Some(&effort),
            None,
        )
        .await
        .map_err(agent_error)?;
    let thread = spawned["id"].as_str().map(str::to_string);
    if let Some(thread) = &thread {
        tasks
            .link(&id, Some(thread), None, false)
            .await
            .map_err(task_error)?;
    }
    let task = tasks
        .gate(
            &id,
            GateEvent::ReviewStart {
                id: id.clone(),
                branch: branch.clone(),
                head: head.clone(),
                thread,
                now: now_s(),
            },
        )
        .await
        .map_err(task_error)?;
    saved(
        &state,
        &task,
        &format!(
            "The reviewer ({model}) runs on {branch} at {}. End your turn; a [worker update] comes when it hands in review {round}. \
             A new commit on {branch} voids it.",
            gates_short(&head)
        ),
    )
    .await
}

fn gates_short(commit: &str) -> &str {
    tasks::short(commit)
}

#[derive(Deserialize)]
pub(super) struct SubmitReview {
    file: PathBuf,
    head: String,
}

pub(super) async fn submit_review(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<SubmitReview>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    ensure_absolute(&r.file)?;
    let tasks = tasks_of(&state)?;
    let task_dir = tasks.dir(&id).map_err(ApiError::bad)?;
    let file = r.file.clone();
    let draft = tokio::task::spawn_blocking(move || gates::hand_in_review(&file, &task_dir))
        .await
        .map_err(ApiError::internal)?
        .map_err(gate_error)?;
    let verdict = draft.verdict;
    let task = tasks
        .gate(
            &id,
            GateEvent::ReviewSubmit {
                id: id.clone(),
                head: r.head,
                draft,
                now: now_s(),
            },
        )
        .await
        .map_err(task_error)?;
    let next = match verdict {
        Verdict::Pass => "Handed in. The user approves the merge on their phone; you're done.",
        _ => "Handed in. The app agent sends the findings back to the workers; you're done.",
    };
    saved(&state, &task, next).await
}

#[derive(Deserialize)]
pub(super) struct ApproveMerge {
    round: u32,
    head: String,
}

pub(super) async fn approve_merge(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<ApproveMerge>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    let tasks = tasks_of(&state)?;
    let (task, repo) = item_and_repo(&state, &id)?;
    // The branch as it is now, not as last seen: a commit since voids it.
    if let Some(branch) = code_of(&task)?.branch.clone() {
        let now = gates::head(&repo, &branch).await.map_err(gate_error)?;
        tasks
            .heads(vec![(id.clone(), now)])
            .await
            .map_err(task_error)?;
    }
    let news = format!(
        "[approved] The user approved merging “{}” (review {} of {}). Merge it now with `squircle merge {}`.",
        task.name(),
        r.round,
        gates_short(&r.head),
        task.id
    );
    let task = tasks
        .gate(
            &id,
            GateEvent::ApproveMerge {
                id: id.clone(),
                round: r.round,
                head: r.head,
                news,
                now: now_s(),
            },
        )
        .await
        .map_err(task_error)?;
    relay(&state).await;
    saved(&state, &task, "Approved; the agent merges it.").await
}

pub(super) async fn merge_item(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    let tasks = tasks_of(&state)?;
    let (task, repo) = item_and_repo(&state, &id)?;
    let code = code_of(&task)?;
    if let Some(reason) = code.merge_blocked() {
        return Err(ApiError::bad(reason));
    }
    let review = code.review().expect("merge_blocked checked").clone();
    if review.approved.is_none() {
        return Err(ApiError::bad(
            "The user hasn't approved this merge. It waits on their Approve merge; only that lets it through.",
        ));
    }
    let branch = code.branch.clone().unwrap_or_default();
    let now = gates::head(&repo, &branch).await.map_err(gate_error)?;
    if now.as_deref() != Some(review.head.as_str()) {
        tasks
            .heads(vec![(id.clone(), now)])
            .await
            .map_err(task_error)?;
        relay(&state).await;
        return Err(ApiError::bad(format!(
            "{branch} moved after review {} of {}: the approval lapsed. Review it again.",
            review.round,
            gates_short(&review.head)
        )));
    }
    let config = gates::config(&repo);
    let base = match config.base {
        Some(base) => base,
        None => gates::current_branch(&repo).await.map_err(gate_error)?,
    };
    // The item's folder: the approved plan as handed in, every review, and the films' stills.
    let task_dir = tasks.dir(&id).map_err(ApiError::bad)?;
    let plan = code.approved().expect("reviewed needs an approved plan");
    let plan_dir = gates::plan_dir(&task_dir, &plan.digest);
    let mut files = vec![(PathBuf::from("plan.md"), plan_dir.join("plan.md"))];
    for p in &plan.pictures {
        let rel = gates::inside(p).map_err(gate_error)?;
        files.push((rel.clone(), plan_dir.join(&rel)));
    }
    for r in &code.reviews {
        let dir = gates::review_dir(&task_dir, &r.digest);
        files.push((
            PathBuf::from(format!("review-{}.md", r.round)),
            dir.join("review.md"),
        ));
        for p in &r.pictures {
            let rel = gates::inside(p).map_err(gate_error)?;
            files.push((rel.clone(), dir.join(&rel)));
        }
    }
    let media = tasks.media(&id);
    for f in &code.films {
        for (i, s) in f.stills.iter().enumerate() {
            if let Some(m) = media.iter().find(|m| &m.id == s) {
                let side = if f.side == Side::Main {
                    "main"
                } else {
                    "branch"
                };
                let ext = m.file.extension().and_then(|e| e.to_str()).unwrap_or("png");
                files.push((
                    PathBuf::from(format!("frames/change-{}-{side}-{i}.{ext}", f.change)),
                    m.file.clone(),
                ));
            }
        }
    }
    let folder = gates::Folder {
        slug: code.slug.clone().unwrap_or_else(|| id.clone()),
        files,
    };
    let message = format!(
        "Merge “{}” (plan round {}, review {} {})\n\nApproved by the user on their phone. Task {}.",
        task.name(),
        plan.round,
        review.round,
        review.verdict.label(),
        task.id
    );
    let commit = gates::merge(
        &repo,
        &base,
        &review.head,
        &folder,
        &message,
        &config.checks,
    )
    .await
    .map_err(gate_error)?;
    let task = tasks
        .gate(
            &id,
            GateEvent::Merged {
                id: id.clone(),
                round: review.round,
                commit: commit.clone(),
                now: now_s(),
            },
        )
        .await
        .map_err(task_error)?;
    saved(
        &state,
        &task,
        &format!(
            "Merged into {base} as {}. Tell the user in a sentence; archive its workers (`thread archive`).",
            gates_short(&commit)
        ),
    )
    .await
}

#[derive(Deserialize)]
pub(super) struct FilmChange {
    change: u32,
    side: Side,
    /// A clip or picture; or `thread` for that thread's newest recording.
    file: Option<PathBuf>,
    thread: Option<String>,
    caption: Option<String>,
}

pub(super) async fn film_change(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<FilmChange>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    let tasks = tasks_of(&state)?;
    let task = tasks.get(&id).map_err(ApiError::missing)?;
    let code = code_of(&task)?;
    let plan = code
        .approved()
        .ok_or_else(|| ApiError::bad("The plan isn't approved yet"))?;
    if !plan.changes.iter().any(|c| c.n == r.change) {
        return Err(ApiError::bad(format!(
            "Plan round {} has no change {}",
            plan.round, r.change
        )));
    }
    let file = match (&r.file, &r.thread) {
        (Some(file), _) => {
            ensure_absolute(file)?;
            file.clone()
        }
        (None, Some(thread)) => {
            let root = state.files.root.clone();
            let mut clips: Vec<crate::media::Media> = crate::media::list(&root, thread)
                .map_err(ApiError::bad)?
                .into_iter()
                .filter(|m| m.kind == "video")
                .collect();
            clips.sort_by(|a, b| a.created_at.total_cmp(&b.created_at));
            clips
                .pop()
                .ok_or_else(|| {
                    ApiError::bad(
                        "That thread has no recording yet: film it with `squircle sim start` first",
                    )
                })?
                .file
        }
        (None, None) => return Err(ApiError::bad("Pass --file CLIP or --thread ID")),
    };
    let side = if r.side == Side::Main {
        "main"
    } else {
        "branch"
    };
    let caption = r
        .caption
        .clone()
        .unwrap_or_else(|| format!("change {} on {side}", r.change));
    let dir = tasks.media_dir(&id).map_err(ApiError::bad)?;
    let clip = crate::media::add_in(&dir, &id, &file, Some(&caption)).map_err(gate_error)?;
    let mut stills = vec![];
    let mut jumps = vec![];
    if clip.kind == "video" {
        let scratch = tasks
            .dir(&id)
            .map_err(ApiError::bad)?
            .join("frames")
            .join(&clip.id);
        let frames = gates::film(&clip.file, &scratch).await;
        let frames = match frames {
            Ok(frames) => frames,
            Err(error) => {
                crate::media::remove(&clip);
                return Err(gate_error(
                    error.context("Measuring the film failed; nothing was filed"),
                ));
            }
        };
        for (path, label) in &frames.stills {
            let still = crate::media::add_in(&dir, &id, path, Some(&format!("{caption}: {label}")))
                .map_err(gate_error)?;
            stills.push(still.id);
        }
        let _ = std::fs::remove_dir_all(&scratch);
        jumps = frames.jumps;
    }
    let film = tasks::Film {
        change: r.change,
        side: r.side,
        media: clip.id.clone(),
        stills,
        jumps: jumps.clone(),
        caption,
        at: now_s(),
    };
    let task = tasks
        .gate(
            &id,
            GateEvent::Film {
                id: id.clone(),
                film,
                now: now_s(),
            },
        )
        .await
        .map_err(task_error)?;
    let left = code_of(&task)?.unfilmed();
    let jumps = if jumps.is_empty() {
        "no abrupt jumps measured".to_string()
    } else {
        format!("frames jump at {jumps:.2?} s: look at those stills")
    };
    saved(
        &state,
        &task,
        &format!(
            "Filed as change {}'s film on {side} ({jumps}). {}",
            r.change,
            if left.is_empty() {
                "Every change is filmed on the branch; `squircle review` next.".to_string()
            } else {
                format!("Still to film on the branch: changes {left:?}.")
            }
        ),
    )
    .await
}

#[derive(Deserialize)]
pub(super) struct SetKind {
    kind: Kind,
}

pub(super) async fn set_kind(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<SetKind>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    let task = tasks_of(&state)?
        .gate(
            &id,
            GateEvent::Kind {
                id: id.clone(),
                kind: r.kind,
                now: now_s(),
            },
        )
        .await
        .map_err(task_error)?;
    saved(&state, &task, "Filed.").await
}

#[derive(Deserialize)]
pub(super) struct AnswerItem {
    text: String,
    #[serde(default)]
    files: Vec<PathBuf>,
}

pub(super) async fn answer_item(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<AnswerItem>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    let tasks = tasks_of(&state)?;
    let dir = tasks.media_dir(&id).map_err(ApiError::bad)?;
    let mut media = vec![];
    for file in &r.files {
        ensure_absolute(file)?;
        media.push(
            crate::media::add_in(&dir, &id, file, None)
                .map_err(gate_error)?
                .id,
        );
    }
    let task = tasks
        .gate(
            &id,
            GateEvent::Answer {
                id: id.clone(),
                answer: tasks::Answer {
                    text: r.text.trim().chars().take(4000).collect(),
                    media,
                    at: now_s(),
                },
                now: now_s(),
            },
        )
        .await
        .map_err(task_error)?;
    saved(
        &state,
        &task,
        "It shows on the item; the user closes it or asks more. Any fix it found is its own code item (`task add --kind code --from ID`).",
    )
    .await
}

#[derive(Deserialize)]
pub(super) struct ChangeItem {
    text: String,
}

/// The user's Change… (or Ask more…): their words go on the item as an
/// ask, the agent hears them, and a review stage goes back to the workers.
pub(super) async fn change_item(
    State(state): State<AppState>,
    Path(id): Path<String>,
    payload: std::result::Result<Json<ChangeItem>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    let text = r.text.trim();
    if text.is_empty() {
        return Err(ApiError::bad("Say what to change"));
    }
    let tasks = tasks_of(&state)?;
    let item = tasks.get(&id).map_err(ApiError::missing)?;
    let title: String = text
        .split_whitespace()
        .take(6)
        .collect::<Vec<_>>()
        .join(" ");
    let ask = tasks
        .add(
            &item.project_id,
            &title,
            text,
            None,
            None,
            tasks::By::User,
            None,
            vec![],
            Some(&id),
            None,
        )
        .await
        .map_err(task_error)?;
    let stage = match &item.track {
        Some(Track::Code(code)) => match code.gate {
            Gate::Planning | Gate::PlanWaiting => format!(
                "Draw plan round {} with these words tied to a change and hand it in (`squircle plan`).",
                code.plans.len() + 1
            ),
            Gate::Reviewing { .. } | Gate::Reviewed => "It is back at Build: send the workers the whole current spec with these words, then review again.".into(),
            _ => "Send the workers the whole current spec with these words.".into(),
        },
        Some(Track::NoCode { .. }) => "Answer it (`squircle task answer`).".into(),
        _ => String::new(),
    };
    let news = format!(
        "[change] The user wants a change to “{}” (filed as ask {}): “{text}”. {stage}",
        item.name(),
        ask.id
    );
    let task = tasks
        .gate(
            &id,
            GateEvent::Change {
                id: id.clone(),
                ask: ask.id.clone(),
                news,
                now: now_s(),
            },
        )
        .await
        .map_err(task_error)?;
    relay(&state).await;
    saved(
        &state,
        &task,
        "Your words are on the item; the agent has them.",
    )
    .await
}

pub(super) async fn close_item(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    let task = tasks_of(&state)?
        .gate(
            &id,
            GateEvent::Close {
                id: id.clone(),
                now: now_s(),
            },
        )
        .await
        .map_err(task_error)?;
    saved(&state, &task, "Closed.").await
}

/// Queues news for the app agents now rather than at the next tick.
async fn relay(state: &AppState) {
    if let Some(agents) = &state.agents
        && let Err(error) = agents.relay_news().await
    {
        eprintln!("Gate news not delivered yet: {error:#}");
    }
}

/// A file of a plan or review round as handed in.
pub(super) async fn round_file(
    State(state): State<AppState>,
    Path((id, kind, round, path)): Path<(String, String, u32, String)>,
) -> ApiResult<Response> {
    let tasks = tasks_of(&state)?;
    let task = tasks.get(&id).map_err(ApiError::missing)?;
    let code = code_of(&task)?;
    let task_dir = tasks.dir(&id).map_err(ApiError::bad)?;
    let dir = match kind.as_str() {
        "plan" => code
            .plans
            .iter()
            .find(|p| p.round == round)
            .map(|p| gates::plan_dir(&task_dir, &p.digest)),
        "review" => code
            .reviews
            .iter()
            .find(|r| r.round == round)
            .map(|r| gates::review_dir(&task_dir, &r.digest)),
        _ => None,
    }
    .ok_or_else(|| ApiError::missing("No such round"))?;
    let rel = gates::inside(&path).map_err(ApiError::bad)?;
    let file = dir.join(&rel);
    let content_type = match file.extension().and_then(|e| e.to_str()).unwrap_or("") {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "md" => "text/markdown; charset=utf-8",
        "mp4" | "m4v" => "video/mp4",
        "mov" => "video/quicktime",
        _ => "application/octet-stream",
    };
    super::media_routes::serve_file(&file, content_type).await
}

#[derive(Deserialize)]
pub(super) struct EnableGates {
    thread: Option<String>,
    project: Option<String>,
    base: Option<String>,
    #[serde(default)]
    rules: Vec<String>,
    #[serde(default)]
    checks: Vec<String>,
    provider: Option<String>,
    model: Option<String>,
    effort: Option<String>,
}

/// Writes the app's `.squircle/gates.toml`: its base branch, reviewer,
/// rules and merge checks. Gates apply to every app either way.
pub(super) async fn enable_gates(
    State(state): State<AppState>,
    payload: std::result::Result<Json<EnableGates>, JsonRejection>,
) -> ApiResult<Json<Value>> {
    let r = body(payload)?;
    let project = task_project(&state, r.project, r.thread.as_deref())?;
    let repo = agents(&state)?
        .project_root(&project)
        .ok_or_else(|| ApiError::bad("T3 has no folder for this app's project"))?;
    let base = match r.base {
        Some(base) => base,
        None => gates::current_branch(&repo).await.map_err(gate_error)?,
    };
    let config = gates::Config {
        base: Some(base),
        reviewer_provider: r.provider.or(Some(gates::REVIEWER.0.into())),
        reviewer_model: r.model.or(Some(gates::REVIEWER.1.into())),
        reviewer_effort: r.effort.or(Some(gates::REVIEWER.2.into())),
        rules: r.rules,
        checks: r.checks,
    };
    let path = repo.join(gates::CONFIG);
    std::fs::create_dir_all(path.parent().expect("has a parent")).map_err(ApiError::internal)?;
    std::fs::write(&path, gates::render_config(&config)).map_err(ApiError::internal)?;
    Ok(Json(success(json!({
        "file": path, "config": gates::render_config(&config),
        "next": "Commit it through a gated work item like any change (it is the app's own file).",
    }))))
}
