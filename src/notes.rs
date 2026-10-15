//! An app agent's notes: the few durable things worth knowing every turn
//! (the user's preferences, decisions, gotchas), kept per app (T3 project)
//! in `<data>/notes/<project>.json` and shown compactly in each turn's note.
//! Not a record of what happened: that stays in T3, tasks, builds and git
//! (`squircle history`).

use crate::store::{atomic_json, private_dir, read_json};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// One note's length, and all of them together: they ride in every turn.
const NOTE_CHARS: usize = 300;
const TOTAL_CHARS: usize = 4000;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Notes {
    pub notes: Vec<Note>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Note {
    pub text: String,
    pub updated_at: u64,
}

fn path(root: &Path, project: &str) -> Result<PathBuf> {
    ensure!(crate::t3steps::valid(project, &[]), "Invalid project ID");
    Ok(root.join("notes").join(format!("{project}.json")))
}

pub fn load(root: &Path, project: &str) -> Result<Notes> {
    let path = path(root, project)?;
    if !path.try_exists()? { return Ok(Notes::default()); }
    read_json(&path)
}

/// What a change does to the notes.
pub enum Change<'a> {
    Add(&'a str),
    /// 1-based, as `show` numbers them.
    Edit(usize, &'a str),
    Remove(usize),
}

pub fn change(root: &Path, project: &str, change: Change) -> Result<Notes> {
    let mut notes = load(root, project)?;
    let clean = |text: &str| -> Result<String> {
        let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
        ensure!(!text.is_empty(), "A note needs text");
        ensure!(text.chars().count() <= NOTE_CHARS, "Keep a note under {NOTE_CHARS} characters: one preference, decision or gotcha");
        Ok(text)
    };
    let index = |n: usize, len: usize| -> Result<usize> {
        ensure!(n >= 1 && n <= len, "No note {n}; notes show lists them");
        Ok(n - 1)
    };
    let now = crate::model::now();
    match change {
        Change::Add(text) => notes.notes.push(Note { text: clean(text)?, updated_at: now }),
        Change::Edit(n, text) => { let i = index(n, notes.notes.len())?; notes.notes[i] = Note { text: clean(text)?, updated_at: now }; }
        Change::Remove(n) => { let i = index(n, notes.notes.len())?; notes.notes.remove(i); }
    }
    let total: usize = notes.notes.iter().map(|n| n.text.chars().count()).sum();
    ensure!(total <= TOTAL_CHARS, "Notes are full ({total} of {TOTAL_CHARS} characters): merge, shorten or remove some first");
    let path = path(root, project)?;
    private_dir(path.parent().context("notes path")?)?;
    atomic_json(&path, &notes)?;
    Ok(notes)
}

/// Numbered, one per line.
pub fn listing(notes: &Notes) -> String {
    notes.notes.iter().enumerate().map(|(i, n)| format!("{}. {}\n", i + 1, n.text)).collect()
}
