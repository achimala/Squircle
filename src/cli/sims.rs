use super::*;

#[derive(Subcommand)]
pub(super) enum SimCommand {
    /// Open, boot and start recording a simulator for your thread; then T3's device_open on it gives the agent-device command to drive it.
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
    /// Shut down simulators Squircle or its agents booted that nothing holds, and delete stale ones (see prune).
    #[command(
        after_help = "Only simulators Squircle leased (sim start) or an agent's own simctl/xcodebuild command created or booted are touched; never one the user booted, one open in T3's device tools for the user or a working thread, the preview simulator (SQUIRCLE_SIMULATOR_ID), or one in a session. The service applies the same policy every minute, shutting a free simulator down after SQUIRCLE_SIM_IDLE_MINUTES (default 10), and one of Squircle's that only a working thread's T3 device session keeps booted once unused for SQUIRCLE_SIM_HOLD_IDLE_MINUTES (default 30); cleanup skips the first wait. It also stops any simulator app above 90% of a core for 20 minutes straight, and refuses starts while the Mac's simulator host is failing. At most SQUIRCLE_MAX_SIMULATORS sessions (default 3) run at once."
    )]
    Cleanup {
        #[arg(
            long,
            help = "Report what would be shut down or deleted; change nothing"
        )]
        dry_run: bool,
    },
    /// Delete simulators nobody has used for two weeks, whoever created them (and agent-created ones unused for a day).
    #[command(
        after_help = "A shut-down simulator is stale once its last use (CoreSimulator's last boot, its device.plist's last write, or a Squircle session or agent command on it) is SQUIRCLE_SIM_STALE_DAYS old (default 14). Never a booted simulator, one in a session, one open in T3's device tools, the preview simulator, one an agent may still be using, or one on the keep list (squircle sim keep). The service applies this every minute; prune runs it now. --dry-run lists what would go and the space it frees."
    )]
    Prune {
        #[arg(
            long,
            help = "List what would be deleted and the space freed; delete nothing"
        )]
        dry_run: bool,
    },
    /// The simulators you keep: never deleted by prune or the service, by name or UDID.
    Keep {
        #[command(subcommand)]
        command: KeepCommand,
    },
}

#[derive(Subcommand)]
pub(super) enum KeepCommand {
    /// Keep a simulator (its exact name or UDID).
    Add { device: String },
    /// Stop keeping a simulator.
    Remove { device: String },
    /// List the simulators you keep.
    List,
}

pub(super) async fn run(cli: &Cli, command: &SimCommand) -> Result<Option<Value>> {
    let data = match command {
        SimCommand::Start { thread, device } => {
            post(cli, "/v1/sims", json!({"thread_id":thread,"device":device})).await?
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
        SimCommand::Prune { dry_run } => {
            post(cli, "/v1/sims/prune", json!({"dry_run": dry_run})).await?
        }
        SimCommand::Keep { command } => match command {
            KeepCommand::Add { device } => {
                post(cli, "/v1/sims/keep", json!({"add": [device]})).await?
            }
            KeepCommand::Remove { device } => {
                post(cli, "/v1/sims/keep", json!({"remove": [device]})).await?
            }
            KeepCommand::List => get(cli, "/v1/sims/keep").await?,
        },
    };
    Ok(Some(data))
}
