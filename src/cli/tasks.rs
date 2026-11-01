use super::*;

#[derive(Subcommand)]
pub(super) enum TaskCommand {
    /// Record a new work item: an ask in the user's words, before any work on it; it starts queued unless you say otherwise.
    Add {
        #[arg(
            long,
            help = "Your thread ID (the app is taken from it, and the message it came from is recorded)"
        )]
        thread: Option<String>,
        #[arg(long, help = "T3 project ID instead of a thread")]
        project: Option<String>,
        #[arg(
            long,
            help = "A short name for it: a few words, sentence case (\"App agents reply briefly\"); the phone lists it by this"
        )]
        title: String,
        #[arg(
            long,
            help = "What the user asked for, verbatim in their words (kept as the record and shown under the title)"
        )]
        ask: String,
        #[arg(long, value_enum)]
        status: Option<squircle::tasks::Status>,
        #[arg(long, help = "What it waits on, in a few words")]
        note: Option<String>,
        #[arg(
            long,
            value_delimiter = ',',
            value_name = "ID[,ID]",
            help = "Earlier asks this one replaces: they are dropped as replaced and stop reaching workers"
        )]
        replaces: Vec<String>,
    },
    /// Change a task's status, note, title or wording.
    Update {
        id: String,
        #[arg(long, help = "A new short name: a few words, sentence case")]
        title: Option<String>,
        #[arg(long, value_enum)]
        status: Option<squircle::tasks::Status>,
        #[arg(long, help = "What it waits on or what happened, in a few words")]
        note: Option<String>,
        #[arg(long, help = "The user's words, if they were recorded wrong")]
        ask: Option<String>,
        #[arg(
            long,
            value_name = "ITEM_ID|none",
            help = "Move it under this work item, or with none make it a work item of its own"
        )]
        under: Option<String>,
        #[arg(
            long,
            value_name = "ID",
            help = "A later ask replaces this one: it is dropped as replaced and stops reaching workers"
        )]
        replaced_by: Option<String>,
    },
    /// Sub-tasks: the small items under a work item (an ask that belongs to it, or your own breakdown).
    Sub {
        #[command(subcommand)]
        command: SubCommand,
    },
    /// Link (or with --remove unlink) a worker thread or a build.
    Link {
        id: String,
        #[arg(long)]
        thread: Option<String>,
        #[arg(long)]
        build: Option<String>,
        #[arg(long)]
        remove: bool,
    },
    /// Attach a screenshot or clip (png, jpg, mp4, mov, m4v), or a document (pdf, md, txt, json, csv); the phone shows it on the task and opens documents in a viewer.
    Attach {
        id: String,
        #[arg(long)]
        file: PathBuf,
        #[arg(long, help = "One line saying what it shows")]
        caption: Option<String>,
    },
    /// The app's work items with their sub-tasks, open ones only, in brief: ID, title, status, note, open questions, and the ask for untitled ones (task show or --full has the rest); --all adds closed ones and History, newest first, a page at a time.
    List {
        #[arg(long, help = "Your thread ID (the app is taken from it)")]
        thread: Option<String>,
        #[arg(long, help = "T3 project ID instead of a thread")]
        project: Option<String>,
        #[arg(long)]
        all: bool,
        #[arg(
            long,
            requires = "all",
            help = "With --all: the next History page, from a reply's history_next"
        )]
        history_before: Option<String>,
        #[arg(long, help = "Include every task's ask in the user's words")]
        asks: bool,
        #[arg(
            long,
            help = "Whole records as the phone gets them (linked work, media, questions, history)"
        )]
        full: bool,
    },
    /// Ask the user a question about a work item or sub-task, instead of asking in chat: it waits on their phone with everything else waiting on them (and notifies them), the task shows needs you until it is answered or withdrawn (the only way a task needs the user), and the answer comes back to you as an [answer] message. Attach the screenshot or clip it is about with --file rather than describing it or pointing at the task's media: the user sees only what the question carries. End your turn after asking unless other work needs no answer.
    Ask {
        /// The work item or sub-task it is about.
        id: String,
        #[arg(long, help = "Your thread ID; the answer is sent there")]
        thread: String,
        #[arg(long, help = "The question, short and self-contained")]
        question: String,
        #[arg(
            long = "option",
            value_name = "CHOICE",
            help = "A choice to offer as a button (repeat, up to 6); the user can always type their own"
        )]
        options: Vec<String>,
        #[arg(
            long = "file",
            value_name = "PATH",
            help = "A screenshot or clip (png, jpg, mp4, mov, m4v) or document (pdf, md, txt, json, csv) the question is about, shown on the question card (repeat for several)"
        )]
        files: Vec<PathBuf>,
    },
    /// Take back a question (from task ask) that no longer matters.
    Withdraw {
        /// The question's ID, from task ask or task show.
        question: String,
    },
    /// One task (a work item with its sub-tasks) with linked threads, builds, media, questions and history.
    Show { id: String },
    /// Mark the user's messages so far as asking for nothing to track (a thanks, a question you answered). Until each of their messages is recorded (task add / sub add --thread) or marked, thread spawn, send and answer refuse.
    Heard {
        #[arg(long, help = "Your (the app agent's) thread ID")]
        thread: String,
    },
}

#[derive(Subcommand)]
pub(super) enum SubCommand {
    /// Add a sub-task to a work item; update, link, attach and show take its ID like any task's.
    Add {
        /// The work item's ID.
        item: String,
        #[arg(
            long,
            help = "A short name for it: a few words, sentence case (\"App agents reply briefly\"); the phone lists it by this"
        )]
        title: String,
        #[arg(
            long,
            help = "What it is: the user's words verbatim when it is their ask, else yours"
        )]
        ask: String,
        #[arg(long, value_enum)]
        status: Option<squircle::tasks::Status>,
        #[arg(long, help = "What it waits on, in a few words")]
        note: Option<String>,
        #[arg(
            long,
            help = "Your thread ID, to record the message it came from (an app agent's unrecorded messages block spawn and send)"
        )]
        thread: Option<String>,
        #[arg(
            long,
            value_delimiter = ',',
            value_name = "ID[,ID]",
            help = "Earlier asks this one replaces: they are dropped as replaced and stop reaching workers"
        )]
        replaces: Vec<String>,
    },
}

fn task_ids(ids: &[String]) -> Result<Vec<&str>> {
    ids.iter().map(|id| task_id(id)).collect()
}

pub(super) async fn run(cli: &Cli, command: &TaskCommand) -> Result<Option<Value>> {
    let data = match command {
        TaskCommand::Add {
            thread,
            project,
            title,
            ask,
            status,
            note,
            replaces,
        } => {
            post(
                cli,
                "/v1/tasks",
                json!({"thread":thread,"project":project,"title":title,"ask":ask,"status":status,"note":note,"replaces":task_ids(replaces)?}),
            )
            .await?
        }
        TaskCommand::Update {
            id,
            title,
            status,
            note,
            ask,
            under,
            replaced_by,
        } => {
            let parent = match under.as_deref() {
                Some("none") => Some(String::new()),
                Some(item) => Some(task_id(item)?.to_string()),
                None => None,
            };
            request(
                cli,
                reqwest::Method::PATCH,
                &format!("/v1/tasks/{}", task_id(id)?),
                Some(json!({"title":title,"status":status,"note":note,"ask":ask,"parent":parent,
                    "replaced_by":replaced_by.as_deref().map(task_id).transpose()?})),
                false,
            )
            .await?
        }
        TaskCommand::Link {
            id,
            thread,
            build,
            remove,
        } => {
            post(
                cli,
                &format!("/v1/tasks/{}/link", task_id(id)?),
                json!({"thread":thread,"build":build,"remove":remove}),
            )
            .await?
        }
        TaskCommand::Attach { id, file, caption } => {
            post(
                cli,
                &format!("/v1/tasks/{}/media", task_id(id)?),
                json!({"file":std::path::absolute(file)?,"caption":caption}),
            )
            .await?
        }
        TaskCommand::Sub {
            command:
                SubCommand::Add {
                    item,
                    title,
                    ask,
                    status,
                    note,
                    thread,
                    replaces,
                },
        } => post(
            cli,
            "/v1/tasks",
            json!({"parent":task_id(item)?,"thread":thread,"title":title,"ask":ask,"status":status,"note":note,"replaces":task_ids(replaces)?}),
        )
        .await?,
        TaskCommand::Show { id } => get(cli, &format!("/v1/tasks/{}", task_id(id)?)).await?,
        TaskCommand::Ask {
            id,
            thread,
            question,
            options,
            files,
        } => {
            let files = files
                .iter()
                .map(std::path::absolute)
                .collect::<std::io::Result<Vec<_>>>()?;
            post(
                cli,
                &format!("/v1/tasks/{}/questions", task_id(id)?),
                json!({"thread": thread, "question": question, "options": options, "files": files}),
            )
            .await?
        }
        TaskCommand::Withdraw { question } => {
            post(
                cli,
                &format!("/v1/questions/{}/withdraw", task_id(question)?),
                json!({}),
            )
            .await?
        }
        TaskCommand::Heard { thread } => {
            post(cli, "/v1/agents/heard", json!({"thread": thread})).await?
        }
        TaskCommand::List {
            thread,
            project,
            all,
            history_before,
            asks,
            full,
        } => {
            let query = url::form_urlencoded::Serializer::new(String::new())
                .extend_pairs(thread.as_ref().map(|t| ("thread", t.as_str())))
                .extend_pairs(project.as_ref().map(|p| ("project", p.as_str())))
                .extend_pairs(
                    history_before
                        .as_ref()
                        .map(|c| ("history_before", c.as_str())),
                )
                // Without --all History is dropped anyway; don't expand it.
                .extend_pairs((!*all).then_some(("history_limit", "1")))
                .finish();
            let mut value = get(cli, &format!("/v1/tasks?{query}")).await?;
            if !*all && value["ok"] == true {
                let data = &mut value["data"];
                if let Some(tasks) = data["tasks"].as_array_mut() {
                    let open =
                        |t: &Value| !matches!(t["status"].as_str(), Some("done" | "dropped"));
                    tasks.retain(open);
                    for task in tasks.iter_mut() {
                        if let Some(subtasks) = task["subtasks"].as_array_mut() {
                            subtasks.retain(open);
                        }
                    }
                }
                if let Some(object) = data.as_object_mut() {
                    object.remove("history");
                    object.remove("history_next");
                }
            }
            if value["ok"] == true && !*full {
                for list in ["tasks", "history"] {
                    if let Some(tasks) = value["data"].get_mut(list).and_then(Value::as_array_mut) {
                        tasks.iter_mut().for_each(|t| *t = brief(t, *asks));
                    }
                }
            }
            value
        }
    };
    Ok(Some(data))
}

/// A task as `task list` shows it: enough to find and file work, with the
/// ask only when it has no title or `--asks` wants it.
fn brief(task: &Value, asks: bool) -> Value {
    let mut out = json!({"id": task["id"], "title": task["title"], "status": task["status"]});
    if task["title"].as_str().is_none_or(str::is_empty) || asks {
        out["ask"] = task["ask"].clone();
    }
    if task["note"].as_str().is_some_and(|n| !n.is_empty()) {
        out["note"] = task["note"].clone();
    }
    let questions: Vec<Value> = task["questions"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|q| q["state"]["kind"] == "open")
        .map(|q| json!({"id": q["id"], "question": q["text"]}))
        .collect();
    if !questions.is_empty() {
        out["open_questions"] = json!(questions);
    }
    if let Some(subtasks) = task["subtasks"].as_array().filter(|s| !s.is_empty()) {
        out["subtasks"] = subtasks.iter().map(|s| brief(s, asks)).collect();
    }
    out
}
