use super::*;

#[derive(Subcommand)]
pub(super) enum AuthCommand {
    Show {
        #[arg(long, value_enum, default_value = "diagnostics")]
        scope: Scope,
    },
}

#[derive(Clone, ValueEnum)]
pub(super) enum Scope {
    Control,
    Diagnostics,
}

#[derive(Subcommand)]
pub(super) enum DiagnosticCommand {
    Send {
        #[arg(long, help = "Path to one diagnostic event JSON file")]
        file: PathBuf,
    },
}

#[derive(Subcommand)]
pub(super) enum ServiceCommand {
    /// Run the service as a launchd user agent: started at login, restarted after a crash.
    #[command(
        after_help = "Writes ~/Library/LaunchAgents/dev.squircle.service.plist (RunAtLoad; KeepAlive unless it stopped cleanly) and loads it. If a service runs for this data directory, its binary, serve arguments and environment (PATH, HOME, LANG, DEVELOPER_DIR, SQUIRCLE_*) are used and it hands its simulator sessions over to launchd's; otherwise this binary. launchd runs a signed copy from ~/Library/Application Support/dev.squircle.service (identifier dev.squircle.service, the Mac's Apple Development identity), which restart refreshes from the source binary. Pass --listen or --public-url to change serve's arguments. The log stays in DATA_DIR/serve.log.\nmacOS keeps background services out of Documents, Desktop, Downloads and iCloud Drive: with the data directory there, the copy needs Full Disk Access, granted once in System Settings (the signature keeps it across rebuilds). Install, restart and start try the copy under launchd first and, if it can't read the data directory, say what to grant and leave the running service alone."
    )]
    Install {
        #[arg(long, help = "serve --listen for the installed service")]
        listen: Option<String>,
        #[arg(long, help = "serve --public-url for the installed service")]
        public_url: Option<String>,
    },
    /// Start the installed service (after service stop).
    Start,
    /// Hand over to a new service process without ending simulator sessions.
    Restart,
    /// Stop the service, ending simulator sessions. Installed, it stays stopped until service start or the next login.
    Stop,
    /// Remove the launchd user agent, stopping the service it runs.
    Uninstall,
    /// Check this binary can read the data directory (install runs it under launchd).
    #[command(hide = true)]
    Check,
}

pub(super) async fn service(cli: &Cli, command: &ServiceCommand) -> Result<Option<Value>> {
    let data = {
        let root = root(cli)?;
        ensure!(
            local_server(&cli.server),
            "service controls this Mac's service; --server must be on this Mac"
        );
        success(match command {
            ServiceCommand::Install { listen, public_url } => {
                let mut args = vec![];
                if let Some(listen) = listen {
                    args.extend(["--listen".to_string(), listen.clone()]);
                }
                if let Some(url) = public_url {
                    args.extend(["--public-url".to_string(), url.clone()]);
                }
                squircle::service::install(&root, &cli.server, args).await?
            }
            ServiceCommand::Start => squircle::service::start(&root, &cli.server).await?,
            ServiceCommand::Restart => squircle::service::restart(&root, &cli.server).await?,
            ServiceCommand::Stop => squircle::service::stop(&root).await?,
            ServiceCommand::Uninstall => squircle::service::uninstall(&root).await?,
            ServiceCommand::Check => squircle::service::check_access(&std::path::absolute(&root)?)?,
        })
    };
    Ok(Some(data))
}

pub(super) async fn auth(cli: &Cli, command: &AuthCommand) -> Result<Option<Value>> {
    let data = match command {
        AuthCommand::Show { scope } => {
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
    };
    Ok(Some(data))
}

pub(super) async fn diagnostics(cli: &Cli, command: &DiagnosticCommand) -> Result<Option<Value>> {
    let data = match command {
        DiagnosticCommand::Send { file } => {
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

pub(super) async fn doctor(cli: &Cli) -> Value {
    async fn check(program: &str, args: &[&str]) -> Value {
        match tokio::process::Command::new(program)
            .args(args)
            .kill_on_drop(true)
            .output()
            .await
        {
            Ok(output) => {
                json!({"available":output.status.success(),"summary":String::from_utf8_lossy(&output.stdout).trim(),"error":if output.status.success(){String::new()}else{String::from_utf8_lossy(&output.stderr).chars().take(2000).collect()}})
            }
            Err(error) => json!({"available":false,"error":error.to_string()}),
        }
    }
    let identities = check(
        "/usr/bin/security",
        &["find-identity", "-v", "-p", "codesigning"],
    )
    .await;
    let xcode = check("/usr/bin/xcodebuild", &["-version"]).await;
    let developer = check("/usr/bin/xcode-select", &["-p"]).await;
    success(
        json!({"platform":std::env::consts::OS,"architecture":std::env::consts::ARCH,"xcode":xcode,"developer_directory":developer,"signing":identities,"server":cli.server,"data_dir":root(cli).ok(),"notes":["Signing visibility depends on the actual service user, Keychain access and sandbox.","This command does not validate provisioning, device registration or cellular HTTPS reachability.","Tailscale and HTTPS are configured by the user; no settings were changed."]}),
    )
}
