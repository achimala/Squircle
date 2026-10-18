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
    /// Hand over to a new service process without ending simulator sessions.
    Restart,
    /// Stop the service, ending simulator sessions.
    Stop,
}

pub(super) async fn service(cli: &Cli, command: &ServiceCommand) -> Result<Option<Value>> {
    let data = {
        let root = root(cli)?;
        ensure!(
            local_server(&cli.server),
            "service controls this Mac's service; --server must be on this Mac"
        );
        success(match command {
            ServiceCommand::Restart => squircle::service::restart(&root, &cli.server).await?,
            ServiceCommand::Stop => squircle::service::stop(&root).await?,
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

pub(super) fn doctor(cli: &Cli) -> Value {
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
