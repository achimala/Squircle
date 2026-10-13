//! Recordings and images an agent publishes into a T3 thread, so the phone
//! can show them inline. Files live under `<data>/threads/<thread>/media/`.

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Media {
    pub id: String,
    pub thread_id: String,
    /// "video" or "image".
    pub kind: String,
    pub caption: String,
    pub content_type: String,
    pub bytes: u64,
    /// Seconds since 1970, fractional.
    pub created_at: f64,
    pub file: PathBuf,
    /// Set when Squircle recorded a simulator session (`squircle sim`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub simulator: Option<SimulatorClip>,
}

/// Which simulator session a recording covers, so the phone can show it in
/// the turn where it began.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SimulatorClip {
    pub session_id: String,
    pub device_id: String,
    pub device_name: String,
    pub started_at: f64,
    pub ended_at: f64,
}

const MAX_BYTES: u64 = 512 * 1024 * 1024;

pub fn valid_thread(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

fn directory(root: &Path, thread: &str) -> Result<PathBuf> {
    if !valid_thread(thread) {
        bail!("Thread ID must be a T3 thread identifier");
    }
    Ok(root.join("threads").join(thread).join("media"))
}

fn kind(path: &Path) -> Result<(&'static str, &'static str)> {
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
    Ok(match ext.as_str() {
        "mp4" => ("video", "video/mp4"),
        "mov" => ("video", "video/quicktime"),
        "m4v" => ("video", "video/x-m4v"),
        "png" => ("image", "image/png"),
        "jpg" | "jpeg" => ("image", "image/jpeg"),
        _ => bail!("Unsupported media type .{ext}; use mp4, mov, m4v, png or jpg"),
    })
}

/// Copies `file` into the thread's media; returns its record.
pub fn add(root: &Path, thread: &str, file: &Path, caption: Option<&str>) -> Result<Media> {
    store(root, thread, file, caption, None, false)
}

/// Moves a finished simulator recording into the thread's media.
pub fn add_recording(root: &Path, thread: &str, file: &Path, clip: SimulatorClip) -> Result<Media> {
    store(root, thread, file, None, Some(clip), true)
}

/// Where a recording in progress is written: beside the media it will join,
/// hidden from listings until it is moved in.
pub fn recording_path(root: &Path, thread: &str, session: &str) -> Result<PathBuf> {
    let dir = directory(root, thread)?;
    fs::create_dir_all(&dir)?;
    Ok(dir.join(format!(".{session}.recording.mp4")))
}

fn store(root: &Path, thread: &str, file: &Path, caption: Option<&str>, simulator: Option<SimulatorClip>, take: bool) -> Result<Media> {
    let dir = directory(root, thread)?;
    let (kind, content_type) = kind(file)?;
    let size = fs::metadata(file).with_context(|| format!("Reading {}", file.display()))?.len();
    if size == 0 || size > MAX_BYTES {
        bail!("Media must be between 1 byte and 512 MB");
    }
    fs::create_dir_all(&dir)?;
    let id = uuid::Uuid::new_v4().to_string();
    let ext = file.extension().and_then(|e| e.to_str()).unwrap_or("bin").to_ascii_lowercase();
    let stored = dir.join(format!("{id}.{ext}"));
    let partial = dir.join(format!(".{id}.partial"));
    if take {
        fs::rename(file, &stored).context("Moving the recording into media")?;
    } else {
        fs::copy(file, &partial).context("Copying media")?;
        fs::rename(&partial, &stored)?;
    }
    // A recording belongs where its session began.
    let created_at = match &simulator {
        Some(clip) => clip.started_at,
        None => SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs_f64(),
    };
    let media = Media {
        id: id.clone(),
        thread_id: thread.into(),
        kind: kind.into(),
        caption: caption.unwrap_or("").trim().chars().take(300).collect(),
        content_type: content_type.into(),
        bytes: size,
        created_at,
        file: stored,
        simulator,
    };
    let record = dir.join(format!("{id}.json"));
    let partial = dir.join(format!(".{id}.json.partial"));
    fs::write(&partial, serde_json::to_vec_pretty(&media)?)?;
    fs::rename(&partial, &record)?;
    Ok(media)
}

pub fn list(root: &Path, thread: &str) -> Result<Vec<Media>> {
    let dir = directory(root, thread)?;
    let Ok(entries) = fs::read_dir(&dir) else { return Ok(Vec::new()) };
    let mut items: Vec<Media> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "json"))
        .filter_map(|p| fs::read(&p).ok().and_then(|b| serde_json::from_slice::<Media>(&b).ok()))
        // Only ever serve the file beside its record, whatever path the
        // record names (the data directory may have been given relatively).
        .filter_map(|mut m| {
            let name = m.file.file_name()?.to_owned();
            m.file = dir.join(name);
            m.file.is_file().then_some(m)
        })
        .collect();
    items.sort_by(|a, b| a.created_at.total_cmp(&b.created_at));
    Ok(items)
}

pub fn get(root: &Path, thread: &str, id: &str) -> Result<Media> {
    uuid::Uuid::parse_str(id).context("Media ID must be a UUID")?;
    list(root, thread)?
        .into_iter()
        .find(|m| m.id == id)
        .context("No such media in this thread")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adds_lists_and_rejects_bad_input() {
        let root = tempfile::tempdir().unwrap();
        let clip = root.path().join("demo.mp4");
        fs::write(&clip, b"not really a movie").unwrap();
        let thread = "c3e60882-f28f-4656-879d-99b3e2dcddbb";
        let media = add(root.path(), thread, &clip, Some("Tapping through onboarding")).unwrap();
        assert_eq!(media.kind, "video");
        let listed = list(root.path(), thread).unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].caption, "Tapping through onboarding");
        assert_eq!(get(root.path(), thread, &media.id).unwrap().bytes, 18);
        assert!(add(root.path(), "../etc", &clip, None).is_err());
        let text = root.path().join("notes.txt");
        fs::write(&text, b"x").unwrap();
        assert!(add(root.path(), thread, &text, None).is_err());
    }
}
