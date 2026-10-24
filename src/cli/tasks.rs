use super::*;

#[derive(Subcommand)]
pub(super) enum TaskCommand {
    /// Record a new work item: an ask in the user's words, before any work on it; it starts queued unless you say otherwise.
    Add {
        #[arg(long, help = "Your thread ID (the app is taken from it)")]
        thread: Option<String>,
        #[arg(long, help = "T3 project ID instead of a thread")]
        project: Option<String>,
        #[arg(
            long,
            help = "What the user asked for, in their words, trimmed to a line"
        )]
        ask: String,
        #[arg(long, value_enum)]
        status: Option<squircle::tasks::Status>,
        #[arg(long, help = "What it waits on, in a few words")]
        note: Option<String>,
    },
    /// Change a task's status, note or wording.
    Update {
        id: String,
        #[arg(long, value_enum)]
        status: Option<squircle::tasks::Status>,
        #[arg(long, help = "What it waits on or what happened, in a few words")]
        note: Option<String>,
        #[arg(long)]
        ask: Option<String>,
        #[arg(long, help = "Put it first in its group")]
        top: bool,
        #[arg(
            long,
            value_name = "ITEM_ID|none",
            help = "Move it under this work item, or with none make it a work item of its own"
        )]
        under: Option<String>,
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
    /// Attach a screenshot or clip (png, jpg, mp4, mov, m4v); the phone shows it on the task.
    Attach {
        id: String,
        #[arg(long)]
        file: PathBuf,
        #[arg(long, help = "One line saying what it shows")]
        caption: Option<String>,
    },
    /// The app's work items with their sub-tasks, open ones only; --all adds closed ones and History, newest first, a page at a time.
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
    },
    /// One task (a work item with its sub-tasks) with linked threads, builds, media and history.
    Show { id: String },
}

#[derive(Subcommand)]
pub(super) enum SubCommand {
    /// Add a sub-task to a work item; update, link, attach and show take its ID like any task's.
    Add {
        /// The work item's ID.
        item: String,
        #[arg(long, help = "What it is, in the user's words when it is their ask")]
        ask: String,
        #[arg(long, value_enum)]
        status: Option<squircle::tasks::Status>,
        #[arg(long, help = "What it waits on, in a few words")]
        note: Option<String>,
        #[arg(long, help = "Your thread ID, to record the message it came from")]
        thread: Option<String>,
    },
}

pub(super) async fn run(cli: &Cli, command: &TaskCommand) -> Result<Option<Value>> {
    let data =
        match command {
            TaskCommand::Add {
                thread,
                project,
                ask,
                status,
                note,
            } => post(
                cli,
                "/v1/tasks",
                json!({"thread":thread,"project":project,"ask":ask,"status":status,"note":note}),
            )
            .await?,
            TaskCommand::Update {
                id,
                status,
                note,
                ask,
                top,
                under,
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
                    Some(json!({"status":status,"note":note,"ask":ask,"to_top":top,"parent":parent})),
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
                        ask,
                        status,
                        note,
                        thread,
                    },
            } => {
                post(
                    cli,
                    "/v1/tasks",
                    json!({"parent":task_id(item)?,"thread":thread,"ask":ask,"status":status,"note":note}),
                )
                .await?
            }
            TaskCommand::Show { id } => get(cli, &format!("/v1/tasks/{}", task_id(id)?)).await?,
            TaskCommand::List {
                thread,
                project,
                all,
                history_before,
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
                        let open = |t: &Value| !matches!(t["status"].as_str(), Some("done" | "dropped"));
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
                value
            }
        };
    Ok(Some(data))
}
