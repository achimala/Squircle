use super::*;

#[derive(Subcommand)]
pub(super) enum AppCommand {
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
    /// Read one app's metadata. T3 owns conversations.
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

pub(super) async fn run(cli: &Cli, command: &AppCommand) -> Result<Option<Value>> {
    let data = match command {
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
        };
    Ok(Some(data))
}
