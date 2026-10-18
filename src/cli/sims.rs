use super::*;

#[derive(Subcommand)]
pub(super) enum SimCommand {
    /// Open, boot and start recording a simulator for your thread; returns the agent-device command to drive it.
    #[command(
        after_help = "Idempotent: starting again on the same simulator returns the running session. Without --device: the simulator this thread used last, else a booted one of Squircle's that nothing holds, else a shut-down one (never a simulator the user or another agent has booted). At most SQUIRCLE_MAX_SIMULATORS sessions (default 3) run at once; past that, start puts your thread in line (first come, first served) and returns status \"queued\" with your position: end your turn, and Squircle wakes your thread with a [simulator ready] message once one is held for you; run start again then. sim stop leaves the line. Stopping (or the turn ending) shuts the simulator down. Use this for every simulator: don't boot or create simulators with simctl or xcodebuild."
    )]
    Start {
        #[arg(long, help = "Your T3 thread ID")]
        thread: String,
        #[arg(long, help = "Simulator name or UDID (squircle sim devices)")]
        device: Option<String>,
    },
    /// Stop your thread's session (the recording is added to your current turn), or leave the line for one.
    Stop {
        #[arg(long, help = "Your T3 thread ID")]
        thread: Option<String>,
        #[arg(long, help = "A session ID instead of a thread")]
        id: Option<String>,
    },
    /// Every booted simulator with its owner (a session's thread, a T3 device session, or unowned), running sessions, the line waiting for one, and recent recordings.
    Status {
        #[arg(long)]
        thread: Option<String>,
    },
    /// This Mac's iOS simulators and which thread is recording each.
    Devices,
    /// Shut down simulators Squircle or its agents booted that nothing holds, and delete agent-created ones unused for a day.
    #[command(
        after_help = "Only simulators Squircle leased (sim start) or an agent's own simctl/xcodebuild command created or booted are touched; never one the user booted, one open in T3's device tools for the user or a working thread, the preview simulator (SQUIRCLE_SIMULATOR_ID), or one in a session. The service applies the same policy every minute, shutting a free simulator down after SQUIRCLE_SIM_IDLE_MINUTES (default 10); cleanup skips that wait. At most SQUIRCLE_MAX_SIMULATORS sessions (default 3) run at once."
    )]
    Cleanup {
        #[arg(
            long,
            help = "Report what would be shut down or deleted; change nothing"
        )]
        dry_run: bool,
    },
}

pub(super) async fn run(cli: &Cli, command: &SimCommand) -> Result<Option<Value>> {
    let data = match command {
        SimCommand::Start { thread, device } => {
            post(
                cli,
                "/v1/sims",
                json!({"thread_id":thread_id(thread)?,"device":device}),
            )
            .await?
        }
        SimCommand::Stop { thread, id } => {
            if thread.is_none() && id.is_none() {
                bail!("Pass --thread (your T3 thread ID) or --id");
            }
            post(cli, "/v1/sims/stop", json!({"thread_id":thread,"id":id})).await?
        }
        SimCommand::Status { thread } => {
            let query = url::form_urlencoded::Serializer::new(String::new())
                .append_pair("simulators", "true")
                .extend_pairs(thread.as_ref().map(|t| ("thread", t)))
                .finish();
            get(cli, &format!("/v1/sims?{query}")).await?
        }
        SimCommand::Devices => get(cli, "/v1/sims/devices").await?,
        SimCommand::Cleanup { dry_run } => {
            post(cli, "/v1/sims/cleanup", json!({"dry_run": dry_run})).await?
        }
    };
    Ok(Some(data))
}
