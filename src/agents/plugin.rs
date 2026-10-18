use super::*;

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

/// Installs the plugin (agent definition and hooks) into the data directory
/// and adds T3's "squircle" Claude instance that launches with it, on the
/// same Claude binary and login as T3's own Claude. `remove` takes the
/// instance out again. Returns what changed.
pub async fn setup(root: &Path, server: &str, remove: bool) -> Result<Value> {
    // T3 and hooks run elsewhere: every path they get must be absolute.
    let root = &root
        .canonicalize()
        .context("Squircle data directory not found; run squircle init")?;
    let client = T3::connect(T3Config::load(root)?).await?;
    let settings = client.call("server.getSettings", json!({})).await?;
    let mut instances = settings["providerInstances"]
        .as_object()
        .cloned()
        .unwrap_or_default();
    let plugin = root.join("plugin").join("squircle");
    if remove {
        let removed = instances.remove(INSTANCE).is_some();
        client
            .call(
                "server.updateSettings",
                json!({"patch": {"providerInstances": instances}}),
            )
            .await?;
        return Ok(json!({"removed_instance": removed, "plugin_left_at": plugin}));
    }
    let cli = cli_invocation(root, server);
    let escaped = serde_json::to_string(&cli)?;
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
    let claude = &settings["providers"]["claudeAgent"];
    let mut config = serde_json::Map::new();
    for key in ["binaryPath", "homePath"] {
        if let Some(value) = claude[key].as_str().filter(|v| !v.is_empty()) {
            config.insert(key.into(), json!(value));
        }
    }
    let launch = format!("--plugin-dir {} --agent squircle:app-agent", quote(&plugin));
    config.insert("launchArgs".into(), json!(launch));
    instances.insert(
        INSTANCE.into(),
        json!({"driver": "claudeAgent", "displayName": "Squircle agent", "config": config}),
    );
    client
        .call(
            "server.updateSettings",
            json!({"patch": {"providerInstances": instances}}),
        )
        .await?;
    Ok(
        json!({"plugin": plugin, "instance": INSTANCE, "launch_args": launch,
              "note": "T3 now offers a \"Squircle agent\" Claude instance on your existing Claude login. Run with --remove to take it out."}),
    )
}
