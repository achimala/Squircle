//! Every build checks the service's two concurrency rules (AGENTS.md):
//!
//! 1. **No locks.** State is shared only through single owners
//!    (`src/actor.rs`, docs/fsm-architecture.md §4): no mutex, read-write
//!    lock, semaphore, file lock or blocking wait in the service's own code,
//!    so a deadlock can't be written. Test fakes may keep leaf locks.
//! 2. **No waits or timers.** Code waits for the event it needs (an owner's
//!    message, a channel closing, a process exiting, a file changing, a T3
//!    event), never for a time. The only clock is `src/clock.rs`; each place
//!    that waits on it is a policy rule listed in `POLICY_CLOCKS` with its
//!    reason. Tests never sleep: timed policy runs on tokio's paused clock
//!    through `clock::elapse`.
//!
//! It reads the token stream (comments are gone, strings are literals, macro
//! bodies such as `select!` are included), so text inside strings or after
//! `http://` neither hides nor fakes anything. A violation fails the build.

use proc_macro2::{Delimiter, TokenStream, TokenTree};
use std::path::{Path, PathBuf};

/// Lock types and the calls that block a thread until something else happens.
const LOCKS: [&str; 11] = [
    "Mutex",
    "RwLock",
    "Condvar",
    "Barrier",
    "Semaphore",
    "parking_lot",
    "blocking_recv",
    "blocking_send",
    "blocking_lock",
    "block_on",
    "get_or_init",
];

/// Paths (by their last segments) that block a thread in production code.
const BLOCKING_PATHS: [&str; 3] = ["thread::sleep", "std::process::Command", "std::sync::mpsc"];

/// Paths that wait for a time, anywhere outside `src/clock.rs`.
const TIMER_PATHS: [&str; 10] = [
    "time::sleep",
    "time::sleep_until",
    "time::timeout",
    "time::timeout_at",
    "time::interval",
    "time::interval_at",
    "time::advance",
    "time::pause",
    "time::*",
    "task::yield_now",
];

/// Methods that wait on a lock or a channel unless awaited.
const BLOCKING_METHODS: [&str; 4] = ["lock", "lock_shared", "recv", "recv_timeout"];

/// Where production code waits on the clock: the policy rule each one is.
/// Adding a wait means adding it here, with the rule the user chose; a wait
/// that isn't a rule should wait for its event instead.
const POLICY_CLOCKS: [(&str, usize, &str); 11] = [
    (
        "src/agents/lifecycle.rs",
        1,
        "a failed reset's retry pacing",
    ),
    (
        "src/agents/outbox_driver.rs",
        1,
        "wake-ups coalesce a few seconds; failed deliveries back off",
    ),
    (
        "src/agents/runtime.rs",
        1,
        "T3 reconnect pacing (nothing announces T3 listening)",
    ),
    (
        "src/agents/upkeep.rs",
        1,
        "compaction and fresh-start idle thresholds, the nightly hour",
    ),
    (
        "src/preview.rs",
        1,
        "settle before a preview screenshot (no event says an app has drawn)",
    ),
    (
        "src/push/delivery.rs",
        3,
        "alert coalescing, alert retry pacing, the activity policy's next due time",
    ),
    ("src/server/runtime.rs", 1, "tasks age into History"),
    (
        "src/service.rs",
        2,
        "launchd tells a job's state only to launchctl print",
    ),
    (
        "src/simpool.rs",
        1,
        "the pool applies its policy every minute (simctl announces nothing)",
    ),
    (
        "src/sims/maintenance.rs",
        1,
        "idle grace, recording limit, owed cleanup retries",
    ),
    (
        "src/simwatch.rs",
        2,
        "the simulator host's hang deadline; runaway CPU sampling",
    ),
];

/// Exact lines allowed despite a rule above, with why.
const EXCEPTIONS: [(&str, &str, &str); 3] = [
    (
        "src/actor.rs",
        "type Turn = tokio::sync::Mutex<()>;",
        "the one lock: a lane's turn, entered only in rank order",
    ),
    (
        "src/cli/poll.rs",
        "let (response, etag) = match tokio::time::timeout_at(deadline, fetch(held.take())).await {",
        "the caller's own --timeout",
    ),
    (
        "src/cli/builds.rs",
        "let submitted = tokio::time::timeout_at(",
        "the caller's own --timeout",
    ),
];

fn main() {
    let root = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=src");
    println!("cargo:rerun-if-changed=tests");
    let mut files = vec![];
    for dir in ["src", "tests"] {
        sources(&root.join(dir), &mut files);
    }
    files.sort();
    let mut found = vec![];
    let mut clocks: Vec<(String, usize)> = vec![];
    for file in files {
        let name = file
            .strip_prefix(&root)
            .unwrap()
            .to_string_lossy()
            .into_owned();
        let text = std::fs::read_to_string(&file).unwrap();
        let Ok(tokens) = text.parse::<TokenStream>() else {
            // Let rustc report what doesn't even lex.
            continue;
        };
        let tests = test_lines(&text, name.starts_with("tests/"));
        let lines: Vec<&str> = text.lines().collect();
        let mut scan = Scan::default();
        scan.walk(tokens, &[], false);
        let allowed = |line: usize| {
            let code = lines.get(line - 1).map_or("", |l| l.trim());
            EXCEPTIONS
                .iter()
                .any(|(file, exact, _)| *file == name && code == *exact)
        };
        let mut report = |line: usize, what: &str| {
            if !allowed(line) {
                let code = lines.get(line - 1).map_or("", |l| l.trim());
                found.push(format!("{name}:{line}: {what}: {code}"));
            }
        };
        let in_test = |line: usize| tests.iter().any(|r| r.contains(&line));
        let clock_module = name == "src/clock.rs";
        for (line, path) in &scan.paths {
            let test = in_test(*line);
            if !test && path.split("::").any(|segment| LOCKS.contains(&segment)) {
                report(*line, &format!("lock or blocking wait `{path}`"));
            }
            if !test && BLOCKING_PATHS.iter().any(|p| names(path, p)) {
                report(*line, &format!("blocks a thread `{path}`"));
            }
            if !clock_module && TIMER_PATHS.iter().any(|p| names(path, p)) {
                report(*line, &format!("waits for a time `{path}`"));
            }
        }
        for (line, method, awaited) in &scan.methods {
            let test = in_test(*line);
            if !test && !awaited && BLOCKING_METHODS.contains(&method.as_str()) {
                report(*line, &format!("blocking `.{method}()`"));
            }
            if !clock_module && method == "timeout" {
                report(*line, "a time limit `.timeout()`");
            }
        }
        if !clock_module {
            let waits = scan
                .paths
                .iter()
                .filter(|(line, path)| {
                    !in_test(*line)
                        && ["clock::after", "clock::until", "clock::reach"]
                            .iter()
                            .any(|p| names(path, p))
                })
                .count();
            if waits > 0 {
                clocks.push((name.clone(), waits));
            }
        }
    }
    for (file, count, rule) in POLICY_CLOCKS {
        let actual = clocks
            .iter()
            .find(|(name, _)| name == file)
            .map_or(0, |(_, n)| *n);
        if actual != count {
            found.push(format!(
                "{file}: waits on the clock {actual} times; POLICY_CLOCKS lists {count} ({rule})"
            ));
        }
    }
    for (file, count) in &clocks {
        if !POLICY_CLOCKS.iter().any(|(listed, _, _)| listed == file) {
            found.push(format!(
                "{file}: waits on the clock {count} times and isn't in POLICY_CLOCKS"
            ));
        }
    }
    if !found.is_empty() {
        panic!(
            "\nNo locks and no waits (AGENTS.md; build.rs explains the rules):\n{}\n\n\
            Share state through a crate::actor::Owner (readers use a Snapshot; non-overlapping \
            async work a ranked Lane), and wait for the event that matters: an owner's message, \
            a channel closing, a process exiting (crate::kq), a file changing, a T3 event. A \
            duration the user chose as a rule goes through crate::clock and into POLICY_CLOCKS; \
            tests advance tokio's paused clock with crate::clock::elapse.\n",
            found.join("\n")
        );
    }
}

/// Whether `path` names `pattern`'s segments in a row (`std::process::Command`
/// in `std::process::Command::new`).
fn names(path: &str, pattern: &str) -> bool {
    let path: Vec<&str> = path.split("::").collect();
    let pattern: Vec<&str> = pattern.split("::").collect();
    path.windows(pattern.len()).any(|w| w == pattern.as_slice())
}

fn sources(dir: &Path, found: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries {
        let path = entry.unwrap().path();
        if path.is_dir() {
            sources(&path, found);
        } else if path.extension().is_some_and(|e| e == "rs") {
            found.push(path);
        }
    }
}

/// Paths (`a::b::c`, use groups expanded) and method calls, with their lines.
#[derive(Default)]
struct Scan {
    paths: Vec<(usize, String)>,
    /// Line, method name, and whether `.await` follows the call.
    methods: Vec<(usize, String, bool)>,
}

impl Scan {
    /// `selecting`: inside `select!`, whose branches are awaited by it.
    fn walk(&mut self, stream: TokenStream, prefix: &[String], selecting: bool) {
        let tokens: Vec<TokenTree> = stream.into_iter().collect();
        let mut i = 0;
        let mut element_start = true;
        while i < tokens.len() {
            match &tokens[i] {
                TokenTree::Ident(ident) => {
                    let line = ident.span().start().line;
                    // A method call: `.name(…)`, awaited or not.
                    let dotted = i > 0 && is_punct(&tokens[i - 1], '.');
                    if dotted
                        && matches!(tokens.get(i + 1), Some(TokenTree::Group(g)) if g.delimiter() == Delimiter::Parenthesis)
                    {
                        let awaited = selecting
                            || (tokens.get(i + 2).is_some_and(|t| is_punct(t, '.'))
                                && matches!(tokens.get(i + 3), Some(TokenTree::Ident(a)) if a == "await"));
                        self.methods.push((line, ident.to_string(), awaited));
                        i += 1;
                        element_start = false;
                        continue;
                    }
                    // A path: ident (:: ident)*, then maybe :: { group } or :: *.
                    let mut path: Vec<String> = if element_start {
                        prefix.to_vec()
                    } else {
                        vec![]
                    };
                    path.push(ident.to_string());
                    let mut j = i + 1;
                    loop {
                        let colons = tokens.get(j).is_some_and(|t| is_punct(t, ':'))
                            && tokens.get(j + 1).is_some_and(|t| is_punct(t, ':'));
                        if !colons {
                            break;
                        }
                        match tokens.get(j + 2) {
                            Some(TokenTree::Ident(next)) => {
                                path.push(next.to_string());
                                j += 3;
                            }
                            Some(TokenTree::Punct(p)) if p.as_char() == '*' => {
                                path.push("*".into());
                                j += 3;
                                break;
                            }
                            Some(TokenTree::Group(group))
                                if group.delimiter() == Delimiter::Brace =>
                            {
                                self.walk(group.stream(), &path, selecting);
                                j += 3;
                                path.clear();
                                break;
                            }
                            // Turbofish and the like: the path ends here.
                            _ => break,
                        }
                    }
                    // `tokio::select! { … }`: its futures are awaited.
                    if path.last().is_some_and(|last| last == "select")
                        && tokens.get(j).is_some_and(|t| is_punct(t, '!'))
                        && let Some(TokenTree::Group(body)) = tokens.get(j + 1)
                    {
                        self.walk(body.stream(), &[], true);
                        j += 2;
                    }
                    if !path.is_empty() {
                        self.paths.push((line, path.join("::")));
                    }
                    element_start = false;
                    i = j;
                    continue;
                }
                TokenTree::Group(group) => self.walk(group.stream(), &[], selecting),
                TokenTree::Punct(p) if p.as_char() == ',' || p.as_char() == ';' => {
                    element_start = true;
                    i += 1;
                    continue;
                }
                _ => {}
            }
            element_start = false;
            i += 1;
        }
    }
}

fn is_punct(token: &TokenTree, c: char) -> bool {
    matches!(token, TokenTree::Punct(p) if p.as_char() == c)
}

/// The line ranges of test code: `#[cfg(test)]` modules (nested ones too;
/// what follows one is still production code) and files that are tests
/// whole (`#![cfg(test)]`, or anything under `tests/`).
fn test_lines(text: &str, whole: bool) -> Vec<std::ops::RangeInclusive<usize>> {
    use syn::{spanned::Spanned, visit::Visit};
    let all = 1..=text.lines().count().max(1);
    if whole {
        return vec![all];
    }
    fn test_only(attrs: &[syn::Attribute]) -> bool {
        attrs.iter().any(|attr| {
            attr.path().is_ident("cfg")
                && attr
                    .parse_args::<syn::Path>()
                    .is_ok_and(|p| p.is_ident("test"))
        })
    }
    #[derive(Default)]
    struct Tests(Vec<std::ops::RangeInclusive<usize>>);
    impl<'ast> Visit<'ast> for Tests {
        fn visit_item_mod(&mut self, item: &'ast syn::ItemMod) {
            if test_only(&item.attrs) {
                self.0
                    .push(item.span().start().line..=item.span().end().line);
            } else {
                syn::visit::visit_item_mod(self, item);
            }
        }
    }
    let Ok(file) = syn::parse_file(text) else {
        return vec![];
    };
    if test_only(&file.attrs) {
        return vec![all];
    }
    let mut tests = Tests::default();
    tests.visit_file(&file);
    tests.0
}
