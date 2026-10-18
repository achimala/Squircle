//! Service state is shared only through single owners (`src/actor.rs`,
//! docs/fsm-architecture.md §4): no lock and no blocking wait in the
//! service's own code, so a deadlock can't be written. `cargo clippy`
//! enforces the same through clippy.toml; this holds it without clippy.
//! Test modules are skipped: their fakes record calls behind leaf locks.

use std::path::{Path, PathBuf};

/// Locks, and the calls that block a thread until something else happens.
const BANNED: [&str; 9] = [
    "Mutex",
    "RwLock",
    "Condvar",
    "parking_lot",
    "blocking_recv",
    "blocking_send",
    "blocking_lock",
    "block_on",
    "get_or_init",
];

/// The one lock: a lane's turn, entered only in rank order (`actor::Lane`).
const ALLOWED: [(&str, &str); 1] = [("src/actor.rs", "type Turn = tokio::sync::Mutex<()>;")];

fn sources(dir: &Path, found: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            sources(&path, found);
        } else if path.extension().is_some_and(|e| e == "rs") {
            found.push(path);
        }
    }
}

/// The file without its test module (`#[cfg(test)]` then `mod tests`).
fn without_tests(text: &str) -> &str {
    let lines: Vec<&str> = text.lines().collect();
    let start = lines.iter().enumerate().find(|(i, line)| {
        line.trim() == "#[cfg(test)]"
            && lines[i + 1..]
                .iter()
                .take(4)
                .any(|l| l.trim_start().starts_with("mod tests"))
    });
    match start {
        Some((i, _)) => &text[..lines[..i].iter().map(|l| l.len() + 1).sum::<usize>()],
        None => text,
    }
}

#[test]
fn the_service_shares_state_only_through_owners() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut files = vec![];
    sources(&root.join("src"), &mut files);
    let mut found = vec![];
    for file in files {
        let name = file
            .strip_prefix(root)
            .unwrap()
            .to_string_lossy()
            .into_owned();
        let text = std::fs::read_to_string(&file).unwrap();
        for (number, line) in without_tests(&text).lines().enumerate() {
            let code = line.split("//").next().unwrap_or("");
            for word in BANNED.iter().filter(|word| code.contains(*word)) {
                if !ALLOWED
                    .iter()
                    .any(|(allowed, exact)| *allowed == name && line.trim() == *exact)
                {
                    found.push(format!("{name}:{}: {word}: {}", number + 1, line.trim()));
                }
            }
        }
    }
    assert!(
        found.is_empty(),
        "Share state through a crate::actor::Owner (readers use a Snapshot; \
        non-overlapping async work a ranked Lane) instead of:\n{}",
        found.join("\n")
    );
    let manifest = std::fs::read_to_string(root.join("Cargo.toml")).unwrap();
    assert!(
        !manifest.contains("parking_lot"),
        "parking_lot is a lock crate"
    );
}
