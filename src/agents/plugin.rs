use super::*;

/// T3's built-in Claude provider instance, and its driver.
const CLAUDE: &str = "claudeAgent";

pub(super) const PLUGIN_FILES: [(&str, &str); 4] = [
    (
        ".claude-plugin/plugin.json",
        include_str!("../../plugin/squircle/.claude-plugin/plugin.json"),
    ),
    (
        "agents/app-agent.md",
        include_str!("../../plugin/squircle/agents/app-agent.md"),
    ),
    (
        "agents/history.md",
        include_str!("../../plugin/squircle/agents/history.md"),
    ),
    (
        "hooks/hooks.json",
        include_str!("../../plugin/squircle/hooks/hooks.json"),
    ),
];

/// What `agent setup` asks T3 for: reading settings and changing provider instances.
pub const SETUP_SCOPES: &str = "orchestration:read providers:manage";

/// Installs the plugin (agent definition and hooks) into the data directory
/// and adds T3's "squircle" Claude instance that launches with it, on the
/// same Claude binary and login as T3's own Claude, and the "squircle-codex"
/// Codex instance with Squircle's hooks (see `codex`). `provider` limits it
/// to one; `remove` takes them out again. Returns what changed.
/// `pairing_token` is a one-time T3 pairing token: the service's own session
/// may only operate threads, and changing T3's providers needs
/// `providers:manage`, so setup exchanges it for a session it never saves.
pub async fn setup(
    root: &Path,
    server: &str,
    remove: bool,
    provider: Option<&str>,
    pairing_token: &str,
) -> Result<Value> {
    let providers = match provider {
        Some(name) => vec![Provider::parse(name)?],
        None => vec![Provider::Claude, Provider::Codex],
    };
    // T3 and hooks run elsewhere: every path they get must be absolute.
    let root = &root
        .canonicalize()
        .context("Squircle data directory not found; run squircle init")?;
    let url = T3Config::load(root)?.url;
    let session =
        crate::t3::exchange(&url, pairing_token, SETUP_SCOPES, "Squircle agent setup").await?;
    let client = T3::connect(session).await?;
    let settings = client.call("server.getSettings", json!({})).await?;
    let instances = &settings["providerInstances"];
    ensure!(
        instances.is_object(),
        "T3's settings have no providerInstances; Squircle needs the current T3"
    );
    let plugin = root.join("plugin").join("squircle");
    if remove {
        let mut out = json!({"plugin_left_at": plugin});
        if providers.contains(&Provider::Claude) {
            let removed = instances.get(INSTANCE).is_some();
            if removed {
                client
                    .call(
                        "server.updateSettings",
                        json!({"patch": {}, "providerInstanceMutation": {"operation": "remove", "instanceId": INSTANCE}}),
                    )
                    .await?;
            }
            out["removed_instance"] = json!(removed);
        }
        if providers.contains(&Provider::Codex) {
            out["codex"] = codex::remove(&client, instances, root).await?;
        }
        return Ok(out);
    }
    // Agents type plain `squircle`; hooks keep the full path.
    if !wrapper(root).exists() {
        write_wrapper(root, server, &std::env::current_exe()?.canonicalize()?)?;
    }
    let on_path = link_wrapper(root)?;
    let cli = cli_invocation(root, server);
    let escaped = serde_json::to_string(&cli_full(root, server))?;
    let escaped = &escaped[1..escaped.len() - 1];
    for (path, template) in PLUGIN_FILES {
        let target = plugin.join(path);
        private_dir(target.parent().unwrap())?;
        let cli = if path.ends_with(".json") {
            escaped
        } else {
            cli.as_str()
        };
        std::fs::write(
            &target,
            template
                .replace("{{CLI}}", cli)
                .replace("{{VERSION}}", env!("CARGO_PKG_VERSION")),
        )?;
    }
    let mut out = json!({"plugin": plugin,
          "squircle_on_path": on_path.as_ref().ok(), "squircle_not_on_path": on_path.as_ref().err(), "invocation": cli});
    if providers.contains(&Provider::Claude) {
        out["claude"] = claude(&client, instances, &plugin).await?;
    }
    if providers.contains(&Provider::Codex) {
        out["codex"] = codex::setup(&client, instances, root).await?;
    }
    out["note"] = json!(
        "T3 now offers Squircle's agent instances on your existing Claude and Codex logins; agent restart --provider moves an agent between them. Run with --remove to take them out."
    );
    Ok(out)
}

/// The Claude instance, launched with the plugin.
async fn claude(client: &T3, instances: &Value, plugin: &Path) -> Result<Value> {
    // The built-in Claude's binary and home, as T3 runs it: its `claudeAgent`
    // instance. An absent instance or key is T3's default (`claude` on PATH,
    // the default home), which this instance then gets too.
    let builtin = match &instances[CLAUDE] {
        Value::Null => &Value::Null,
        builtin => {
            ensure!(
                builtin["driver"] == CLAUDE,
                "T3's {CLAUDE} provider instance has driver {}, not {CLAUDE}",
                builtin["driver"]
            );
            &builtin["config"]
        }
    };
    let mut config = serde_json::Map::new();
    for key in ["binaryPath", "homePath"] {
        match &builtin[key] {
            Value::Null => {}
            Value::String(value) if value.is_empty() => {}
            Value::String(value) => {
                config.insert(key.into(), json!(value));
            }
            other => bail!("T3's {CLAUDE} {key} is not a string: {other}"),
        }
    }
    let launch = format!("--plugin-dir {} --agent squircle:app-agent", quote(plugin));
    config.insert("launchArgs".into(), json!(launch));
    let instance = json!({"driver": CLAUDE, "displayName": "Squircle agent", "config": config});
    client
        .call(
            "server.updateSettings",
            json!({"patch": {}, "providerInstanceMutation": {"operation": "upsert", "instanceId": INSTANCE, "instance": instance}}),
        )
        .await?;
    Ok(json!({"instance": INSTANCE, "launch_args": launch}))
}
