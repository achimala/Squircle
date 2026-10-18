use super::*;

#[derive(Subcommand)]
pub(super) enum PerfCommand {
    /// Summarize a capture: hitches with symbolicated main-thread stacks, heaviest functions, timeline. Text unless --json.
    Show {
        #[arg(help = "Capture path (from the message) or ID (perf list)")]
        capture: String,
        #[arg(
            long,
            help = "A .dSYM bundle or binary for the app, when Squircle's builds and Spotlight don't have it"
        )]
        dsym: Vec<PathBuf>,
    },
    /// Recent performance captures and screen recordings uploaded from the phone.
    List,
}

#[derive(Subcommand)]
pub(super) enum MediaCommand {
    /// Copy an mp4/mov/png/jpg into the thread's media; the phone shows it in the conversation.
    #[command(
        after_help = "To show a simulator flow, use squircle sim start / sim stop instead: the session records itself and the recording appears in your turn."
    )]
    Add {
        #[arg(long, help = "T3 thread ID shown in the agent's instructions")]
        thread: String,
        #[arg(long)]
        file: PathBuf,
        #[arg(long, help = "One line saying what the clip shows")]
        caption: Option<String>,
    },
    /// List media published into a thread.
    List {
        #[arg(long)]
        thread: String,
    },
}

pub(super) async fn perf(cli: &Cli, command: &PerfCommand) -> Result<Option<Value>> {
    let data = {
        let root = root(cli)?;
        match command {
            PerfCommand::Show { capture, dsym } => {
                let (text, data) = squircle::perf::show(&root, capture, dsym).await?;
                if !cli.json {
                    print!("{text}");
                    return Ok(None);
                }
                success(data)
            }
            PerfCommand::List => success(json!({"captures": squircle::perf::list(&root)?})),
        }
    };
    Ok(Some(data))
}

pub(super) async fn media(cli: &Cli, command: &MediaCommand) -> Result<Option<Value>> {
    let data = {
        let root = root(cli)?;
        ensure!(
            local_server(&cli.server),
            "media writes this Mac's data directory and cannot publish to {}; run it on the service's Mac with its --data-dir",
            cli.server
        );
        match command {
            MediaCommand::Add {
                thread,
                file,
                caption,
            } => {
                let media = squircle::media::add(&root, thread, file, caption.as_deref())?;
                success(
                    json!({"id":media.id,"thread_id":media.thread_id,"kind":media.kind,"caption":media.caption,"bytes":media.bytes,"next":"The clip appears in the thread on the phone within a few seconds."}),
                )
            }
            MediaCommand::List { thread } => {
                success(json!({"media":squircle::media::list(&root, thread)?}))
            }
        }
    };
    Ok(Some(data))
}
