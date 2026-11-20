//! Visual gates (user, 2026-11-20; docs/task-tracking.md#gates): every work
//! item that changes code moves Plan → Build → Review → Merge, and two of
//! those steps are the user's. A plan round waits for their Approve plan;
//! a passing review round waits for their Approve merge; `squircle merge`
//! is the one way onto the base branch and only takes exactly the commit
//! they approved. Questions and research are No code items (asked →
//! answered → closed by the user); a backlog is Not planned yet.
//!
//! Approvals are bound: a plan approval names the round and its digest, a
//! merge approval the review round and the commit it reviewed. Anything
//! that is no longer current is refused. The branch moving (the service
//! sees its ref change) voids the review and its approval and sends the
//! item back to Build. Nothing here reads a clock or the disk.

use super::*;

/// What kind of work item it is. Sub-tasks (the user's words on an item)
/// have none; neither do work items from before gates that were already
/// closed (History shows their old status).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Track {
    /// A backlog: the user's asks wait here in their words until the agent
    /// takes some on into a work item with a plan.
    NotPlanned,
    /// A question or research: answered by the agent, closed by the user.
    /// Any fix it finds becomes its own work item (`from`).
    NoCode {
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        answers: Vec<Answer>,
    },
    /// Code: the two gates.
    Code(Code),
}

/// The kind a work item is given (`task add --kind`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, clap::ValueEnum)]
#[serde(rename_all = "snake_case")]
#[value(rename_all = "kebab-case")]
pub enum Kind {
    Code,
    NoCode,
    NotPlanned,
}

impl Kind {
    pub fn track(self) -> Track {
        match self {
            Kind::Code => Track::Code(Code::default()),
            Kind::NoCode => Track::NoCode { answers: vec![] },
            Kind::NotPlanned => Track::NotPlanned,
        }
    }
}

impl Track {
    pub fn kind(&self) -> Kind {
        match self {
            Track::NotPlanned => Kind::NotPlanned,
            Track::NoCode { .. } => Kind::NoCode,
            Track::Code(_) => Kind::Code,
        }
    }
}

/// The agent's answer to a No code item, with its pictures (media IDs).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Answer {
    pub text: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub media: Vec<String>,
    pub at: u64,
}

/// A code work item's plan rounds, review rounds, films and where it stands.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Code {
    /// Its folder in the app's repo: `docs/plans/<slug>/`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub slug: Option<String>,
    /// The branch its workers build on, once a review names it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(default)]
    pub plans: Vec<PlanRound>,
    #[serde(default)]
    pub reviews: Vec<ReviewRound>,
    #[serde(default)]
    pub films: Vec<Film>,
    #[serde(default)]
    pub gate: Gate,
}

/// Where a code item stands. The rounds it refers to are always the latest
/// ones (`violations` checks).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(tag = "stage", rename_all = "snake_case")]
pub enum Gate {
    /// The agent is drawing the next plan round.
    #[default]
    Planning,
    /// The latest plan round waits on the user's Approve plan.
    PlanWaiting,
    /// The latest plan round is approved; workers build and film it.
    Building,
    /// The reviewer runs on `head`, for the next review round.
    Reviewing {
        head: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        thread: Option<String>,
    },
    /// The latest review round is in; PASS waits on the user's Approve
    /// merge, anything else goes back to the workers.
    Reviewed,
    /// On the base branch as `commit`.
    Merged { commit: String, at: u64 },
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PlanRound {
    pub round: u32,
    /// Of the plan and its pictures as handed in: what Approve plan names.
    pub digest: String,
    pub title: String,
    pub summary: String,
    /// File names of its pictures in the round's folder, in order.
    #[serde(default)]
    pub pictures: Vec<String>,
    pub changes: Vec<PlanChange>,
    pub at: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approved: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PlanChange {
    pub n: u32,
    pub title: String,
    /// The asks it answers: the item's own ID or its sub-tasks'.
    #[serde(default)]
    pub asks: Vec<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    Pass,
    Revise,
    Blocked,
}

impl Verdict {
    pub fn label(self) -> &'static str {
        match self {
            Verdict::Pass => "PASS",
            Verdict::Revise => "REVISE",
            Verdict::Blocked => "BLOCKED",
        }
    }
}

/// How a planned change was built.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Mark {
    Built,
    Differs,
    Dropped,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ChangeLine {
    pub n: u32,
    pub mark: Mark,
    pub text: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub why: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Finding {
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub picture: Option<String>,
    #[serde(default)]
    pub planned: String,
    #[serde(default)]
    pub branch: String,
    #[serde(default)]
    pub fix: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ReviewRound {
    pub round: u32,
    /// The plan round it checked.
    pub plan: u32,
    /// The commit it reviewed: what Approve merge names.
    pub head: String,
    pub verdict: Verdict,
    pub digest: String,
    pub summary: String,
    pub lines: Vec<ChangeLine>,
    #[serde(default)]
    pub findings: Vec<Finding>,
    #[serde(default)]
    pub pictures: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thread: Option<String>,
    pub at: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approved: Option<u64>,
    /// The branch moved after it: it and its approval no longer count.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub lapsed: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, clap::ValueEnum)]
#[serde(rename_all = "snake_case")]
#[value(rename_all = "snake_case")]
pub enum Side {
    Main,
    Branch,
}

/// One change filmed on one side, kept in the item's media.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Film {
    pub change: u32,
    pub side: Side,
    /// The clip (or picture) in the item's media.
    pub media: String,
    /// Before/after and jump stills, in the item's media.
    #[serde(default)]
    pub stills: Vec<String>,
    /// Seconds from the clip's start where a frame jumped.
    #[serde(default)]
    pub jumps: Vec<f64>,
    #[serde(default)]
    pub caption: String,
    pub at: u64,
}

/// A plan round as the service read it from `plan.md`.
#[derive(Clone, Debug, PartialEq)]
pub struct PlanDraft {
    pub digest: String,
    pub title: String,
    pub summary: String,
    pub pictures: Vec<String>,
    pub changes: Vec<PlanChange>,
}

/// A review round as the reviewer handed it in.
#[derive(Clone, Debug, PartialEq)]
pub struct ReviewDraft {
    pub verdict: Verdict,
    pub digest: String,
    pub summary: String,
    pub lines: Vec<ChangeLine>,
    pub findings: Vec<Finding>,
    pub pictures: Vec<String>,
}

/// Something the app agent must hear (an approval, a lapse, the user's
/// Change…), kept until it is queued for the agent.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AgentNews {
    pub id: String,
    pub text: String,
}

/// Everything that moves a gate.
#[derive(Debug)]
pub enum GateEvent {
    /// The agent hands in plan round N+1.
    Plan {
        id: String,
        slug: String,
        draft: PlanDraft,
        now: u64,
    },
    /// The user's Approve plan, naming what their phone showed.
    ApprovePlan {
        id: String,
        round: u32,
        digest: String,
        news: String,
        now: u64,
    },
    /// The reviewer starts on `head` of `branch`.
    ReviewStart {
        id: String,
        branch: String,
        head: String,
        thread: Option<String>,
        now: u64,
    },
    /// The reviewer hands in its round for `head`.
    ReviewSubmit {
        id: String,
        head: String,
        draft: ReviewDraft,
        now: u64,
    },
    /// The user's Approve merge, naming the review round and commit shown.
    ApproveMerge {
        id: String,
        round: u32,
        head: String,
        news: String,
        now: u64,
    },
    /// Where each item's branch points now (None: the branch is gone).
    Heads {
        heads: Vec<(String, Option<String>)>,
        now: u64,
    },
    /// `squircle merge` landed the approved commit as `commit`.
    Merged {
        id: String,
        round: u32,
        commit: String,
        now: u64,
    },
    Film {
        id: String,
        film: Film,
        now: u64,
    },
    /// The agent's answer to a No code item.
    Answer {
        id: String,
        answer: Answer,
        now: u64,
    },
    /// The agent (re)files a work item as another kind; only before it has
    /// a plan round.
    Kind {
        id: String,
        kind: Kind,
        now: u64,
    },
    /// The user's Change… on an item: their words are already filed as an
    /// ask (`ask`); a review stage goes back to the workers.
    Change {
        id: String,
        ask: String,
        news: String,
        now: u64,
    },
    /// The user closes a No code item.
    Close {
        id: String,
        now: u64,
    },
    /// AgentNews queued for the agent.
    Told {
        id: String,
        news: String,
    },
}

impl Code {
    pub fn plan(&self) -> Option<&PlanRound> {
        self.plans.last()
    }

    /// The approved plan round workers build, if the latest is approved.
    pub fn approved(&self) -> Option<&PlanRound> {
        self.plans.last().filter(|p| p.approved.is_some())
    }

    pub fn review(&self) -> Option<&ReviewRound> {
        self.reviews.last()
    }

    /// Changes of the approved plan with no film on the branch side.
    pub fn unfilmed(&self) -> Vec<u32> {
        self.approved()
            .map(|plan| {
                plan.changes
                    .iter()
                    .map(|c| c.n)
                    .filter(|n| {
                        !self
                            .films
                            .iter()
                            .any(|f| f.change == *n && f.side == Side::Branch)
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Why Approve merge can't be pressed now, or `None` when it can.
    pub fn merge_blocked(&self) -> Option<String> {
        let review = match (&self.gate, self.review()) {
            (Gate::Reviewed, Some(review)) => review,
            (Gate::Merged { .. }, _) => return Some("Merged".into()),
            (Gate::Reviewing { .. }, _) => return Some("The review is running".into()),
            _ => return Some("No review of the branch as it is now".into()),
        };
        if review.verdict != Verdict::Pass {
            return Some(format!(
                "Can't merge: review {} says {}",
                review.round,
                review.verdict.label()
            ));
        }
        let unfilmed = self.unfilmed();
        if !unfilmed.is_empty() {
            return Some(format!("Can't merge: {} has no film", changes(&unfilmed)));
        }
        None
    }
}

fn changes(ns: &[u32]) -> String {
    let list: Vec<String> = ns.iter().map(u32::to_string).collect();
    match list.len() {
        1 => format!("change {}", list[0]),
        _ => format!("changes {}", list.join(", ")),
    }
}

/// The user's words on a work item that a plan must answer: the item's
/// own ask and its open sub-tasks that are the user's (filed from their
/// message or by them on the phone).
pub(super) fn open_asks(book: &Book, item: &Record) -> Vec<String> {
    let mut asks = vec![item.id.clone()];
    let mut subs: Vec<&Record> = book
        .children(&item.id)
        .filter(|t| t.users_words() && t.status.open())
        .collect();
    subs.sort_by_key(|t| (t.created_at, t.id.clone()));
    asks.extend(subs.into_iter().map(|t| t.id.clone()));
    asks
}

/// Open asks the latest plan round doesn't tie to a change.
pub(super) fn uncovered(book: &Book, item: &Record) -> Vec<String> {
    let Some(Track::Code(code)) = &item.track else {
        return vec![];
    };
    let covered: Vec<&String> = code
        .plan()
        .map(|p| p.changes.iter().flat_map(|c| &c.asks).collect())
        .unwrap_or_default();
    open_asks(book, item)
        .into_iter()
        .filter(|a| !covered.contains(&a))
        .collect()
}

/// Whether the item waits on the user's approval now: a plan round that
/// covers every ask, or a passing review not yet approved.
pub(super) fn waits(book: &Book, item: &Record) -> bool {
    match &item.track {
        Some(Track::Code(code)) if item.status.open() => match code.gate {
            Gate::PlanWaiting => uncovered(book, item).is_empty(),
            Gate::Reviewed => {
                code.merge_blocked().is_none()
                    && code.review().is_some_and(|r| r.approved.is_none())
            }
            _ => false,
        },
        _ => false,
    }
}

fn refuse(book: Book, reason: impl Into<String>) -> Reduction<Book, Effect> {
    Reduction::same(book, Disposition::Rejected(reason.into()))
}

/// The code track of work item `id`, or why there is none.
fn code_of<'a>(book: &'a mut Book, id: &str) -> Result<&'a mut Record, String> {
    let item = book.tasks.get_mut(id).ok_or(format!("No task {id}"))?;
    if item.parent.is_some() {
        return Err(format!("{id} is a sub-task; gates are on its work item"));
    }
    match &item.track {
        Some(Track::Code(_)) if item.status.open() => Ok(item),
        Some(Track::Code(_)) => Err(format!("{id} is closed")),
        _ => Err(format!(
            "{id} is not a code work item (`task kind ID code` files it as one)"
        )),
    }
}

fn code(item: &mut Record) -> &mut Code {
    match &mut item.track {
        Some(Track::Code(code)) => code,
        _ => unreachable!("checked by code_of"),
    }
}

/// A short commit hash for messages.
pub fn short(commit: &str) -> &str {
    &commit[..commit.len().min(8)]
}

pub(super) fn reduce(mut book: Book, event: GateEvent) -> Reduction<Book, Effect> {
    match event {
        GateEvent::Plan {
            id,
            slug,
            draft,
            now,
        } => {
            let asks = match book.tasks.get(&id) {
                Some(item) => open_asks(&book, item),
                None => return missing(book, &id),
            };
            let item = match code_of(&mut book, &id) {
                Ok(item) => item,
                Err(reason) => return refuse(book, reason),
            };
            if draft.changes.is_empty() {
                return refuse(book, "A plan needs at least one numbered change");
            }
            for (i, change) in draft.changes.iter().enumerate() {
                if change.n != i as u32 + 1 {
                    return refuse(book, "Number the changes 1, 2, 3… in order");
                }
            }
            let tied: Vec<&String> = draft.changes.iter().flat_map(|c| &c.asks).collect();
            if let Some(stray) = tied.iter().find(|a| !asks.contains(a)) {
                {
                    let reason = format!(
                        "{stray} is not an open ask of this item (`task show {id}` lists them)"
                    );
                    return refuse(book, reason);
                }
            }
            let left: Vec<&String> = asks.iter().filter(|a| !tied.contains(a)).collect();
            if !left.is_empty() {
                let list: Vec<String> = left.iter().map(|a| a.to_string()).collect();
                {
                    let reason = format!(
                        "Every one of the user's asks must be tied to a change (\"what else got dropped?\"); not tied: {}. \
                         Tie each with an `asks:` line under the change that answers it, or retire one the user replaced (`task update ID --replaced-by NEW`).",
                        list.join(", ")
                    );
                    return refuse(book, reason);
                }
            }
            let code = code(item);
            if matches!(code.gate, Gate::Reviewing { .. } | Gate::Merged { .. }) {
                return refuse(
                    book,
                    "A review is running; hand in a new plan after it reports",
                );
            }
            if code.plan().is_some_and(|p| p.digest == draft.digest) {
                return refuse(
                    book,
                    "This plan is the same as the latest round; change it first",
                );
            }
            let round = code.plans.len() as u32 + 1;
            code.slug = Some(slug);
            code.plans.push(PlanRound {
                round,
                digest: draft.digest,
                title: draft.title,
                summary: draft.summary,
                pictures: draft.pictures,
                changes: draft.changes,
                at: now,
                approved: None,
            });
            code.gate = Gate::PlanWaiting;
            item.touch(now);
            item.stir(now);
            changed(book)
        }
        GateEvent::ApprovePlan {
            id,
            round,
            digest,
            news,
            now,
        } => {
            let left = match book.tasks.get(&id) {
                Some(item) => uncovered(&book, item),
                None => return missing(book, &id),
            };
            let item = match code_of(&mut book, &id) {
                Ok(item) => item,
                Err(reason) => return refuse(book, reason),
            };
            let code = code(item);
            let Some(plan) = code.plans.last_mut() else {
                return refuse(book, "There is no plan to approve yet");
            };
            if plan.round != round || plan.digest != digest {
                {
                    let reason = format!(
                        "That isn't the current plan: round {} is. Look at it again first.",
                        plan.round
                    );
                    return refuse(book, reason);
                }
            }
            if code.gate != Gate::PlanWaiting || plan.approved.is_some() {
                return refuse(book, format!("Plan round {round} isn't waiting on you"));
            }
            if !left.is_empty() {
                return refuse(
                    book,
                    "Some of your words aren't in the plan yet; the agent draws the next round",
                );
            }
            plan.approved = Some(now);
            code.gate = Gate::Building;
            item.news.push(AgentNews {
                id: format!("{id}.plan.{round}"),
                text: news,
            });
            item.touch(now);
            item.stir(now);
            changed(book)
        }
        GateEvent::ReviewStart {
            id,
            branch,
            head,
            thread,
            now,
        } => {
            let item = match code_of(&mut book, &id) {
                Ok(item) => item,
                Err(reason) => return refuse(book, reason),
            };
            let code = code(item);
            if code.approved().is_none() {
                return refuse(
                    book,
                    "The plan isn't approved: nothing is reviewed before the user approves its plan",
                );
            }
            match &code.gate {
                Gate::Building | Gate::Reviewed => {}
                Gate::Reviewing { .. } => return refuse(book, "A review is already running"),
                _ => return refuse(book, "Not at the build stage"),
            }
            if code.review().is_some_and(|r| r.head == head && !r.lapsed) {
                {
                    let reason = format!(
                        "Review {} already covers {}; commit the fixes first",
                        code.reviews.len(),
                        short(&head)
                    );
                    return refuse(book, reason);
                }
            }
            code.branch = Some(branch);
            code.gate = Gate::Reviewing { head, thread };
            item.touch(now);
            item.stir(now);
            changed(book)
        }
        GateEvent::ReviewSubmit {
            id,
            head,
            draft,
            now,
        } => {
            let item = match code_of(&mut book, &id) {
                Ok(item) => item,
                Err(reason) => return refuse(book, reason),
            };
            let code = code(item);
            let (reviewing, thread) = match &code.gate {
                Gate::Reviewing { head, thread } => (head.clone(), thread.clone()),
                _ => {
                    return refuse(
                        book,
                        "No review is running (the branch may have moved since it started: start a new one)",
                    );
                }
            };
            if reviewing != head {
                {
                    let reason = format!(
                        "This review is of {}, but the branch is at {}",
                        short(&head),
                        short(&reviewing)
                    );
                    return refuse(book, reason);
                }
            }
            let plan = code.approved().expect("reviewing needs an approved plan");
            let missing_lines: Vec<u32> = plan
                .changes
                .iter()
                .map(|c| c.n)
                .filter(|n| !draft.lines.iter().any(|l| l.n == *n))
                .collect();
            if !missing_lines.is_empty() {
                {
                    let reason = format!(
                        "Give one plan-vs-actual line per planned change: {} missing",
                        changes(&missing_lines)
                    );
                    return refuse(book, reason);
                }
            }
            if let Some(stray) = draft
                .lines
                .iter()
                .find(|l| !plan.changes.iter().any(|c| c.n == l.n))
            {
                return refuse(book, format!("The plan has no change {}", stray.n));
            }
            let unfilmed = code.unfilmed();
            if !unfilmed.is_empty() {
                {
                    let reason = format!(
                        "{} has no film on the branch (`squircle film`); a review needs every change filmed",
                        changes(&unfilmed)
                    );
                    return refuse(book, reason);
                }
            }
            let plan = plan.round;
            let round = code.reviews.len() as u32 + 1;
            code.reviews.push(ReviewRound {
                round,
                plan,
                head,
                verdict: draft.verdict,
                digest: draft.digest,
                summary: draft.summary,
                lines: draft.lines,
                findings: draft.findings,
                pictures: draft.pictures,
                thread,
                at: now,
                approved: None,
                lapsed: false,
            });
            code.gate = Gate::Reviewed;
            item.touch(now);
            item.stir(now);
            changed(book)
        }
        GateEvent::ApproveMerge {
            id,
            round,
            head,
            news,
            now,
        } => {
            let item = match code_of(&mut book, &id) {
                Ok(item) => item,
                Err(reason) => return refuse(book, reason),
            };
            let code = code(item);
            if let Some(reason) = code.merge_blocked() {
                return refuse(book, reason);
            }
            let review = code.reviews.last_mut().expect("merge_blocked checked");
            if review.round != round || review.head != head {
                {
                    let reason = format!(
                        "That isn't the current review: round {} of {} is. Look at it again first.",
                        review.round,
                        short(&review.head)
                    );
                    return refuse(book, reason);
                }
            }
            if review.approved.is_some() {
                return Reduction::same(book, Disposition::Duplicate);
            }
            review.approved = Some(now);
            item.news.push(AgentNews {
                id: format!("{id}.merge.{round}"),
                text: news,
            });
            item.touch(now);
            item.stir(now);
            changed(book)
        }
        GateEvent::Heads { heads, now } => {
            let mut any = false;
            for (id, head) in heads {
                let Some(item) = book.tasks.get_mut(&id) else {
                    continue;
                };
                if !item.status.open() {
                    continue;
                }
                let Some(Track::Code(code)) = &mut item.track else {
                    continue;
                };
                let at = match &code.gate {
                    Gate::Reviewing { head, .. } => head.clone(),
                    Gate::Reviewed => match code.review() {
                        Some(r) => r.head.clone(),
                        None => continue,
                    },
                    _ => continue,
                };
                if head.as_deref() == Some(at.as_str()) {
                    continue;
                }
                let was_review = matches!(code.gate, Gate::Reviewed);
                if was_review && let Some(review) = code.reviews.last_mut() {
                    review.lapsed = true;
                }
                let approved = was_review && code.review().is_some_and(|r| r.approved.is_some());
                code.gate = Gate::Building;
                let moved = match &head {
                    Some(head) => format!("moved to {}", short(head)),
                    None => "is gone".into(),
                };
                let what = if approved {
                    "the user's merge approval lapsed with its review"
                } else if was_review {
                    "its review no longer counts"
                } else {
                    "the running review no longer counts"
                };
                item.news.push(AgentNews {
                    id: format!("{id}.moved.{}", head.as_deref().unwrap_or("gone")),
                    text: format!(
                        "[gates] The branch of “{}” {moved} after {}: {what}. It is back at Build; run `review` again when the branch is ready.",
                        item.title,
                        short(&at)
                    ),
                });
                item.touch(now);
                item.stir(now);
                any = true;
            }
            if any {
                changed(book)
            } else {
                Reduction::same(book, Disposition::Unchanged)
            }
        }
        GateEvent::Merged {
            id,
            round,
            commit,
            now,
        } => {
            let item = match code_of(&mut book, &id) {
                Ok(item) => item,
                Err(reason) => return refuse(book, reason),
            };
            let code = code(item);
            if let Some(reason) = code.merge_blocked() {
                return refuse(book, reason);
            }
            let review = code.review().expect("merge_blocked checked");
            if review.round != round || review.approved.is_none() {
                return refuse(
                    book,
                    "The user hasn't approved this merge: only their Approve merge on the current review lets it through",
                );
            }
            code.gate = Gate::Merged { commit, at: now };
            item.set(Stage::Done, By::Auto, Some("Merged"), now);
            book.cascade(&id, Stage::Done, By::Auto, now);
            changed(book)
        }
        GateEvent::Film { id, film, now } => {
            let item = match code_of(&mut book, &id) {
                Ok(item) => item,
                Err(reason) => return refuse(book, reason),
            };
            let code = code(item);
            let Some(plan) = code.approved() else {
                return refuse(
                    book,
                    "The plan isn't approved yet: film changes once the user approves it",
                );
            };
            if !plan.changes.iter().any(|c| c.n == film.change) {
                {
                    let reason = format!("Plan round {} has no change {}", plan.round, film.change);
                    return refuse(book, reason);
                }
            }
            code.films
                .retain(|f| !(f.change == film.change && f.side == film.side));
            code.films.push(film);
            item.touch(now);
            item.stir(now);
            changed(book)
        }
        GateEvent::Answer { id, answer, now } => {
            let Some(item) = book.tasks.get_mut(&id) else {
                return missing(book, &id);
            };
            let Some(Track::NoCode { answers }) = &mut item.track else {
                {
                    let reason =
                        format!("{id} is not a No code item; a code item answers with its plan");
                    return refuse(book, reason);
                }
            };
            if answer.text.trim().is_empty() {
                return refuse(book, "The answer is empty");
            }
            answers.push(answer);
            if !item.status.open() {
                item.set(Stage::Queued, By::Agent, None, now);
            }
            item.touch(now);
            item.stir(now);
            changed(book)
        }
        GateEvent::Kind { id, kind, now } => {
            let Some(item) = book.tasks.get_mut(&id) else {
                return missing(book, &id);
            };
            if item.parent.is_some() {
                return refuse(
                    book,
                    format!("{id} is a sub-task: the user's words on its item"),
                );
            }
            if let Some(Track::Code(code)) = &item.track
                && !code.plans.is_empty()
            {
                return refuse(
                    book,
                    "It has a plan round already; drop it and file a new item instead",
                );
            }
            if item.track.as_ref().map(Track::kind) == Some(kind) {
                return Reduction::same(book, Disposition::Unchanged);
            }
            item.track = Some(kind.track());
            item.touch(now);
            changed(book)
        }
        GateEvent::Change { id, ask, news, now } => {
            let Some(item) = book.tasks.get_mut(&id) else {
                return missing(book, &id);
            };
            if let Some(Track::Code(code)) = &mut item.track
                && matches!(code.gate, Gate::Reviewing { .. } | Gate::Reviewed)
            {
                if let Some(review) = code.reviews.last_mut()
                    && matches!(code.gate, Gate::Reviewed)
                {
                    review.lapsed = true;
                }
                code.gate = Gate::Building;
            }
            item.news.push(AgentNews {
                id: format!("{id}.change.{ask}"),
                text: news,
            });
            item.touch(now);
            item.stir(now);
            changed(book)
        }
        GateEvent::Close { id, now } => {
            let Some(item) = book.tasks.get_mut(&id) else {
                return missing(book, &id);
            };
            if !matches!(item.track, Some(Track::NoCode { .. })) {
                return refuse(book, "Only a No code item is closed by hand");
            }
            item.set(Stage::Done, By::User, Some("Closed"), now);
            book.cascade(&id, Stage::Done, By::User, now);
            changed(book)
        }
        GateEvent::Told { id, news } => {
            let Some(item) = book.tasks.get_mut(&id) else {
                return Reduction::same(book, Disposition::Unchanged);
            };
            let before = item.news.len();
            item.news.retain(|n| n.id != news);
            if item.news.len() == before {
                Reduction::same(book, Disposition::Unchanged)
            } else {
                changed(book)
            }
        }
    }
}

/// Gate invariants, for `M17::violations`.
pub(super) fn violations(record: &Record) -> Vec<String> {
    let mut found = vec![];
    let id = &record.id;
    match &record.track {
        Some(_) if record.parent.is_some() => {
            found.push(format!("sub-task {id} has a track"));
        }
        Some(Track::Code(code)) => {
            let plan = code.plan();
            let ok = match &code.gate {
                Gate::Planning => true,
                Gate::PlanWaiting => plan.is_some_and(|p| p.approved.is_none()),
                Gate::Building | Gate::Reviewing { .. } => code.approved().is_some(),
                Gate::Reviewed => {
                    code.approved().is_some()
                        && code
                            .review()
                            .is_some_and(|r| Some(r.plan) == plan.map(|p| p.round) && !r.lapsed)
                }
                Gate::Merged { .. } => code
                    .review()
                    .is_some_and(|r| r.verdict == Verdict::Pass && r.approved.is_some()),
            };
            if !ok {
                found.push(format!(
                    "code item {id} at {:?} without its rounds",
                    code.gate
                ));
            }
            if matches!(code.gate, Gate::Merged { .. }) != (record.status == Stage::Done) {
                found.push(format!("code item {id} is done exactly when merged"));
            }
            for (i, p) in code.plans.iter().enumerate() {
                if p.round != i as u32 + 1 {
                    found.push(format!("code item {id} plan rounds out of order"));
                }
            }
            for (i, r) in code.reviews.iter().enumerate() {
                if r.round != i as u32 + 1 {
                    found.push(format!("code item {id} review rounds out of order"));
                }
            }
        }
        _ => {}
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    const ITEM: &str = "00000000-0000-4000-8000-000000000001";
    const ASK: &str = "00000000-0000-4000-8000-000000000002";

    fn step(book: Book, event: Event) -> Book {
        let reduction = M17::reduce(book, event);
        assert_eq!(reduction.disposition, Disposition::Applied);
        assert_eq!(M17::violations(&reduction.state), vec![]);
        reduction.state
    }

    fn gate(book: Book, event: GateEvent) -> Book {
        step(book, Event::Gate(event))
    }

    fn refused(book: Book, event: GateEvent) -> (Book, String) {
        let reduction = M17::reduce(book, Event::Gate(event));
        let Disposition::Rejected(reason) = reduction.disposition else {
            panic!("not refused: {:?}", reduction.disposition)
        };
        (reduction.state, reason)
    }

    fn stage(book: &Book) -> Gate {
        match &book.tasks[ITEM].track {
            Some(Track::Code(code)) => code.gate.clone(),
            other => panic!("{other:?}"),
        }
    }

    fn item() -> Book {
        step(
            Book::default(),
            Event::Add {
                id: TaskID::parse(ITEM).unwrap(),
                project: "p".into(),
                title: "Keep the deck on the phone".into(),
                ask: "Does it work offline?".into(),
                status: None,
                note: None,
                by: By::Agent,
                source: None,
                threads: vec![],
                parent: None,
                kind: Some(Kind::Code),
                now: 1,
            },
        )
    }

    fn draft(digest: &str, asks: &[&str]) -> PlanDraft {
        PlanDraft {
            digest: digest.into(),
            title: "Keep the deck".into(),
            summary: "One picture".into(),
            pictures: vec!["now.png".into()],
            changes: vec![PlanChange {
                n: 1,
                title: "Keep the whole deck".into(),
                asks: asks.iter().map(|a| a.to_string()).collect(),
            }],
        }
    }

    fn plan(book: Book, digest: &str) -> Book {
        gate(
            book,
            GateEvent::Plan {
                id: ITEM.into(),
                slug: "deck".into(),
                draft: draft(digest, &[ITEM]),
                now: 2,
            },
        )
    }

    fn approve_plan(round: u32, digest: &str) -> GateEvent {
        GateEvent::ApprovePlan {
            id: ITEM.into(),
            round,
            digest: digest.into(),
            news: "approved".into(),
            now: 3,
        }
    }

    fn review(verdict: Verdict) -> ReviewDraft {
        ReviewDraft {
            verdict,
            digest: "r".into(),
            summary: String::new(),
            lines: vec![ChangeLine {
                n: 1,
                mark: Mark::Built,
                text: "Kept".into(),
                why: String::new(),
            }],
            findings: vec![],
            pictures: vec![],
        }
    }

    fn film(book: Book) -> Book {
        gate(
            book,
            GateEvent::Film {
                id: ITEM.into(),
                film: Film {
                    change: 1,
                    side: Side::Branch,
                    media: "m".into(),
                    stills: vec![],
                    jumps: vec![],
                    caption: String::new(),
                    at: 4,
                },
                now: 4,
            },
        )
    }

    /// Planned, approved, filmed and reviewed at `head` with `verdict`.
    fn reviewed(head: &str, verdict: Verdict) -> Book {
        let book = film(gate(plan(item(), "d1"), approve_plan(1, "d1")));
        let book = gate(
            book,
            GateEvent::ReviewStart {
                id: ITEM.into(),
                branch: "deck".into(),
                head: head.into(),
                thread: None,
                now: 5,
            },
        );
        gate(
            book,
            GateEvent::ReviewSubmit {
                id: ITEM.into(),
                head: head.into(),
                draft: review(verdict),
                now: 6,
            },
        )
    }

    fn approve_merge(round: u32, head: &str) -> GateEvent {
        GateEvent::ApproveMerge {
            id: ITEM.into(),
            round,
            head: head.into(),
            news: "approved".into(),
            now: 7,
        }
    }

    fn merged(round: u32) -> GateEvent {
        GateEvent::Merged {
            id: ITEM.into(),
            round,
            commit: "m1".into(),
            now: 8,
        }
    }

    #[test]
    fn a_plan_approval_binds_to_the_round_and_digest_shown() {
        let book = plan(item(), "d1");
        let book = plan(book, "d2");
        // The phone still showed round 1, or round 2 with old pictures.
        let (book, _) = refused(book, approve_plan(1, "d1"));
        let (book, _) = refused(book, approve_plan(2, "d1"));
        let book = gate(book, approve_plan(2, "d2"));
        assert_eq!(stage(&book), Gate::Building);
        // Pressed twice: the second is no longer waiting.
        let (book, _) = refused(book, approve_plan(2, "d2"));
        assert_eq!(book.tasks[ITEM].news.len(), 1);
    }

    #[test]
    fn every_ask_must_be_tied_to_a_change_before_the_plan_can_be_approved() {
        let book = plan(item(), "d1");
        // The user adds words after the round was handed in.
        let book = step(
            book,
            Event::Add {
                id: TaskID::parse(ASK).unwrap(),
                project: "p".into(),
                title: "Subtler".into(),
                ask: "Make it subtler".into(),
                status: None,
                note: None,
                by: By::User,
                source: None,
                threads: vec![],
                parent: Some(ITEM.into()),
                kind: None,
                now: 3,
            },
        );
        assert!(!waits(&book, &book.tasks[ITEM]));
        let (book, _) = refused(book, approve_plan(1, "d1"));
        // A round that leaves it out is refused; one that ties it goes in.
        let (book, reason) = refused(
            book,
            GateEvent::Plan {
                id: ITEM.into(),
                slug: "deck".into(),
                draft: draft("d2", &[ITEM]),
                now: 4,
            },
        );
        assert!(reason.contains(ASK), "{reason}");
        let book = gate(
            book,
            GateEvent::Plan {
                id: ITEM.into(),
                slug: "deck".into(),
                draft: draft("d2", &[ITEM, ASK]),
                now: 4,
            },
        );
        assert!(waits(&book, &book.tasks[ITEM]));
        gate(book, approve_plan(2, "d2"));
    }

    #[test]
    fn merge_needs_a_passing_review_of_the_head_approved_by_the_user() {
        // A blocked review can't be approved or merged.
        let (_, reason) = refused(reviewed("c1", Verdict::Blocked), approve_merge(1, "c1"));
        assert!(reason.contains("BLOCKED"), "{reason}");
        let (_, _) = refused(reviewed("c1", Verdict::Blocked), merged(1));
        // A passing one merges only once the user approved that round and commit.
        let book = reviewed("c1", Verdict::Pass);
        assert!(waits(&book, &book.tasks[ITEM]));
        let (book, _) = refused(book, merged(1));
        let (book, _) = refused(book, approve_merge(1, "c0"));
        let book = gate(book, approve_merge(1, "c1"));
        let book = gate(book, merged(1));
        assert_eq!(book.tasks[ITEM].status, Stage::Done);
    }

    #[test]
    fn the_branch_moving_voids_the_review_and_its_approval() {
        let book = gate(reviewed("c1", Verdict::Pass), approve_merge(1, "c1"));
        // The same head is no news.
        let book = M17::reduce(
            book,
            Event::Gate(GateEvent::Heads {
                heads: vec![(ITEM.into(), Some("c1".into()))],
                now: 9,
            }),
        )
        .state;
        assert_eq!(stage(&book), Gate::Reviewed);
        let book = gate(
            book,
            GateEvent::Heads {
                heads: vec![(ITEM.into(), Some("c2".into()))],
                now: 9,
            },
        );
        assert_eq!(stage(&book), Gate::Building);
        let (book, _) = refused(book, merged(1));
        let (book, _) = refused(book, approve_merge(1, "c1"));
        // A new review of the new head needs a new yes.
        let book = gate(
            book,
            GateEvent::ReviewStart {
                id: ITEM.into(),
                branch: "deck".into(),
                head: "c2".into(),
                thread: None,
                now: 10,
            },
        );
        let book = gate(
            book,
            GateEvent::ReviewSubmit {
                id: ITEM.into(),
                head: "c2".into(),
                draft: review(Verdict::Pass),
                now: 11,
            },
        );
        let (book, _) = refused(book, merged(2));
        let (book, _) = refused(book, approve_merge(1, "c1"));
        let book = gate(book, approve_merge(2, "c2"));
        gate(book, merged(2));
    }

    #[test]
    fn a_review_handed_in_for_an_older_head_or_without_every_change_is_refused() {
        let book = film(gate(plan(item(), "d1"), approve_plan(1, "d1")));
        let book = gate(
            book,
            GateEvent::ReviewStart {
                id: ITEM.into(),
                branch: "deck".into(),
                head: "c1".into(),
                thread: None,
                now: 5,
            },
        );
        // The branch moves while the reviewer runs.
        let moved = gate(
            book.clone(),
            GateEvent::Heads {
                heads: vec![(ITEM.into(), Some("c2".into()))],
                now: 6,
            },
        );
        refused(
            moved,
            GateEvent::ReviewSubmit {
                id: ITEM.into(),
                head: "c1".into(),
                draft: review(Verdict::Pass),
                now: 7,
            },
        );
        let mut empty = review(Verdict::Pass);
        empty.lines.clear();
        refused(
            book,
            GateEvent::ReviewSubmit {
                id: ITEM.into(),
                head: "c1".into(),
                draft: empty,
                now: 7,
            },
        );
    }

    #[test]
    fn an_unfilmed_change_blocks_the_review() {
        let book = gate(plan(item(), "d1"), approve_plan(1, "d1"));
        let book = gate(
            book,
            GateEvent::ReviewStart {
                id: ITEM.into(),
                branch: "deck".into(),
                head: "c1".into(),
                thread: None,
                now: 5,
            },
        );
        let (_, reason) = refused(
            book,
            GateEvent::ReviewSubmit {
                id: ITEM.into(),
                head: "c1".into(),
                draft: review(Verdict::Pass),
                now: 6,
            },
        );
        assert!(reason.contains("film"), "{reason}");
    }

    #[test]
    fn change_on_a_passed_review_sends_it_back_and_voids_the_approval() {
        let book = gate(reviewed("c1", Verdict::Pass), approve_merge(1, "c1"));
        let book = gate(
            book,
            GateEvent::Change {
                id: ITEM.into(),
                ask: ASK.into(),
                news: "change".into(),
                now: 9,
            },
        );
        assert_eq!(stage(&book), Gate::Building);
        refused(book, merged(1));
    }
}
