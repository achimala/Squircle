use super::*;

#[derive(Parser)]
#[command(
    name = "squircle",
    version,
    about = "iOS builds, install links, and diagnostics for any agent",
    disable_help_subcommand = true,
    after_help = "Start here: squircle help workflow\nDiscover: squircle capabilities --json\nNo agent runtime required. Tailscale and Apple signing remain user-managed."
)]
pub(super) struct Cli {
    #[arg(long, global = true, help = "Emit a versioned JSON result on stdout")]
    pub(super) json: bool,
    #[arg(
        long,
        global = true,
        env = "SQUIRCLE_DATA_DIR",
        help = "Private local state directory (default: platform application data/Squircle)"
    )]
    pub(super) data_dir: Option<PathBuf>,
    #[arg(
        long,
        global = true,
        env = "SQUIRCLE_SERVER",
        default_value = "http://127.0.0.1:8787",
        help = "Squircle service URL; no redirects followed"
    )]
    pub(super) server: String,
    #[command(subcommand)]
    pub(super) command: Commands,
}

#[derive(Subcommand)]
pub(super) enum Commands {
    /// Initialize local state and separate control/diagnostic credentials.
    Init,
    /// Run the local HTTP service in the foreground. Does not configure Tailscale.
    Serve {
        #[arg(long, default_value = "127.0.0.1:8787")]
        listen: SocketAddr,
        #[arg(
            long,
            help = "Externally reachable HTTPS origin for installation links; you configure HTTPS separately. Kept in the data directory's config.json: later starts without it use the last one"
        )]
        public_url: Option<String>,
        #[arg(
            long,
            help = "Append the service's output to this file (launchd's service: DATA_DIR/serve.log)"
        )]
        log: Option<PathBuf>,
    },
    /// Restart or stop the running service for this data directory.
    #[command(
        after_help = "install: runs the service as a launchd user agent (dev.squircle.service) so it starts at login and comes back after a crash; it takes over from the running service without ending its simulator sessions. Installed, restart is launchd's kickstart and stop lasts until service start or the next login.\nrestart: the running service hands its simulator sessions over (recordings keep going, T3's device sessions stay open) and the same command line starts again, picking up a binary rebuilt at the same path; returns once it answers. It builds nothing; its output goes to DATA_DIR/serve.log.\nstop: ends simulator sessions (recordings are filed) and exits.\nA plain SIGTERM to squircle serve is a restart's handover; SIGINT (Ctrl-C) is a stop."
    )]
    Service {
        #[command(subcommand)]
        command: ServiceCommand,
    },
    /// Inspect Mac build prerequisites without changing configuration.
    Doctor,
    /// List implemented operations, output schema, and important limits.
    Capabilities,
    /// Progressive help; use `help workflow` for the complete verification path.
    Help { topic: Option<String> },
    /// Explicitly reveal a credential for configuring trusted clients.
    Auth {
        #[command(subcommand)]
        command: AuthCommand,
    },
    /// Start, inspect, cancel, or import a build. Start returns a job ID, not a completed app.
    Build {
        #[command(subcommand)]
        command: BuildCommand,
    },
    /// Register apps, update their summary, and publish real screenshots after UI work.
    App {
        #[command(subcommand)]
        command: AppCommand,
    },
    /// Create an expiring installation link. This does not install or launch the app.
    InstallLink {
        build_id: String,
        #[arg(long, default_value_t = 3600)]
        ttl_seconds: u64,
    },
    /// Read persisted app logs with a cursor. Use build log for compiler output.
    Logs {
        build_id: String,
        #[arg(long, default_value_t = 0)]
        since: usize,
        #[arg(long, default_value_t = 100)]
        limit: usize,
    },
    /// Retrieve captured crash reports associated with a specific build.
    Crashes {
        build_id: String,
        #[arg(long, default_value_t = 0)]
        since: usize,
        #[arg(long, default_value_t = 20)]
        limit: usize,
    },
    /// Attempt local Apple-text crash symbolication using the selected Xcode and a dSYM.
    Symbolicate {
        #[arg(long, help = "Apple-text .crash report; JSON .ips is not supported")]
        report: PathBuf,
        #[arg(long, help = "Retained .dSYM bundle; Xcode matches its binary UUID")]
        dsym: PathBuf,
    },
    /// Performance recordings made in the app on the phone: summary with symbolicated hitches, plus the raw file.
    #[command(
        after_help = "The user records performance from the debug overlay's + menu (Record Performance) while using the app; the message links a .perf.json capture on this Mac.\n  squircle perf show PATH_OR_ID           frames that reached the screen, late frames by cause (CPU/GPU/drawable/pacing), every thread's CPU with stacks (app frames from the build's dSYM), GPU per frame and pass, per-second timeline\n  squircle --json perf show PATH_OR_ID    the same as structured JSON\n  squircle perf list                      recent captures\nScreen recordings from the same menu and videos the user attaches are .mp4 or .mov files in the same folder; look at their frames (e.g. ffmpeg -i FILE -vf fps=2 /tmp/f%03d.png)."
    )]
    Perf {
        #[command(subcommand)]
        command: PerfCommand,
    },
    /// Publish a recording or image into a T3 thread so Squircle shows it inline (this Mac's service only).
    #[command(
        after_help = "Writes this Mac's data directory directly, so it needs a --server on this Mac (the default) using that same --data-dir. Simulator sessions file their own recordings: squircle sim --help."
    )]
    Media {
        #[command(subcommand)]
        command: MediaCommand,
    },
    /// Use an iOS simulator so the user can watch: start records it, stop files the recording in your turn.
    #[command(
        after_help = "Start a session before you run, check or demo the app in a simulator:\n  squircle sim start --thread YOUR_T3_THREAD_ID [--device NAME_OR_UDID]\nIt opens the simulator for your thread, boots it, records its screen and names the simulator; call T3's device_open with that deviceId for the agent-device command to drive it. The user sees it live as a picture-in-picture on their phone and in your turn. When done: squircle sim stop --thread YOUR_T3_THREAD_ID; the recording appears in your turn. A session also stops when your turn ends."
    )]
    Sim {
        #[command(subcommand)]
        command: SimCommand,
    },
    /// Submit a JSON diagnostic fixture; useful for checking the phone-to-Mac contract.
    Diagnostics {
        #[command(subcommand)]
        command: DiagnosticCommand,
    },
    /// Pair this service with your T3 server (its own session, scoped to orchestration).
    T3 {
        #[command(subcommand)]
        command: T3Command,
    },
    /// One agent per app: set up T3's Squircle instance, start an app's agent, list agents.
    #[command(
        after_help = "The app agent is a T3 thread on T3's \"Squircle agent\" Claude instance, in the project's folder. It can run worker threads with `squircle thread`; the service wakes it when a worker finishes.\nOnce: squircle t3 connect, squircle agent setup. Then: squircle agent start --project T3_PROJECT_ID."
    )]
    Agent {
        #[command(subcommand)]
        command: AgentCommand,
    },
    /// Notifications and the Live Activity on the phone, sent from this Mac to Apple with your own APNs key.
    #[command(
        after_help = "Once: create an APNs auth key (Apple Developer > Keys > +, Apple Push Notifications service), then:\n  squircle push setup --key-file ~/Downloads/AuthKey_ABC123DEFG.p8 --key-id ABC123DEFG --team-id YOURTEAMID\nThe key is copied into the data directory (owner-only) and never printed. Open Squircle on the phone and allow notifications, then: squircle push test.\nThe phone is told when an app's agent replies or asks, a worker finishes, errors or needs input, and a device build succeeds or fails; nothing for the thread it is showing. Bursts arrive as one notification."
    )]
    Push {
        #[command(subcommand)]
        command: PushCommand,
    },
    /// The user's asks to an app's agent and where each stands; the phone shows them as Tasks.
    #[command(
        after_help = "Every ask goes in before any work on it: a work item (task add) for a new piece of work, or a sub-task (task sub add ITEM) of the work item it clearly belongs to; never under an unrelated one (move it with task update ID --under ITEM|none). Break your own work down into sub-tasks too. In the user's words. Status: queued, in_progress, needs_you, ready_to_try, done, dropped.\nLinked workers and builds move a task or sub-task on by themselves (a worker working → in_progress, waiting on a question → needs_you, a linked build succeeding → ready_to_try); a status you set holds until one of them changes.\nA work item with sub-tasks follows them whenever one changes status (any needs you → needs_you; any working, or some done and some queued → in_progress; all closed → ready_to_try, or done when the user closed the last); closing a work item closes its open sub-tasks. update, link, attach and show take a sub-task's ID too.\nDone and dropped work items move to History after a day, untouched open ones after three days, sub-tasks with them; any change brings one back.\n  squircle task add --thread YOUR_THREAD_ID --ask \"stack the sims and fan them out\"\n  squircle task sub add ITEM_ID --ask \"fan out on tap\"\n  squircle thread spawn ... --task TASK_ID      links the worker\n  squircle build start ... --task TASK_ID       links the build\n  squircle task update TASK_ID --status needs_you --note \"pick a layout\"\n  squircle task attach TASK_ID --file /abs/shot.png --caption \"New strip\"\n  squircle task list --thread YOUR_THREAD_ID"
    )]
    Task {
        #[command(subcommand)]
        command: TaskCommand,
    },
    /// Search an app's past where it lives (T3 conversations and tool activity, tasks, builds, git, docs); read-only, no copied store.
    #[command(
        after_help = "Results are short ranked snippets with a reference; show expands one.\n  squircle history search \"why did we drop the 3D tilt\" --thread YOUR_THREAD_ID\n  squircle history search simulator deck --in messages,commits --since 14d\n  squircle history show msg:ID | thread:ID | act:ID | task:ID | build:ID | commit:SHA | doc:PATH#L12\nThe app is the project of --thread or --project, else of the current folder. Text unless --json. Nothing is indexed: each search reads T3's statev2.sqlite (read-only), Squircle's tasks and builds, git log and the project's Markdown files."
    )]
    History {
        #[command(subcommand)]
        command: HistoryCommand,
    },
    /// The app agent's durable notes (preferences, decisions, gotchas), shown in each turn's note.
    #[command(
        after_help = "Keep a few lines worth knowing every turn, not a log: what happened stays searchable with squircle history.\n  squircle notes show --thread YOUR_THREAD_ID\n  squircle notes add --thread YOUR_THREAD_ID \"User wants builds only on request\"\n  squircle notes edit 2 --thread YOUR_THREAD_ID \"...\"\n  squircle notes remove 2 --thread YOUR_THREAD_ID\nA note is at most 300 characters, all of them at most 4000."
    )]
    Notes {
        #[command(subcommand)]
        command: NotesCommand,
    },
    /// Worker threads of an app agent: spawn, message, read, answer, archive.
    #[command(
        after_help = "Workers are ordinary T3 threads, each in its own worktree on a new branch. Do not poll: the app agent receives a [worker update] message when a worker finishes, errors or needs input."
    )]
    Thread {
        #[command(subcommand)]
        command: ThreadCommand,
    },
}
