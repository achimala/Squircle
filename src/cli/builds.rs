use super::*;

#[derive(Subcommand)]
pub(super) enum BuildCommand {
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
        #[arg(
            long,
            help = "Link the build to this task; it becomes ready to try when the build succeeds"
        )]
        task: Option<String>,
        #[arg(
            long,
            help = "Your T3 thread ID: when the build finishes, your app's agent and the user's chat get it (Install, or why it failed)"
        )]
        thread: Option<String>,
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
pub(super) enum Mode {
    Archive,
    Simulator,
}

#[derive(Subcommand)]
pub(super) enum PreviewCommand {
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

pub(super) async fn run(cli: &Cli, command: &BuildCommand) -> Result<Option<Value>> {
    let data = match command {
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
            task,
            thread,
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
                thread: thread.clone(),
            };
            let started = post(cli, "/v1/builds", serde_json::to_value(request)?).await?;
            if let (Some(task), Some(build)) = (task, started["data"]["job"]["id"].as_str()) {
                let linked = post(
                    cli,
                    &format!("/v1/tasks/{}/link", task_id(task)?),
                    json!({"build":build}),
                )
                .await?;
                if linked["ok"] != true {
                    eprintln!(
                        "The build started but was not linked to the task: {}",
                        linked["error"]["message"]
                    );
                }
            }
            started
        }
        BuildCommand::List => get(cli, "/v1/builds").await?,
        BuildCommand::Status { build_id } => {
            get(cli, &format!("/v1/builds/{}", valid_id(build_id)?)).await?
        }
        BuildCommand::Wait { build_id, timeout } => {
            valid_id(build_id)?;
            poll(cli, build_id, deadline(*timeout)?, WaitFor::Build).await?
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
    };
    Ok(Some(data))
}

pub(super) async fn preview(cli: &Cli, command: &PreviewCommand) -> Result<Option<Value>> {
    let data = match command {
        PreviewCommand::Capture {
            build_id,
            simulator,
            timeout,
        } => {
            valid_id(build_id)?;
            if let Some(simulator) = simulator {
                uuid::Uuid::parse_str(simulator).context("Simulator ID must be a UUID")?;
            }
            let deadline = deadline(*timeout)?;
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
                Err(_) => WaitFor::Preview.timeout(),
                Ok(Err(error)) => return Err(error),
                Ok(Ok(value)) if value["ok"] == false => value,
                Ok(Ok(_)) => poll(cli, build_id, deadline, WaitFor::Preview).await?,
            }
        }
    };
    Ok(Some(data))
}
