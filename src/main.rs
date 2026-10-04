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
    /// Submit a JSON diagnostic fixture; useful for checking the phone-to-Mac contract.
    Diagnostics {
        #[command(subcommand)]
        command: DiagnosticCommand,
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
            json!({"name":"Squircle","version":env!("CARGO_PKG_VERSION"),"schema_version":SCHEMA_VERSION,"operations":["doctor","build.start","build.list","build.status","build.wait","build.cancel","build.log","build.import","install-link","logs","crashes","symbolicate","diagnostics.send"],"build_modes":["archive","simulator"],"max_concurrent_builds":1,"max_queued_or_running_builds":16,"diagnostic_event_max_bytes":1048576,"diagnostics_storage_max_bytes_per_build":67108864,"requires_local_http_service":true,"manages_tailscale":false,"remote_launch":false,"lldb":false,"crash_symbolication":"local Xcode symbolicatecrash; Apple-text reports; frame resolution must be checked","cellular_install_verified":false}),
        ),
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
                    if state == "succeeded" {
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
