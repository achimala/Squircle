use super::*;

/// T3's runtime modes. A new app agent gets the one the user chose, or
/// `full-access`; a fresh start keeps its predecessor's, and workers inherit
/// their agent's. A thread whose mode T3 doesn't report is never given one.
pub(super) const RUNTIME_MODES: [&str; 4] = [
    "approval-required",
    "auto-accept-edits",
    "auto",
    "full-access",
];

pub(super) const AGENT_MODE: &str = "full-access";

pub(super) fn runtime_mode(mode: Option<&str>) -> Result<String> {
    let mode = mode.unwrap_or(AGENT_MODE);
    ensure!(
        RUNTIME_MODES.contains(&mode),
        "Unknown runtime mode \"{mode}\". Modes: {}",
        RUNTIME_MODES.join(", ")
    );
    Ok(mode.into())
}

/// A worker's runtime mode, and what T3 makes of it on the worker's provider
/// (its driver): the mode asked for, else its coordinator's. Claude, Codex,
/// Cursor and Grok each have an `auto` that runs unattended behind the
/// provider's own checks; Antigravity's would ask before everything, so an
/// inherited `auto` takes its auto-edit mode there. A worker that hits an
/// approval prompt waits as needs-you for the user.
pub(super) fn worker_mode(
    driver: &str,
    coordinator: Option<&str>,
    requested: Option<&str>,
) -> Result<(String, &'static str)> {
    let mode = match requested {
        Some(mode) => runtime_mode(Some(mode))?,
        None => match coordinator.filter(|mode| RUNTIME_MODES.contains(mode)) {
            Some("auto") if driver == "antigravity" => "auto-accept-edits".into(),
            Some(mode) => mode.into(),
            None => bail!(
                "T3 doesn't report a runtime mode this service knows for the app agent ({}), so the worker can't inherit it; \
                           pass --runtime-mode",
                coordinator.unwrap_or("none")
            ),
        },
    };
    let permissions = match (driver, mode.as_str()) {
        ("claudeAgent", "approval-required") => {
            "Claude Code default: asks before edits and commands"
        }
        ("claudeAgent", "auto-accept-edits") => {
            "Claude Code acceptEdits: edits freely, asks before commands"
        }
        ("claudeAgent", "auto") => {
            "Claude Code auto: runs unattended; its safety checks block risky actions"
        }
        ("codex", "approval-required") => "Codex read-only sandbox; asks before anything else",
        ("codex", "auto-accept-edits") => "Codex workspace-write sandbox; asks before leaving it",
        ("codex", "auto") => {
            "Codex workspace-write sandbox; Codex's auto-reviewer decides on leaving it"
        }
        ("codex", _) => "Codex without a sandbox; never asks",
        ("cursor", "auto") => "Cursor auto-review: runs unattended; its reviewer checks actions",
        ("grok", "auto") => "Grok auto: runs unattended behind its own checks",
        ("antigravity", "auto-accept-edits") => {
            "Antigravity auto_edit: edits freely, asks before commands"
        }
        ("opencode", "full-access") => "OpenCode: allows everything",
        ("opencode", _) => "OpenCode: asks before everything except reads",
        (_, "full-access") => "No checks; never asks",
        (_, "approval-required") => "Asks before edits and commands",
        _ => "Asks before some actions",
    };
    Ok((mode, permissions))
}

/// A worker's T3 model selection, checked against the providers T3 reports
/// ready. Claude by default, on the app agent's model; another provider
/// defaults to its own default model. Squircle's own instance carries the
/// app-agent plugin (and its Codex one Squircle's hooks), so they are not
/// offered to workers.
pub(super) fn worker_selection(
    config: &Value,
    provider: Option<&str>,
    model: Option<&str>,
    effort: Option<&str>,
    agent_model: Option<&str>,
) -> Result<Value> {
    let ready: Vec<&Value> = config["providers"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|p| {
            p["status"] == "ready"
                && p["enabled"] != false
                && !p["instanceId"].as_str().is_some_and(agent_instance)
        })
        .collect();
    let names = |items: Vec<&str>| items.join(", ");
    let instance = provider.unwrap_or("claudeAgent");
    let provider = ready
        .iter()
        .find(|p| p["instanceId"] == instance)
        .with_context(|| {
            format!(
                "T3 has no ready provider \"{instance}\". Ready: {}",
                names(
                    ready
                        .iter()
                        .filter_map(|p| p["instanceId"].as_str())
                        .collect()
                )
            )
        })?;
    let models: Vec<&Value> = provider["models"]
        .as_array()
        .into_iter()
        .flatten()
        .collect();
    let model = model
        .map(str::to_string)
        .or_else(|| match instance {
            "claudeAgent" => Some(agent_model.unwrap_or(DEFAULT_MODEL).to_string()),
            _ => models
                .iter()
                .find(|m| m["isDefault"] == true)
                .or(models.first())
                .and_then(|m| m["slug"].as_str())
                .map(str::to_string),
        })
        .with_context(|| format!("T3 lists no models for \"{instance}\""))?;
    let entry = models
        .iter()
        .find(|m| m["slug"] == model.as_str())
        .with_context(|| {
            format!(
                "\"{instance}\" has no model \"{model}\". Models: {}",
                names(models.iter().filter_map(|m| m["slug"].as_str()).collect())
            )
        })?;
    let mut selection = json!({"instanceId": instance, "model": model});
    if let Some(effort) = effort {
        // Claude calls it "effort", Codex "reasoningEffort".
        let option = entry["capabilities"]["optionDescriptors"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|o| {
                o["type"] == "select"
                    && matches!(o["id"].as_str(), Some("effort" | "reasoningEffort"))
            })
            .with_context(|| format!("{model} has no reasoning effort setting"))?;
        let levels: Vec<&str> = option["options"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|o| o["id"].as_str())
            .collect();
        ensure!(
            levels.contains(&effort),
            "{model} has no effort \"{effort}\". Levels: {}",
            names(levels)
        );
        selection["options"] = json!([{"id": option["id"], "value": effort}]);
    }
    Ok(selection)
}

/// Which of Squircle's instances an app agent runs on.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Provider {
    Claude,
    Codex,
}

impl Provider {
    /// `claude` or `codex` (T3's instance and driver names are taken too).
    pub fn parse(name: &str) -> Result<Self> {
        match name {
            "claude" | "claudeAgent" | INSTANCE => Ok(Self::Claude),
            "codex" | CODEX_INSTANCE => Ok(Self::Codex),
            other => bail!("Unknown agent provider \"{other}\". Providers: claude, codex"),
        }
    }

    /// The provider of a thread's model selection, if it is an agent instance.
    pub fn of(selection: &Value) -> Option<Self> {
        match selection["instanceId"].as_str()? {
            INSTANCE => Some(Self::Claude),
            CODEX_INSTANCE => Some(Self::Codex),
            _ => None,
        }
    }

    pub fn instance(self) -> &'static str {
        match self {
            Self::Claude => INSTANCE,
            Self::Codex => CODEX_INSTANCE,
        }
    }

    /// T3's built-in instance of the same driver, whose models a project's
    /// default selection names.
    fn builtin(self) -> &'static str {
        match self {
            Self::Claude => "claudeAgent",
            Self::Codex => "codex",
        }
    }

    /// Refuses `mode` for an agent on this provider. T3 gives Codex its
    /// sandbox with every turn, and only full access lets it reach the
    /// Squircle service the agent's `squircle` commands talk to.
    pub fn check_mode(self, mode: Option<&str>) -> Result<()> {
        ensure!(
            self != Self::Codex || mode == Some("full-access"),
            "A Codex app agent needs full access (its approvals are {}): in any other mode Codex's sandbox blocks the \
             `squircle` commands it coordinates with. Set the agent's approvals to Full access first.",
            mode.unwrap_or("unknown")
        );
        Ok(())
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Claude => "Claude",
            Self::Codex => "Codex",
        }
    }
}

/// An app agent's model selection on `provider`'s instance, checked against
/// what T3 reports ready: `model` if given, else the project's default when
/// it is on the same driver, else Claude's default (Claude) or the
/// instance's default model.
pub(super) fn agent_selection(
    config: &Value,
    provider: Provider,
    model: Option<&str>,
    project_default: &Value,
) -> Result<Value> {
    let instance = provider.instance();
    let entry = config["providers"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|p| p["instanceId"] == instance && p["status"] == "ready" && p["enabled"] != false)
        .with_context(|| {
            format!("T3 has no ready \"{instance}\" agent instance. Run: squircle agent setup")
        })?;
    let models: Vec<&str> = entry["models"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|m| m["slug"].as_str())
        .collect();
    let model = match model {
        Some(model) => model.to_string(),
        None => project_default["model"]
            .as_str()
            .filter(|_| project_default["instanceId"] == provider.builtin())
            .map(str::to_string)
            .or_else(|| (provider == Provider::Claude).then(|| DEFAULT_MODEL.to_string()))
            .filter(|m| models.is_empty() || models.contains(&m.as_str()))
            .or_else(|| {
                let all = entry["models"].as_array()?;
                let default = all
                    .iter()
                    .find(|m| m["isDefault"] == true)
                    .or(all.first())?;
                default["slug"].as_str().map(str::to_string)
            })
            .with_context(|| format!("T3 lists no models for \"{instance}\""))?,
    };
    ensure!(
        models.is_empty() || models.contains(&model.as_str()),
        "\"{instance}\" has no model \"{model}\". Models: {}",
        models.join(", ")
    );
    Ok(json!({"instanceId": instance, "model": model}))
}
