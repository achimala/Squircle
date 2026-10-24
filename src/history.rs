//! `squircle history`: search and show an app's past where it already lives.
//! T3 owns conversations (its `state.sqlite`, read-only through the system
//! `t3db`), Squircle owns tasks and builds, git owns commits and the
//! project's Markdown docs. Nothing is copied or indexed: each search reads
//! the sources on the fly (tens of milliseconds for messages, a few hundred
//! for tool activity) and ranks the matches here, so results are short
//! snippets with a stable reference that `show` expands.

use crate::t3db::{DETAIL_READ, params, query, sql};
use crate::t3steps::valid;
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

/// Where a result comes from; also the `--in` names.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    Message,
    Thread,
    Activity,
    Task,
    Build,
    Commit,
    Doc,
}

impl Kind {
    pub const ALL: [Kind; 7] = [
        Kind::Message,
        Kind::Thread,
        Kind::Activity,
        Kind::Task,
        Kind::Build,
        Kind::Commit,
        Kind::Doc,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Kind::Message => "messages",
            Kind::Thread => "threads",
            Kind::Activity => "activities",
            Kind::Task => "tasks",
            Kind::Build => "builds",
            Kind::Commit => "commits",
            Kind::Doc => "docs",
        }
    }

    fn prefix(self) -> &'static str {
        match self {
            Kind::Message => "msg",
            Kind::Thread => "thread",
            Kind::Activity => "act",
            Kind::Task => "task",
            Kind::Build => "build",
            Kind::Commit => "commit",
            Kind::Doc => "doc",
        }
    }

    pub fn parse(name: &str) -> Result<Kind> {
        Kind::ALL
            .into_iter()
            .find(|k| {
                k.name() == name || k.prefix() == name || k.name().trim_end_matches('s') == name
            })
            .with_context(|| {
                format!(
                    "Unknown source \"{name}\"; use {}",
                    Kind::ALL.map(Kind::name).join(", ")
                )
            })
    }

    /// How much a match here is worth: what the user and agents said and
    /// decided outranks tool chatter.
    fn weight(self) -> f64 {
        match self {
            Kind::Task => 1.4,
            Kind::Thread => 1.3,
            Kind::Message | Kind::Commit => 1.1,
            Kind::Doc => 1.0,
            Kind::Build => 0.8,
            Kind::Activity => 0.6,
        }
    }
}

/// The app a search is about: a T3 project.
#[derive(Clone, Debug)]
pub struct Scope {
    pub project_id: String,
    pub title: String,
    pub root: PathBuf,
}

/// The project of `thread`, else `project`, else the deepest project (or
/// worker worktree) containing `cwd`.
pub async fn scope(thread: Option<&str>, project: Option<&str>, cwd: &Path) -> Result<Scope> {
    let row = |r: &Value| Scope {
        project_id: r["project_id"].as_str().unwrap_or("").into(),
        title: r["title"].as_str().unwrap_or("").into(),
        root: PathBuf::from(r["workspace_root"].as_str().unwrap_or("")),
    };
    if let Some(thread) = thread {
        ensure!(valid(thread, &[]), "Thread ID must be a T3 ID");
        let rows = query(sql::THREAD_PROJECT, params![thread], DETAIL_READ).await?;
        return rows
            .first()
            .map(row)
            .with_context(|| format!("T3 has no thread {thread}"));
    }
    if let Some(project) = project {
        ensure!(valid(project, &[]), "Project ID must be a T3 ID");
        let rows = query(sql::PROJECT, params![project], DETAIL_READ).await?;
        return rows
            .first()
            .map(row)
            .with_context(|| format!("T3 has no project {project}"));
    }
    let rows = query(sql::PROJECT_PLACES, params![], DETAIL_READ).await?;
    let places: Vec<PathBuf> = rows
        .iter()
        .map(|r| PathBuf::from(r["place"].as_str().unwrap_or("/nonexistent")))
        .collect();
    let refs: Vec<&Path> = places.iter().map(PathBuf::as_path).collect();
    match crate::agents::deepest_root(&refs, cwd) {
        Ok(Some(index)) => Ok(row(&rows[index])),
        Ok(None) => bail!(
            "No T3 project contains {}; pass --thread or --project",
            cwd.display()
        ),
        Err(tied) => {
            let ids: HashSet<&str> = tied
                .iter()
                .filter_map(|i| rows[*i]["project_id"].as_str())
                .collect();
            ensure!(
                ids.len() == 1,
                "Several T3 projects share {}; pass --thread or --project",
                cwd.display()
            );
            Ok(row(&rows[tied[0]]))
        }
    }
}

// MARK: Ranking

/// One searchable thing, already matched against at least one term.
#[derive(Clone, Debug)]
pub struct Item {
    pub kind: Kind,
    /// Stable reference `show` accepts, e.g. `msg:<id>`.
    pub reference: String,
    pub title: String,
    pub text: String,
    /// Unix seconds.
    pub at: Option<i64>,
    /// Results from one conversation share a group, so one long thread
    /// can't fill the list.
    pub group: Option<String>,
    /// Extra weight: a service note (0.6) is worth less than what someone said.
    pub weight: f64,
}

const STOPWORDS: &[&str] = &[
    "a", "an", "and", "are", "as", "at", "be", "by", "did", "do", "does", "for", "from", "how",
    "i", "in", "is", "it", "of", "on", "or", "that", "the", "this", "to", "was", "we", "what",
    "when", "where", "which", "who", "why", "with", "you", "our", "about", "any", "can", "has",
    "have", "had", "were", "will", "should", "would", "there", "its", "it's", "don't", "dont",
];

/// The query's search terms: lowercase words of letters, digits and `_-./#+`,
/// without stopwords. Only these characters ever reach SQL.
pub fn terms(query: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for word in query
        .to_lowercase()
        .split(|c: char| !(c.is_alphanumeric() || "_-./#+'".contains(c)))
    {
        let word = word.trim_matches(|c: char| ".-/'".contains(c));
        if STOPWORDS.contains(&word) {
            continue;
        }
        let word: String = word
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || "_-./#+".contains(*c))
            .collect();
        if word.len() >= 2 && !STOPWORDS.contains(&word.as_str()) && !out.contains(&word) {
            out.push(word);
        }
    }
    out
}

fn count(haystack: &str, needle: &str) -> usize {
    haystack.match_indices(needle).count()
}

/// Ranks matched items: BM25 over the matched set, scaled by how many of
/// the terms an item has (all terms beat a few repeated), a bonus for the
/// whole phrase, the source's weight and a mild preference for recent
/// things. At most `per_group` results per conversation.
pub fn rank(
    terms: &[String],
    items: Vec<Item>,
    now: i64,
    limit: usize,
    per_group: usize,
) -> Vec<(f64, Item)> {
    const K1: f64 = 1.2;
    const B: f64 = 0.6;
    if terms.is_empty() {
        return Vec::new();
    }
    let lowered: Vec<(String, String)> = items
        .iter()
        .map(|i| (i.title.to_lowercase(), i.text.to_lowercase()))
        .collect();
    let n = items.len().max(1) as f64 * 2.0;
    let df: Vec<f64> = terms
        .iter()
        .map(|t| {
            lowered
                .iter()
                .filter(|(a, b)| a.contains(t.as_str()) || b.contains(t.as_str()))
                .count() as f64
        })
        .collect();
    let lengths: Vec<f64> = lowered
        .iter()
        .map(|(a, b)| (a.len() + b.len()).max(1) as f64)
        .collect();
    let average = lengths.iter().sum::<f64>() / lengths.len().max(1) as f64;
    let phrase = terms.join(" ");
    let mut scored: Vec<(f64, Item)> = items
        .into_iter()
        .enumerate()
        .filter_map(|(index, item)| {
            let (title, text) = &lowered[index];
            let mut score = 0.0;
            let mut matched = 0;
            for (term, df) in terms.iter().zip(&df) {
                let tf = (count(text, term) + 2 * count(title, term)) as f64;
                if tf == 0.0 {
                    continue;
                }
                matched += 1;
                let idf = (1.0 + (n - df + 0.5) / (df + 0.5)).ln();
                score +=
                    idf * tf * (K1 + 1.0) / (tf + K1 * (1.0 - B + B * lengths[index] / average));
            }
            if matched == 0 {
                return None;
            }
            let coverage = matched as f64 / terms.len() as f64;
            score *= coverage * coverage;
            if terms.len() > 1 && (text.contains(&phrase) || title.contains(&phrase)) {
                score *= 1.5;
            }
            let age_days = item
                .at
                .map_or(365.0, |at| ((now - at).max(0)) as f64 / 86400.0);
            score *= 1.0 + 0.6 * (-age_days / 21.0).exp();
            score *= item.kind.weight() * item.weight;
            Some((score, item))
        })
        .collect();
    scored.sort_by(|a, b| b.0.total_cmp(&a.0).then(b.1.at.cmp(&a.1.at)));
    let mut seen: HashMap<String, usize> = HashMap::new();
    scored.retain(|(_, item)| match &item.group {
        Some(group) => {
            let n = seen.entry(group.clone()).or_default();
            *n += 1;
            *n <= per_group
        }
        None => true,
    });
    scored.truncate(limit);
    scored
}

/// About `width` characters of `text` around where most distinct terms
/// meet, on one line, with … where it was cut.
pub fn snippet(text: &str, terms: &[String], width: usize) -> String {
    let flat: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let chars: Vec<char> = flat.chars().collect();
    if chars.len() <= width {
        return flat;
    }
    let lower: Vec<char> = flat.to_lowercase().chars().collect();
    // Lowercasing can change lengths (rarely); fall back to the start then.
    let hits: Vec<(usize, usize)> = if lower.len() == chars.len() {
        let lower: String = lower.iter().collect();
        terms
            .iter()
            .enumerate()
            .flat_map(|(t, term)| {
                lower
                    .match_indices(term.as_str())
                    .map(move |(byte, _)| (t, byte))
                    .collect::<Vec<_>>()
            })
            .map(|(t, byte)| (t, lower[..byte].chars().count()))
            .collect()
    } else {
        Vec::new()
    };
    let mut best = (0, 0usize);
    for &(_, at) in &hits {
        let start = at.saturating_sub(width / 4);
        let distinct: HashSet<usize> = hits
            .iter()
            .filter(|(_, p)| *p >= start && *p < start + width)
            .map(|(t, _)| *t)
            .collect();
        if distinct.len() > best.1 {
            best = (start, distinct.len());
        }
    }
    let start = best.0.min(chars.len().saturating_sub(width));
    let end = (start + width).min(chars.len());
    format!(
        "{}{}{}",
        if start > 0 { "…" } else { "" },
        chars[start..end].iter().collect::<String>().trim(),
        if end < chars.len() { "…" } else { "" }
    )
}

/// `7d`, `12h`, `30m` ago or a `YYYY-MM-DD` date, as Unix seconds.
pub fn since(text: &str, now: i64) -> Result<i64> {
    let text = text.trim();
    if text.contains('-') {
        let date = time::Date::parse(
            text,
            time::macros::format_description!("[year]-[month]-[day]"),
        )
        .with_context(|| format!("--since {text} is not a real YYYY-MM-DD date"))?;
        return Ok(date.midnight().assume_utc().unix_timestamp());
    }
    let (number, unit) = text.split_at(
        text.find(|c: char| !c.is_ascii_digit())
            .context("--since takes 7d, 12h, 30m or YYYY-MM-DD")?,
    );
    let number: i64 = number
        .parse()
        .context("--since takes 7d, 12h, 30m or YYYY-MM-DD")?;
    let seconds = match unit {
        "d" => 86400,
        "h" => 3600,
        "m" => 60,
        "w" => 7 * 86400,
        _ => bail!("--since takes 7d, 12h, 30m or YYYY-MM-DD"),
    };
    Ok(now - number * seconds)
}

pub fn now() -> i64 {
    crate::model::now() as i64
}

/// `2026-10-14 22:23` (UTC) for display.
pub fn when(at: i64) -> String {
    let iso = crate::t3::iso_utc(at);
    iso[..16].replace('T', " ")
}

fn t3_time(text: &str) -> Option<i64> {
    crate::t3::iso_parse(text).map(|s| s as i64)
}

// MARK: Sources

/// Everything matching any term, from the sources asked for.
async fn gather(
    root: &Path,
    scope: &Scope,
    terms: &[String],
    kinds: &[Kind],
    after: Option<i64>,
) -> Result<(Vec<Item>, Vec<String>)> {
    let mut items = Vec::new();
    let mut unavailable = Vec::new();
    let project = &scope.project_id;
    ensure!(valid(project, &[]), "Invalid project ID");
    let after_iso = after.map(|a| format!("{}Z", crate::t3::iso_utc(a)));
    if kinds
        .iter()
        .any(|k| matches!(k, Kind::Message | Kind::Thread | Kind::Activity))
    {
        match query(
            sql::SEARCH,
            params![
                project,
                after_iso,
                serde_json::to_string(terms)?,
                kinds.contains(&Kind::Message),
                kinds.contains(&Kind::Thread),
                kinds.contains(&Kind::Activity)
            ],
            DETAIL_READ,
        )
        .await
        {
            Ok(rows) => {
                for row in rows {
                    let text = |k: &str| row[k].as_str().unwrap_or("").to_string();
                    let kind = match row["src"].as_str() {
                        Some("msg") => Kind::Message,
                        Some("thread") => Kind::Thread,
                        _ => Kind::Activity,
                    };
                    let title = match kind {
                        Kind::Message => format!("{} in \"{}\"", text("role"), text("title")),
                        Kind::Activity => format!("{} in \"{}\"", text("role"), text("title")),
                        _ => text("title"),
                    };
                    items.push(Item {
                        kind,
                        reference: format!("{}:{}", kind.prefix(), text("id")),
                        title,
                        text: text("text"),
                        at: t3_time(&text("at")),
                        group: Some(text("thread")),
                        weight: if row["marked"] == 1 { 0.6 } else { 1.0 },
                    });
                }
            }
            Err(error) => unavailable.push(format!("T3: {error:#}")),
        }
    }
    let matches = |text: &str| {
        let lower = text.to_lowercase();
        terms.iter().any(|t| lower.contains(t.as_str()))
    };
    if kinds.contains(&Kind::Task) {
        match crate::tasks::read(root) {
            Ok(tasks) => {
                let work = tasks.list(project);
                let all = work
                    .iter()
                    .flat_map(|t| std::iter::once(t).chain(&t.subtasks));
                for task in all {
                    let notes: Vec<&str> = task
                        .history
                        .iter()
                        .map(|c| c.note.as_str())
                        .filter(|n| !n.is_empty())
                        .collect();
                    let text = format!("{} {} {}", task.ask, task.note, notes.join(" "));
                    if matches(&text) && after.is_none_or(|a| task.updated_at as i64 >= a) {
                        items.push(Item {
                            kind: Kind::Task,
                            reference: format!("task:{}", task.id),
                            title: format!(
                                "{}, {}",
                                if task.parent_id.is_some() {
                                    "sub-task"
                                } else {
                                    "task"
                                },
                                task.status.label()
                            ),
                            text,
                            at: Some(task.updated_at as i64),
                            group: None,
                            weight: 1.0,
                        });
                    }
                }
            }
            Err(error) => unavailable.push(format!("tasks: {error:#}")),
        }
    }
    if kinds.contains(&Kind::Build) {
        match crate::store::Store::open(root.to_path_buf()).and_then(|s| s.list_jobs()) {
            Ok(jobs) => {
                for job in jobs {
                    let Some(request) = job.request() else {
                        continue;
                    };
                    if !request.project.starts_with(&scope.root) {
                        continue;
                    }
                    let error = match &job.phase {
                        crate::model::JobPhase::Failed { message }
                        | crate::model::JobPhase::Interrupted { message } => message.clone(),
                        crate::model::JobPhase::Cancelled { message } => {
                            message.clone().unwrap_or_default()
                        }
                        _ => String::new(),
                    };
                    let text = format!(
                        "{} {} build {:?} {error}",
                        request.scheme,
                        request.configuration,
                        job.state()
                    );
                    if matches(&text) && after.is_none_or(|a| job.created_at as i64 >= a) {
                        items.push(Item {
                            kind: Kind::Build,
                            reference: format!("build:{}", job.id),
                            title: format!("{} build, {:?}", request.scheme, job.state())
                                .to_lowercase(),
                            text,
                            at: Some(job.created_at as i64),
                            group: None,
                            weight: 1.0,
                        });
                    }
                }
            }
            Err(error) => unavailable.push(format!("builds: {error:#}")),
        }
    }
    if kinds.contains(&Kind::Commit) {
        match crate::git::text(
            &scope.root,
            &["log", "-n", "3000", "--format=%H%x1f%at%x1f%s%x1f%b%x1e"],
        )
        .await
        {
            Ok(log) => {
                for record in log.split('\x1e') {
                    let mut fields = record.trim_start_matches('\n').split('\x1f');
                    let (Some(sha), Some(at), Some(subject)) =
                        (fields.next(), fields.next(), fields.next())
                    else {
                        continue;
                    };
                    let body = fields.next().unwrap_or("").trim();
                    let at = at.parse::<i64>().ok();
                    if (matches(subject) || matches(body))
                        && after.is_none_or(|a| at.is_some_and(|at| at >= a))
                    {
                        items.push(Item {
                            kind: Kind::Commit,
                            reference: format!("commit:{}", &sha[..sha.len().min(12)]),
                            title: subject.to_string(),
                            text: body.to_string(),
                            at,
                            group: None,
                            weight: 1.0,
                        });
                    }
                }
            }
            Err(error) => unavailable.push(format!("git: {error:#}")),
        }
    }
    if kinds.contains(&Kind::Doc) && after.is_none() {
        match crate::git::text(&scope.root, &["ls-files", "-z", "--", "*.md"]).await {
            Ok(files) => {
                for file in files.split('\0').filter(|f| !f.is_empty()).take(500) {
                    let path = scope.root.join(file);
                    if std::fs::metadata(&path).map_or(true, |m| m.len() > 2 * 1024 * 1024) {
                        continue;
                    }
                    let Ok(content) = std::fs::read_to_string(&path) else {
                        continue;
                    };
                    for section in sections(&content) {
                        let body = &content[section.start..section.end];
                        if matches(body) {
                            items.push(Item {
                                kind: Kind::Doc,
                                reference: format!("doc:{file}#L{}", section.line),
                                title: format!("{file} › {}", section.heading),
                                text: body.to_string(),
                                at: None,
                                group: None,
                                weight: 1.0,
                            });
                        }
                    }
                }
            }
            Err(error) => unavailable.push(format!("docs: {error:#}")),
        }
    }
    Ok((items, unavailable))
}

/// A Markdown section: from a heading to the next heading of any level.
#[derive(Debug, PartialEq)]
pub struct Section {
    pub heading: String,
    /// 1-based line of the heading (1 for text before the first heading).
    pub line: usize,
    pub start: usize,
    pub end: usize,
}

/// The file's sections, skipping headings inside fenced code.
pub fn sections(content: &str) -> Vec<Section> {
    let mut out: Vec<Section> = Vec::new();
    let mut fenced = false;
    let mut offset = 0;
    let mut current = Section {
        heading: "top".into(),
        line: 1,
        start: 0,
        end: 0,
    };
    for (index, line) in content.split_inclusive('\n').enumerate() {
        let trimmed = line.trim_start();
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            fenced = !fenced;
        }
        let heading =
            !fenced && line.starts_with('#') && line.trim_start_matches('#').starts_with(' ');
        if heading {
            current.end = offset;
            if current.end > current.start {
                out.push(current);
            }
            current = Section {
                heading: line.trim_start_matches('#').trim().to_string(),
                line: index + 1,
                start: offset,
                end: 0,
            };
        }
        offset += line.len();
    }
    current.end = offset;
    if current.end > current.start {
        out.push(current);
    }
    out
}

// MARK: Commands

pub struct Search<'a> {
    pub query: &'a str,
    pub kinds: Vec<Kind>,
    pub limit: usize,
    pub since: Option<&'a str>,
}

/// Ranked results with snippets; text for agents, and the same as JSON.
pub async fn search(root: &Path, scope: &Scope, search: Search<'_>) -> Result<(String, Value)> {
    let terms = terms(search.query);
    ensure!(!terms.is_empty(), "Give some words to search for");
    let now = now();
    let after = search.since.map(|s| since(s, now)).transpose()?;
    let kinds = if search.kinds.is_empty() {
        Kind::ALL.to_vec()
    } else {
        search.kinds
    };
    let (items, unavailable) = gather(root, scope, &terms, &kinds, after).await?;
    let matched = items.len();
    let ranked = rank(&terms, items, now, search.limit.clamp(1, 50), 2);
    let mut text = String::new();
    let mut results = Vec::new();
    for (score, item) in &ranked {
        let snippet = snippet(&item.text, &terms, 200);
        let at = item
            .at
            .map(|at| format!(" · {}", when(at)))
            .unwrap_or_default();
        text += &format!(
            "{}{at} · {}\n  {}\n",
            item.reference,
            item.title.replace('\n', " "),
            snippet
        );
        results.push(json!({"ref": item.reference, "kind": item.kind.name(), "title": item.title, "at": item.at,
                            "snippet": snippet, "score": (score * 100.0).round() / 100.0}));
    }
    if ranked.is_empty() {
        text += "No matches.\n";
    }
    for source in &unavailable {
        text += &format!("(unavailable: {source})\n");
    }
    if !ranked.is_empty() {
        text += "Expand one with: history show REF\n";
    }
    Ok((
        text,
        json!({"app": scope.title, "project_id": scope.project_id, "terms": terms, "matched": matched,
                     "results": results, "unavailable": unavailable, "index": "none: sources are read on each search"}),
    ))
}

fn cap(text: &str, limit: usize) -> String {
    if text.chars().count() <= limit {
        return text.to_string();
    }
    format!(
        "{}… [{} more characters; --max-chars to see more]",
        text.chars().take(limit).collect::<String>(),
        text.chars().count() - limit
    )
}

fn one_line(text: &str, limit: usize) -> String {
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() <= limit {
        flat
    } else {
        format!("{}…", flat.chars().take(limit).collect::<String>())
    }
}

/// One item in full (bounded by `max_chars`). Message, thread and activity
/// references need no app; commits and docs are read in `scope`'s folder.
pub async fn show(
    root: &Path,
    scope: Option<&Scope>,
    reference: &str,
    max_chars: usize,
    limit: usize,
) -> Result<(String, Value)> {
    let (prefix, id) = reference.split_once(':').context(
        "A reference looks like msg:ID, thread:ID, task:ID, build:ID, commit:SHA or doc:PATH#L12",
    )?;
    let kind = Kind::ALL
        .into_iter()
        .find(|k| k.prefix() == prefix)
        .with_context(|| format!("Unknown reference kind \"{prefix}\""))?;
    let id = id.trim();
    match kind {
        Kind::Message => {
            ensure!(valid(id, &[':', '_', '.']), "Invalid message ID");
            let rows = query(sql::MESSAGE, params![id], DETAIL_READ).await?;
            let row = rows
                .first()
                .with_context(|| format!("T3 has no message {id}"))?;
            let s = |k: &str| row[k].as_str().unwrap_or("").to_string();
            let mut text = format!(
                "{} · {} · {} in \"{}\" (thread:{})\n\n{}\n",
                reference,
                t3_time(&s("created_at")).map(when).unwrap_or_default(),
                s("role"),
                s("title"),
                s("thread_id"),
                cap(&s("text"), max_chars)
            );
            if !s("before_id").is_empty() {
                text += &format!(
                    "\nBefore (msg:{}): {}\n",
                    s("before_id"),
                    one_line(&s("before_text"), 300)
                );
            }
            if !s("after_id").is_empty() {
                text += &format!(
                    "After (msg:{}): {}\n",
                    s("after_id"),
                    one_line(&s("after_text"), 300)
                );
            }
            Ok((
                text,
                json!({"ref": reference, "thread_id": s("thread_id"), "thread_title": s("title"), "role": s("role"),
                             "at": s("created_at"), "text": cap(&s("text"), max_chars),
                             "before": {"ref": format!("msg:{}", s("before_id")), "text": one_line(&s("before_text"), 300)},
                             "after": {"ref": format!("msg:{}", s("after_id")), "text": one_line(&s("after_text"), 300)}}),
            ))
        }
        Kind::Thread => {
            ensure!(valid(id, &[]), "Invalid thread ID");
            let thread = query(sql::THREAD, params![id], DETAIL_READ).await?;
            let thread = thread
                .first()
                .with_context(|| format!("T3 has no thread {id}"))?;
            let messages = query(
                sql::MESSAGES,
                params![id, limit.clamp(1, 500) as i64],
                DETAIL_READ,
            )
            .await?;
            let s = |k: &str| thread[k].as_str().unwrap_or("").to_string();
            let total = thread["total"].as_u64().unwrap_or(0);
            let mut text = format!(
                "{reference} · \"{}\"{} · {} to {}{}\n",
                s("title"),
                if s("branch").is_empty() {
                    String::new()
                } else {
                    format!(" [{}]", s("branch"))
                },
                t3_time(&s("created_at")).map(when).unwrap_or_default(),
                t3_time(&s("updated_at")).map(when).unwrap_or_default(),
                if s("archived_at").is_empty() {
                    ""
                } else {
                    " · archived"
                }
            );
            if total as usize > messages.len() {
                text += &format!(
                    "({} earlier messages; --limit to see more)\n",
                    total as usize - messages.len()
                );
            }
            let mut budget = max_chars;
            let lines: Vec<String> = messages
                .iter()
                .map(|m| {
                    let body = one_line(m["text"].as_str().unwrap_or(""), 240.min(budget.max(60)));
                    budget = budget.saturating_sub(body.len());
                    format!(
                        "msg:{} · {} · {}: {}",
                        m["message_id"].as_str().unwrap_or(""),
                        t3_time(m["created_at"].as_str().unwrap_or(""))
                            .map(when)
                            .unwrap_or_default(),
                        m["role"].as_str().unwrap_or(""),
                        body
                    )
                })
                .collect();
            text += &lines.join("\n");
            text.push('\n');
            Ok((
                text,
                json!({"ref": reference, "title": s("title"), "branch": s("branch"), "created_at": s("created_at"),
                             "updated_at": s("updated_at"), "archived_at": thread["archived_at"], "messages_total": total, "messages": lines}),
            ))
        }
        Kind::Activity => {
            ensure!(valid(id, &[':', '_', '.', '%']), "Invalid activity ID");
            let rows = query(sql::ACTIVITY, params![id, max_chars as i64], DETAIL_READ).await?;
            let row = rows
                .first()
                .with_context(|| format!("T3 has no activity {id}"))?;
            let s = |k: &str| row[k].as_str().unwrap_or("").to_string();
            let text = format!(
                "{reference} · {} · {} in \"{}\" (thread:{})\n{}\n{}\n",
                t3_time(&s("created_at")).map(when).unwrap_or_default(),
                s("kind"),
                s("title"),
                s("thread_id"),
                cap(&format!("{}: {}", s("summary"), s("detail")), max_chars),
                cap(&s("input"), max_chars)
            );
            Ok((
                text,
                json!({"ref": reference, "thread_id": s("thread_id"), "kind": s("kind"), "summary": s("summary"),
                             "detail": s("detail"), "input": s("input"), "at": s("created_at")}),
            ))
        }
        Kind::Task => {
            let task = crate::tasks::read(root)?
                .get(id)
                .with_context(|| format!("No task {id}"))?;
            let mut text = format!(
                "{reference} · {} · created {}, updated {}\nAsk: {}\n",
                task.status.label(),
                when(task.created_at as i64),
                when(task.updated_at as i64),
                task.ask
            );
            if !task.note.is_empty() {
                text += &format!("Note: {}\n", task.note);
            }
            if let Some(parent) = &task.parent_id {
                text += &format!("Sub-task of task:{parent}\n");
            }
            for sub in &task.subtasks {
                text += &format!(
                    "Sub-task task:{} ({}): {}\n",
                    sub.id,
                    sub.status.label(),
                    sub.ask
                );
            }
            for thread in &task.threads {
                text += &format!("Worker: thread:{thread}\n");
            }
            for build in &task.builds {
                text += &format!("Build: build:{build}\n");
            }
            for change in task.history.iter().rev().take(limit) {
                text += &format!(
                    "- {} {} by {:?}{}\n",
                    when(change.at as i64),
                    change.status.label(),
                    change.by,
                    if change.note.is_empty() {
                        String::new()
                    } else {
                        format!(": {}", change.note)
                    }
                );
            }
            Ok((text, serde_json::to_value(&task)?))
        }
        Kind::Build => {
            ensure!(uuid::Uuid::parse_str(id).is_ok(), "Build ID must be a UUID");
            let job = crate::store::Store::open(root.to_path_buf())?.load_job(id)?;
            let mut text = format!(
                "{reference} · {:?} · {}\n",
                job.state(),
                when(job.created_at as i64)
            );
            if let Some(request) = job.request() {
                text += &format!(
                    "{} {} ({:?}) from {}\n",
                    request.scheme,
                    request.configuration,
                    request.mode,
                    request.project.display()
                );
                if let Some(thread) = &request.thread {
                    text += &format!("Started by thread:{thread}\n");
                }
            }
            if let Some(revision) = job.provenance().and_then(|p| p.revision.as_ref()) {
                text += &format!("Source: commit:{}\n", &revision[..revision.len().min(12)]);
            }
            if let Some(output) = job.output() {
                text += &format!(
                    "{} {} ({})\n",
                    output.title, output.version, output.build_number
                );
            }
            match &job.phase {
                crate::model::JobPhase::Failed { message }
                | crate::model::JobPhase::Interrupted { message } => {
                    text += &format!("{}\n", cap(message, max_chars))
                }
                _ => {}
            }
            text += &format!("Details: build status {id}\n");
            Ok((text, serde_json::to_value(&job)?))
        }
        Kind::Commit => {
            let scope = scope.context(
                "Pass --thread or --project, or run in the app's folder, to show a commit",
            )?;
            ensure!(
                !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_hexdigit()),
                "A commit reference is a hex SHA"
            );
            let mut text = crate::git::text(
                &scope.root,
                &[
                    "show",
                    "--no-ext-diff",
                    "--no-textconv",
                    "--stat",
                    "--format=commit %H%nDate: %ad%n%n%B",
                    "--date=iso",
                    id,
                ],
            )
            .await?;
            if max_chars > text.len() {
                let patch = crate::git::text(
                    &scope.root,
                    &[
                        "show",
                        "--no-ext-diff",
                        "--no-textconv",
                        "--format=",
                        "--patch",
                        id,
                    ],
                )
                .await
                .unwrap_or_default();
                text += &format!("\n{}", cap(&patch, max_chars - text.len()));
            }
            let text = cap(&text, max_chars);
            Ok((format!("{text}\n"), json!({"ref": reference, "text": text})))
        }
        Kind::Doc => {
            let scope = scope
                .context("Pass --thread or --project, or run in the app's folder, to show a doc")?;
            let (file, line) = id
                .rsplit_once("#L")
                .map_or((id, 1), |(f, l)| (f, l.parse().unwrap_or(1)));
            ensure!(
                !file.starts_with('/') && !file.split('/').any(|p| p == ".."),
                "A doc reference is a path inside the project"
            );
            let content = std::fs::read_to_string(scope.root.join(file))
                .with_context(|| format!("No doc {file}"))?;
            let section = sections(&content)
                .into_iter()
                .rfind(|s| s.line <= line)
                .context("Empty doc")?;
            let text = cap(&content[section.start..section.end], max_chars);
            Ok((
                format!("{reference}\n{text}\n"),
                json!({"ref": reference, "heading": section.heading, "text": text}),
            ))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(
        kind: Kind,
        reference: &str,
        title: &str,
        text: &str,
        age_days: i64,
        group: Option<&str>,
    ) -> Item {
        Item {
            kind,
            reference: reference.into(),
            title: title.into(),
            text: text.into(),
            at: Some(1_000_000_000 - age_days * 86400),
            group: group.map(Into::into),
            weight: 1.0,
        }
    }

    #[test]
    fn terms_drop_stopwords_and_keep_only_safe_characters() {
        assert_eq!(
            terms("Why did we drop the 3D-tilt push? 'sim_pool' it's O'Brien; DROP TABLE x--"),
            ["drop", "3d-tilt", "push", "sim_pool", "obrien", "table"]
        );
        assert!(terms("the and of").is_empty());
        assert!(terms("'; select * from x; --").iter().all(|t| {
            t.chars()
                .all(|c| c.is_ascii_alphanumeric() || "_-./#+".contains(c))
        }));
    }

    #[test]
    fn ranks_all_terms_above_repetition_of_one() {
        let now = 1_000_000_000;
        let items = vec![
            item(
                Kind::Message,
                "msg:a",
                "user",
                "simulator simulator simulator simulator simulator",
                1,
                Some("t1"),
            ),
            item(
                Kind::Message,
                "msg:b",
                "assistant",
                "we decided the simulator deck fans out on tap",
                30,
                Some("t2"),
            ),
            item(Kind::Message, "msg:c", "user", "the deck", 1, Some("t3")),
        ];
        let ranked: Vec<String> = rank(&terms("simulator deck"), items, now, 10, 2)
            .into_iter()
            .map(|(_, i)| i.reference)
            .collect();
        assert_eq!(ranked[0], "msg:b");
    }

    #[test]
    fn snippet_centres_on_the_terms() {
        let text = format!(
            "{} the jelly crew decision: workers are chibi sprouts {}",
            "filler ".repeat(100),
            "tail ".repeat(100)
        );
        let s = snippet(&text, &terms("jelly sprouts"), 80);
        assert!(
            s.contains("jelly") && s.contains("sprouts") && s.starts_with('…') && s.ends_with('…'),
            "{s}"
        );
        assert_eq!(
            snippet("short  text\n here", &terms("text"), 80),
            "short text here"
        );
    }

    #[test]
    fn markdown_sections_skip_fenced_headings() {
        let doc = "intro\n# One\nbody\n```sh\n# not a heading\n```\n## Two\nmore\n";
        let s = sections(doc);
        assert_eq!(
            s.iter()
                .map(|s| (s.heading.as_str(), s.line))
                .collect::<Vec<_>>(),
            vec![("top", 1), ("One", 2), ("Two", 7)]
        );
        assert!(doc[s[1].start..s[1].end].contains("# not a heading"));
    }

    #[test]
    fn since_reads_durations_and_dates() {
        assert_eq!(since("2d", 1_000_000).unwrap(), 1_000_000 - 172_800);
        assert_eq!(since("1970-01-02", 0).unwrap(), 86400);
        assert!(since("soon", 0).is_err());
        assert!(since("2026-02-30", 0).is_err() && since("2026-13-01", 0).is_err());
        assert_eq!(when(86400 + 3661), "1970-01-02 01:01");
    }
}
