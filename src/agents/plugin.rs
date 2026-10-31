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
    let instances = &settings["providerInstances"];
    ensure!(
        instances.is_object(),
        "T3's settings have no providerInstances; Squircle needs the current T3"
    );
    let plugin = root.join("plugin").join("squircle");
    if remove {
        let removed = instances.get(INSTANCE).is_some();
        if removed {
            client
                .call(
                    "server.updateSettings",
                    json!({"patch": {}, "providerInstanceMutation": {"operation": "remove", "instanceId": INSTANCE}}),
                )
                .await?;
        }
        return Ok(json!({"removed_instance": removed, "plugin_left_at": plugin}));
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
    let launch = format!("--plugin-dir {} --agent squircle:app-agent", quote(&plugin));
    config.insert("launchArgs".into(), json!(launch));
    let instance = json!({"driver": CLAUDE, "displayName": "Squircle agent", "config": config});
    client
        .call(
            "server.updateSettings",
            json!({"patch": {}, "providerInstanceMutation": {"operation": "upsert", "instanceId": INSTANCE, "instance": instance}}),
        )
        .await?;
    Ok(
        json!({"plugin": plugin, "instance": INSTANCE, "launch_args": launch,
              "squircle_on_path": on_path.as_ref().ok(), "squircle_not_on_path": on_path.as_ref().err(), "invocation": cli,
              "note": "T3 now offers a \"Squircle agent\" Claude instance on your existing Claude login. Run with --remove to take it out."}),
    )
}
