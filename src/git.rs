//! The one way the service runs git.

use std::{path::Path, time::Duration};

use anyhow::{Context, Result, ensure};

/// What a git command run through [`text`] may take and print.
const LIMIT: Duration = Duration::from_secs(120);
const MAX_OUTPUT: usize = 32 * 1024 * 1024;

/// Runs `/usr/bin/git -C dir args…` under `xcode::run_bounded` (deadline,
/// output cap, its whole process group killed if dropped), configured by
/// nothing but the repository: `GIT_*` variables are removed, a configured
/// fsmonitor is not started, there is no pager or prompt, and optional index
/// locks are skipped so a read never contends with the user's git. Callers
/// pass `--no-ext-diff --no-textconv` where git would diff.
pub(crate) async fn run(dir: &Path, args: &[&str], limit: Duration, max_output: usize) -> Result<Vec<u8>> {
    let mut command = tokio::process::Command::new("/usr/bin/git");
    for (name, _) in std::env::vars_os() {
        if name.to_string_lossy().starts_with("GIT_") { command.env_remove(name); }
    }
    command.env("GIT_TERMINAL_PROMPT", "0").env("GIT_OPTIONAL_LOCKS", "0")
        .args(["-c", "core.fsmonitor=false", "--no-pager", "-C"]).arg(dir).args(args);
    let output = crate::xcode::run_bounded(
        command,
        crate::xcode::Sink::Capture(max_output),
        crate::xcode::Sink::Capture(64 * 1024),
        tokio::time::Instant::now() + limit,
        None,
    )
    .await
    .with_context(|| format!("running git {}", args.join(" ")))?;
    ensure!(output.status.success(), "git {}: {}", args.join(" "), String::from_utf8_lossy(&output.stderr).trim());
    Ok(output.stdout)
}

/// [`run`] with the ordinary bounds, as text.
pub(crate) async fn text(dir: &Path, args: &[&str]) -> Result<String> {
    Ok(String::from_utf8_lossy(&run(dir, args, LIMIT, MAX_OUTPUT).await?).into_owned())
}
