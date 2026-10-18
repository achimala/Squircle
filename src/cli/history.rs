use super::*;

#[derive(clap::Args)]
pub(super) struct AppScope {
    #[arg(long, help = "A thread of the app (yours); its T3 project is the app")]
    pub(super) thread: Option<String>,
    #[arg(long, help = "T3 project ID")]
    pub(super) project: Option<String>,
}

#[derive(Subcommand)]
pub(super) enum HistoryCommand {
    /// Ranked snippets matching the words, each with a reference for show.
    Search {
        #[arg(required = true, num_args = 1.., help = "Words to look for")]
        query: Vec<String>,
        #[command(flatten)]
        scope: AppScope,
        #[arg(
            long = "in",
            value_delimiter = ',',
            help = "Only these sources: messages, threads, activities, tasks, builds, commits, docs"
        )]
        sources: Vec<String>,
        #[arg(long, default_value_t = 8)]
        limit: usize,
        #[arg(long, help = "Only newer than 7d, 12h, 30m or YYYY-MM-DD")]
        since: Option<String>,
    },
    /// One item in full: a message with its neighbours, a thread's latest messages, an activity, task, build, commit or doc section.
    Show {
        #[arg(help = "msg:ID, thread:ID, act:ID, task:ID, build:ID, commit:SHA or doc:PATH#L12")]
        reference: String,
        #[command(flatten)]
        scope: AppScope,
        #[arg(long, default_value_t = 4000, help = "Cap on the text shown")]
        max_chars: usize,
        #[arg(
            long,
            default_value_t = 30,
            help = "Messages of a thread, changes of a task"
        )]
        limit: usize,
    },
}

#[derive(Subcommand)]
pub(super) enum NotesCommand {
    /// The app's notes, numbered.
    Show {
        #[command(flatten)]
        scope: AppScope,
    },
    /// Add one note.
    Add {
        text: String,
        #[command(flatten)]
        scope: AppScope,
    },
    /// Replace note N.
    Edit {
        number: usize,
        text: String,
        #[command(flatten)]
        scope: AppScope,
    },
    /// Remove note N.
    Remove {
        number: usize,
        #[command(flatten)]
        scope: AppScope,
    },
}

pub(super) async fn history(cli: &Cli, command: &HistoryCommand) -> Result<Option<Value>> {
    let data = {
        let root = root(cli)?;
        let cwd = std::env::current_dir()?;
        let resolve = |scope: &AppScope| {
            let (thread, project) = (scope.thread.clone(), scope.project.clone());
            let cwd = cwd.clone();
            async move { squircle::history::scope(thread.as_deref(), project.as_deref(), &cwd).await }
        };
        let (text, data) = match command {
            HistoryCommand::Search {
                query,
                scope,
                sources,
                limit,
                since,
            } => {
                let kinds = sources
                    .iter()
                    .map(|s| squircle::history::Kind::parse(s))
                    .collect::<Result<Vec<_>>>()?;
                let scope = resolve(scope).await?;
                squircle::history::search(
                    &root,
                    &scope,
                    squircle::history::Search {
                        query: &query.join(" "),
                        kinds,
                        limit: *limit,
                        since: since.as_deref(),
                    },
                )
                .await?
            }
            HistoryCommand::Show {
                reference,
                scope,
                max_chars,
                limit,
            } => {
                // Messages, threads, tasks and builds are found by ID alone.
                let needs_scope = reference.starts_with("commit:") || reference.starts_with("doc:");
                let scope = if needs_scope {
                    Some(resolve(scope).await?)
                } else {
                    None
                };
                squircle::history::show(&root, scope.as_ref(), reference, *max_chars, *limit)
                    .await?
            }
        };
        if !cli.json {
            print!("{text}");
            return Ok(None);
        }
        success(data)
    };
    Ok(Some(data))
}

pub(super) async fn notes(cli: &Cli, command: &NotesCommand) -> Result<Option<Value>> {
    let data = {
        let root = root(cli)?;
        ensure!(
            local_server(&cli.server),
            "notes live in this Mac's data directory; run it on the service's Mac with its --data-dir"
        );
        let cwd = std::env::current_dir()?;
        let scope = match command {
            NotesCommand::Show { scope }
            | NotesCommand::Add { scope, .. }
            | NotesCommand::Edit { scope, .. }
            | NotesCommand::Remove { scope, .. } => scope,
        };
        let app = squircle::history::scope(scope.thread.as_deref(), scope.project.as_deref(), &cwd)
            .await?;
        use squircle::notes::{Change, change, listing, load};
        let notes = match command {
            NotesCommand::Show { .. } => load(&root, &app.project_id)?,
            NotesCommand::Add { text, .. } => change(&root, &app.project_id, Change::Add(text))?,
            NotesCommand::Edit { number, text, .. } => {
                change(&root, &app.project_id, Change::Edit(*number, text))?
            }
            NotesCommand::Remove { number, .. } => {
                change(&root, &app.project_id, Change::Remove(*number))?
            }
        };
        if !cli.json {
            let list = listing(&notes);
            print!(
                "{}",
                if list.is_empty() {
                    format!("{} has no notes yet.\n", app.title)
                } else {
                    list
                }
            );
            return Ok(None);
        }
        success(json!({"app": app.title, "project_id": app.project_id, "notes": notes.notes}))
    };
    Ok(Some(data))
}
