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
    /// Re-encode existing recordings light: full-resolution HEVC at constant quality, every frame kept.
    #[command(
        after_help = "Each filed video (threads' and tasks' media) not yet light is re-encoded with VideoToolbox HEVC, then replaces the original under the same name only once it decodes with the same frames and duration and is smaller. Already-light and small (<2 MB) files are skipped; a file the service is re-encoding is skipped. New recordings are made light by the service as they are filed.\n  --dry-run    count what would be done and estimate the savings (encodes nothing)\n  --orphans    also recover recordings older versions left unfiled (over the old 512 MB cap): make them light, file them into their threads, delete avconvert's leftovers. Recordings of a session still running are never touched.\n  --orphans=delete    instead delete those recordings with their posters, avconvert's leftovers and logs, and nothing else (encodes nothing; with --dry-run, lists each file and its size). Sessions still recording and files a shrink is working on are never touched.\n  --limit N    encode at most N movies (largest first)\nNeeds Homebrew's ffmpeg (or SQUIRCLE_FFMPEG). Progress goes to stderr."
    )]
    Shrink {
        #[arg(long)]
        dry_run: bool,
        #[arg(long, value_enum, num_args = 0..=1, default_missing_value = "recover")]
        orphans: Option<Orphans>,
        #[arg(long)]
        limit: Option<usize>,
    },
}

#[derive(Clone, Copy, PartialEq, ValueEnum)]
pub(super) enum Orphans {
    Recover,
    Delete,
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
            MediaCommand::Shrink {
                dry_run,
                orphans,
                limit,
            } => {
                use squircle::recordings;
                if *orphans == Some(Orphans::Delete) {
                    return Ok(Some(success(recordings::delete_orphans(&root, *dry_run))));
                }
                let tools = recordings::Tools::find()?;
                let plan = recordings::plan(&tools, &root).await?;
                let summary = recordings::summary(&plan);
                if *dry_run {
                    success(json!({"dry_run": true, "plan": summary}))
                } else {
                    let result =
                        recordings::migrate(&tools, &root, plan, orphans.is_some(), *limit).await;
                    success(json!({"plan": summary, "result": result}))
                }
            }
        }
    };
    Ok(Some(data))
}
