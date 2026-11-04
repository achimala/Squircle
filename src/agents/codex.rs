//! The Codex side of `agent setup`: T3's "squircle-codex" instance and the
//! approval of its hooks. Codex has no agent definition or plugin flag like
//! Claude's `--plugin-dir`, so the instance carries Squircle's hooks (the
//! per-turn note and the guard) as `-c` overrides in its launch arguments:
//! only Codex sessions T3 starts on that instance load them, never workers
//! or the user's own Codex. Codex runs no hook until it is approved, and it
//! reads approvals only from its home's own settings, so setup asks Codex
//! itself (`codex app-server`: `hooks/list` for each hook's key and hash,
//! `config/batchWrite` to record it) to approve exactly these hooks; the
//! user agreed to that (2026-11-04). Nothing else in Codex's settings changes.

use super::*;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout};

/// T3's built-in Codex instance, and its driver.
const CODEX: &str = "codex";

/// Codex's hook events Squircle uses, and the subcommand each runs.
const HOOKS: [(&str, &str); 3] = [
    ("SessionStart", "agent context --hook"),
    ("UserPromptSubmit", "agent context --hook"),
    ("PreToolUse", "agent guard"),
];

/// The launch arguments of Squircle's Codex instance: no subagents (the
/// agent delegates through T3 workers, and has no history subagent on
/// Codex) and the hooks, which call the data directory's wrapper so a
/// rebuilt binary keeps their approval.
pub(super) fn launch_args(root: &Path) -> String {
    let squircle = quote(&wrapper(root));
    let mut args = vec!["--disable".to_string(), "multi_agent".to_string()];
    for (event, command) in HOOKS {
        // The note is longer than Codex's default inline limit; 0 keeps it inline.
        let limit = if command.starts_with("agent context") {
            ",additionalContextLimit=0"
        } else {
            ""
        };
        args.push("-c".into());
        args.push(t3_arg(&format!(
            "hooks.{event}=[{{hooks=[{{type=\"command\",command={},timeout=20{limit}}}]}}]",
            toml_string(&format!("{squircle} {command}"))
        )));
    }
    args.join(" ")
}

/// A TOML basic string.
fn toml_string(text: &str) -> String {
    let mut out = String::from("\"");
    for c in text.chars() {
        match c {
            '"' | '\\' => {
                out.push('\\');
                out.push(c);
            }
            c if c.is_control() => out.push_str(&format!("\\u{:04X}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// One argument as T3 splits launch arguments: double-quoted, with `"`, `\`,
/// `$` and `` ` `` escaped.
fn t3_arg(text: &str) -> String {
    let mut out = String::from("\"");
    for c in text.chars() {
        if matches!(c, '"' | '\\' | '$' | '`') {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('"');
    out
}

/// T3's launch-argument splitting, for running Codex as T3 would.
fn split_args(text: &str) -> Vec<String> {
    let (mut args, mut current, mut quote, mut quoted) = (Vec::new(), String::new(), None, false);
    let mut chars = text.trim().chars().peekable();
    while let Some(c) = chars.next() {
        match quote {
            Some(q) if c == q => quote = None,
            Some('"') if c == '\\' && matches!(chars.peek(), Some('"' | '\\' | '$' | '`')) => {
                current.push(chars.next().unwrap())
            }
            Some(_) => current.push(c),
            None if c == '\'' || c == '"' => {
                quote = Some(c);
                quoted = true;
            }
            None if c.is_whitespace() => {
                if !current.is_empty() || quoted {
                    args.push(std::mem::take(&mut current));
                    quoted = false;
                }
            }
            None => current.push(c),
        }
    }
    if !current.is_empty() || quoted {
        args.push(current);
    }
    args
}

/// The settings the Squircle instance copies from T3's built-in Codex
/// instance, so it runs the same binary on the same home and login.
fn builtin_config(instances: &Value) -> Result<serde_json::Map<String, Value>> {
    let builtin = match &instances[CODEX] {
        Value::Null => &Value::Null,
        builtin => {
            ensure!(
                builtin["driver"] == CODEX,
                "T3's {CODEX} provider instance has driver {}, not {CODEX}",
                builtin["driver"]
            );
            &builtin["config"]
        }
    };
    let mut config = serde_json::Map::new();
    for key in ["binaryPath", "homePath", "shadowHomePath"] {
        match &builtin[key] {
            Value::Null => {}
            Value::String(value) if value.trim().is_empty() => {}
            Value::String(value) => {
                config.insert(key.into(), json!(value));
            }
            other => bail!("T3's {CODEX} {key} is not a string: {other}"),
        }
    }
    Ok(config)
}

/// Adds (or updates) the instance and approves its hooks.
pub(super) async fn setup(client: &T3, instances: &Value, root: &Path) -> Result<Value> {
    let mut config = builtin_config(instances)?;
    let launch = launch_args(root);
    config.insert("launchArgs".into(), json!(launch));
    let instance =
        json!({"driver": CODEX, "displayName": "Squircle agent (Codex)", "config": config});
    // The instance first: a refusal from T3 leaves no approval behind.
    client
        .call(
            "server.updateSettings",
            json!({"patch": {}, "providerInstanceMutation": {"operation": "upsert", "instanceId": CODEX_INSTANCE, "instance": instance}}),
        )
        .await?;
    let approved = approve(&config, root, true)
        .await
        .context("T3 has the Codex agent instance, but its hooks are not approved, so they won't run; run agent setup again")?;
    Ok(json!({"instance": CODEX_INSTANCE, "launch_args": launch, "approved_hooks": approved}))
}

/// Takes the instance out, and the approval of its hooks.
pub(super) async fn remove(client: &T3, instances: &Value, root: &Path) -> Result<Value> {
    let mut config = builtin_config(instances)?;
    config.insert("launchArgs".into(), json!(launch_args(root)));
    let unapproved = approve(&config, root, false).await?;
    let removed = instances.get(CODEX_INSTANCE).is_some();
    if removed {
        client
            .call(
                "server.updateSettings",
                json!({"patch": {}, "providerInstanceMutation": {"operation": "remove", "instanceId": CODEX_INSTANCE}}),
            )
            .await?;
    }
    Ok(json!({"removed_instance": removed, "unapproved_hooks": unapproved}))
}

/// Records (or, with `approve` false, removes) Codex's approval of the
/// instance's hooks, through a `codex app-server` started as T3 starts the
/// instance. Returns the hook keys it changed.
async fn approve(
    config: &serde_json::Map<String, Value>,
    root: &Path,
    approve: bool,
) -> Result<Vec<String>> {
    let binary = config
        .get("binaryPath")
        .and_then(Value::as_str)
        .unwrap_or(CODEX);
    let mut command = Process::new(binary);
    command
        .arg("app-server")
        .args(split_args(
            config["launchArgs"].as_str().unwrap_or_default(),
        ))
        .current_dir(root)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    // T3 sets CODEX_HOME to the shadow home if there is one, else a custom home.
    if let Some(home) = ["shadowHomePath", "homePath"]
        .iter()
        .find_map(|k| config.get(*k).and_then(Value::as_str))
    {
        let home = match home.strip_prefix("~/") {
            Some(rest) => dirs::home_dir().context("no home directory")?.join(rest),
            None => PathBuf::from(home),
        };
        command.env("CODEX_HOME", home);
    }
    let mut codex = AppServer::start(command)
        .await
        .with_context(|| format!("Could not run {binary} app-server"))?;
    let ours = |codex_hooks: &Value| -> Vec<(String, String, String)> {
        codex_hooks["data"]
            .as_array()
            .into_iter()
            .flatten()
            .flat_map(|entry| entry["hooks"].as_array().into_iter().flatten())
            .filter(|h| h["source"] == "sessionFlags")
            .filter(|h| {
                h["command"]
                    .as_str()
                    .is_some_and(|c| HOOKS.iter().any(|(_, sub)| c.ends_with(sub)))
            })
            .filter_map(|h| {
                Some((
                    h["key"].as_str()?.to_string(),
                    h["currentHash"].as_str()?.to_string(),
                    h["trustStatus"].as_str().unwrap_or_default().to_string(),
                ))
            })
            .collect()
    };
    let cwd = root.display().to_string();
    let hooks = ours(&codex.call("hooks/list", json!({"cwds": [cwd]})).await?);
    ensure!(
        hooks.len() == HOOKS.len(),
        "Codex lists {} of Squircle's {} hooks for its instance; this Codex may not support hooks (Squircle needs Codex 0.160 or later)",
        hooks.len(),
        HOOKS.len()
    );
    let keys: Vec<String> = hooks.iter().map(|(key, ..)| key.clone()).collect();
    if approve {
        let state: serde_json::Map<String, Value> = hooks
            .iter()
            .map(|(key, hash, _)| (key.clone(), json!({"trusted_hash": hash})))
            .collect();
        codex
            .call("config/batchWrite", json!({"edits": [{"keyPath": "hooks.state", "mergeStrategy": "upsert", "value": state}]}))
            .await?;
        let after = ours(&codex.call("hooks/list", json!({"cwds": [cwd]})).await?);
        let untrusted: Vec<&str> = after
            .iter()
            .filter(|(.., status)| status != "trusted")
            .map(|(key, ..)| key.as_str())
            .collect();
        ensure!(
            untrusted.is_empty(),
            "Codex still doesn't trust Squircle's hooks {}",
            untrusted.join(", ")
        );
    } else {
        let read = codex
            .call("config/read", json!({"includeLayers": true}))
            .await?;
        let user = read["layers"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|layer| layer["name"]["type"] == "user");
        let Some(mut state) = user.and_then(|l| l["config"]["hooks"]["state"].as_object().cloned())
        else {
            return Ok(vec![]);
        };
        let before = state.len();
        state.retain(|key, _| !keys.contains(key));
        if state.len() == before {
            return Ok(vec![]);
        }
        codex
            .call("config/batchWrite", json!({"edits": [{"keyPath": "hooks.state", "mergeStrategy": "replace", "value": state}]}))
            .await?;
    }
    Ok(keys)
}

/// A `codex app-server` spoken to over stdio JSON-RPC; killed when dropped.
struct AppServer {
    _child: Child,
    input: ChildStdin,
    output: Lines<BufReader<ChildStdout>>,
    next: u64,
}

impl AppServer {
    async fn start(mut command: Process) -> Result<Self> {
        let mut child = command.spawn()?;
        let input = child.stdin.take().context("no stdin")?;
        let output = BufReader::new(child.stdout.take().context("no stdout")?).lines();
        let mut server = Self {
            _child: child,
            input,
            output,
            next: 0,
        };
        server
            .call(
                "initialize",
                json!({"clientInfo": {"name": "squircle", "version": env!("CARGO_PKG_VERSION")}}),
            )
            .await?;
        server.send(&json!({"method": "initialized"})).await?;
        Ok(server)
    }

    async fn send(&mut self, message: &Value) -> Result<()> {
        let mut line = serde_json::to_vec(message)?;
        line.push(b'\n');
        self.input.write_all(&line).await?;
        Ok(())
    }

    /// Sends a request and reads until its answer; notifications in between are skipped.
    async fn call(&mut self, method: &str, params: Value) -> Result<Value> {
        self.next += 1;
        let id = self.next;
        self.send(&json!({"id": id, "method": method, "params": params}))
            .await?;
        while let Some(line) = self.output.next_line().await? {
            let Ok(message) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            if message["id"] != id {
                continue;
            }
            if let Some(error) = message.get("error") {
                bail!(
                    "Codex refused {method}: {}",
                    error["message"].as_str().unwrap_or("no reason given")
                );
            }
            return Ok(message["result"].clone());
        }
        bail!("Codex's app-server exited before answering {method}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// T3 must hand Codex each hook override as one argument, exactly.
    #[test]
    fn launch_args_survive_t3s_splitting() {
        let root = Path::new("/tmp/squircle data/it's");
        let args = split_args(&launch_args(root));
        assert_eq!(args[..2], ["--disable", "multi_agent"]);
        assert_eq!(args.len(), 2 + 2 * HOOKS.len());
        assert_eq!(
            args[3],
            format!(
                "hooks.SessionStart=[{{hooks=[{{type=\"command\",command={},timeout=20,additionalContextLimit=0}}]}}]",
                toml_string(&format!("{} agent context --hook", quote(&wrapper(root))))
            )
        );
        assert!(args[7].contains("agent guard\",timeout=20}"));
    }
}
