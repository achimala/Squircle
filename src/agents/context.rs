use super::*;

/// A message Squircle puts in a conversation in the user's place: T3 sends
/// every message as the user's, so each one carries a context record whose
/// kind starts with `squircle-`. The app shows any marked message as
/// Squircle's line (whatever the kind, so a new one can't pass as the
/// user's) and only unmarked ones as the user's own words.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Note {
    /// The service's wake-up that workers moved on.
    WorkerUpdate,
    /// The service's news that a build failed.
    BuildUpdate,
    /// A worker's prompt from its app agent.
    Task,
    /// `thread send` from another agent.
    AgentMessage,
    /// The service's news that a simulator is held for a thread in line.
    SimReady,
    /// The service compacting an idle agent's context.
    Upkeep,
    /// The service's news about this Mac's simulators: a runaway app it
    /// stopped, or the simulator host failing.
    SimHealth,
    /// The user's answer to a question in the tracker, or to a worker's
    /// question or approval they answered directly.
    Answer,
}

impl Note {
    pub const ALL: [Note; 8] = [
        Note::WorkerUpdate,
        Note::BuildUpdate,
        Note::Task,
        Note::AgentMessage,
        Note::SimReady,
        Note::Upkeep,
        Note::SimHealth,
        Note::Answer,
    ];

    pub(super) fn kind(self) -> &'static str {
        match self {
            Note::WorkerUpdate => "squircle-worker-update",
            Note::BuildUpdate => "squircle-build-update",
            Note::Task => "squircle-task",
            Note::AgentMessage => "squircle-agent-message",
            Note::SimReady => "squircle-sim-ready",
            Note::Upkeep => "squircle-upkeep",
            Note::SimHealth => "squircle-sim-health",
            Note::Answer => "squircle-answer",
        }
    }

    pub(super) fn label(self) -> &'static str {
        match self {
            Note::WorkerUpdate => "Worker update",
            Note::BuildUpdate => "Build update",
            Note::Task | Note::AgentMessage => "Agent message",
            Note::SimReady => "Simulator ready",
            Note::Upkeep => "Tidied up",
            Note::SimHealth => "Simulator trouble",
            Note::Answer => "Answered",
        }
    }

    /// The context record that marks a message as this note.
    pub fn record(self, payload: Value) -> Value {
        self.labeled(self.label(), payload)
    }

    /// The record with its own label, which the app shows as the line.
    pub(super) fn labeled(self, label: &str, payload: Value) -> Value {
        json!({"version": 1, "contextId": uuid::Uuid::new_v4().to_string(), "label": label,
               "kind": self.kind(), "payload": payload})
    }

    /// The user message T3 is sent for this note.
    pub fn message(self, id: &str, text: &str, payload: Value) -> Value {
        Self::with_record(id, text, self.record(payload))
    }

    pub(super) fn with_record(id: &str, text: &str, record: Value) -> Value {
        json!({"messageId": id, "role": "user", "text": text, "attachments": [],
               "context": {"version": 1, "records": [record]}})
    }

    /// The note marking a T3 message, if any.
    pub(super) fn of(message: &Value) -> Option<Note> {
        let records = message["context"]["records"].as_array()?;
        records
            .iter()
            .find_map(|r| Note::ALL.into_iter().find(|n| r["kind"] == n.kind()))
    }
}

/// The protocol 2 command that delivers a user message (`messageId`,
/// `text`, `attachments`, optional `context`) to a thread. T3 resolves
/// `deliveryIntent: auto` against the thread as it stands when the command
/// runs: it starts a run on an idle thread and steers or queues behind one
/// in progress, as T3's own clients do.
pub(super) fn deliver(thread: &str, message: Value) -> Value {
    let mut command = json!({
        "type": "message.dispatch", "threadId": thread,
        "messageId": message["messageId"], "text": message["text"],
        "attachments": message.get("attachments").cloned().unwrap_or(json!([])),
        "createdBy": "user", "creationSource": "server",
        "dispatchMode": {"type": "start_immediately"}, "deliveryIntent": "auto",
    });
    if let Some(context) = message.get("context") {
        command["context"] = context.clone();
    }
    command
}

/// Whether the user wrote this T3 message: a user message no note marks
/// and no agent wrote (T3 marks background-work notices and other agents'
/// messages `createdBy` an agent).
pub(super) fn users_own(message: &Value) -> bool {
    message["role"] == "user"
        && message["createdBy"].as_str().is_none_or(|by| by == "user")
        && !message["context"]["records"]
            .as_array()
            .into_iter()
            .flatten()
            .any(|r| {
                r["kind"]
                    .as_str()
                    .is_some_and(|k| k.starts_with("squircle-"))
            })
}

pub(super) fn quote(path: &Path) -> String {
    let text = path.display().to_string();
    if text
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || "/._-~".contains(c))
    {
        text
    } else {
        format!("'{}'", text.replace('\'', "'\\''"))
    }
}

/// How agents invoke this same CLI against this same service: plain
/// `squircle` once `agent setup` has put this data directory's wrapper on
/// their PATH, else the binary's path with both options.
pub fn cli_invocation(root: &Path, server: &str) -> String {
    if on_path(root) {
        "squircle".into()
    } else {
        cli_full(root, server)
    }
}

/// This binary's path with the data directory and service spelled out,
/// for hooks and anywhere PATH can't be relied on.
pub fn cli_full(root: &Path, server: &str) -> String {
    let exe = std::env::current_exe()
        .and_then(|p| p.canonicalize())
        .unwrap_or_else(|_| PathBuf::from("squircle"));
    format!(
        "{} --data-dir {} --server {server}",
        quote(&exe),
        quote(root)
    )
}

/// The data directory's `squircle`: runs this binary against this data
/// directory and service from anywhere, so agents can type just `squircle`.
pub fn wrapper(root: &Path) -> PathBuf {
    root.join("bin").join("squircle")
}

/// Where T3's agents find `squircle`: `~/.local/bin`, on the PATH T3 gives
/// them (Claude Code installs itself there).
pub fn path_link() -> Option<PathBuf> {
    dirs::home_dir().map(|home| home.join(".local/bin/squircle"))
}

/// Whether `squircle` on agents' PATH is this data directory's wrapper.
fn on_path(root: &Path) -> bool {
    let target = |p: &Path| p.canonicalize().ok();
    path_link().is_some_and(|link| target(&link).is_some_and(|t| Some(t) == target(&wrapper(root))))
}

/// Writes the wrapper for `exe` (the service's own binary), replacing an
/// older one. It sets the data directory and service for every call.
pub fn write_wrapper(root: &Path, server: &str, exe: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let root = root.canonicalize()?;
    let path = wrapper(&root);
    let text = format!(
        "#!/bin/sh\n# Squircle's CLI for the service at {server} with its data in {}; written by the service.\n\
         SQUIRCLE_DATA_DIR={}\nSQUIRCLE_SERVER={}\nexport SQUIRCLE_DATA_DIR SQUIRCLE_SERVER\nexec {} \"$@\"\n",
        root.display(),
        quote(&root),
        quote(Path::new(server)),
        quote(exe)
    );
    if std::fs::read_to_string(&path).ok().as_deref() == Some(text.as_str()) {
        return Ok(());
    }
    private_dir(path.parent().unwrap())?;
    let staged = path.with_extension("new");
    std::fs::write(&staged, text)?;
    std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o755))?;
    std::fs::rename(&staged, &path)?;
    Ok(())
}

/// Puts this data directory's wrapper on agents' PATH as `squircle`. Leaves
/// a `squircle` that is someone else's (a file, or a link to a wrapper that
/// still exists) alone, and says so.
pub fn link_wrapper(root: &Path) -> Result<std::result::Result<PathBuf, String>> {
    let Some(link) = path_link() else {
        return Ok(Err("no home directory".into()));
    };
    let target = wrapper(root);
    if on_path(root) {
        return Ok(Ok(link));
    }
    match std::fs::symlink_metadata(&link) {
        Ok(meta) if !meta.file_type().is_symlink() => {
            return Ok(Err(format!(
                "{} is another program; agents keep the full path",
                link.display()
            )));
        }
        Ok(_) if link.canonicalize().is_ok() => {
            return Ok(Err(format!(
                "{} runs another data directory's Squircle; agents keep the full path",
                link.display()
            )));
        }
        Ok(_) => std::fs::remove_file(&link)?,
        Err(_) => {}
    }
    std::fs::create_dir_all(link.parent().unwrap())?;
    std::os::unix::fs::symlink(&target, &link)?;
    Ok(Ok(link))
}

/// The project root that contains `cwd` most closely, comparing resolved
/// paths so symlinked aliases match. Two projects with the same root are
/// ambiguous: all of their indexes.
pub(crate) fn deepest_root(
    roots: &[&Path],
    cwd: &Path,
) -> std::result::Result<Option<usize>, Vec<usize>> {
    let resolve = |p: &Path| p.canonicalize().unwrap_or_else(|_| p.to_path_buf());
    let cwd = resolve(cwd);
    let mut matches: Vec<(usize, usize)> = roots
        .iter()
        .enumerate()
        .map(|(index, root)| (index, resolve(root)))
        .filter(|(_, root)| cwd.starts_with(root))
        .map(|(index, root)| (index, root.components().count()))
        .collect();
    matches.sort_by_key(|(_, depth)| std::cmp::Reverse(*depth));
    match matches.as_slice() {
        [] => Ok(None),
        [(index, depth), rest @ ..] if rest.first().is_none_or(|(_, d)| d < depth) => {
            Ok(Some(*index))
        }
        [(_, depth), ..] => Err(matches
            .iter()
            .filter(|(_, d)| d == depth)
            .map(|(i, _)| *i)
            .collect()),
    }
}

/// See `Agents::build_owner`.
pub(super) fn owner<'a>(
    registry: &'a Registry,
    tasks: &[crate::tasks::Task],
    thread: Option<&str>,
    build: &str,
) -> Option<&'a Agent> {
    let by_thread = thread.and_then(|t| {
        let coordinator = registry
            .workers
            .get(t)
            .map_or(t, |w| w.coordinator.as_str());
        registry
            .agents
            .values()
            .find(|a| a.thread_id == coordinator)
    });
    by_thread.or_else(|| {
        tasks
            .iter()
            .find(|t| t.builds.iter().any(|b| b == build))
            .and_then(|t| registry.agents.get(&t.project_id))
    })
}

/// A build in flight (queued or running), as the per-turn note names it.
pub struct LiveBuild {
    pub id: String,
    pub scheme: String,
    /// The thread that started it.
    pub thread: Option<String>,
    pub running: bool,
}

/// What to call a task in the note: its title, or the start of its ask
/// until an agent names it.
fn named(task: &crate::tasks::Task) -> String {
    if !task.title.is_empty() {
        return format!("“{}”", task.title);
    }
    let ask = task.ask.replace('\n', " ");
    let short: String = ask.chars().take(80).collect();
    let more = if short.len() < ask.len() { "…" } else { "" };
    format!("untitled, asked “{short}{more}”")
}

impl Agents {
    /// What needs the agent now from the tracker and its work: workers
    /// that are running or waiting on their own question, builds in
    /// flight, each with the task it serves, and questions open to the
    /// user. The rest of the tracker it reads with `task list`.
    pub(super) fn now(
        &self,
        agent: &Agent,
        workers: &[Value],
        builds: &[LiveBuild],
    ) -> (String, String) {
        let items = self.tasks.list(&agent.project_id);
        // Sub-tasks first: the most specific task a piece of work serves.
        let tasks: Vec<&crate::tasks::Task> = items
            .iter()
            .flat_map(|t| &t.subtasks)
            .chain(&items)
            .collect();
        let serves = |linked: &dyn Fn(&crate::tasks::Task) -> bool| {
            tasks
                .iter()
                .filter(|t| linked(t))
                .min_by_key(|t| !t.status.open())
                .map(|t| format!(", for {} ({})", named(t), t.id))
                .unwrap_or_default()
        };
        let mut running: String = workers
            .iter()
            .filter(|w| {
                matches!(
                    w["state"].as_str(),
                    Some("working" | "needs-you" | "starting")
                )
            })
            .map(|w| {
                let id = w["id"].as_str().unwrap_or("");
                format!(
                    "\n- worker “{}” ({id}) [{}] {}{}",
                    w["title"].as_str().unwrap_or(""),
                    w["branch"].as_str().unwrap_or(""),
                    w["state"].as_str().unwrap_or(""),
                    serves(&|t| t.threads.iter().any(|x| x == id)),
                )
            })
            .collect();
        let ours = |thread: &Option<String>| {
            thread
                .as_deref()
                .is_some_and(|t| t == agent.thread_id || workers.iter().any(|w| w["id"] == t))
        };
        running.extend(
            builds
                .iter()
                .map(|b| (b, serves(&|t| t.builds.contains(&b.id))))
                .filter(|(b, serving)| !serving.is_empty() || ours(&b.thread))
                .map(|(b, serving)| {
                    format!(
                        "\n- build {} ({}) {}{serving}",
                        b.scheme,
                        b.id,
                        if b.running { "running" } else { "queued" }
                    )
                }),
        );
        let asked: String = tasks
            .iter()
            .flat_map(|t| t.questions.iter().filter(|q| q.open()).map(move |q| (t, q)))
            .map(|(t, q)| {
                format!(
                    "\n? “{}” ({}) on {} ({})",
                    q.text.replace('\n', " "),
                    q.id,
                    named(t),
                    t.id
                )
            })
            .collect();
        (running, asked)
    }

    /// The note at the start of each agent turn and after compaction: its
    /// role and reply style in brief (the system prompt has the rest), its
    /// thread ID (needed to spawn workers), the app's notes and only what
    /// needs it now: the user's messages not yet in the tracker, its
    /// questions waiting on the user, and its running workers and `builds`
    /// with the task each serves. The tracker itself is a `task list` away.
    pub async fn context(&self, cwd: &Path, builds: &[LiveBuild]) -> String {
        let candidates: Vec<(Agent, String, PathBuf)> = {
            let View {
                registry, shell, ..
            } = &*self.view.get();
            registry
                .agents
                .values()
                .filter_map(|a| {
                    let project = shell.project(&a.project_id)?;
                    let root = PathBuf::from(project["workspaceRoot"].as_str()?);
                    Some((
                        a.clone(),
                        project["title"].as_str().unwrap_or("this app").to_string(),
                        root,
                    ))
                })
                .collect()
        };
        let roots: Vec<&Path> = candidates
            .iter()
            .map(|(_, _, root)| root.as_path())
            .collect();
        let (agent, app) = match deepest_root(&roots, cwd) {
            Ok(Some(index)) => (candidates[index].0.clone(), candidates[index].1.clone()),
            Ok(None) => return "[squircle] No app agent works in this folder.".into(),
            Err(tied) => {
                return format!(
                    "[squircle] Several app agents work in this folder ({}); worker commands need the right thread ID.",
                    tied.iter()
                        .map(|i| candidates[*i].1.as_str())
                        .collect::<Vec<_>>()
                        .join(", ")
                );
            }
        };
        // Claude keeps a resumed session's first system prompt; a restarted
        // agent gets the current one here, once.
        let refreshed = if agent.lifecycle == (Lifecycle::Ready { refresh: true }) {
            let project = agent.project_id.clone();
            let cleared = self
                .change_if(move |registry| {
                    let agent = registry
                        .agents
                        .get_mut(&project)
                        .filter(|a| a.lifecycle == Lifecycle::Ready { refresh: true })?;
                    agent.lifecycle = Lifecycle::Ready { refresh: false };
                    Some(())
                })
                .await;
            // Unsaved, the next turn gets the instructions again.
            if let Err(error) = cleared {
                eprintln!("Agent state not saved: {error:#}");
            }
            std::fs::read_to_string(self.root.join("plugin/squircle/agents/app-agent.md")).ok()
                .and_then(|t| t.splitn(3, "---\n").nth(2).map(|body| format!(
                    "\n[squircle] You were restarted. Your instructions are now the following; they replace any earlier version:\n{}", body.trim())))
                .unwrap_or_default()
        } else {
            String::new()
        };
        let workers = self.workers(Some(&agent.thread_id));
        let (running, asked) = self.now(&agent, &workers, builds);
        let running = if running.is_empty() {
            " nothing".to_string()
        } else {
            running
        };
        let asked = if asked.is_empty() {
            String::new()
        } else {
            format!("\nYour questions waiting on the user:{asked}")
        };
        let unheard = match self.unheard(&agent.thread_id).await {
            Ok(unheard) => super::demands::listed(&unheard).map(|list| format!(
                "\nThe user's messages not in the tracker yet; record each demand in them (`task sub add ITEM --thread {id} --title ... --ask` in their words, \
                 corrections and details like \"from bottom\" included) or run `task heard --thread {id}` if they ask for nothing, \
                 before anything else: thread spawn, send and answer refuse until then:{list}",
                id = agent.thread_id,
            )),
            Err(_) => None,
        }
        .unwrap_or_default();
        let notes = match crate::notes::load(&self.root, &agent.project_id) {
            Ok(notes) if notes.notes.is_empty() => {
                " none yet; add the user's preferences, decisions and gotchas as you learn them"
                    .to_string()
            }
            Ok(notes) => notes
                .notes
                .iter()
                .map(|n| format!("\n- {}", n.text))
                .collect(),
            Err(error) => format!(" unreadable ({error:#})"),
        };
        format!(
            "[squircle] You are {app}'s app agent: you coordinate, and worker threads do the implementation \
             (`{cli} thread --help`), unless the user says otherwise.\n\
             Replies are a quick iMessage exchange: usually 1-3 short sentences of plain prose on what changed for the user and what's next. \
             No bullets, headings, bold lead-ins, lists of fixes, recaps of worker reports or process narration; details stay in the worker threads. \
             One picture ![..](/absolute/path) or clip [..](/absolute/path) only if it proves the point, copied out of /tmp into ~/.t3/userdata/attachments. \
             Builds started with `build start --thread {id}` appear in the chat by themselves with Install or why they failed: don't promise otherwise or paste build IDs. \
             No bare paths, IDs, branch names, commit hashes or Squircle internals unless asked.\n\
             Every piece of delegated work, reviews and research included, \
             runs as a T3 worker via `thread spawn` (`--provider codex --model <slug> --effort <level>` for Codex), never by running the codex \
             or claude CLIs yourself or through subagents or workflows, so the user can see it; the one subagent is `squircle:history`, \
             cheap and read-only: ask it, in the foreground, before answering anything about past work or decisions. Archive a worker once its work is merged or abandoned, \
             so no branches or worktrees are left behind. Your thread id: {id}. Running now (`thread status` lists all your workers):{running}{asked}{unheard}\n\
             Your notes (`{cli} notes --help`; keep them current):{notes}\n\
             The tracker (`{cli} task --help`) isn't in this note: run `task list --thread {id}` whenever you need it, such as to file an ask under the right work item, \
             to pick up open work or before briefing a worker (`task show ID` for one in full). \
             Before any work on something the user asks, put it in the tracker in their words: a sub-task (`task sub add ITEM`) of the work item it clearly belongs to, \
             otherwise a new work item (`task add`); never under an unrelated one. Give each a title (`--title`): a few words in sentence case naming it, \
             as the phone lists it (\"App agents reply briefly\", not their sentence); the ask stays their words verbatim, never paraphrased. \
             Name an untitled one with `task update ID --title` when you next touch it. Track your own breakdown as sub-tasks; link workers (`thread spawn --task`) \
             and builds (`build start --task`) to the sub-task or item they serve, attach screenshots or clips worth seeing, and set status and note when that changes \
             (in progress shows only while a linked worker or build runs and can't be set; an item follows its sub-tasks). A worker's brief (`thread spawn --task`, `thread send`) ends with the user's current asks for its work item \
             from the tracker, so a correction you don't record never reaches it. When the user corrects or adds to work in progress, mark the asks it \
             replaces (`task update ID --replaced-by NEW`) and send the worker the whole current spec, not just the new piece; after many revisions, \
             prefer a fresh worker briefed from the clean spec. \
             Ask the user anything (a choice, a review, a go-ahead) only with `task ask ITEM --thread {id} --question \"...\" [--option \"...\"] [--file PATH]` (the screenshot or clip it is about rides on the card; never describe one instead), \
             never as a question in your reply: it waits on their phone with everything else waiting on them (the `?` lines in this note), and the answer \
             arrives as an [answer] message; end your turn after asking unless other work needs no answer. Workers' own questions and approvals \
             reach the user directly in the same place; you are told when one is answered; never relay or repeat them. Never tell the user something works or is done until you or a worker \
             has looked at it (screenshots or a recording) against every one of its asks; say what is still wrong. Don't promise check-ins at times: \
             you can't keep time, [worker update]s wake you.{refreshed}",
            cli = self.cli(),
            id = agent.thread_id,
        )
    }
}
