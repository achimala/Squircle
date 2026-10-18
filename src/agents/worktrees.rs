use super::*;

pub(super) async fn git(dir: &Path, args: &[&str]) -> Result<String> {
    Ok(crate::git::text(dir, args).await?.trim().to_string())
}

/// A worker's branch and worktree as git sees them.
#[derive(Debug, Default)]
pub(super) struct GitState {
    pub(super) branch: Option<String>,
    pub(super) branch_exists: bool,
    /// The branch tip that was checked; deletion refuses a branch that moved.
    pub(super) tip: Option<String>,
    /// Commits on the branch whose work is not known to be in its base:
    /// none if the base contains the tip; otherwise `git cherry`'s unmatched
    /// commits (so rebased or cherry-picked merges count as merged) plus
    /// every merge commit, whose resolution `cherry` cannot compare.
    pub(super) unmerged: usize,
    /// The worktree, if it still exists, and its uncommitted files.
    pub(super) worktree: Option<PathBuf>,
    pub(super) dirty: usize,
}

impl GitState {
    pub(super) fn blocker(&self) -> Option<String> {
        let mut reasons = vec![];
        if self.unmerged > 0 {
            reasons.push(format!(
                "{} commit{} not merged",
                self.unmerged,
                if self.unmerged == 1 { "" } else { "s" }
            ));
        }
        if self.dirty > 0 {
            reasons.push(format!(
                "{} uncommitted file{}",
                self.dirty,
                if self.dirty == 1 { "" } else { "s" }
            ));
        }
        (!reasons.is_empty()).then(|| reasons.join(" and "))
    }
}

pub(super) async fn inspect(
    root: &Path,
    worktree: Option<&Path>,
    branch: Option<&str>,
    base: Option<&str>,
) -> Result<GitState> {
    let mut state = GitState::default();
    if let Some(path) = worktree.filter(|p| p.exists()) {
        state.dirty = git(path, &["status", "--porcelain"]).await?.lines().count();
        state.worktree = Some(path.to_path_buf());
    }
    let Some(branch) = branch.filter(|b| !b.is_empty()) else {
        return Ok(state);
    };
    state.branch = Some(branch.into());
    state.tip = git(
        root,
        &[
            "rev-parse",
            "--verify",
            "--quiet",
            &format!("refs/heads/{branch}^{{commit}}"),
        ],
    )
    .await
    .ok();
    state.branch_exists = state.tip.is_some();
    if let Some(tip) = &state.tip {
        let base = base.context("The worker has no base branch to compare with")?;
        ensure!(base != branch, "The worker's branch is its base");
        let contained = Process::new("git")
            .arg("-C")
            .arg(root)
            .args(["merge-base", "--is-ancestor", tip, base])
            .status()
            .await?
            .success();
        if !contained {
            let compare = |args: Vec<String>| async move {
                git(root, &args.iter().map(String::as_str).collect::<Vec<_>>())
                    .await
                    .with_context(|| format!("Cannot compare {branch} with {base}"))
            };
            let picked = compare(vec!["cherry".into(), base.into(), tip.clone()])
                .await?
                .lines()
                .filter(|l| l.starts_with('+'))
                .count();
            let merges = compare(vec![
                "rev-list".into(),
                "--merges".into(),
                "--count".into(),
                format!("{base}..{tip}"),
            ])
            .await?
            .parse::<usize>()
            .unwrap_or(1);
            state.unmerged = picked + merges;
        }
    }
    Ok(state)
}

#[derive(Default)]
pub(super) struct Removed {
    pub(super) worktree: Option<PathBuf>,
    pub(super) branch: Option<String>,
}

/// Removes what `inspect` found. Without `discard`, git itself refuses to
/// drop uncommitted changes, and the branch is deleted only at the tip that
/// was checked (`branch -D` also refuses one checked out elsewhere).
/// Proof that T3 reported the worker's session stopped (or no thread at
/// all) on the live shell; only `Agents::stopped` makes one, and removing a
/// worker's files takes one.
pub(super) struct StopReceipt(pub(super) ());

pub(super) async fn remove(
    root: &Path,
    state: &GitState,
    discard: bool,
    _stopped: &StopReceipt,
) -> Result<Removed> {
    let mut removed = Removed::default();
    if let Some(path) = &state.worktree {
        let path = path.to_string_lossy();
        let mut args = vec!["worktree", "remove"];
        if discard {
            args.push("--force");
        }
        args.push(&path);
        git(root, &args).await?;
        removed.worktree = state.worktree.clone();
    }
    git(root, &["worktree", "prune"]).await?;
    if let (Some(branch), Some(tip)) = (state.branch.as_deref(), state.tip.as_deref()) {
        let now = git(
            root,
            &[
                "rev-parse",
                "--verify",
                "--quiet",
                &format!("refs/heads/{branch}^{{commit}}"),
            ],
        )
        .await
        .ok();
        if now.is_some() {
            ensure!(
                now.as_deref() == Some(tip),
                "{branch} moved while it was being archived; nothing more was deleted"
            );
            // `inspect` checked it is merged (`branch -d` doesn't understand
            // rebased merges) or the caller chose to discard it.
            git(root, &["branch", "-D", branch]).await?;
            removed.branch = Some(branch.into());
        }
    }
    Ok(removed)
}
