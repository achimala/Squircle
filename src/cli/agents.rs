use super::*;

#[derive(Subcommand)]
pub(super) enum T3Command {
    /// Exchange a one-time T3 pairing token (read from stdin) for the service's own session.
    #[command(
        after_help = "Create the pairing token in T3 (pair a new client), then: pbpaste | squircle t3 connect --url http://127.0.0.1:3773. Restart squircle serve afterwards."
    )]
    Connect {
        #[arg(long, default_value = "http://127.0.0.1:3773")]
        url: String,
    },
    /// Whether the running service is connected to T3.
    Status,
}

#[derive(Subcommand)]
pub(super) enum AgentCommand {
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
        #[arg(
            long,
            help = "Claude model slug; default: the project's default or claude-opus-5-5"
        )]
        model: Option<String>,
        #[arg(long, value_parser = ["approval-required", "auto-accept-edits", "auto", "full-access"],
            help = "T3 runtime mode the agent's thread is created with, before its first turn; default: the service's")]
        runtime_mode: Option<String>,
    },
    /// List app agents and the service's T3 connection.
    List,
    /// Relaunch the agent's Claude session on the same thread: its next message starts with the current instructions and the same history.
    #[command(
        after_help = "Happens now if the agent is between turns, otherwise when its current turn ends (an agent asking to restart itself just ends its turn)."
    )]
    Restart {
        #[command(flatten)]
        target: AgentTarget,
    },
    /// Replace the agent with a new thread seeded by a short handoff; the old conversation stays readable and its workers move to the new agent.
    #[command(
        after_help = "The handoff has the app, recent commits, open workers, the user's recent messages, your last reply and your --handoff note. Happens now if the agent is between turns, otherwise when its current turn ends."
    )]
    Fresh {
        #[command(flatten)]
        target: AgentTarget,
        #[arg(
            long,
            help = "What the new agent must know that git and the workers don't show: what the user asked to remember, plans in flight"
        )]
        handoff: Option<String>,
    },
    /// Compact the agent's context now (Claude's /compact, keeping tasks, decisions, running work and recent exchanges).
    #[command(
        after_help = "Refused while the agent's turn runs. The service also does this by itself when an agent sits idle with a large context; see docs/cli.md (agent upkeep)."
    )]
    Compact {
        #[command(flatten)]
        target: AgentTarget,
    },
    /// The note an app agent gets at the start of each turn (rules and live workers).
    Context {
        #[arg(
            long,
            help = "Read a Claude Code hook event on stdin and answer in hook JSON"
        )]
        hook: bool,
        #[arg(long, help = "Worktree directory; default: current directory")]
        cwd: Option<PathBuf>,
    },
    /// PreToolUse hook: denies the app agent running models outside T3 (codex/claude CLIs, subagents, workflows), pointing to `thread spawn`.
    Guard,
}

#[derive(clap::Args)]
#[group(required = true, multiple = false)]
pub(super) struct AgentTarget {
    #[arg(long, help = "T3 project ID")]
    pub(super) project: Option<String>,
    #[arg(long, help = "The app agent's thread ID")]
    pub(super) thread: Option<String>,
}

#[derive(Subcommand)]
pub(super) enum ThreadCommand {
    /// Start a worker thread in its own worktree. Its prompt must stand alone.
    Spawn {
        #[arg(long, help = "Your (the app agent's) thread ID")]
        coordinator: String,
        #[arg(long, help = "Short issue title the user will see")]
        title: String,
        #[arg(long, help = "New branch for the worker")]
        branch: String,
        #[arg(
            long,
            help = "Base branch; default: the project checkout's current branch"
        )]
        base: Option<String>,
        #[arg(long)]
        prompt: String,
        #[arg(long, help = "T3 provider instance, e.g. codex; default: claudeAgent")]
        provider: Option<String>,
        #[arg(
            long,
            help = "Model slug; default: the app agent's model for Claude, else the provider's default"
        )]
        model: Option<String>,
        #[arg(long, help = "Reasoning effort, e.g. high; default: the provider's")]
        effort: Option<String>,
        #[arg(long, value_parser = ["approval-required", "auto-accept-edits", "auto", "full-access"],
            help = "T3 runtime mode; default: yours (the app agent's), mapped to the provider's closest; the result says what it allows")]
        runtime_mode: Option<String>,
        #[arg(long, help = "Link the worker to this task (squircle task --help)")]
        task: Option<String>,
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
    #[command(
        after_help = "Refuses while the branch has commits not in its base, the worktree has uncommitted changes, or the worker is still working."
    )]
    Archive {
        id: String,
        #[arg(
            long,
            alias = "force",
            help = "Archive anyway, dropping unmerged commits and uncommitted changes"
        )]
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

pub(super) async fn t3(cli: &Cli, command: &T3Command) -> Result<Option<Value>> {
    let data = match command {
        T3Command::Connect { url } => {
            let mut token = String::new();
            std::io::Read::read_to_string(&mut std::io::stdin(), &mut token)?;
            if token.trim().is_empty() {
                bail!("Pipe a T3 pairing token on stdin");
            }
            let config = squircle::t3::pair(&root(cli)?, url, &token).await?;
            success(
                json!({"url":config.url,"expires_at":config.expires_at,"next":"Restart squircle serve, then run squircle agent setup."}),
            )
        }
        T3Command::Status => {
            let value = get(cli, "/v1/agents").await?;
            if value["ok"] == false {
                value
            } else {
                success(json!({"t3":value["data"]["t3"]}))
            }
        }
    };
    Ok(Some(data))
}

pub(super) async fn agent(cli: &Cli, command: &AgentCommand) -> Result<Option<Value>> {
    let data = match command {
            AgentCommand::Setup { remove } => success(squircle::agents::setup(&root(cli)?, &cli.server, *remove).await?),
            AgentCommand::Start { project, message, model, runtime_mode } => {
                post(cli, "/v1/agents", json!({"project_id":project,"message":message,"model":model,"runtime_mode":runtime_mode})).await?
            }
            AgentCommand::List => get(cli, "/v1/agents").await?,
            AgentCommand::Restart { target } => {
                post(cli, "/v1/agents/restart", json!({"project_id":target.project,"thread_id":target.thread})).await?
            }
            AgentCommand::Fresh { target, handoff } => {
                post(cli, "/v1/agents/fresh", json!({"project_id":target.project,"thread_id":target.thread,"handoff":handoff})).await?
            }
            AgentCommand::Compact { target } => {
                post(cli, "/v1/agents/compact", json!({"project_id":target.project,"thread_id":target.thread})).await?
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
            AgentCommand::Guard => {
                let mut input = String::new();
                let _ = std::io::Read::read_to_string(&mut std::io::stdin(), &mut input);
                let event: Value = serde_json::from_str(&input).unwrap_or(Value::Null);
                let cli_text = root(cli).map(|r| squircle::agents::cli_invocation(&r, &cli.server)).unwrap_or_else(|_| "squircle".into());
                if let Some(reason) = squircle::guard::check(&event, &cli_text) {
                    println!("{}", json!({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":reason}}));
                }
                return Ok(None);
            }
        };
    Ok(Some(data))
}

pub(super) async fn thread(cli: &Cli, command: &ThreadCommand) -> Result<Option<Value>> {
    let data = match command {
            ThreadCommand::Spawn { coordinator, title, branch, base, prompt, provider, model, effort, runtime_mode, task } => post(cli, "/v1/workers",
                json!({"coordinator":coordinator,"title":title,"branch":branch,"base":base,"prompt":prompt,"provider":provider,"model":model,"effort":effort,"runtime_mode":runtime_mode,"task":task})).await?,
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
        };
    Ok(Some(data))
}
