//! The service side of visual gates (docs/task-tracking.md#gates): reading
//! an agent's `plan.md` and a reviewer's `review-N.md`, keeping each round
//! as handed in (its digest is what an approval names), filming a change,
//! the one merge onto the base branch, and following each reviewed branch's
//! ref so a moved branch voids its review. The decisions themselves are the
//! tasks owner's (`crate::fsm::tasks::gates`).

use crate::tasks::{ChangeLine, Finding, Mark, PlanChange, PlanDraft, ReviewDraft, Verdict};
use anyhow::{Context, Result, bail, ensure};
use sha2::{Digest, Sha256};
use std::path::{Component, Path, PathBuf};

// MARK: plan.md

/// A plan as written: `# Title`, a few sentences, its pictures as Markdown
/// images, then `## Changes` with one numbered line per change and, under
/// each, an `asks:` line naming the asks it answers.
#[derive(Debug, PartialEq)]
pub struct PlanDoc {
    pub title: String,
    pub summary: String,
    pub pictures: Vec<String>,
    pub changes: Vec<(u32, String, Vec<String>)>,
}

/// The `![..](path)` images on a line, in order.
fn images(line: &str) -> Vec<String> {
    let mut out = vec![];
    let mut rest = line;
    while let Some(start) = rest.find("![") {
        rest = &rest[start + 2..];
        let Some(close) = rest.find("](") else { break };
        rest = &rest[close + 2..];
        let Some(end) = rest.find(')') else { break };
        let path = rest[..end].split_whitespace().next().unwrap_or("");
        if !path.is_empty() {
            out.push(path.to_string());
        }
        rest = &rest[end + 1..];
    }
    out
}

/// `12. Title` → (12, "Title").
fn numbered(line: &str) -> Option<(u32, String)> {
    let line = line.trim_start();
    let digits: String = line.chars().take_while(char::is_ascii_digit).collect();
    let rest = line[digits.len()..].strip_prefix(['.', ')'])?;
    Some((digits.parse().ok()?, rest.trim().to_string()))
}

fn heading(line: &str, level: usize) -> Option<&str> {
    let hashes = "#".repeat(level);
    let rest = line.strip_prefix(&hashes)?;
    (rest.starts_with(' ')).then(|| rest.trim())
}

pub fn parse_plan(text: &str) -> Result<PlanDoc> {
    let mut title = None;
    let mut summary = vec![];
    let mut pictures = vec![];
    let mut changes: Vec<(u32, String, Vec<String>)> = vec![];
    let mut in_changes = false;
    for line in text.lines() {
        pictures.extend(images(line));
        if let Some(h) = heading(line, 1) {
            title.get_or_insert_with(|| h.to_string());
            continue;
        }
        if let Some(h) = heading(line, 2) {
            in_changes = h.eq_ignore_ascii_case("changes");
            continue;
        }
        if in_changes {
            if let Some((n, title)) = numbered(line).filter(|_| !line.starts_with([' ', '\t'])) {
                changes.push((n, title, vec![]));
            } else if let Some(refs) = line
                .trim()
                .strip_prefix("asks:")
                .or_else(|| line.trim().strip_prefix("Asks:"))
                .or_else(|| line.trim().strip_prefix("ask:"))
            {
                let Some(last) = changes.last_mut() else {
                    bail!("An `asks:` line must sit under a numbered change");
                };
                last.2.extend(
                    refs.split([',', ' '])
                        .map(str::trim)
                        .filter(|r| !r.is_empty())
                        .map(str::to_string),
                );
            }
        } else if title.is_some() && !line.trim().is_empty() && images(line).is_empty() {
            summary.push(line.trim().to_string());
        }
    }
    let title = title.context("plan.md starts with `# Title`")?;
    ensure!(
        !changes.is_empty(),
        "plan.md needs a `## Changes` section with numbered changes (`1. …`)"
    );
    Ok(PlanDoc {
        title,
        summary: summary.join(" "),
        pictures,
        changes,
    })
}

/// The ask IDs `refs` name: `item` for the item's own ask, or an ID or a
/// unique prefix of at least six characters of one of `open`.
pub fn resolve_asks(refs: &[String], item: &str, open: &[String]) -> Result<Vec<String>> {
    let mut out = vec![];
    for r in refs {
        let id = if r.eq_ignore_ascii_case("item") {
            item.to_string()
        } else {
            ensure!(
                r.len() >= 6,
                "`{r}` is too short: name an ask by its ID or its first 8 characters"
            );
            let found: Vec<&String> = open.iter().filter(|a| a.starts_with(r.as_str())).collect();
            match found.as_slice() {
                [one] => (*one).clone(),
                [] => bail!(
                    "`{r}` is not an open ask of this item (`squircle task show {item}` lists them)"
                ),
                _ => bail!("`{r}` names more than one ask; give more of its ID"),
            }
        };
        if !out.contains(&id) {
            out.push(id);
        }
    }
    Ok(out)
}

// MARK: review-N.md

/// A review as written: a heading or `Verdict:` line with PASS, REVISE or
/// BLOCKED, a few sentences, `## Plan vs actual` with one numbered line per
/// planned change marked ✓ (built), ≠ (built differently, with why) or ✗
/// (dropped, with why), and `## Findings` with one `### Title` per finding,
/// its picture, and `planned:`, `branch:` and `fix:` lines.
#[derive(Debug, PartialEq)]
pub struct ReviewDoc {
    pub verdict: Verdict,
    pub summary: String,
    pub lines: Vec<ChangeLine>,
    pub findings: Vec<Finding>,
    pub pictures: Vec<String>,
}

fn verdict_in(line: &str) -> Option<Verdict> {
    let upper = line.to_uppercase();
    [Verdict::Blocked, Verdict::Revise, Verdict::Pass]
        .into_iter()
        .find(|v| {
            upper
                .split(|c: char| !c.is_ascii_alphabetic())
                .any(|w| w == v.label())
        })
}

fn mark(text: &str) -> Option<(Mark, &str)> {
    let text = text.trim();
    for (marks, mark) in [
        (&["✓", "✔", "[x]", "built:"][..], Mark::Built),
        (&["≠", "~", "differs:", "differently:"][..], Mark::Differs),
        (&["✗", "✘", "×", "dropped:"][..], Mark::Dropped),
    ] {
        for m in marks {
            if let Some(rest) = text.strip_prefix(m) {
                return Some((mark, rest.trim()));
            }
        }
    }
    None
}

pub fn parse_review(text: &str) -> Result<ReviewDoc> {
    #[derive(PartialEq)]
    enum Part {
        Top,
        Lines,
        Findings,
        Other,
    }
    let mut verdict = None;
    let mut part = Part::Top;
    let mut summary = vec![];
    let mut lines: Vec<ChangeLine> = vec![];
    let mut findings: Vec<Finding> = vec![];
    let mut pictures = vec![];
    for line in text.lines() {
        let found = images(line);
        pictures.extend(found.iter().cloned());
        if let Some(h) = heading(line, 1) {
            if verdict.is_none() {
                verdict = verdict_in(h);
            }
            continue;
        }
        if let Some(v) = line.trim().strip_prefix("Verdict:") {
            verdict = verdict_in(v).or(verdict);
            continue;
        }
        if let Some(h) = heading(line, 2) {
            let h = h.to_lowercase();
            part = if h.starts_with("plan vs") {
                Part::Lines
            } else if h.starts_with("finding") {
                Part::Findings
            } else {
                Part::Other
            };
            continue;
        }
        match part {
            Part::Top => {
                if !line.trim().is_empty() && found.is_empty() {
                    summary.push(line.trim().to_string());
                }
            }
            Part::Lines => {
                if let Some((n, rest)) = numbered(line).filter(|_| !line.starts_with([' ', '\t'])) {
                    let (mark, rest) = mark(&rest).with_context(|| {
                        format!("Plan vs actual line {n} needs ✓ (built), ≠ (built differently) or ✗ (dropped) before its text")
                    })?;
                    let (text, why) = match rest.split_once("why:") {
                        Some((t, w)) => {
                            (t.trim().trim_end_matches(['—', '-', ',']).trim(), w.trim())
                        }
                        None => (rest, ""),
                    };
                    lines.push(ChangeLine {
                        n,
                        mark,
                        text: text.to_string(),
                        why: why.to_string(),
                    });
                } else if let Some(why) = line.trim().strip_prefix("why:")
                    && let Some(last) = lines.last_mut()
                {
                    last.why = why.trim().to_string();
                }
            }
            Part::Findings => {
                if let Some(h) = heading(line, 3) {
                    findings.push(Finding {
                        title: h.to_string(),
                        picture: None,
                        planned: String::new(),
                        branch: String::new(),
                        fix: String::new(),
                    });
                    continue;
                }
                let Some(last) = findings.last_mut() else {
                    continue;
                };
                if let Some(p) = found.first() {
                    last.picture.get_or_insert_with(|| p.clone());
                }
                let entry = line.trim().trim_start_matches(['-', '*']).trim();
                for (key, field) in [
                    ("planned:", &mut last.planned),
                    ("branch:", &mut last.branch),
                    ("fix:", &mut last.fix),
                ] {
                    if let Some(value) = entry.strip_prefix(key) {
                        *field = value.trim().to_string();
                    }
                }
            }
            Part::Other => {}
        }
    }
    let verdict = verdict.context(
        "The review must say PASS, REVISE or BLOCKED in its `# ` heading or a `Verdict:` line",
    )?;
    for d in lines.iter().filter(|l| l.mark != Mark::Built) {
        ensure!(
            !d.why.is_empty(),
            "Plan vs actual line {} is built differently or dropped: say why (`why: …`)",
            d.n
        );
    }
    for f in &findings {
        ensure!(
            f.picture.is_some(),
            "Finding “{}” needs its picture (`![..](path)`)",
            f.title
        );
    }
    Ok(ReviewDoc {
        verdict,
        summary: summary.join(" "),
        lines,
        findings,
        pictures,
    })
}

// MARK: rounds as handed in

/// A relative path inside a round's folder, refused if it could leave it.
pub fn inside(rel: &str) -> Result<PathBuf> {
    let path = Path::new(rel);
    ensure!(
        !rel.is_empty()
            && path
                .components()
                .all(|c| matches!(c, Component::Normal(_) | Component::CurDir)),
        "`{rel}` must be a path inside the folder (no `..` or absolute paths)"
    );
    Ok(path.components().collect())
}

/// Copies `file` (in `from`) and `pictures` (relative to it) into a new
/// folder under `into`, named by their digest, which it returns with the
/// folder. Another hand-in with the same content lands in the same folder.
pub fn keep(
    from: &Path,
    file: &str,
    pictures: &[String],
    into: &Path,
) -> Result<(String, PathBuf)> {
    let mut hash = Sha256::new();
    let mut files = vec![(
        PathBuf::from(file),
        std::fs::read(from.join(file))
            .with_context(|| format!("Reading {}", from.join(file).display()))?,
    )];
    for picture in pictures {
        let rel = inside(picture)?;
        let bytes = std::fs::read(from.join(&rel))
            .with_context(|| format!("The picture {picture} isn't in {}", from.display()))?;
        files.push((rel, bytes));
    }
    for (rel, bytes) in &files {
        hash.update(rel.to_string_lossy().as_bytes());
        hash.update((bytes.len() as u64).to_le_bytes());
        hash.update(bytes);
    }
    let digest: String = hash.finalize().iter().map(|b| format!("{b:02x}")).collect();
    let dir = into.join(&digest[..16]);
    for (rel, bytes) in files {
        let path = dir.join(rel);
        crate::store::private_dir(path.parent().context("no parent")?)?;
        crate::store::write_private(&path, true, |out| {
            std::io::Write::write_all(out, &bytes)?;
            Ok(())
        })?;
    }
    Ok((digest, dir))
}

/// Where plan round `digest` of a task is kept.
pub fn plan_dir(task_dir: &Path, digest: &str) -> PathBuf {
    task_dir.join("plans").join(&digest[..digest.len().min(16)])
}

pub fn review_dir(task_dir: &Path, digest: &str) -> PathBuf {
    task_dir
        .join("reviews")
        .join(&digest[..digest.len().min(16)])
}

/// Reads `plan.md` in `dir`, ties its asks, and keeps it as a round.
pub fn hand_in_plan(dir: &Path, item: &str, open: &[String], task_dir: &Path) -> Result<PlanDraft> {
    let text = std::fs::read_to_string(dir.join("plan.md"))
        .with_context(|| format!("No plan.md in {}", dir.display()))?;
    let doc = parse_plan(&text)?;
    let mut changes = vec![];
    for (n, title, refs) in doc.changes {
        changes.push(PlanChange {
            n,
            title,
            asks: resolve_asks(&refs, item, open)?,
        });
    }
    let (digest, _) = keep(dir, "plan.md", &doc.pictures, &task_dir.join("plans"))?;
    Ok(PlanDraft {
        digest,
        title: doc.title,
        summary: doc.summary,
        pictures: doc.pictures,
        changes,
    })
}

/// Reads a review file and keeps it with its pictures.
pub fn hand_in_review(file: &Path, task_dir: &Path) -> Result<ReviewDraft> {
    let text =
        std::fs::read_to_string(file).with_context(|| format!("Reading {}", file.display()))?;
    let doc = parse_review(&text)?;
    let dir = file.parent().context("The review file has no folder")?;
    let name = file
        .file_name()
        .and_then(|n| n.to_str())
        .context("The review file has no name")?;
    let (digest, kept) = keep(dir, name, &doc.pictures, &task_dir.join("reviews"))?;
    if name != "review.md" {
        std::fs::rename(kept.join(name), kept.join("review.md"))
            .or_else(|_| std::fs::copy(kept.join(name), kept.join("review.md")).map(drop))?;
    }
    Ok(ReviewDraft {
        verdict: doc.verdict,
        digest,
        summary: doc.summary,
        lines: doc.lines,
        findings: doc.findings,
        pictures: doc.pictures,
    })
}

// MARK: per-app settings

/// `.squircle/gates.toml` in the app's repo: base branch, the reviewer,
/// the rule documents it enforces and the checks a merge runs.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Config {
    pub base: Option<String>,
    pub reviewer_provider: Option<String>,
    pub reviewer_model: Option<String>,
    pub reviewer_effort: Option<String>,
    pub rules: Vec<String>,
    pub checks: Vec<String>,
}

pub const CONFIG: &str = ".squircle/gates.toml";

fn toml_value(raw: &str) -> Option<Vec<String>> {
    let raw = raw.trim();
    let strings = |s: &str| -> Vec<String> {
        let mut out = vec![];
        let mut chars = s.chars();
        while let Some(c) = chars.next() {
            if c == '"' {
                let mut word = String::new();
                for c in chars.by_ref() {
                    if c == '"' {
                        break;
                    }
                    word.push(c);
                }
                out.push(word);
            }
        }
        out
    };
    if raw.starts_with('[') || raw.starts_with('"') {
        Some(strings(raw))
    } else {
        None
    }
}

pub fn parse_config(text: &str) -> Config {
    let mut config = Config::default();
    let mut section = String::new();
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('#') || line.is_empty() {
            continue;
        }
        if let Some(name) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
            section = name.trim().to_string();
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let Some(values) = toml_value(value) else {
            continue;
        };
        let one = values.first().cloned();
        match (section.as_str(), key.trim()) {
            ("", "base") => config.base = one,
            ("", "rules") => config.rules = values,
            ("", "checks") => config.checks = values,
            ("reviewer", "provider") => config.reviewer_provider = one,
            ("reviewer", "model") => config.reviewer_model = one,
            ("reviewer", "effort") => config.reviewer_effort = one,
            _ => {}
        }
    }
    config
}

pub fn config(repo: &Path) -> Config {
    std::fs::read_to_string(repo.join(CONFIG))
        .map(|t| parse_config(&t))
        .unwrap_or_default()
}

pub fn render_config(c: &Config) -> String {
    let list = |v: &[String]| {
        v.iter()
            .map(|s| format!("\"{}\"", s.replace('"', "'")))
            .collect::<Vec<_>>()
            .join(", ")
    };
    let mut out = String::from(
        "# Squircle's visual gates for this app (squircle help gates).\n# Every code change: plan approval, then merge approval; `squircle merge` is the only way onto `base`.\n",
    );
    if let Some(base) = &c.base {
        out.push_str(&format!("base = \"{base}\"\n"));
    }
    out.push_str(&format!(
        "# Documents the reviewer enforces.\nrules = [{}]\n",
        list(&c.rules)
    ));
    out.push_str(&format!(
        "# Run in the main checkout before a merge commits; any failure refuses it.\nchecks = [{}]\n",
        list(&c.checks)
    ));
    out.push_str("\n[reviewer]\n");
    for (key, value) in [
        ("provider", &c.reviewer_provider),
        ("model", &c.reviewer_model),
        ("effort", &c.reviewer_effort),
    ] {
        if let Some(value) = value {
            out.push_str(&format!("{key} = \"{value}\"\n"));
        }
    }
    out
}

/// The independent reviewer when an app names none: Codex's GPT-6 Astra.
pub const REVIEWER: (&str, &str, &str) = ("codex", "gpt-6-astra", "xhigh");

// MARK: git

/// Where `branch` points in `repo`, or None if it doesn't exist.
pub async fn head(repo: &Path, branch: &str) -> Result<Option<String>> {
    match crate::git::text(
        repo,
        &[
            "rev-parse",
            "--verify",
            "--quiet",
            &format!("refs/heads/{branch}^{{commit}}"),
        ],
    )
    .await
    {
        Ok(sha) => Ok(Some(sha.trim().to_string())),
        Err(_) => {
            // A missing ref and a broken repository look alike to rev-parse; tell them apart.
            crate::git::text(repo, &["rev-parse", "--git-dir"]).await?;
            Ok(None)
        }
    }
}

/// The folder holding `repo`'s refs (shared by its worktrees).
pub async fn common_dir(repo: &Path) -> Result<PathBuf> {
    let dir = crate::git::text(repo, &["rev-parse", "--git-common-dir"]).await?;
    let dir = PathBuf::from(dir.trim());
    Ok(if dir.is_absolute() {
        dir
    } else {
        repo.join(dir)
    })
}

/// The branch checked out in `repo`.
pub async fn current_branch(repo: &Path) -> Result<String> {
    Ok(crate::git::text(repo, &["symbolic-ref", "--short", "HEAD"])
        .await
        .context("The app's folder isn't on a branch")?
        .trim()
        .to_string())
}

/// What a merge writes besides the approved commit: the item's folder.
pub struct Folder {
    pub slug: String,
    /// (path inside the folder, file to copy)
    pub files: Vec<(PathBuf, PathBuf)>,
}

/// Merges exactly `commit` into `base`, checked out in `repo`, with the
/// item's folder: runs the app's checks on the merged tree first, and
/// leaves `repo` as it was if anything fails. Returns the merge commit.
pub async fn merge(
    repo: &Path,
    base: &str,
    commit: &str,
    folder: &Folder,
    message: &str,
    checks: &[String],
) -> Result<String> {
    let on = current_branch(repo).await?;
    ensure!(
        on == base,
        "The app's folder is on {on}, not {base}: `squircle merge` merges into {base} where it is checked out"
    );
    let dirty = crate::git::text(repo, &["status", "--porcelain", "--untracked-files=no"]).await?;
    ensure!(
        dirty.trim().is_empty(),
        "The app's folder has uncommitted changes on {base}; nothing merges over them:\n{}",
        dirty.trim()
    );
    crate::git::text(repo, &["merge", "--no-ff", "--no-commit", commit])
        .await
        .map_err(|e| {
            e.context(format!(
                "{commit} doesn't merge cleanly into {base}: rebase the branch on {base}, review it again, and ask again"
            ))
        })?;
    let result = async {
        for check in checks {
            let mut command = tokio::process::Command::new("/bin/sh");
            command.arg("-c").arg(check).current_dir(repo);
            let out = crate::process::run_bounded(
                command,
                crate::process::Sink::Capture(4 * 1024 * 1024),
                crate::process::Sink::Capture(4 * 1024 * 1024),
                None,
            )
            .await
            .map_err(|e| anyhow::anyhow!("{e}"))
            .with_context(|| format!("running `{check}`"))?;
            if !out.status.success() {
                let tail = |b: &[u8]| {
                    let t = String::from_utf8_lossy(b);
                    let lines: Vec<&str> = t.lines().collect();
                    lines[lines.len().saturating_sub(20)..].join("\n")
                };
                bail!(
                    "The merge check `{check}` failed on the merged tree; nothing was merged:\n{}\n{}",
                    tail(&out.stdout),
                    tail(&out.stderr)
                );
            }
        }
        let root = repo.join("docs/plans").join(&folder.slug);
        for (rel, from) in &folder.files {
            let to = root.join(rel);
            std::fs::create_dir_all(to.parent().context("no parent")?)?;
            std::fs::copy(from, &to).with_context(|| format!("Writing {}", to.display()))?;
        }
        let rel = format!("docs/plans/{}", folder.slug);
        crate::git::text(repo, &["add", "--", &rel]).await?;
        crate::git::text(repo, &["commit", "--no-verify", "-m", message]).await?;
        Ok(crate::git::text(repo, &["rev-parse", "HEAD"]).await?.trim().to_string())
    }
    .await;
    if result.is_err() {
        let _ = crate::git::text(repo, &["merge", "--abort"]).await;
        let root = repo.join("docs/plans").join(&folder.slug);
        for (rel, _) in &folder.files {
            let path = root.join(rel);
            let tracked = crate::git::text(
                repo,
                &["ls-files", "--error-unmatch", "--", &path.to_string_lossy()],
            )
            .await;
            if tracked.is_err() {
                let _ = std::fs::remove_file(path);
            }
        }
    }
    result
}

// MARK: following reviewed branches

/// Keeps every reviewed branch's head current in the tasks owner: watches
/// the ref folders of items at Review (the kernel tells it of a ref
/// written, packed or deleted), reads their heads, and looks again whenever
/// the tasks or T3's projects change. A move voids the review (and the
/// user's approval of it) and sends the item back to Build.
pub async fn follow_heads(
    tasks: std::sync::Arc<crate::tasks::Tasks>,
    agents: std::sync::Arc<crate::agents::Agents>,
) {
    use crate::tasks::{Gate, Track};
    use futures_util::StreamExt;
    let mut changes = futures_util::stream::select_all([tasks.changes(), agents.changes()]);
    loop {
        let watched: Vec<(String, PathBuf, String)> = tasks
            .all()
            .into_iter()
            .filter_map(|t| {
                let Some(Track::Code(code)) = &t.track else {
                    return None;
                };
                if !t.status.open() || !matches!(code.gate, Gate::Reviewing { .. } | Gate::Reviewed)
                {
                    return None;
                }
                Some((
                    t.id.clone(),
                    agents.project_root(&t.project_id)?,
                    code.branch.clone()?,
                ))
            })
            .collect();
        // Watching starts before reading, so a move in between is seen.
        let mut watchers = vec![];
        let mut heads = vec![];
        for (id, repo, branch) in &watched {
            if let Ok(common) = common_dir(repo).await {
                let refs = common.join("refs/heads").join(branch);
                for dir in [refs.parent().map(Path::to_path_buf), Some(common)]
                    .into_iter()
                    .flatten()
                {
                    if let Ok(watch) = crate::kq::Changes::watch(&dir) {
                        watchers.push(watch);
                    }
                }
            }
            match head(repo, branch).await {
                Ok(at) => heads.push((id.clone(), at)),
                Err(error) => eprintln!("Can't read {branch} in {}: {error:#}", repo.display()),
            }
        }
        if !heads.is_empty()
            && let Err(error) = tasks.heads(heads).await
        {
            eprintln!("Branch heads not recorded: {error:#}");
        }
        let moved = async {
            if watchers.is_empty() {
                return std::future::pending().await;
            }
            futures_util::future::select_all(watchers.iter().map(|w| Box::pin(w.next())))
                .await
                .0
        };
        tokio::select! {
            changed = changes.next() => if changed.is_none() { return },
            _ = moved => {}
        }
    }
}

// MARK: films

/// A film's stills (before, after, and each jump) and when it jumped.
pub struct Frames {
    pub stills: Vec<(PathBuf, String)>,
    pub jumps: Vec<f64>,
}

const SMALL_W: usize = 90;
const SMALL_H: usize = 196;
const MAX_JUMPS: usize = 6;

/// Frames that change much more than the ones around them: over 3× the
/// median change of the 8 neighbouring frames (LanguageApp's review-clip
/// measure), strongest first.
pub fn jumps(changes: &[f64]) -> Vec<usize> {
    let mut found: Vec<(usize, f64)> = vec![];
    for (i, &c) in changes.iter().enumerate() {
        let lo = i.saturating_sub(4);
        let hi = (i + 5).min(changes.len());
        let mut around: Vec<f64> = (lo..hi).filter(|&j| j != i).map(|j| changes[j]).collect();
        if around.is_empty() {
            continue;
        }
        around.sort_by(|a, b| a.total_cmp(b));
        let median = around[around.len() / 2];
        if c > 3.0 * median.max(0.5) && c > 2.0 {
            found.push((i, c));
        }
    }
    found.sort_by(|a, b| b.1.total_cmp(&a.1));
    found.truncate(MAX_JUMPS);
    found.into_iter().map(|(i, _)| i).collect()
}

/// Measures a clip and pulls its stills into `out`. A recorder or decoder
/// error fails the call: evidence never goes in half-measured.
pub async fn film(clip: &Path, out: &Path) -> Result<Frames> {
    let tools = crate::recordings::Tools::find()?;
    std::fs::create_dir_all(out)?;
    let run = |program: &Path, args: Vec<String>| {
        let mut command = tokio::process::Command::new(program);
        command.args(args);
        async move {
            let out = crate::process::run_bounded(
                command,
                crate::process::Sink::Capture(256 * 1024 * 1024),
                crate::process::Sink::Capture(1024 * 1024),
                None,
            )
            .await
            .map_err(|e| anyhow::anyhow!("{e}"))?;
            ensure!(
                out.status.success(),
                "{}",
                String::from_utf8_lossy(&out.stderr)
                    .lines()
                    .last()
                    .unwrap_or("failed")
            );
            Ok(out.stdout)
        }
    };
    let input = clip.to_string_lossy().to_string();
    let times = run(
        &tools.ffprobe,
        vec![
            "-v".into(),
            "error".into(),
            "-select_streams".into(),
            "v:0".into(),
            "-show_entries".into(),
            "frame=pts_time".into(),
            "-of".into(),
            "csv=p=0".into(),
            input.clone(),
        ],
    )
    .await
    .context("Reading the clip's frame times")?;
    let times: Vec<f64> = String::from_utf8_lossy(&times)
        .lines()
        .filter_map(|l| l.trim().trim_end_matches(',').parse().ok())
        .collect();
    ensure!(times.len() >= 2, "The clip has fewer than two frames");
    let raw = run(
        &tools.ffmpeg,
        vec![
            "-v".into(),
            "error".into(),
            "-i".into(),
            input.clone(),
            "-vsync".into(),
            "passthrough".into(),
            "-vf".into(),
            format!("scale={SMALL_W}:{SMALL_H},format=gray"),
            "-f".into(),
            "rawvideo".into(),
            "-".into(),
        ],
    )
    .await
    .context("Decoding the clip")?;
    let size = SMALL_W * SMALL_H;
    let frames: Vec<&[u8]> = raw.chunks_exact(size).collect();
    let changes: Vec<f64> = frames
        .windows(2)
        .map(|w| {
            w[0].iter()
                .zip(w[1])
                .map(|(a, b)| (*a as i32 - *b as i32).unsigned_abs() as f64)
                .sum::<f64>()
                / size as f64
        })
        .collect();
    let first = times[0];
    let at = |i: usize| times.get(i).copied().unwrap_or(first) - first;
    let mut jumped: Vec<usize> = jumps(&changes).into_iter().map(|i| i + 1).collect();
    jumped.sort();
    let still = |name: String, seek: Vec<String>| {
        let path = out.join(&name);
        let mut args = vec!["-v".into(), "error".into(), "-y".into()];
        args.extend(seek);
        args.extend([
            "-frames:v".into(),
            "1".into(),
            path.to_string_lossy().to_string(),
        ]);
        (path, args)
    };
    let mut stills = vec![];
    let (path, args) = still("before.png".into(), vec!["-i".into(), input.clone()]);
    run(&tools.ffmpeg, args)
        .await
        .context("Taking the first frame")?;
    stills.push((path, "before".to_string()));
    let (path, args) = still(
        "after.png".into(),
        vec![
            "-sseof".into(),
            "-0.25".into(),
            "-i".into(),
            input.clone(),
            "-update".into(),
            "1".into(),
        ],
    );
    run(&tools.ffmpeg, args)
        .await
        .context("Taking the last frame")?;
    stills.push((path, "after".to_string()));
    for i in &jumped {
        let t = at(*i);
        let (path, args) = still(
            format!("jump-{t:.2}.png"),
            vec!["-ss".into(), format!("{t:.3}"), "-i".into(), input.clone()],
        );
        run(&tools.ffmpeg, args)
            .await
            .context("Taking a jump's frame")?;
        stills.push((path, format!("jump at {t:.2} s")));
    }
    Ok(Frames {
        stills,
        jumps: jumped.into_iter().map(at).collect(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_plan_reads_its_pictures_changes_and_asks() {
        let doc = parse_plan(
            "# Keep the deck on the phone\n\nNothing is kept today.\n\n![now](pictures/now.png) ![change](pictures/change.png)\n\n\
             ## Changes\n\n1. Keep the whole deck\n   asks: item, 3f2a9c1b\n   detail the phone never shows\n2. Server sends only changed cards\n",
        )
        .unwrap();
        assert_eq!(doc.title, "Keep the deck on the phone");
        assert_eq!(doc.summary, "Nothing is kept today.");
        assert_eq!(
            doc.pictures,
            vec!["pictures/now.png", "pictures/change.png"]
        );
        assert_eq!(
            doc.changes,
            vec![
                (
                    1,
                    "Keep the whole deck".into(),
                    vec!["item".into(), "3f2a9c1b".into()]
                ),
                (2, "Server sends only changed cards".into(), vec![]),
            ]
        );
        let open = vec!["item-id".to_string(), "3f2a9c1b-0000".to_string()];
        assert_eq!(
            resolve_asks(&doc.changes[0].2, "item-id", &open).unwrap(),
            open
        );
        assert!(resolve_asks(&["3f2a".into()], "item-id", &open).is_err());
        assert!(resolve_asks(&["ffffffff".into()], "item-id", &open).is_err());
    }

    #[test]
    fn a_review_needs_a_verdict_a_why_for_each_difference_and_a_picture_per_finding() {
        let doc = parse_review(
            "# Review 2: BLOCKED\n\nTwo to fix.\n\n## Plan vs actual\n1. ✓ Deck kept\n2. ≠ Late grade kept — why: newest wins\n3. ✗ Dropped\n   why: no time\n\n\
             ## Findings\n### Offline it still says Loading\n![](frames/f1.png)\n- planned: opens from the phone\n- branch: waits on the server\n- fix: read Cards first\n",
        )
        .unwrap();
        assert_eq!(doc.verdict, Verdict::Blocked);
        assert_eq!(doc.lines.len(), 3);
        assert_eq!(
            (doc.lines[1].mark, doc.lines[1].why.as_str()),
            (Mark::Differs, "newest wins")
        );
        assert_eq!(doc.lines[1].text, "Late grade kept");
        assert_eq!(doc.lines[2].why, "no time");
        assert_eq!(doc.findings[0].picture.as_deref(), Some("frames/f1.png"));
        assert_eq!(doc.findings[0].fix, "read Cards first");
        assert!(parse_review("# Review\n").is_err());
        assert!(parse_review("# PASS\n## Plan vs actual\n1. ≠ Built otherwise\n").is_err());
        assert!(parse_review("# PASS\n## Plan vs actual\n1. Built\n").is_err());
        assert!(parse_review("# PASS\n## Findings\n### No picture\n- fix: x\n").is_err());
    }

    #[test]
    fn kept_rounds_stay_inside_their_folder() {
        assert!(inside("../x.png").is_err());
        assert!(inside("/etc/passwd").is_err());
        assert!(inside("pictures/now.png").is_ok());
    }

    #[test]
    fn a_jump_is_a_change_much_bigger_than_its_neighbours() {
        let mut changes = vec![1.0; 20];
        changes[10] = 9.0;
        assert_eq!(jumps(&changes), vec![10]);
        // Steady motion is no jump.
        assert!(jumps(&[5.0; 20]).is_empty());
    }

    #[test]
    fn the_app_settings_read_back() {
        let c = Config {
            base: Some("main".into()),
            reviewer_provider: Some("codex".into()),
            reviewer_model: Some("gpt-6-astra".into()),
            reviewer_effort: Some("xhigh".into()),
            rules: vec!["docs/engineering-preferences.md".into()],
            checks: vec!["bun run typecheck".into()],
        };
        assert_eq!(parse_config(&render_config(&c)), c);
    }
}
