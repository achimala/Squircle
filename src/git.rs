//! The one way the service runs git.

use std::path::Path;

use anyhow::{Context, Result, ensure};

/// What a git command run through [`text`] may print.
const MAX_OUTPUT: usize = 32 * 1024 * 1024;

/// Runs `/usr/bin/git -C dir args…` under `crate::process::run_bounded` (output
/// cap, its whole process group killed if dropped), configured by
/// nothing but the repository: `GIT_*` variables are removed, a configured
/// fsmonitor is not started, there is no pager or prompt, and optional index
/// locks are skipped so a read never contends with the user's git. Callers
/// pass `--no-ext-diff --no-textconv` where git would diff.
pub(crate) async fn run(dir: &Path, args: &[&str], max_output: usize) -> Result<Vec<u8>> {
    let mut command = tokio::process::Command::new("/usr/bin/git");
    for (name, _) in std::env::vars_os() {
        if name.to_string_lossy().starts_with("GIT_") {
            command.env_remove(name);
        }
    }
    command
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .args(["-c", "core.fsmonitor=false", "--no-pager", "-C"])
        .arg(dir)
        .args(args);
    // Tests never read the user's git configuration (signing, hooks,
    // templates) or run hooks.
    if cfg!(test) {
        command.envs(ISOLATED);
    }
    let output = crate::process::run_bounded(
        command,
        crate::process::Sink::Capture(max_output),
        crate::process::Sink::Capture(64 * 1024),
        None,
    )
    .await
    .with_context(|| format!("running git {}", args.join(" ")))?;
    ensure!(
        output.status.success(),
        "git {}: {}",
        args.join(" "),
        String::from_utf8_lossy(&output.stderr).trim()
    );
    Ok(output.stdout)
}

/// The environment that keeps a git command away from the user's and the
/// system's configuration and hooks.
const ISOLATED: [(&str, &str); 5] = [
    ("GIT_CONFIG_GLOBAL", "/dev/null"),
    ("GIT_CONFIG_NOSYSTEM", "1"),
    ("GIT_CONFIG_COUNT", "1"),
    ("GIT_CONFIG_KEY_0", "core.hooksPath"),
    ("GIT_CONFIG_VALUE_0", "/dev/null"),
];

/// [`run`] with the ordinary bounds, as text.
pub(crate) async fn text(dir: &Path, args: &[&str]) -> Result<String> {
    Ok(String::from_utf8_lossy(&run(dir, args, MAX_OUTPUT).await?).into_owned())
}

/// `path` as it sits in its repository's main checkout, when it is inside a
/// linked worktree (`git worktree add`, as T3 makes them) and exists there
/// too. Read from the worktree's `.git` file and `commondir`, the way git
/// finds them, without running git; None for a main checkout, a submodule, a
/// bare repository's worktree or a path outside any repository.
pub(crate) fn main_checkout(path: &Path) -> Option<std::path::PathBuf> {
    let path = path.canonicalize().ok()?;
    let top = path.ancestors().find(|dir| dir.join(".git").exists())?;
    let link = std::fs::read_to_string(top.join(".git")).ok()?;
    let gitdir = top.join(link.strip_prefix("gitdir:")?.trim());
    let common = std::fs::read_to_string(gitdir.join("commondir")).ok()?;
    let common = gitdir.join(common.trim()).canonicalize().ok()?;
    if common.file_name()? != ".git" {
        return None;
    }
    let main = common.parent()?.join(path.strip_prefix(top).ok()?);
    (main != path && main.exists()).then_some(main)
}

#[cfg(test)]
mod tests {
    use super::main_checkout;
    use std::process::Command;

    #[test]
    fn a_worktree_path_maps_to_the_main_checkout() {
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        let main = root.join("main");
        std::fs::create_dir_all(main.join("ios/App.xcodeproj")).unwrap();
        std::fs::write(main.join("ios/App.xcodeproj/project.pbxproj"), "").unwrap();
        let git = |args: &[&str]| {
            let mut command = Command::new("/usr/bin/git");
            command
                .arg("-C")
                .arg(&main)
                .args(["-c", "user.name=t", "-c", "user.email=t@t"])
                .args(args)
                .env_remove("GIT_DIR")
                .env_remove("GIT_WORK_TREE");
            command.envs(super::ISOLATED);
            let status = command.output().unwrap();
            assert!(status.status.success(), "{status:?}");
        };
        git(&["init", "-q"]);
        git(&["add", "."]);
        git(&["commit", "-qm", "init"]);
        let tree = root.join("worktrees/feature");
        git(&["worktree", "add", "-q", tree.to_str().unwrap()]);
        let project = tree.join("ios/App.xcodeproj");
        assert_eq!(
            main_checkout(&project),
            Some(main.join("ios/App.xcodeproj"))
        );
        assert_eq!(main_checkout(&main.join("ios/App.xcodeproj")), None);
        // Only in the branch: nothing in the main checkout to belong to.
        std::fs::create_dir_all(tree.join("ios/New.xcodeproj")).unwrap();
        assert_eq!(main_checkout(&tree.join("ios/New.xcodeproj")), None);
    }
}
