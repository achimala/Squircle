use super::*;

#[derive(Subcommand)]
pub(super) enum PushCommand {
    /// Store your APNs auth key (.p8). Works without the service running.
    Setup {
        #[arg(long, help = "The AuthKey_XXXXXXXXXX.p8 file downloaded from Apple")]
        key_file: Option<PathBuf>,
        #[arg(long, help = "The key's 10-character Key ID")]
        key_id: Option<String>,
        #[arg(long, help = "Your 10-character Apple Team ID")]
        team_id: Option<String>,
        #[arg(long, help = "Delete the stored key instead")]
        remove: bool,
    },
    /// Send a test notification (and with --live-activity, start a test Live Activity) to registered phones.
    Test {
        #[arg(long)]
        live_activity: bool,
    },
    /// Whether a key is set and which phones registered (no tokens shown).
    Status,
}

pub(super) async fn run(cli: &Cli, command: &PushCommand) -> Result<Option<Value>> {
    let data = match command {
        PushCommand::Setup {
            key_file,
            key_id,
            team_id,
            remove,
        } => success(squircle::push::setup(
            &root(cli)?,
            key_file.as_deref(),
            key_id.as_deref(),
            team_id.as_deref(),
            *remove,
        )?),
        PushCommand::Test { live_activity } => {
            post(
                cli,
                "/v1/push/test",
                json!({"live_activity": live_activity}),
            )
            .await?
        }
        PushCommand::Status => get(cli, "/v1/push").await?,
    };
    Ok(Some(data))
}
