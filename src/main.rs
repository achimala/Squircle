use anyhow::{Context, Result, bail};
use clap::{CommandFactory, Parser, Subcommand, ValueEnum};
use serde_json::{Value, json};
use squircle::{model::*, store::Store};
use std::{net::SocketAddr, path::PathBuf, process::Command, time::Duration};

#[derive(Parser)]
#[command(
    name = "squircle",
    version,
    about = "iOS builds, install links, and diagnostics for any agent",
    disable_help_subcommand = true,
    after_help = "Start here: squircle help workflow\nDiscover: squircle capabilities --json\nNo agent runtime required. Tailscale and Apple signing remain user-managed."
)]
struct Cli {
    #[arg(long, global = true, help = "Emit a versioned JSON result on stdout")]
    json: bool,
    #[arg(
        long,
        global = true,
        env = "SQUIRCLE_DATA_DIR",
        help = "Private local state directory (default: platform application data/Squircle)"
    )]
    data_dir: Option<PathBuf>,
    #[arg(
        long,
        global = true,
        env = "SQUIRCLE_SERVER",
        default_value = "http://127.0.0.1:8787",
        help = "Squircle service URL; no redirects followed"
    )]
    server: String,
    #[command(subcommand)]
    command: Commands,
}
#[derive(Subcommand)]
enum Commands {
    /// Initialize local state and separate control/diagnostic credentials.
    Init,
    /// Run the local HTTP service in the foreground. Does not configure Tailscale.
    #[command(
        after_help = "Set SQUIRCLE_SIMULATOR_ID to the UUID of a dedicated existing iPhone simulator to enable build previews. Captures install and freshly launch only the target app on that simulator."
    )]
    Serve {
        #[arg(long, default_value = "127.0.0.1:8787")]
        listen: SocketAddr,
        #[arg(
            long,
            help = "Externally reachable HTTPS origin for installation links; you configure HTTPS separately"
        )]
        public_url: Option<String>,
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
    /// Capture actual pixels from an app on a dedicated iOS simulator.
    Preview {
        #[command(subcommand)]
        command: PreviewCommand,
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
    #[command(after_help = "The user records performance from the debug overlay's + menu (Record Performance) while using the app; the message links a .perf.json capture on this Mac.\n  squircle perf show PATH_OR_ID           worst hitches with main-thread stacks (app frames from the build's dSYM), heaviest functions, per-second timeline, log\n  squircle --json perf show PATH_OR_ID    the same as structured JSON\n  squircle perf list                      recent captures\nScreen recordings from the same menu are .mp4 files in the same folder; look at their frames (e.g. ffmpeg -i FILE -vf fps=2 /tmp/f%03d.png).")]
    Perf {
        #[command(subcommand)]
        command: PerfCommand,
    },
    /// Publish a recording or image into a T3 thread so Squircle shows it inline.
    Media {
        #[command(subcommand)]
        command: MediaCommand,
    },
    /// Use an iOS simulator so the user can watch: start records it, stop files the recording in your turn.
    #[command(after_help = "Start a session before you run, check or demo the app in a simulator:\n  squircle sim start --thread YOUR_T3_THREAD_ID [--device NAME_OR_UDID]\nIt opens the simulator for your thread, boots it, records its screen and returns the agent-device command to drive it. The user sees it live as a picture-in-picture on their phone and in your turn. When done: squircle sim stop --thread YOUR_T3_THREAD_ID; the recording appears in your turn. A session also stops when your turn ends.")]
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
    #[command(after_help = "The app agent is a T3 thread on T3's \"Squircle agent\" Claude instance, in the project's folder. It can run worker threads with `squircle thread`; the service wakes it when a worker finishes.\nOnce: squircle t3 connect, squircle agent setup. Then: squircle agent start --project T3_PROJECT_ID.")]
    Agent {
        #[command(subcommand)]
        command: AgentCommand,
    },
    /// Worker threads of an app agent: spawn, message, read, answer, archive.
    #[command(after_help = "Workers are ordinary T3 threads, each in its own worktree on a new branch. Do not poll: the app agent receives a [worker update] message when a worker finishes, errors or needs input.")]
    Thread {
        #[command(subcommand)]
        command: ThreadCommand,
    },
}
#[derive(Subcommand)]
enum T3Command {
    /// Exchange a one-time T3 pairing token (read from stdin) for the service's own session.
    #[command(after_help = "Create the pairing token in T3 (pair a new client), then: pbpaste | squircle t3 connect --url http://127.0.0.1:3773. Restart squircle serve afterwards.")]
    Connect {
        #[arg(long, default_value = "http://127.0.0.1:3773")]
        url: String,
    },
    /// Whether the running service is connected to T3.
    Status,
}
#[derive(Subcommand)]
enum AgentCommand {
    /// Install the app-agent plugin and add T3's "Squircle agent" Claude instance (uses your existing Claude login).
    Setup {
        #[arg(long, help = "Remove the T3 instance instead")]
        remove: bool,
    },
    /// Start (or find) the app agent for a T3 project, optionally with a first message.
    Start {
        #[arg(long, help = "T3 project ID")]
        project: String,
        #[arg(long)]
        message: Option<String>,
        #[arg(long, help = "Claude model slug; default: the project's default or claude-opus-5-5")]
        model: Option<String>,
    },
    /// List app agents and the service's T3 connection.
    List,
    /// Relaunch the agent's Claude session on the same thread: its next message starts with the current instructions and the same history.
    #[command(after_help = "Happens now if the agent is between turns, otherwise when its current turn ends (an agent asking to restart itself just ends its turn).")]
    Restart {
        #[command(flatten)]
        target: AgentTarget,
    },
    /// Replace the agent with a new thread seeded by a short handoff; the old conversation stays readable and its workers move to the new agent.
    #[command(after_help = "The handoff has the app, recent commits, open workers, the user's recent messages, your last reply and your --handoff note. Happens now if the agent is between turns, otherwise when its current turn ends.")]
    Fresh {
        #[command(flatten)]
        target: AgentTarget,
        #[arg(long, help = "What the new agent must know that git and the workers don't show: what the user asked to remember, plans in flight")]
        handoff: Option<String>,
    },
    /// The note an app agent gets at the start of each turn (rules and live workers).
    Context {
        #[arg(long, help = "Read a Claude Code hook event on stdin and answer in hook JSON")]
        hook: bool,
        #[arg(long, help = "Worktree directory; default: current directory")]
        cwd: Option<PathBuf>,
    },
}
#[derive(clap::Args)]
#[group(required = true, multiple = false)]
struct AgentTarget {
    #[arg(long, help = "T3 project ID")]
    project: Option<String>,
    #[arg(long, help = "The app agent's thread ID")]
    thread: Option<String>,
}
#[derive(Subcommand)]
enum ThreadCommand {
    /// Start a worker thread in its own worktree. Its prompt must stand alone.
    Spawn {
        #[arg(long, help = "Your (the app agent's) thread ID")]
        coordinator: String,
        #[arg(long, help = "Short issue title the user will see")]
        title: String,
        #[arg(long, help = "New branch for the worker")]
        branch: String,
        #[arg(long, help = "Base branch; default: the project checkout's current branch")]
        base: Option<String>,
        #[arg(long)]
        prompt: String,
        #[arg(long, help = "Claude model slug; default: the app agent's model")]
        model: Option<String>,
    },
    /// Message a thread; folds into its turn if it is mid-turn.
    Send { id: String, text: String },
    /// Workers and their state: working, needs-you, done, error.
    Status {
        #[arg(long)]
        coordinator: Option<String>,
    },
    /// A thread's last reply, diff stat against its base, uncommitted files and pending question.
    Read { id: String },
    /// Answer every question in a thread's pending request with this text.
    Answer { id: String, text: String },
    /// Archive a worker once its branch is merged: removes its worktree and deletes its branch.
    #[command(after_help = "Refuses while the branch has commits not in its base, the worktree has uncommitted changes, or the worker is still working.")]
    Archive {
        id: String,
        #[arg(long, alias = "force", help = "Archive anyway, dropping unmerged commits and uncommitted changes")]
        discard: bool,
    },
    /// Archive your finished workers whose work is merged, delete their branches and worktrees, and list what is left and why.
    Cleanup {
        #[arg(long, help = "Your (the app agent's) thread ID")]
        coordinator: String,
        #[arg(long, help = "Only report what would be removed")]
        dry_run: bool,
    },
}
#[derive(Subcommand)]
enum SimCommand {
    /// Open, boot and start recording a simulator for your thread; returns the agent-device command to drive it.
    #[command(after_help = "Idempotent: starting again on the same simulator returns the running session. Without --device: the simulator this thread used last, else a booted one no other agent is using, else any free one.")]
    Start {
        #[arg(long, help = "Your T3 thread ID")]
        thread: String,
        #[arg(long, help = "Simulator name or UDID (squircle sim devices)")]
        device: Option<String>,
    },
    /// Stop your thread's session; the recording is added to your current turn.
    Stop {
        #[arg(long, help = "Your T3 thread ID")]
        thread: Option<String>,
        #[arg(long, help = "A session ID instead of a thread")]
        id: Option<String>,
    },
    /// Running sessions and recent recordings, optionally for one thread.
    Status {
        #[arg(long)]
        thread: Option<String>,
    },
    /// This Mac's iOS simulators and which thread is recording each.
    Devices,
}
#[derive(Subcommand)]
enum PerfCommand {
    /// Summarize a capture: hitches with symbolicated main-thread stacks, heaviest functions, timeline. Text unless --json.
    Show {
        #[arg(help = "Capture path (from the message) or ID (perf list)")]
        capture: String,
        #[arg(long, help = "A .dSYM bundle or binary for the app, when Squircle's builds and Spotlight don't have it")]
        dsym: Vec<PathBuf>,
    },
    /// Recent performance captures and screen recordings uploaded from the phone.
    List,
}
#[derive(Subcommand)]
enum MediaCommand {
    /// Copy an mp4/mov/png/jpg into the thread's media; the phone shows it in the conversation.
    #[command(after_help = "Record a simulator flow first, for example with T3's agent-device: record start /tmp/demo.mp4 --scope device … record stop.")]
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
#[derive(Subcommand)]
enum AuthCommand {
    Show {
        #[arg(long, value_enum, default_value = "diagnostics")]
        scope: Scope,
    },
}
#[derive(Clone, ValueEnum)]
enum Scope {
    Control,
    Diagnostics,
}
#[derive(Subcommand)]
enum BuildCommand {
    /// Archive/export a device IPA, or build an unsigned simulator app.
    Start {
        #[arg(long, help = "Absolute or relative .xcodeproj/.xcworkspace path")]
        project: PathBuf,
        #[arg(long)]
        scheme: String,
        #[arg(long, default_value = "Release")]
        configuration: String,
        #[arg(long, value_enum, default_value = "archive")]
        mode: Mode,
        #[arg(
            long,
            help = "ExportOptions.plist for a local device export; required in archive mode"
        )]
        export_options: Option<PathBuf>,
        #[arg(long, help = "Stable retry key; changing arguments requires a new key")]
        request_id: Option<String>,
        #[arg(
            long,
            help = "Explicitly allow Xcode to create/update signing assets through your configured Apple account"
        )]
        allow_provisioning_updates: bool,
        #[arg(
            long,
            help = "Capture simulator pixels after building; service needs SQUIRCLE_SIMULATOR_ID. Preview failure preserves the IPA."
        )]
        preview: bool,
        #[arg(
            long,
            help = "Leave out the Squircle debug overlay that device builds otherwise carry (never in App Store exports)"
        )]
        no_overlay: bool,
    },
    /// List persisted build records, newest first.
    List,
    /// Inspect a build and whether the app has acknowledged a launch.
    Status { build_id: String },
    /// Wait for completion; timeout does not cancel the build.
    Wait {
        build_id: String,
        #[arg(long, default_value_t = 60)]
        timeout: u64,
    },
    /// Request cancellation of a queued/running build.
    Cancel { build_id: String },
    /// Read a bounded compiler log chunk using byte offsets.
    Log {
        build_id: String,
        #[arg(long, default_value_t = 0)]
        offset: u64,
        #[arg(long, default_value_t = 32768)]
        limit: usize,
    },
    /// Copy an existing IPA into Squircle. Apple signature validity is not certified by import.
    Import {
        #[arg(long)]
        ipa: PathBuf,
    },
}
#[derive(Clone, ValueEnum)]
enum Mode {
    Archive,
    Simulator,
}
#[derive(Subcommand)]
enum DiagnosticCommand {
    Send {
        #[arg(long, help = "Path to one diagnostic event JSON file")]
        file: PathBuf,
    },
}

#[derive(Subcommand)]
enum PreviewCommand {
    /// Reuse this job's simulator app, or rebuild its current project source for an archive. Installs and launches only that app on the selected simulator.
    Capture {
        build_id: String,
        #[arg(
            long,
            help = "Dedicated simulator UUID; defaults to service SQUIRCLE_SIMULATOR_ID. Never selects 'booted'."
        )]
        simulator: Option<String>,
        #[arg(
            long,
            default_value_t = 1900,
            help = "Seconds to wait; timeout does not cancel capture"
        )]
        timeout: u64,
    },
}

#[derive(Subcommand)]
enum AppCommand {
    /// Browse one Mac directory (default: service user's home). Xcode packages are selectable, not traversed.
    Browse {
        #[arg(
            long,
            help = "Absolute Mac directory or ~/path; resolved by the service"
        )]
        path: Option<String>,
    },
    /// Read Xcode schemes and iPhoneOS signing settings without building. Package/setup issues remain actionable results.
    Inspect {
        #[arg(long)]
        project: String,
        #[arg(long)]
        scheme: Option<String>,
        #[arg(long)]
        configuration: Option<String>,
    },
    /// Add an existing iOS app and save its archive recipe, without starting a build or changing its Xcode project. Later builds allow Xcode provisioning updates through the configured account, but do not register devices. Signing may still need setup.
    Import {
        #[arg(long)]
        project: String,
        #[arg(long)]
        scheme: String,
        #[arg(long)]
        name: String,
        #[arg(long, default_value = "Release")]
        configuration: String,
    },
    /// Register an Xcode project/scheme identity. Repeated registration preserves edited name and summary.
    Register {
        #[arg(long)]
        project: PathBuf,
        #[arg(long)]
        scheme: String,
        #[arg(long)]
        name: String,
        #[arg(long)]
        bundle_id: Option<String>,
        #[arg(long, default_value = "")]
        summary: String,
    },
    /// List persistent app metadata and current preview versions.
    List,
    /// Read one app's metadata. Hermes still owns conversations.
    Show { app_id: String },
    /// Update app-facing metadata after implementation work.
    Update {
        app_id: String,
        #[arg(long)]
        name: Option<String>,
        #[arg(long)]
        summary: Option<String>,
    },
    /// Publish a real PNG screenshot from a path on the service's Mac. The service retains a private copy; no build is required.
    Preview {
        app_id: String,
        #[arg(long)]
        file: PathBuf,
        #[arg(long, default_value = "")]
        caption: String,
        #[arg(long, alias = "build-id")]
        build: Option<String>,
        #[arg(long)]
        source_revision: Option<String>,
    },
}

fn root(cli: &Cli) -> Result<PathBuf> {
    Ok(cli.data_dir.clone().unwrap_or(
        dirs::data_local_dir()
            .context("Cannot determine application data directory; pass --data-dir")?
            .join("Squircle"),
    ))
}

#[tokio::main]
async fn main() {
    let machine = std::env::args().any(|s| s == "--json");
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(error) => {
            if matches!(
                error.kind(),
                clap::error::ErrorKind::DisplayHelp | clap::error::ErrorKind::DisplayVersion
            ) {
                let _ = error.print();
                return;
            }
            if machine {
                println!(
                    "{}",
                    failure(
                        "invalid_arguments",
                        error.to_string(),
                        "Run squircle --help or squircle <command> --help."
                    )
                );
            } else {
                let _ = error.print();
            }
            std::process::exit(2);
        }
    };
    match run(&cli).await {
        Ok(Some(value)) => {
            let failed = value["ok"] == false;
            print_result(&value, cli.json);
            if failed {
                std::process::exit(2);
            }
        }
        Ok(None) => {}
        Err(error) => {
            print_result(
                &failure(
                    "operation_failed",
                    format!("{error:#}"),
                    "Run squircle doctor; ensure the service is running and inspect command help.",
                ),
                cli.json,
            );
            std::process::exit(2);
        }
    }
}
fn print_result(value: &Value, machine: bool) {
    if machine {
        println!("{}", value);
    } else {
        println!("{}", serde_json::to_string_pretty(value).unwrap());
    }
}

async fn request(
    cli: &Cli,
    method: reqwest::Method,
    path: &str,
    payload: Option<Value>,
    diagnostic: bool,
) -> Result<Value> {
    let store = Store::open(root(cli)?)?;
    let key = if diagnostic {
        store.settings.diagnostic_token
    } else {
        store.settings.control_token
    };
    let url = url::Url::parse(&cli.server)?;
    if !matches!(url.scheme(), "http" | "https")
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        bail!("Invalid service URL");
    }
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(60))
        .build()?;
    let mut request = client
        .request(
            method,
            format!("{}{}", cli.server.trim_end_matches('/'), path),
        )
        .bearer_auth(key);
    if let Some(payload) = payload {
        request = request.json(&payload);
    }
    let response = request
        .send()
        .await
        .context("Cannot reach Squircle service")?;
    let status = response.status();
    let value: Value = response
        .json()
        .await
        .context("Service did not return JSON")?;
    if value["schema_version"] != SCHEMA_VERSION || !value["ok"].is_boolean() {
        bail!("Unsupported server response schema (HTTP {status})");
    }
    Ok(value)
}
async fn get(cli: &Cli, path: &str) -> Result<Value> {
    request(cli, reqwest::Method::GET, path, None, false).await
}
async fn post(cli: &Cli, path: &str, payload: Value) -> Result<Value> {
    request(cli, reqwest::Method::POST, path, Some(payload), false).await
}
fn thread_id(id: &str) -> Result<&str> {
    uuid::Uuid::parse_str(id).context("Thread ID must be a UUID")?;
    Ok(id)
}
fn valid_id(id: &str) -> Result<&str> {
    uuid::Uuid::parse_str(id).context("Build ID must be a UUID")?;
    Ok(id)
}

async fn run(cli: &Cli) -> Result<Option<Value>> {
    let data = match &cli.command {
        Commands::Init => {
            let store = Store::open(root(cli)?)?;
            success(
                json!({"data_dir":store.root,"credentials_file":store.root.join("config.json"),"next":"squircle serve"}),
            )
        }
        Commands::Serve { listen, public_url } => {
            squircle::server::serve(root(cli)?, *listen, public_url.clone()).await?;
            return Ok(None);
        }
        Commands::Capabilities => success(
            json!({"name":"Squircle","version":env!("CARGO_PKG_VERSION"),"schema_version":SCHEMA_VERSION,"operations":["doctor","app.browse","app.inspect","app.import","app.register","app.list","app.show","app.update","app.preview","build.start","build.list","build.status","build.wait","build.cancel","build.log","build.import","preview.capture","install-link","media.add","media.list","sim.start","sim.stop","sim.status","sim.devices","t3.connect","t3.status","agent.setup","agent.start","agent.list","agent.restart","agent.fresh","agent.context","thread.spawn","thread.send","thread.status","thread.read","thread.answer","thread.archive","thread.cleanup","logs","crashes","symbolicate","diagnostics.send","perf.show","perf.list"],"build_modes":["archive","simulator"],"preview":{"build_opt_in":"capture_preview / build start --preview","default_simulator_env":"SQUIRCLE_SIMULATOR_ID","download":"GET /v1/builds/{id}/preview; control bearer; image/png","source":"simulator jobs reuse their product; archive previews rebuild current working tree, not a frozen source snapshot"},"max_concurrent_builds":1,"max_queued_or_running_builds":16,"diagnostic_event_max_bytes":1048576,"diagnostics_storage_max_bytes_per_build":67108864,"requires_local_http_service":true,"manages_tailscale":false,"remote_launch":false,"lldb":false,"crash_symbolication":"local Xcode symbolicatecrash; Apple-text reports; frame resolution must be checked","cellular_install_verified":false,"app_agents":{"instance":"squircle","wake_ups":"service sends a [worker update] turn to the app agent when a worker finishes, errors or needs input"}}),
        ),
        Commands::App { command } => match command {
            AppCommand::Browse { path } => {
                let query=url::form_urlencoded::Serializer::new(String::new()).extend_pairs(path.as_ref().map(|path|("path",path))).finish();
                get(cli,&format!("/v1/projects?{query}")).await?
            }
            AppCommand::Inspect { project, scheme, configuration } => {
                let mut query=url::form_urlencoded::Serializer::new(String::new());
                query.append_pair("project",project);
                if let Some(scheme)=scheme {query.append_pair("scheme",scheme);}
                if let Some(configuration)=configuration {query.append_pair("configuration",configuration);}
                get(cli,&format!("/v1/projects/inspect?{}",query.finish())).await?
            }
            AppCommand::Import { project, scheme, name, configuration } => post(cli,"/v1/apps/import",json!({"project":project,"scheme":scheme,"name":name,"configuration":configuration})).await?,
            AppCommand::List => get(cli,"/v1/apps").await?,
            AppCommand::Show { app_id } => get(cli,&format!("/v1/apps/{}",valid_id(app_id)?)).await?,
            AppCommand::Register { project, scheme, name, bundle_id, summary } => post(cli,"/v1/apps",json!({"project":std::path::absolute(project)?,"scheme":scheme,"name":name,"bundle_id":bundle_id,"summary":summary})).await?,
            AppCommand::Update { app_id, name, summary } => request(cli,reqwest::Method::PATCH,&format!("/v1/apps/{}",valid_id(app_id)?),Some(json!({"name":name,"summary":summary})),false).await?,
            AppCommand::Preview { app_id, file, caption, build, source_revision } => {
                if let Some(build) = build { valid_id(build)?; }
                post(cli,&format!("/v1/apps/{}/preview",valid_id(app_id)?),json!({"file":std::path::absolute(file)?,"caption":caption,"build_id":build,"source_revision":source_revision})).await?
            }
        },
        Commands::Doctor => doctor(cli),
        Commands::Help { topic } => {
            if topic.as_deref() == Some("workflow") {
                println!("{}", include_str!("../docs/verification.md"));
            } else if let Some(topic) = topic {
                let mut command = Cli::command();
                let sub = command
                    .find_subcommand_mut(topic)
                    .with_context(|| format!("Unknown help topic: {topic}"))?;
                sub.print_long_help()?;
                println!();
            } else {
                Cli::command().print_long_help()?;
                println!();
            }
            return Ok(None);
        }
        Commands::Auth {
            command: AuthCommand::Show { scope },
        } => {
            let store = Store::open(root(cli)?)?;
            match scope {
                Scope::Control => {
                    success(json!({"scope":"control","token":store.settings.control_token}))
                }
                Scope::Diagnostics => {
                    success(json!({"scope":"diagnostics","token":store.settings.diagnostic_token}))
                }
            }
        }
        Commands::Build { command } => match command {
            BuildCommand::Start {
                project,
                scheme,
                configuration,
                mode,
                export_options,
                request_id,
                allow_provisioning_updates,
                preview,
                no_overlay,
            } => {
                let request = BuildRequest {
                    project: project.canonicalize()?,
                    scheme: scheme.clone(),
                    configuration: configuration.clone(),
                    mode: match mode {
                        Mode::Archive => BuildMode::Archive,
                        Mode::Simulator => BuildMode::Simulator,
                    },
                    export_options: export_options
                        .as_ref()
                        .map(|p| p.canonicalize())
                        .transpose()?,
                    request_id: request_id.clone(),
                    allow_provisioning_updates: *allow_provisioning_updates,
                    capture_preview: *preview,
                    no_overlay: *no_overlay,
                };
                post(cli, "/v1/builds", serde_json::to_value(request)?).await?
            }
            BuildCommand::List => get(cli, "/v1/builds").await?,
            BuildCommand::Status { build_id } => {
                get(cli, &format!("/v1/builds/{}", valid_id(build_id)?)).await?
            }
            BuildCommand::Wait { build_id, timeout } => {
                valid_id(build_id)?;
                if *timeout > 86400 {
                    bail!("Timeout cannot exceed 86400 seconds");
                }
                let deadline = tokio::time::Instant::now() + Duration::from_secs(*timeout);
                loop {
                    let response = match tokio::time::timeout_at(
                        deadline,
                        get(cli, &format!("/v1/builds/{build_id}")),
                    )
                    .await
                    {
                        Ok(response) => response?,
                        Err(_) => break wait_timeout(),
                    };
                    if response["ok"] == false {
                        break response;
                    }
                    let state = response["data"]["job"]["state"].as_str().unwrap_or("");
                    let preview_busy = matches!(
                        response["data"]["job"]["output"]["preview_state"].as_str(),
                        Some("pending" | "running")
                    );
                    if state == "succeeded" && !preview_busy {
                        break response;
                    }
                    if ["failed", "cancelled", "interrupted"].contains(&state) {
                        let mut error = failure(
                            "build_not_succeeded",
                            format!("Build {build_id} is {state}"),
                            "Read build status and build log before retrying.",
                        );
                        error["data"] = response["data"].clone();
                        break error;
                    }
                    if tokio::time::Instant::now() >= deadline {
                        break wait_timeout();
                    }
                    tokio::time::sleep_until(
                        (tokio::time::Instant::now() + Duration::from_millis(500)).min(deadline),
                    )
                    .await;
                }
            }
            BuildCommand::Cancel { build_id } => {
                post(
                    cli,
                    &format!("/v1/builds/{}/cancel", valid_id(build_id)?),
                    json!({}),
                )
                .await?
            }
            BuildCommand::Log {
                build_id,
                offset,
                limit,
            } => {
                get(
                    cli,
                    &format!(
                        "/v1/builds/{}/log?offset={offset}&limit={limit}",
                        valid_id(build_id)?
                    ),
                )
                .await?
            }
            BuildCommand::Import { ipa } => {
                post(cli, "/v1/import", json!({"ipa":ipa.canonicalize()?})).await?
            }
        },
        Commands::InstallLink {
            build_id,
            ttl_seconds,
        } => {
            post(
                cli,
                &format!("/v1/builds/{}/install-link", valid_id(build_id)?),
                json!({"ttl_seconds":ttl_seconds}),
            )
            .await?
        }
        Commands::Preview {
            command:
                PreviewCommand::Capture {
                    build_id,
                    simulator,
                    timeout,
                },
        } => {
            valid_id(build_id)?;
            if *timeout > 86400 {
                bail!("Timeout cannot exceed 86400 seconds");
            }
            if let Some(simulator) = simulator {
                uuid::Uuid::parse_str(simulator).context("Simulator ID must be a UUID")?;
            }
            let deadline = tokio::time::Instant::now() + Duration::from_secs(*timeout);
            let submitted = tokio::time::timeout_at(
                deadline,
                post(
                    cli,
                    &format!("/v1/builds/{build_id}/preview"),
                    json!({"simulator":simulator}),
                ),
            )
            .await;
            match submitted {
                Err(_) => preview_wait_timeout(),
                Ok(Err(error)) => return Err(error),
                Ok(Ok(value)) if value["ok"] == false => value,
                Ok(Ok(_)) => loop {
                    let response = match tokio::time::timeout_at(
                        deadline,
                        get(cli, &format!("/v1/builds/{build_id}")),
                    )
                    .await
                    {
                        Ok(value) => value?,
                        Err(_) => break preview_wait_timeout(),
                    };
                    if response["ok"] == false {
                        break response;
                    }
                    match response["data"]["job"]["output"]["preview_state"].as_str() {
                        Some("succeeded") => break response,
                        Some("failed") => {
                            let mut failure = failure(
                                "preview_failed",
                                response["data"]["job"]["output"]["preview_error"]
                                    .as_str()
                                    .unwrap_or("Preview failed"),
                                "Inspect build log and simulator; the signed IPA is unchanged.",
                            );
                            failure["data"] = response["data"].clone();
                            break failure;
                        }
                        _ => {}
                    }
                    tokio::time::sleep_until(
                        (tokio::time::Instant::now() + Duration::from_millis(500)).min(deadline),
                    )
                    .await;
                },
            }
        }
        Commands::Logs {
            build_id,
            since,
            limit,
        } => {
            get(
                cli,
                &format!(
                    "/v1/builds/{}/diagnostics?since={since}&limit={limit}",
                    valid_id(build_id)?
                ),
            )
            .await?
        }
        Commands::Crashes {
            build_id,
            since,
            limit,
        } => {
            get(
                cli,
                &format!(
                    "/v1/builds/{}/diagnostics?kind=crash&since={since}&limit={limit}",
                    valid_id(build_id)?
                ),
            )
            .await?
        }
        Commands::Symbolicate { report, dsym } => {
            let output = squircle::symbolicate::run(report, dsym).await?;
            success(
                json!({"report":output,"frames_verified":false,"note":"Tool completed; inspect application frames to confirm resolution and matching symbols."}),
            )
        }
        Commands::Perf { command } => {
            let root = root(cli)?;
            match command {
                PerfCommand::Show { capture, dsym } => {
                    let (text, data) = squircle::perf::show(&root, capture, dsym)?;
                    if !cli.json {
                        print!("{text}");
                        return Ok(None);
                    }
                    success(data)
                }
                PerfCommand::List => success(json!({"captures": squircle::perf::list(&root)?})),
            }
        }
        Commands::Media { command } => {
            let root = root(cli)?;
            match command {
                MediaCommand::Add { thread, file, caption } => {
                    let media = squircle::media::add(&root, thread, file, caption.as_deref())?;
                    success(json!({"id":media.id,"thread_id":media.thread_id,"kind":media.kind,"caption":media.caption,"bytes":media.bytes,"next":"The clip appears in the thread on the phone within a few seconds."}))
                }
                MediaCommand::List { thread } => success(json!({"media":squircle::media::list(&root, thread)?})),
            }
        }
        Commands::Sim { command } => match command {
            SimCommand::Start { thread, device } => post(cli, "/v1/sims", json!({"thread_id":thread_id(thread)?,"device":device})).await?,
            SimCommand::Stop { thread, id } => {
                if thread.is_none() && id.is_none() {
                    bail!("Pass --thread (your T3 thread ID) or --id");
                }
                post(cli, "/v1/sims/stop", json!({"thread_id":thread,"id":id})).await?
            }
            SimCommand::Status { thread } => {
                let query = url::form_urlencoded::Serializer::new(String::new()).extend_pairs(thread.as_ref().map(|t| ("thread", t))).finish();
                get(cli, &format!("/v1/sims?{query}")).await?
            }
            SimCommand::Devices => get(cli, "/v1/sims/devices").await?,
        },
        Commands::T3 { command } => match command {
            T3Command::Connect { url } => {
                let mut token = String::new();
                std::io::Read::read_to_string(&mut std::io::stdin(), &mut token)?;
                if token.trim().is_empty() {
                    bail!("Pipe a T3 pairing token on stdin");
                }
                let config = squircle::t3::pair(&root(cli)?, url, &token).await?;
                success(json!({"url":config.url,"expires_at":config.expires_at,"next":"Restart squircle serve, then run squircle agent setup."}))
            }
            T3Command::Status => {
                let value = get(cli, "/v1/agents").await?;
                if value["ok"] == false { value } else { success(json!({"t3":value["data"]["t3"]})) }
            }
        },
        Commands::Agent { command } => match command {
            AgentCommand::Setup { remove } => success(squircle::agents::setup(&root(cli)?, &cli.server, *remove).await?),
            AgentCommand::Start { project, message, model } => {
                post(cli, "/v1/agents", json!({"project_id":project,"message":message,"model":model})).await?
            }
            AgentCommand::List => get(cli, "/v1/agents").await?,
            AgentCommand::Restart { target } => {
                post(cli, "/v1/agents/restart", json!({"project_id":target.project,"thread_id":target.thread})).await?
            }
            AgentCommand::Fresh { target, handoff } => {
                post(cli, "/v1/agents/fresh", json!({"project_id":target.project,"thread_id":target.thread,"handoff":handoff})).await?
            }
            AgentCommand::Context { hook, cwd } => {
                let mut event = Value::Null;
                if *hook {
                    let mut input = String::new();
                    let _ = std::io::Read::read_to_string(&mut std::io::stdin(), &mut input);
                    event = serde_json::from_str(&input).unwrap_or(Value::Null);
                }
                let cwd = cwd.clone()
                    .or_else(|| event["cwd"].as_str().map(PathBuf::from))
                    .map_or_else(std::env::current_dir, Ok)?;
                let query = url::form_urlencoded::Serializer::new(String::new()).append_pair("cwd", &cwd.display().to_string()).finish();
                // A hook must never fail the agent's turn.
                let context = match get(cli, &format!("/v1/agents/context?{query}")).await {
                    Ok(value) if value["ok"] == true => value["data"]["context"].as_str().unwrap_or("").to_string(),
                    _ => "[squircle] The Squircle service is not reachable; worker commands will fail until it is back.".into(),
                };
                if !*hook {
                    success(json!({"context":context}))
                } else {
                    let name = event["hook_event_name"].as_str().unwrap_or("UserPromptSubmit");
                    println!("{}", json!({"hookSpecificOutput":{"hookEventName":name,"additionalContext":context}}));
                    return Ok(None);
                }
            }
        },
        Commands::Thread { command } => match command {
            ThreadCommand::Spawn { coordinator, title, branch, base, prompt, model } => post(cli, "/v1/workers",
                json!({"coordinator":coordinator,"title":title,"branch":branch,"base":base,"prompt":prompt,"model":model})).await?,
            ThreadCommand::Send { id, text } => post(cli, &format!("/v1/workers/{}/messages", thread_id(id)?), json!({"text":text})).await?,
            ThreadCommand::Status { coordinator } => {
                let query = url::form_urlencoded::Serializer::new(String::new()).extend_pairs(coordinator.as_ref().map(|c| ("coordinator", c))).finish();
                get(cli, &format!("/v1/workers?{query}")).await?
            }
            ThreadCommand::Read { id } => get(cli, &format!("/v1/workers/{}", thread_id(id)?)).await?,
            ThreadCommand::Answer { id, text } => post(cli, &format!("/v1/workers/{}/answer", thread_id(id)?), json!({"text":text})).await?,
            ThreadCommand::Archive { id, discard } => post(cli, &format!("/v1/workers/{}/archive", thread_id(id)?), json!({"discard":discard})).await?,
            ThreadCommand::Cleanup { coordinator, dry_run } => post(cli, "/v1/workers/cleanup",
                json!({"coordinator":thread_id(coordinator)?,"dry_run":dry_run})).await?,
        },
        Commands::Diagnostics {
            command: DiagnosticCommand::Send { file },
        } => {
            if std::fs::metadata(file)?.len() > 1024 * 1024 {
                bail!("Diagnostic JSON exceeds 1 MiB");
            }
            let event: Diagnostic = serde_json::from_reader(std::fs::File::open(file)?)?;
            request(
                cli,
                reqwest::Method::POST,
                "/v1/diagnostics",
                Some(serde_json::to_value(event)?),
                true,
            )
            .await?
        }
    };
    Ok(Some(data))
}

fn wait_timeout() -> Value {
    failure(
        "wait_timeout",
        "Wait timed out; the build was not cancelled",
        "Call build status or wait again with the same build ID.",
    )
}
fn preview_wait_timeout() -> Value {
    failure(
        "wait_timeout",
        "Preview wait timed out; accepted capture was not cancelled",
        "Call build status or build cancel with the same build ID; do not resubmit blindly.",
    )
}

fn doctor(cli: &Cli) -> Value {
    fn check(program: &str, args: &[&str]) -> Value {
        match Command::new(program).args(args).output() {
            Ok(output) => {
                json!({"available":output.status.success(),"summary":String::from_utf8_lossy(&output.stdout).trim(),"error":if output.status.success(){String::new()}else{String::from_utf8_lossy(&output.stderr).chars().take(2000).collect()}})
            }
            Err(error) => json!({"available":false,"error":error.to_string()}),
        }
    }
    let identities = check(
        "/usr/bin/security",
        &["find-identity", "-v", "-p", "codesigning"],
    );
    success(
        json!({"platform":std::env::consts::OS,"architecture":std::env::consts::ARCH,"xcode":check("/usr/bin/xcodebuild",&["-version"]),"developer_directory":check("/usr/bin/xcode-select",&["-p"]),"signing":identities,"server":cli.server,"data_dir":root(cli).ok(),"notes":["Signing visibility depends on the actual service user, Keychain access and sandbox.","This command does not validate provisioning, device registration or cellular HTTPS reachability.","Tailscale and HTTPS are configured by the user; no settings were changed."]}),
    )
}
