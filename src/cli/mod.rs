//! CLI dispatch and shared invocation context. Each group owns its clap
//! declarations and handler; the command tree also drives discovery.
mod args;
use args::*;
mod agents;
use agents::*;
mod push;
use push::*;
mod tasks;
use tasks::*;
mod sims;
use sims::*;
mod history;
use history::*;
mod media;
use media::*;
mod local;
use local::*;
mod builds;
use builds::*;
mod apps;
use apps::*;
mod output;
use output::*;
mod client;
use client::*;
mod discovery;
use discovery::*;
mod poll;
use poll::*;

use anyhow::{Context, Result, bail, ensure};
use clap::{CommandFactory, Parser, Subcommand, ValueEnum};
use serde_json::{Value, json};
use squircle::{model::*, store::Store};
use std::{net::SocketAddr, path::PathBuf, time::Duration};

/// Whether `server` is a service on this Mac, which local-only commands
/// (`media`) can stand in for by writing its data directory.
fn local_server(server: &str) -> bool {
    url::Url::parse(server).is_ok_and(|url| {
        url.host()
            .is_some_and(|host| squircle::origin::loopback(&host))
    })
}

fn root(cli: &Cli) -> Result<PathBuf> {
    Ok(cli.data_dir.clone().unwrap_or(
        dirs::data_local_dir()
            .context("Cannot determine application data directory; pass --data-dir")?
            .join("Squircle"),
    ))
}

pub(super) async fn main() {
    let machine = std::env::args_os().any(|s| s == "--json");
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
fn thread_id(id: &str) -> Result<&str> {
    uuid::Uuid::parse_str(id).context("Thread ID must be a UUID")?;
    Ok(id)
}
fn task_id(id: &str) -> Result<&str> {
    uuid::Uuid::parse_str(id).context("Task ID must be a UUID")?;
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
        Commands::Serve {
            listen,
            public_url,
            log,
        } => {
            if let Some(log) = log {
                squircle::service::log_to(log)?;
            }
            squircle::server::serve(root(cli)?, *listen, public_url.clone()).await?;
            return Ok(None);
        }
        Commands::Service { command } => return local::service(cli, command).await,
        Commands::Capabilities => success(
            json!({"name":"Squircle","version":env!("CARGO_PKG_VERSION"),"schema_version":SCHEMA_VERSION,"operations":operations(),"build_modes":["archive","simulator"],"preview":"agents publish a simulator screenshot they looked at: sim start, install, look, then app preview ID --file PATH","max_concurrent_builds":1,"max_queued_or_running_builds":16,"diagnostic_event_max_bytes":1048576,"diagnostics_storage_max_bytes_per_build":67108864,"requires_local_http_service":true,"manages_tailscale":false,"remote_launch":false,"lldb":false,"crash_symbolication":"local Xcode symbolicatecrash; Apple-text reports; frame resolution must be checked","cellular_install_verified":false,"app_agents":{"instance":"squircle","wake_ups":"service sends a [worker update] turn to the app agent when a worker finishes, errors or needs input"},
                "invocation":squircle::agents::cli_invocation(&std::path::absolute(root(cli)?)?, &cli.server)}),
        ),
        Commands::App { command } => return apps::run(cli, command).await,
        Commands::Doctor => doctor(cli).await,
        Commands::Help { topic } => {
            if topic.as_deref() == Some("workflow") {
                println!("{}", include_str!("../../docs/verification.md"));
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
        Commands::Auth { command } => return local::auth(cli, command).await,
        Commands::Build { command } => return builds::run(cli, command).await,
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
        Commands::Perf { command } => return media::perf(cli, command).await,
        Commands::Media { command } => return media::media(cli, command).await,
        Commands::Push { command } => return push::run(cli, command).await,
        Commands::Sim { command } => return sims::run(cli, command).await,
        Commands::T3 { command } => return agents::t3(cli, command).await,
        Commands::Agent { command } => return agents::agent(cli, command).await,
        Commands::History { command } => return history::history(cli, command).await,
        Commands::Notes { command } => return history::notes(cli, command).await,
        Commands::Task { command } => return tasks::run(cli, command).await,
        Commands::Thread { command } => return agents::thread(cli, command).await,
        Commands::Diagnostics { command } => return local::diagnostics(cli, command).await,
    };
    Ok(Some(data))
}
