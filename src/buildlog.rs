//! Why a build failed, read from its `build.log`: the xcodebuild step that
//! failed, its `error:` lines (with file, line and source context) and the
//! build commands Xcode lists as failed. Read-only; the log stays authoritative.

use serde::Serialize;

const MAX_ERRORS: usize = 20;
const MAX_CONTEXT_LINES: usize = 8;
const MAX_LINE_CHARS: usize = 400;

#[derive(Debug, Default, PartialEq, Serialize)]
pub struct Failure {
    /// The service's own error for the job, without the log path.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    /// The failing xcodebuild step ("Archive", "Export", …); None when the
    /// last xcodebuild command succeeded and the failure came after it.
    pub step: Option<String>,
    pub exit_status: Option<i32>,
    pub errors: Vec<Issue>,
    pub failed_commands: Vec<String>,
}

#[derive(Debug, PartialEq, Serialize)]
pub struct Issue {
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    /// Xcode's hint under the error, or the compiler's source excerpt.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// Summarise the last xcodebuild command in `log`. `root` is stripped from
/// file paths so they read relative to the project.
pub fn failure(log: &str, root: Option<&str>) -> Failure {
    let segment = log
        .rfind("\n$ /usr/bin/xcodebuild ")
        .map_or(log, |start| &log[start + 1..]);
    let mut lines = segment.lines().peekable();
    let command = lines.next().unwrap_or_default();
    let mut failure = Failure {
        exit_status: segment
            .lines()
            .rev()
            .find_map(|line| line.strip_prefix("xcodebuild exited: exit status: "))
            .and_then(|code| code.trim().parse().ok()),
        ..Failure::default()
    };
    if failure.exit_status == Some(0) {
        return failure;
    }
    let mut marker = None;
    while let Some(line) = lines.next() {
        if let Some(name) = line
            .strip_prefix("** ")
            .and_then(|rest| rest.strip_suffix(" FAILED **"))
        {
            marker = Some(name.to_string());
        } else if line.starts_with("The following build commands failed:") {
            while let Some(next) = lines.next_if(|next| next.starts_with('\t')) {
                failure.failed_commands.push(clip(next.trim()));
            }
        } else if let Some(mut issue) = issue(line, root) {
            let mut detail = Vec::new();
            while detail.len() < MAX_CONTEXT_LINES {
                let Some(next) = lines.next_if(|next| is_detail(next)) else {
                    break;
                };
                detail.push(clip(next.trim_end()));
            }
            if !detail.is_empty() {
                let indent = detail
                    .iter()
                    .filter(|l| !l.trim().is_empty())
                    .map(|l| l.len() - l.trim_start().len())
                    .min()
                    .unwrap_or(0);
                issue.detail = Some(
                    detail
                        .iter()
                        .map(|l| l.get(indent..).unwrap_or(""))
                        .collect::<Vec<_>>()
                        .join("\n"),
                );
            }
            let duplicate = failure.errors.iter().any(|seen| {
                seen.message == issue.message && seen.file == issue.file && seen.line == issue.line
            });
            if !duplicate && failure.errors.len() < MAX_ERRORS {
                failure.errors.push(issue);
            }
        }
    }
    failure.step = Some(step(marker.as_deref(), command));
    failure
}

fn step(marker: Option<&str>, command: &str) -> String {
    if command.contains("\"SquircleOverlay\"") {
        return "Debug overlay".into();
    }
    if command.contains("\"-showBuildSettings\"") {
        return "Build settings".into();
    }
    if command.contains("\"-exportArchive\"") {
        return "Export".into();
    }
    match marker {
        Some(name) => {
            let mut chars = name.chars();
            chars.next().map_or_else(String::new, |first| {
                first.to_string() + &chars.as_str().to_lowercase()
            })
        }
        None if command.contains("\"archive\"") => "Archive".into(),
        None => "Build".into(),
    }
}

/// `path:line:col: error: message`, `error: message` or `tool: error: message`.
fn issue(line: &str, root: Option<&str>) -> Option<Issue> {
    if line.starts_with(char::is_whitespace) {
        return None; // The compiler's caret line repeats the error.
    }
    let (location, message) = line.split_once("error: ")?;
    let location = location.strip_suffix("fatal ").unwrap_or(location);
    let message = message.trim();
    let message = clip(message.strip_prefix("exportArchive ").unwrap_or(message));
    if location.is_empty() {
        return Some(Issue {
            message,
            file: None,
            line: None,
            detail: None,
        });
    }
    let location = location.strip_suffix(": ")?;
    if location.starts_with('/') {
        let mut parts = location.splitn(3, ':');
        let path = parts.next()?;
        let number = parts.next().and_then(|n| n.parse().ok());
        let file = root
            .and_then(|root| path.strip_prefix(root))
            .map(|rest| rest.trim_start_matches('/'))
            .unwrap_or(path);
        return Some(Issue {
            message,
            file: Some(file.to_string()),
            line: number,
            detail: None,
        });
    }
    // A tool prefix such as `clang` or `xcodebuild`; anything with spaces is prose.
    (!location.contains(' ')).then_some(Issue {
        message,
        file: None,
        line: None,
        detail: None,
    })
}

/// Swift's `12 | source` excerpt, or Xcode's indented hint under an error.
fn is_detail(line: &str) -> bool {
    let trimmed = line.trim_start();
    if trimmed.is_empty() {
        return false;
    }
    let numbered = trimmed
        .split_once('|')
        .is_some_and(|(n, _)| n.trim().chars().all(|c| c.is_ascii_digit()));
    numbered || (line.starts_with("  ") && !line.starts_with('\t') && !trimmed.contains("error: "))
}

fn clip(text: &str) -> String {
    match text.char_indices().nth(MAX_LINE_CHARS) {
        Some((index, _)) => format!("{}…", &text[..index]),
        None => text.to_string(),
    }
}
