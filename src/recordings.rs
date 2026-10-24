//! Making screen recordings light without losing a frame. simctl's own
//! encoder runs at a high fixed bitrate (its H.264 about 20 Mbit/s at full
//! device resolution), so a long session ran to gigabytes. Each recording is
//! re-encoded once with VideoToolbox HEVC at constant quality: full
//! resolution, every frame at its own timestamp (simctl records only when the
//! screen changes), long GOPs for mostly still UI, `hvc1` with the index up
//! front so AVFoundation plays it inline. The new file replaces the old one
//! under the same name, atomically, only after it decodes with the same
//! frames and duration. Measurements: docs/t3-native-migration.md
//! §"Light recordings".

use anyhow::{Context, Result, bail, ensure};
use serde::Serialize;
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use tokio::process::Command;

/// Constant quality for `hevc_videotoolbox` (1-100). 55 keeps small text and
/// paper texture as sharp as the source at a tenth of its size or less.
pub const QUALITY: u32 = 55;
/// Frames between keyframes: scrubbing stays quick, still screens cost little.
const GOP: u32 = 300;
/// Written into every light file so it is never encoded twice.
pub const MARK: &str = "squircle-light-1";
/// Files smaller than this aren't worth a pass.
pub const SMALL: u64 = 2_000_000;

/// ffmpeg and ffprobe (Homebrew's; macOS ships no encoder with a quality
/// setting). `SQUIRCLE_FFMPEG` names ffmpeg explicitly; ffprobe sits beside it.
#[derive(Clone, Debug)]
pub struct Tools {
    pub ffmpeg: PathBuf,
    pub ffprobe: PathBuf,
}

impl Tools {
    pub fn find() -> Result<Self> {
        let ffmpeg = match std::env::var_os("SQUIRCLE_FFMPEG") {
            Some(path) => PathBuf::from(path),
            None => {
                let path = std::env::var_os("PATH").unwrap_or_default();
                // The first folder with both (a lone wrapper script may shadow ffmpeg).
                std::env::split_paths(&path)
                    .chain(["/opt/homebrew/bin".into(), "/usr/local/bin".into()])
                    .map(|dir| dir.join("ffmpeg"))
                    .find(|p| p.is_file() && p.with_file_name("ffprobe").is_file())
                    .context(
                        "ffmpeg is not installed (brew install ffmpeg), or set SQUIRCLE_FFMPEG",
                    )?
            }
        };
        let ffprobe = ffmpeg.with_file_name("ffprobe");
        ensure!(ffprobe.is_file(), "No ffprobe beside {}", ffmpeg.display());
        Ok(Self { ffmpeg, ffprobe })
    }
}

/// What a movie file holds, as far as deciding and verifying go.
#[derive(Clone, Debug, Serialize)]
pub struct Probe {
    pub bytes: u64,
    pub codec: String,
    pub width: u64,
    pub height: u64,
    /// Frames shown (packets not marked discard).
    pub frames: u64,
    pub duration: f64,
    pub light: bool,
}

/// Whether a file gets a pass.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    Shrink,
    AlreadyLight,
    Small,
}

impl Probe {
    pub fn verdict(&self) -> Verdict {
        if self.light {
            Verdict::AlreadyLight
        } else if self.bytes < SMALL {
            Verdict::Small
        } else {
            Verdict::Shrink
        }
    }

    /// A rough size after a pass, for --dry-run: about 4.5 KB a frame at
    /// 1206×2622 (measured: 4.1 on constant animation, 1.1 on mostly still
    /// screens), scaled by pixels; never more than the file now.
    pub fn estimate(&self) -> u64 {
        let pixels = (self.width * self.height) as f64 / (1206.0 * 2622.0);
        ((self.frames as f64 * 4500.0 * pixels) as u64).min(self.bytes)
    }
}

pub async fn probe(tools: &Tools, path: &Path) -> Result<Probe> {
    let bytes = std::fs::metadata(path)?.len();
    let output = Command::new(&tools.ffprobe)
        .args(["-v", "error", "-select_streams", "v:0", "-of", "json"])
        .args([
            "-show_entries",
            "stream=codec_name,width,height:format=duration:format_tags=comment",
        ])
        .arg(path)
        .stdin(Stdio::null())
        .output()
        .await
        .context("Cannot run ffprobe")?;
    ensure!(
        output.status.success(),
        "ffprobe cannot read {}: {}",
        path.display(),
        String::from_utf8_lossy(&output.stderr).trim()
    );
    let info: Value = serde_json::from_slice(&output.stdout)?;
    let stream = &info["streams"][0];
    let codec = stream["codec_name"]
        .as_str()
        .context("No video stream")?
        .to_string();
    let duration = info["format"]["duration"]
        .as_str()
        .and_then(|d| d.parse().ok())
        .context("No duration")?;
    let light = info["format"]["tags"]["comment"].as_str() == Some(MARK);
    Ok(Probe {
        bytes,
        codec,
        width: stream["width"].as_u64().unwrap_or(0),
        height: stream["height"].as_u64().unwrap_or(0),
        frames: shown_frames(tools, path).await?,
        duration,
        light,
    })
}

/// Frames a player shows: the video packets not flagged discard (an edit
/// list's lead-in). Reads the index, not the pictures.
async fn shown_frames(tools: &Tools, path: &Path) -> Result<u64> {
    let output = Command::new(&tools.ffprobe)
        .args([
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "packet=flags",
        ])
        .args(["-of", "csv=p=0"])
        .arg(path)
        .stdin(Stdio::null())
        .output()
        .await
        .context("Cannot run ffprobe")?;
    ensure!(
        output.status.success(),
        "ffprobe cannot list the packets of {}",
        path.display()
    );
    Ok(count_shown(&String::from_utf8_lossy(&output.stdout)))
}

/// ffprobe's packet flags, one line each (`K__`, `___`, `_D_`): the ones
/// without D are shown.
fn count_shown(flags: &str) -> u64 {
    flags
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.contains('D'))
        .count() as u64
}

/// Decodes every picture of `path`; the number decoded, or an error if any
/// failed.
async fn decoded_frames(tools: &Tools, path: &Path) -> Result<u64> {
    let output = Command::new(&tools.ffprobe)
        .args(["-v", "error", "-count_frames", "-select_streams", "v:0"])
        .args(["-show_entries", "stream=nb_read_frames", "-of", "csv=p=0"])
        .arg(path)
        .stdin(Stdio::null())
        .output()
        .await
        .context("Cannot run ffprobe")?;
    let errors = String::from_utf8_lossy(&output.stderr);
    ensure!(
        output.status.success() && errors.trim().is_empty(),
        "The new file does not decode cleanly: {}",
        errors.trim()
    );
    String::from_utf8_lossy(&output.stdout)
        .trim()
        .trim_end_matches(',')
        .parse()
        .context("ffprobe counted no frames")
}

/// Whether a re-encode kept the source: every frame, and its length within
/// half a second or 1% (the source's edit list can trim a lead-in).
pub fn matches(source: &Probe, frames: u64, duration: f64) -> Result<()> {
    ensure!(
        frames == source.frames,
        "The new file has {frames} frames; the source shows {}",
        source.frames
    );
    let slack = (source.duration * 0.01).max(0.5);
    ensure!(
        (duration - source.duration).abs() <= slack,
        "The new file lasts {duration:.2} s; the source {:.2} s",
        source.duration
    );
    Ok(())
}

#[derive(Debug, Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum Outcome {
    Replaced {
        before: u64,
        after: u64,
        frames: u64,
    },
    Skipped {
        verdict: Verdict,
    },
    /// Another process is re-encoding it now.
    Busy,
    /// The pass came out no smaller; the original stays.
    NotSmaller {
        before: u64,
        after: u64,
    },
}

/// Re-encodes `path` in place (see the module). The original stays unless
/// the new file is verified and smaller. A claim beside the file (a
/// non-blocking file lock the OS drops with its process) keeps the service
/// and a migration from encoding the same file at once.
pub async fn shrink(tools: &Tools, path: &Path) -> Result<Outcome> {
    let dir = path.parent().context("No folder")?;
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .context("No file name")?;
    let claim_path = dir.join(format!(".{name}.shrinking"));
    let claim = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&claim_path)?;
    match claim.try_lock() {
        Ok(()) => {}
        Err(std::fs::TryLockError::WouldBlock) => return Ok(Outcome::Busy),
        Err(std::fs::TryLockError::Error(error)) => return Err(error.into()),
    }
    let temporary = dir.join(format!(".{name}.light.mp4"));
    let result = encode_and_replace(tools, path, &temporary).await;
    let _ = std::fs::remove_file(&temporary);
    let _ = std::fs::remove_file(&claim_path);
    drop(claim);
    result
}

async fn encode_and_replace(tools: &Tools, path: &Path, temporary: &Path) -> Result<Outcome> {
    let source = probe(tools, path).await?;
    let verdict = source.verdict();
    if verdict != Verdict::Shrink {
        return Ok(Outcome::Skipped { verdict });
    }
    let output = Command::new(&tools.ffmpeg)
        .args([
            "-v",
            "error",
            "-nostdin",
            "-y",
            "-hwaccel",
            "videotoolbox",
            "-i",
        ])
        .arg(path)
        .args(["-map", "0:v:0", "-map", "0:a?", "-c:a", "copy"])
        // Every frame at its own time: no frame-rate conversion.
        .args(["-fps_mode", "passthrough", "-enc_time_base", "demux"])
        .args(["-c:v", "hevc_videotoolbox", "-q:v", &QUALITY.to_string()])
        .args(["-g", &GOP.to_string(), "-tag:v", "hvc1"])
        .args([
            "-movflags",
            "+faststart",
            "-metadata",
            &format!("comment={MARK}"),
        ])
        .args(["-f", "mp4"])
        .arg(temporary)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .output()
        .await
        .context("Cannot run ffmpeg")?;
    if !output.status.success() {
        bail!(
            "ffmpeg failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    let after = probe(tools, temporary).await?;
    matches(
        &source,
        decoded_frames(tools, temporary).await?,
        after.duration,
    )?;
    ensure!(after.codec == "hevc", "The new file is {}", after.codec);
    if after.bytes as f64 > source.bytes as f64 * 0.9 {
        return Ok(Outcome::NotSmaller {
            before: source.bytes,
            after: after.bytes,
        });
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(path)?.permissions().mode() & 0o777;
        std::fs::set_permissions(temporary, std::fs::Permissions::from_mode(mode))?;
    }
    std::fs::rename(temporary, path)?;
    if let Some(dir) = path.parent() {
        let _ = std::fs::File::open(dir).and_then(|d| d.sync_all());
    }
    crate::media::resized(path, after.bytes);
    Ok(Outcome::Replaced {
        before: source.bytes,
        after: after.bytes,
        frames: source.frames,
    })
}

// MARK: Migration (`squircle media shrink`)

/// A recording an earlier version left unfiled beside a thread's media: its
/// session failed to file it (over the old 512 MB cap) or was cut short.
#[derive(Debug, Serialize)]
pub struct Orphan {
    pub session: String,
    /// `threads` or `tasks`, and the thread's or task's ID.
    pub owner: &'static str,
    pub thread: String,
    /// The movie to keep: simctl's original, else avconvert's copy.
    pub file: Option<PathBuf>,
    pub bytes: u64,
    /// Its poster frames, which recovery files with it.
    pub posters: Vec<PathBuf>,
    /// Everything else of the session's: avconvert's partial segments and
    /// copies, logs, empty files. Deleted with --orphans.
    pub debris: Vec<PathBuf>,
    pub debris_bytes: u64,
}

impl Orphan {
    /// Every file of it.
    pub fn files(&self) -> impl Iterator<Item = &PathBuf> {
        self.file.iter().chain(&self.posters).chain(&self.debris)
    }
}

/// What a migration covers.
#[derive(Debug, Default)]
pub struct Plan {
    /// Filed videos (threads' and tasks' media) and their verdicts.
    pub filed: Vec<(PathBuf, Result<Probe>)>,
    pub orphans: Vec<Orphan>,
    /// Hidden recordings of a session still running (or that can't be
    /// proven stopped): never touched.
    pub live: Vec<PathBuf>,
}

fn is_video(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    [".mp4", ".mov", ".m4v"].iter().any(|e| lower.ends_with(e))
}

/// The session a hidden recording file belongs to, from its name
/// (`.SESSION.recording.mp4`, `.SESSION.recording.compact.mp4`, avconvert's
/// `.SESSION.recording.compact.mp4.sb-…-videoSegmentN.mp4`).
pub fn session_of(name: &str) -> Option<&str> {
    let rest = name.strip_prefix('.')?;
    let (session, tail) = rest.split_once('.')?;
    (uuid::Uuid::parse_str(session).is_ok() && tail.starts_with("recording.")).then_some(session)
}

/// Sessions the service's ledger says are over (finished or failed).
fn settled_sessions(root: &Path) -> std::collections::HashMap<String, Value> {
    let Ok(bytes) = std::fs::read(root.join("sims.json")) else {
        return Default::default();
    };
    let ledger: Value = serde_json::from_slice(&bytes).unwrap_or_default();
    ledger["sessions"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|s| Some((s["id"].as_str()?.to_string(), s.clone())))
        .collect()
}

/// Session IDs some running process names on its command line (a recorder
/// still writing, an avconvert still converting).
async fn running_sessions() -> String {
    tokio::process::Command::new("/bin/ps")
        .args(["-ww", "-A", "-o", "command="])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .output()
        .await
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

pub async fn plan(tools: &Tools, root: &Path) -> Result<Plan> {
    let mut plan = Plan::default();
    for owners in ["threads", "tasks"] {
        let Ok(entries) = std::fs::read_dir(root.join(owners)) else {
            continue;
        };
        let mut dirs: Vec<PathBuf> = entries.flatten().map(|e| e.path().join("media")).collect();
        dirs.sort();
        for dir in dirs {
            let Ok(files) = std::fs::read_dir(&dir) else {
                continue;
            };
            let mut files: Vec<PathBuf> = files.flatten().map(|e| e.path()).collect();
            files.sort();
            for file in files {
                let Some(name) = file.file_name().and_then(|n| n.to_str()) else {
                    continue;
                };
                if file.is_file()
                    && is_video(name)
                    && !name.starts_with('.')
                    && file.with_extension("json").is_file()
                {
                    let probe = probe(tools, &file).await;
                    plan.filed.push((file, probe));
                }
            }
        }
    }
    (plan.orphans, plan.live) = orphans(root).await;
    Ok(plan)
}

/// Hidden files of recording sessions that are over, grouped by session
/// (`.SESSION.recording.*` in threads' and tasks' media), and those of
/// sessions still recording (or not provably over), which nothing touches.
/// A file `media shrink` is working on (`.ID.mp4.shrinking`,
/// `.ID.mp4.light.mp4`) belongs to no session.
pub async fn orphans(root: &Path) -> (Vec<Orphan>, Vec<PathBuf>) {
    let ledger = settled_sessions(root);
    let processes = running_sessions().await;
    let mut hidden: std::collections::BTreeMap<(&'static str, String, String), Vec<PathBuf>> =
        Default::default();
    for owners in ["threads", "tasks"] {
        let Ok(entries) = std::fs::read_dir(root.join(owners)) else {
            continue;
        };
        for entry in entries.flatten() {
            let owner = entry.file_name().to_string_lossy().into_owned();
            let Ok(files) = std::fs::read_dir(entry.path().join("media")) else {
                continue;
            };
            for file in files.flatten().map(|e| e.path()) {
                let Some(name) = file.file_name().and_then(|n| n.to_str()) else {
                    continue;
                };
                if name.ends_with(".shrinking") || name.ends_with(".light.mp4") || !file.is_file() {
                    continue;
                }
                if let Some(session) = session_of(name) {
                    hidden
                        .entry((owners, owner.clone(), session.to_string()))
                        .or_default()
                        .push(file);
                }
            }
        }
    }
    let (mut orphans, mut live) = (Vec::new(), Vec::new());
    for ((owners, thread, session), mut files) in hidden {
        files.sort();
        let settled = match ledger.get(&session) {
            Some(s) => matches!(s["state"].as_str(), Some("finished" | "failed")),
            None => true,
        };
        if !settled || processes.contains(&session) {
            live.extend(files);
            continue;
        }
        let size = |p: &PathBuf| std::fs::metadata(p).map(|m| m.len()).unwrap_or(0);
        let named = |suffix: &str| {
            files
                .iter()
                .find(|f| f.to_str().is_some_and(|n| n.ends_with(suffix)) && size(f) > 0)
                .cloned()
        };
        let file = named(".recording.mp4").or_else(|| named(".recording.compact.mp4"));
        let (posters, debris): (Vec<PathBuf>, Vec<PathBuf>) = files
            .into_iter()
            .filter(|f| Some(f) != file.as_ref())
            .partition(|f| f.to_str().is_some_and(|n| n.contains(".recording.poster.")));
        orphans.push(Orphan {
            bytes: file.as_ref().map(size).unwrap_or(0),
            debris_bytes: debris.iter().map(size).sum(),
            session,
            owner: owners,
            thread,
            file,
            posters,
            debris,
        });
    }
    (orphans, live)
}

/// `media shrink --orphans=delete`: deletes every file of every orphan
/// (recordings, posters, avconvert's leftovers, logs); encodes nothing.
pub async fn delete_orphans(root: &Path, dry_run: bool) -> Value {
    let (orphans, live) = orphans(root).await;
    let (mut files, mut bytes, mut failed) = (Vec::new(), 0u64, Vec::new());
    for orphan in &orphans {
        for file in orphan.files() {
            let size = std::fs::metadata(file).map(|m| m.len()).unwrap_or(0);
            bytes += size;
            if !dry_run && let Err(error) = std::fs::remove_file(file) {
                failed.push(serde_json::json!({"file": file, "error": error.to_string()}));
            }
            files
                .push(serde_json::json!({"file": file, "mb": (size as f64 / 1e4).round() / 100.0}));
        }
    }
    serde_json::json!({
        "dry_run": dry_run,
        "sessions": orphans.len(),
        "recordings": orphans.iter().filter(|o| o.file.is_some()).count(),
        "files": files.len(),
        "gb": (bytes as f64 / 1e7).round() / 100.0,
        "failed": failed,
        "deleted": files,
        "live_untouched": live,
    })
}

/// The plan as numbers: what a run would do and roughly save.
pub fn summary(plan: &Plan) -> Value {
    let mut shrink = (0u64, 0u64, 0u64, 0u64);
    let (mut light, mut small, mut unreadable) = (0u64, 0u64, Vec::new());
    for (file, probe) in &plan.filed {
        match probe {
            Ok(p) => match p.verdict() {
                Verdict::Shrink => {
                    shrink.0 += 1;
                    shrink.1 += p.bytes;
                    shrink.2 += p.estimate();
                    shrink.3 += p.frames;
                }
                Verdict::AlreadyLight => light += 1,
                Verdict::Small => small += 1,
            },
            Err(error) => {
                unreadable.push(serde_json::json!({"file": file, "error": format!("{error:#}")}))
            }
        }
    }
    let orphan_bytes: u64 = plan.orphans.iter().map(|o| o.bytes).sum();
    let debris_bytes: u64 = plan.orphans.iter().map(|o| o.debris_bytes).sum();
    let gb = |b: u64| (b as f64 / 1e7).round() / 100.0;
    serde_json::json!({
        "filed": {
            "videos": plan.filed.len(),
            "to_shrink": shrink.0,
            "to_shrink_gb": gb(shrink.1),
            "estimated_after_gb": gb(shrink.2),
            "estimated_savings_gb": gb(shrink.1 - shrink.2),
            // Measured: about 170 frames a second to encode, then a decode to verify.
            "estimated_hours": ((shrink.3 as f64 / 120.0 / 3600.0) * 10.0).round() / 10.0,
            "already_light": light,
            "small": small,
            "unreadable": unreadable,
        },
        "orphans": {
            "sessions": plan.orphans.len(),
            "recordings": plan.orphans.iter().filter(|o| o.file.is_some()).count(),
            "recordings_gb": gb(orphan_bytes),
            "debris_files": plan.orphans.iter().map(|o| o.debris.len()).sum::<usize>(),
            "debris_gb": gb(debris_bytes),
            "next": "With --orphans: each recording is made light and filed into its thread (dated where its session began); the debris is deleted. With --orphans=delete: all of it is deleted.",
        },
        "live_untouched": plan.live,
    })
}

/// Runs the plan: every filed video that needs it, largest first, then (with
/// `orphans`) the orphans. `limit` caps how many movies are encoded.
pub async fn migrate(
    tools: &Tools,
    root: &Path,
    plan: Plan,
    orphans: bool,
    limit: Option<usize>,
) -> Value {
    let mut work: Vec<(PathBuf, u64)> = plan
        .filed
        .into_iter()
        .filter_map(|(f, p)| {
            p.ok()
                .filter(|p| p.verdict() == Verdict::Shrink)
                .map(|p| (f, p.bytes))
        })
        .collect();
    work.sort_by_key(|(_, bytes)| std::cmp::Reverse(*bytes));
    let mut budget = limit.unwrap_or(usize::MAX);
    let (mut before, mut after, mut done, mut failed) = (0u64, 0u64, 0u64, Vec::new());
    for (file, _) in work {
        if budget == 0 {
            break;
        }
        budget -= 1;
        eprintln!("Shrinking {}", file.display());
        match shrink(tools, &file).await {
            Ok(Outcome::Replaced {
                before: b,
                after: a,
                frames,
            }) => {
                eprintln!(
                    "  {} MB -> {} MB, {frames} frames kept",
                    b / 1_000_000,
                    a / 1_000_000
                );
                (before, after, done) = (before + b, after + a, done + 1);
            }
            Ok(other) => eprintln!("  {other:?}"),
            Err(error) => {
                eprintln!("  left as it was: {error:#}");
                failed.push(serde_json::json!({"file": file, "error": format!("{error:#}")}));
            }
        }
    }
    let mut recovered = Vec::new();
    if orphans {
        let ledger = settled_sessions(root);
        for orphan in plan.orphans.into_iter().filter(|o| o.owner == "threads") {
            for file in &orphan.debris {
                let _ = std::fs::remove_file(file);
            }
            let Some(file) = orphan.file else { continue };
            if budget == 0 {
                break;
            }
            budget -= 1;
            eprintln!("Recovering {}", file.display());
            match file_orphan(
                tools,
                root,
                &orphan.session,
                &orphan.thread,
                &file,
                ledger.get(&orphan.session),
            )
            .await
            {
                Ok((media, b, a)) => {
                    eprintln!("  {} MB -> {} MB, filed", b / 1_000_000, a / 1_000_000);
                    (before, after) = (before + b, after + a);
                    recovered.push(serde_json::json!({"session": orphan.session, "thread": orphan.thread, "media_id": media}));
                }
                Err(error) => {
                    eprintln!("  left as it was: {error:#}");
                    failed.push(serde_json::json!({"file": file, "error": format!("{error:#}")}));
                }
            }
        }
    }
    serde_json::json!({
        "replaced": done,
        "recovered": recovered,
        "before_mb": before / 1_000_000,
        "after_mb": after / 1_000_000,
        "failed": failed,
    })
}

/// Makes an orphan light, then files it into its thread like a session's
/// recording: (media ID, bytes before, after).
async fn file_orphan(
    tools: &Tools,
    root: &Path,
    session: &str,
    thread: &str,
    file: &Path,
    record: Option<&Value>,
) -> Result<(String, u64, u64)> {
    // Its dates, before the pass replaces the file.
    let metadata = std::fs::metadata(file)?;
    let before = metadata.len();
    match shrink(tools, file).await? {
        Outcome::Replaced { .. } | Outcome::Skipped { .. } | Outcome::NotSmaller { .. } => {}
        Outcome::Busy => bail!("Another process is encoding it"),
    }
    let after = std::fs::metadata(file)?.len();
    let seconds = |t: std::io::Result<std::time::SystemTime>| {
        t.ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs_f64())
            .unwrap_or(0.0)
    };
    let started = record
        .and_then(|r| r["started_at"].as_f64())
        .unwrap_or_else(|| seconds(metadata.created()));
    let clip = crate::media::SimulatorClip {
        session_id: session.into(),
        device_id: record
            .and_then(|r| r["device_id"].as_str())
            .unwrap_or_default()
            .into(),
        device_name: record
            .and_then(|r| r["device_name"].as_str())
            .unwrap_or("Simulator")
            .into(),
        started_at: started,
        ended_at: record
            .and_then(|r| r["ended_at"].as_f64())
            .unwrap_or_else(|| seconds(metadata.modified())),
    };
    let raw = crate::media::recording_path(root, thread, session)?;
    let media = crate::media::add_recording(root, thread, file, clip)?;
    let _ = std::fs::rename(
        raw.with_extension("poster.jpg"),
        media.file.with_extension("poster.jpg"),
    );
    Ok((media.id, before, after))
}
