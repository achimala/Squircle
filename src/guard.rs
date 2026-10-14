//! The app agent's PreToolUse guard: delegated work must run as T3 worker
//! threads the user can see, never as model runs the agent starts itself
//! (`codex exec`, `claude -p`, subagents, workflows). Only the app agent's
//! Claude instance carries this hook; workers are unaffected.

use serde_json::Value;

/// Why a tool call is denied, or `None` to let it run. `cli` is how the
/// agent invokes Squircle, for the command the message points to.
pub fn check(event: &Value, cli: &str) -> Option<String> {
    let input = &event["tool_input"];
    let what = match event["tool_name"].as_str()? {
        "Agent" | "Task" => "Subagents",
        "Workflow" => "Workflows",
        _ => {
            let runs = runs_model(input["command"].as_str()?)?;
            return Some(format!("`{runs}` runs a model outside T3, where the user can't see it. {}", spawn_hint(cli)));
        }
    };
    Some(format!("{what} run outside T3, where the user can't see them. {}", spawn_hint(cli)))
}

fn spawn_hint(cli: &str) -> String {
    format!(
        "Run every piece of delegated work, reviews and research included, as a T3 worker, one per reviewer or job: \
         `{cli} thread spawn --coordinator <your thread id> --title \"<title>\" --branch <new-branch> --prompt \"<task>\"`, \
         adding `--provider codex --model <slug> --effort <level>` for Codex (e.g. `--model gpt-6-astra --effort xhigh`) \
         or `--model`/`--effort` for Claude. Each shows up in the user's Threads, and you get a [worker update] when it finishes."
    )
}

/// The `codex` or `claude` model run in a shell command, if any.
pub fn runs_model(command: &str) -> Option<String> {
    for script in substitutions(command).iter().chain(std::iter::once(&command.to_string())) {
        for words in simple_commands(script) {
            if let Some(found) = program_run(&words, 0) {
                return Some(found);
            }
        }
    }
    None
}

/// Commands that wrap another: skip them and their options to the real program.
const WRAPPERS: &[&str] = &[
    "nohup", "env", "exec", "command", "builtin", "time", "nice", "timeout", "gtimeout", "caffeinate", "stdbuf",
    "setsid", "sudo", "xargs", "parallel", "watch", "unbuffer", "noglob", "npx", "bunx", "pnpx", "!", "if", "then",
    "else", "elif", "while", "until", "do",
];
const SHELLS: &[&str] = &["bash", "sh", "zsh", "dash", "fish", "ksh"];
// Subcommands that don't run a model; any other use runs one (or would, given a terminal).
const CODEX_SAFE: &[&str] = &["--help", "-h", "help", "--version", "-V", "login", "logout", "completion", "features", "mcp"];
const CLAUDE_SAFE: &[&str] = &["--help", "-h", "--version", "-v", "mcp", "config", "plugin", "plugins", "doctor", "update"];

fn program_run(words: &[String], depth: usize) -> Option<String> {
    if depth > 8 { return None; }
    let mut i = 0;
    // Leading assignments and redirections.
    while i < words.len() && (is_assignment(&words[i]) || is_redirect(&words[i])) { i += 1; }
    let name = program_name(words.get(i)?);
    let rest = &words[i + 1..];
    if WRAPPERS.contains(&name.as_str()) {
        let mut next = 0;
        while next < rest.len() && skippable_arg(&rest[next]) {
            next += if takes_value(&name, &rest[next]) { 2 } else { 1 };
        }
        return program_run(rest.get(next..)?, depth + 1);
    }
    if matches!(name.as_str(), "npm" | "pnpm" | "yarn" | "bun") {
        let sub = rest.iter().position(|w| !w.starts_with('-'))?;
        return if matches!(rest[sub].as_str(), "exec" | "dlx" | "x") { program_run(&rest[sub + 1..], depth + 1) } else { None };
    }
    if SHELLS.contains(&name.as_str()) {
        let flag = rest.iter().position(|w| w.starts_with('-') && !w.starts_with("--") && w.contains('c'))?;
        return runs_model(rest.get(flag + 1)?);
    }
    if name == "eval" {
        return runs_model(&rest.join(" "));
    }
    let safe = match name.as_str() {
        "codex" => CODEX_SAFE,
        "claude" => CLAUDE_SAFE,
        _ => return None,
    };
    match rest.first() {
        Some(first) if safe.contains(&first.as_str()) => None,
        _ => Some(std::iter::once(name).chain(rest.iter().take(2).cloned()).collect::<Vec<_>>().join(" ")),
    }
}

/// The program a word names: its file name, with npm package names mapped to their binaries.
fn program_name(word: &str) -> String {
    let base = word.rsplit('/').next().unwrap_or(word);
    let package = word.trim_start_matches('@');
    let package = package.split('@').next().unwrap_or(package);
    match package {
        "openai/codex" => "codex".into(),
        "anthropic-ai/claude-code" => "claude".into(),
        _ => base.into(),
    }
}

fn is_assignment(word: &str) -> bool {
    word.split_once('=').is_some_and(|(name, _)| !name.is_empty()
        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        && !name.starts_with(|c: char| c.is_ascii_digit()))
}

fn is_redirect(word: &str) -> bool {
    word.trim_start_matches(|c: char| c.is_ascii_digit()).starts_with(['<', '>'])
}

/// A wrapper's option whose value is the next word.
fn takes_value(wrapper: &str, flag: &str) -> bool {
    let flags: &[&str] = match wrapper {
        "env" => &["-u", "-C", "--unset", "--chdir"],
        "nice" => &["-n"],
        "timeout" | "gtimeout" => &["-s", "-k", "--signal", "--kill-after"],
        "sudo" => &["-u", "-g", "-C", "-D", "-h", "-p", "-U"],
        "xargs" => &["-I", "-J", "-L", "-n", "-P", "-s", "-d", "-E", "-a", "-R", "-S"],
        "parallel" => &["-j", "--jobs"],
        "caffeinate" => &["-t", "-w"],
        "watch" => &["-n", "--interval"],
        _ => &[],
    };
    flags.contains(&flag)
}

/// A wrapper's own option, option value, assignment or duration.
fn skippable_arg(word: &str) -> bool {
    word.starts_with('-') || is_assignment(word) || is_redirect(word) || !word.chars().any(|c| c.is_ascii_alphabetic())
        || word.trim_end_matches(['s', 'm', 'h', 'd']).parse::<f64>().is_ok()
}

/// Splits a shell script into simple commands' words, outside quotes, on
/// `;`, `&`, `|`, newlines, parentheses, braces and backticks. Comments end
/// at the line's end. Heredoc bodies read as commands, which is the safe side.
fn simple_commands(script: &str) -> Vec<Vec<String>> {
    let mut commands = Vec::new();
    let (mut words, mut word, mut in_word) = (Vec::new(), String::new(), false);
    let mut chars = script.chars().peekable();
    let end_word = |words: &mut Vec<String>, word: &mut String, in_word: &mut bool| {
        if *in_word { words.push(std::mem::take(word)); *in_word = false; }
    };
    while let Some(c) = chars.next() {
        match c {
            '\'' => {
                in_word = true;
                for c in chars.by_ref() { if c == '\'' { break; } word.push(c); }
            }
            '"' => {
                in_word = true;
                while let Some(c) = chars.next() {
                    match c {
                        '"' => break,
                        '\\' => if let Some(next) = chars.next() { word.push(next) },
                        c => word.push(c),
                    }
                }
            }
            '\\' => if let Some(next) = chars.next().filter(|c| *c != '\n') { in_word = true; word.push(next) },
            '#' if !in_word => { for c in chars.by_ref() { if c == '\n' { break; } } end_command(&mut commands, &mut words); }
            ';' | '&' | '|' | '\n' | '(' | ')' | '`' | '{' | '}' => {
                end_word(&mut words, &mut word, &mut in_word);
                end_command(&mut commands, &mut words);
            }
            '$' if chars.peek() == Some(&'(') => {
                end_word(&mut words, &mut word, &mut in_word);
                end_command(&mut commands, &mut words);
            }
            c if c.is_whitespace() => end_word(&mut words, &mut word, &mut in_word),
            c => { in_word = true; word.push(c); }
        }
    }
    end_word(&mut words, &mut word, &mut in_word);
    end_command(&mut commands, &mut words);
    commands
}

fn end_command(commands: &mut Vec<Vec<String>>, words: &mut Vec<String>) {
    if !words.is_empty() { commands.push(std::mem::take(words)); }
}

/// Command substitutions inside double quotes, which still run.
fn substitutions(script: &str) -> Vec<String> {
    let mut found = Vec::new();
    let mut in_double = false;
    let chars: Vec<char> = script.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        match chars[i] {
            '\\' => i += 1,
            '"' => in_double = !in_double,
            '\'' if !in_double => {
                i += 1;
                while i < chars.len() && chars[i] != '\'' { i += 1; }
            }
            '$' if in_double && chars.get(i + 1) == Some(&'(') => {
                let (start, mut depth) = (i + 2, 1);
                i += 2;
                while i < chars.len() && depth > 0 {
                    match chars[i] { '(' => depth += 1, ')' => depth -= 1, _ => {} }
                    i += 1;
                }
                found.push(chars[start..i.saturating_sub(1).max(start)].iter().collect());
                continue;
            }
            '`' if in_double => {
                let start = i + 1;
                i += 1;
                while i < chars.len() && chars[i] != '`' { i += 1; }
                found.push(chars[start..i.min(chars.len())].iter().collect());
            }
            _ => {}
        }
        i += 1;
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn catches_model_runs_however_they_are_written() {
        for command in [
            "codex exec 'review src/' > /tmp/astra-scan/1.md 2>&1 &",
            "mkdir -p /tmp/astra-scan && for i in 1 2 3; do nohup codex exec -m gpt-6-astra -c model_reasoning_effort=xhigh \"scan part $i\" > /tmp/astra-scan/$i.log 2>&1 & done",
            "OPENAI_LOG=1 /Users/me/.local/bin/codex exec --full-auto 'x'",
            "env -u FOO CODEX_HOME=~/.codex ~/.local/bin/codex e 'x'",
            "timeout 600 codex review",
            "nice -n 5 caffeinate -i codex -m gpt-6-astra exec 'x'",
            "codex 'just do it'",
            "cd app; codex",
            "claude -p 'review this'",
            "claude --print --model opus 'x' &",
            "echo 'review' | claude --output-format json -p",
            "seq 7 | xargs -P 7 -I {} codex exec 'part {}'",
            "bash -lc 'codex exec x'",
            "sh -c \"cd /tmp && claude -p hi\"",
            "eval \"codex exec x\"",
            "out=$(codex exec x)",
            "echo \"$(claude -p summarize)\"",
            "echo `codex exec x`",
            "npx @openai/codex@latest exec 'x'",
            "pnpm dlx @anthropic-ai/claude-code -p 'x'",
            "(codex exec a &) ; (codex exec b &)",
            "cat <<'EOF' | bash\ncodex exec x\nEOF",
            "if true; then codex exec x; fi",
            "codex \\\n  exec x",
        ] {
            assert!(runs_model(command).is_some(), "missed: {command}");
        }
    }

    #[test]
    fn leaves_ordinary_commands_alone() {
        for command in [
            "git log --oneline | grep codex",
            "echo 'codex exec is not allowed'",
            "rg -n \"claude -p\" src/",
            "ps aux | grep -i codex",
            "pkill -f 'codex exec'",
            "which codex claude",
            "ls ~/.codex # codex exec later",
            "codex --version && claude --version",
            "codex login status; claude mcp list",
            "cat /tmp/astra-scan/1.log",
            "squircle thread spawn --coordinator t --title 'Astra review' --branch r1 --prompt 'review' --provider codex --model gpt-6-astra --effort xhigh",
            "timeout 5 grep codex README.md",
            "FOO=codex make",
            "echo \"$(date) codex exec\"",
            "brew info claude",
        ] {
            assert_eq!(runs_model(command), None, "flagged: {command}");
        }
    }

    #[test]
    fn denies_subagents_and_workflows_only() {
        let event = |tool: &str, input: Value| json!({"hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": input});
        assert!(check(&event("Agent", json!({"prompt": "review"})), "squircle").is_some());
        assert!(check(&event("Task", json!({"prompt": "review"})), "squircle").is_some());
        assert!(check(&event("Workflow", json!({"script": ""})), "squircle").is_some());
        let denied = check(&event("Bash", json!({"command": "codex exec x &"})), "sq").unwrap();
        assert!(denied.contains("sq thread spawn") && denied.contains("--provider codex"));
        assert_eq!(check(&event("Bash", json!({"command": "cargo test"})), "sq"), None);
        assert_eq!(check(&event("TaskCreate", json!({"subject": "x"})), "sq"), None);
        assert_eq!(check(&event("Read", json!({"file_path": "/x"})), "sq"), None);
    }
}
