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

/// Skip only the parsed test modules, including nested ones. A suffix after a
/// test module is still production code. Parsing avoids braces inside strings,
/// comments and macro bodies accidentally hiding that suffix.
fn test_lines(text: &str) -> Vec<std::ops::RangeInclusive<usize>> {
    use syn::{spanned::Spanned, visit::Visit};
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
    let mut tests = Tests::default();
    let file = syn::parse_file(text).expect("valid Rust source");
    if test_only(&file.attrs) {
        return std::iter::once(1..=text.lines().count()).collect();
    }
    tests.visit_file(&file);
    tests.0
}

#[test]
fn test_exclusion_keeps_later_production_code() {
    let source = "#[cfg(test)]\nmod tests { const S: &str = r#\"}\"#; }\nfn later() {}\nmod nested {\n#[cfg(test)] mod tests {}\nfn also_later() {}\n}";
    assert_eq!(test_lines("#![cfg(test)]\nfn fake() {}"), vec![1..=2]);
    let skipped = test_lines(source);
    assert!(skipped.iter().any(|r| r.contains(&2)));
    assert!(!skipped.iter().any(|r| r.contains(&3)));
    assert!(skipped.iter().any(|r| r.contains(&5)));
    assert!(!skipped.iter().any(|r| r.contains(&6)));
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
        let skipped = test_lines(&text);
        for (number, line) in text.lines().enumerate() {
            if skipped.iter().any(|range| range.contains(&(number + 1))) {
                continue;
            }
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
