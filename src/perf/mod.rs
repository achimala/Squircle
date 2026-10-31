//! Performance and screen recordings made inside an app on the phone (the
//! debug overlay's + menu), uploaded through the paired connection. A
//! performance capture is JSON: frame times, hitches, main-thread stack
//! samples as raw addresses, CPU/memory/thermal, touches and log lines.
//! `squircle perf show` names the frames on this Mac (the build's dSYM for the
//! app, the simulator's or Xcode's device symbols for the system) and turns
//! the capture into a summary an agent can act on.

use std::{
    collections::{BTreeMap, HashMap},
    fmt::Write as _,
    fs,
    io::{Read as _, Write as _},
    path::{Path, PathBuf},
    time::UNIX_EPOCH,
};

use anyhow::{Context, Result, bail, ensure};
use serde::Deserialize;
use serde_json::{Value, json};

use tokio::process::Command;

use crate::store::Store;

mod screen;

const MAX_PERF_BYTES: usize = 64 * 1024 * 1024;
pub const MAX_UPLOAD_BYTES: usize = 300 * 1024 * 1024;

pub fn captures_dir(root: &Path) -> PathBuf {
    root.join("captures")
}

/// Stores an upload; returns its absolute path. `kind` is "video" or
/// "performance".
pub fn store(root: &Path, kind: &str, bytes: &[u8]) -> Result<PathBuf> {
    ensure!(
        !bytes.is_empty() && bytes.len() <= MAX_UPLOAD_BYTES,
        "A capture must be between 1 byte and 300 MB"
    );
    let staged = staging_path(root)?;
    let stored = crate::store::create_private(&staged)
        .and_then(|mut file| Ok(file.write_all(bytes)?))
        .and_then(|_| store_file(root, kind, &staged));
    if stored.is_err() {
        let _ = fs::remove_file(&staged);
    }
    stored
}

/// A fresh hidden path in the private captures folder for an upload to be
/// streamed into (create it with mode 0600), then passed to `store_file`.
pub fn staging_path(root: &Path) -> Result<PathBuf> {
    Ok(private_captures(root)?.join(format!(".{}.partial", uuid::Uuid::new_v4())))
}

fn private_captures(root: &Path) -> Result<PathBuf> {
    crate::store::private_dir(root)?;
    let dir = captures_dir(root);
    crate::store::private_dir(&dir)?;
    Ok(dir.canonicalize()?)
}

/// Checks an upload already written to `staged` (from `staging_path`) and
/// moves it into the captures; returns its absolute path. On error the
/// caller removes `staged`.
pub fn store_file(root: &Path, kind: &str, staged: &Path) -> Result<PathBuf> {
    let meta = fs::symlink_metadata(staged)?;
    ensure!(meta.is_file(), "An upload must be a regular file");
    let size = meta.len() as usize;
    ensure!(
        size > 0 && size <= MAX_UPLOAD_BYTES,
        "A capture must be between 1 byte and 300 MB"
    );
    let extension = match kind {
        "video" => {
            let mut head = [0u8; 12];
            let read = fs::File::open(staged)?.read(&mut head)?;
            ensure!(
                size > 12 && read == 12 && &head[4..8] == b"ftyp",
                "A video must be an MP4 or QuickTime file"
            );
            // A video picked on the phone is often QuickTime; it keeps its kind.
            if &head[8..12] == b"qt  " {
                "mov"
            } else {
                "mp4"
            }
        }
        "performance" => {
            ensure!(
                size <= MAX_PERF_BYTES,
                "A performance capture must be at most 64 MB"
            );
            let capture: Capture = serde_json::from_slice(&fs::read(staged)?)
                .context("A performance capture must be Squircle perf JSON")?;
            ensure!(
                capture.format == "squircle-perf",
                "Not a Squircle performance capture"
            );
            "perf.json"
        }
        _ => bail!("kind must be video or performance"),
    };
    let path = private_captures(root)?.join(format!("{}.{extension}", uuid::Uuid::new_v4()));
    crate::store::publish_private(staged, &path)?;
    Ok(path)
}

/// A capture by path, or by the ID in its file name.
pub fn resolve(root: &Path, which: &str) -> Result<PathBuf> {
    let path = Path::new(which);
    if path.is_file() {
        return Ok(path.to_path_buf());
    }
    let id = uuid::Uuid::parse_str(which.trim_end_matches(".perf.json"))
        .context("Pass a capture path or ID (squircle perf list)")?;
    let path = captures_dir(root).join(format!("{id}.perf.json"));
    ensure!(path.is_file(), "No performance capture {id}");
    Ok(path)
}

pub fn list(root: &Path) -> Result<Vec<Value>> {
    let Ok(entries) = fs::read_dir(captures_dir(root)) else {
        return Ok(Vec::new());
    };
    let mut out = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("")
            .to_owned();
        if name.starts_with('.') {
            continue;
        }
        let modified = entry
            .metadata()
            .and_then(|m| m.modified())
            .ok()
            .and_then(|m| m.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_secs())
            .unwrap_or(0);
        if name.ends_with(".perf.json") {
            let Ok(capture) = fs::read(&path)
                .map_err(anyhow::Error::from)
                .and_then(|b| serde_json::from_slice::<Capture>(&b).map_err(anyhow::Error::from))
            else {
                continue;
            };
            out.push(json!({"id":name.trim_end_matches(".perf.json"),"kind":"performance","path":path,"created_at":modified,
                "app":capture.app.name,"bundle_id":capture.app.bundle_id,"duration":round(capture.duration, 1),
                "hitches":capture.hitches.len()}));
        } else if let Some(id) = name
            .strip_suffix(".mp4")
            .or_else(|| name.strip_suffix(".mov"))
        {
            out.push(json!({"id":id,"kind":"video","path":path,"created_at":modified}));
        }
    }
    out.sort_by_key(|v| std::cmp::Reverse(v["created_at"].as_u64().unwrap_or(0)));
    Ok(out)
}

#[derive(Deserialize)]
struct Capture {
    format: String,
    #[serde(default = "one")]
    version: u32,
    #[serde(default)]
    display: Value,
    /// The main thread's system thread ID.
    #[serde(default)]
    main_thread: f64,
    #[serde(default)]
    metal: screen::Metal,
    /// [time, stack, thread ID, CPU µs]
    #[serde(default)]
    thread_samples: Vec<Vec<f64>>,
    #[serde(default)]
    threads: Vec<Value>,
    #[serde(default)]
    app: AppInfo,
    #[serde(default)]
    device: DeviceInfo,
    #[serde(default)]
    started_at: f64,
    duration: f64,
    #[serde(default = "sixty")]
    refresh_hz: f64,
    #[serde(default)]
    frames: Vec<f64>,
    #[serde(default)]
    hitches: Vec<Hitch>,
    #[serde(default)]
    events: Vec<Value>,
    #[serde(default)]
    stacks: Vec<Vec<String>>,
    #[serde(default)]
    samples: Vec<(f64, f64)>,
    #[serde(default)]
    metrics: Vec<Value>,
    #[serde(default)]
    symbols: HashMap<String, PhoneSymbol>,
    #[serde(default)]
    images: Vec<Image>,
    #[serde(default)]
    logs: Vec<Value>,
}
fn sixty() -> f64 {
    60.0
}
fn one() -> u32 {
    1
}

#[derive(Deserialize, Default)]
struct AppInfo {
    #[serde(default)]
    bundle_id: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    version: String,
    #[serde(default)]
    build: String,
    #[serde(default)]
    squircle_build_id: Option<String>,
}
#[derive(Deserialize, Default)]
struct DeviceInfo {
    #[serde(default)]
    model: String,
    #[serde(default)]
    system: String,
    #[serde(default)]
    os_build: String,
    #[serde(default)]
    simulator: bool,
}
#[derive(Deserialize, Clone)]
struct Hitch {
    start: f64,
    #[serde(default)]
    screen: String,
}
#[derive(Deserialize)]
struct PhoneSymbol {
    image: usize,
    symbol: Option<String>,
    #[serde(default)]
    offset: u64,
}
#[derive(Deserialize, Clone)]
struct Image {
    name: String,
    path: String,
    #[serde(default)]
    uuid: String,
    load_address: String,
    #[serde(default)]
    main: bool,
}

/// One resolved address.
#[derive(Clone)]
struct Frame {
    symbol: String,
    image: String,
    /// The app's own code (its executable or a framework in its bundle).
    app: bool,
    /// From a dSYM or symbol file, not just the phone's exported-symbol guess.
    exact: bool,
}

fn parse_hex(s: &str) -> Option<u64> {
    u64::from_str_radix(s.trim_start_matches("0x"), 16).ok()
}

fn round(v: f64, places: i32) -> f64 {
    let f = 10f64.powi(places);
    (v * f).round() / f
}

/// Where symbols for an image of the app come from.
fn app_image(image: &Image) -> bool {
    image.main
        || (image.path.contains(".app/") && !image.path.contains("SquircleOverlay.framework"))
}

/// Runs a symbol tool under `crate::process::run_bounded`, so nothing it
/// started outlives it (stopping `perf show` stops it); its stdout, or
/// nothing if it failed or wrote more than 16 MiB.
async fn run(command: &mut Command, input: Option<Vec<u8>>) -> Option<Vec<u8>> {
    // Callers build it in place; run_bounded takes it whole.
    let command = std::mem::replace(command, Command::new("/usr/bin/false"));
    let finished = crate::process::run_bounded_with_input(
        command,
        input,
        crate::process::Sink::Capture(16 * 1024 * 1024),
        crate::process::Sink::Discard,
        None,
    )
    .await
    .ok()?;
    finished.status.success().then_some(finished.stdout)
}

/// A symbol file whose identity matches the image: the file, and the
/// architecture of the slice with that UUID.
type Symbols = (PathBuf, String);

/// `dwarfdump --uuid`: each slice's (UUID, architecture).
async fn dwarf_uuids(path: &Path) -> Vec<(String, String)> {
    run(
        Command::new("xcrun")
            .arg("dwarfdump")
            .arg("--uuid")
            .arg(path),
        None,
    )
    .await
    .map(|out| parse_uuids(&String::from_utf8_lossy(&out)))
    .unwrap_or_default()
}

/// "UUID: 1A2B… (arm64) /path" lines.
fn parse_uuids(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|l| {
            let mut words = l.strip_prefix("UUID: ")?.split_whitespace();
            let uuid = words.next()?.to_uppercase();
            let arch = words
                .next()?
                .trim_start_matches('(')
                .trim_end_matches(')')
                .to_owned();
            Some((uuid, arch))
        })
        .collect()
}

/// `file` (a DWARF file or binary) or the DWARF files in a dSYM bundle, if
/// one has `uuid`. A file is checked like a bundle: a path is no identity.
async fn matching(
    path: &Path,
    uuid: &str,
    uuids: &impl AsyncFn(&Path) -> Vec<(String, String)>,
) -> Option<Symbols> {
    let candidates: Vec<PathBuf> = if path.is_file() {
        vec![path.to_path_buf()]
    } else {
        fs::read_dir(path.join("Contents/Resources/DWARF"))
            .ok()?
            .flatten()
            .map(|e| e.path())
            .collect()
    };
    for file in candidates {
        if let Some((_, arch)) = uuids(&file).await.into_iter().find(|(u, _)| u == uuid) {
            return Some((file, arch));
        }
    }
    None
}

/// Where `image`'s symbols come from: a given dSYM, a Squircle build's, one
/// Spotlight knows, or the binary itself when it is on this Mac (simulator).
/// Each must carry the image's UUID. `Err` names given files that didn't.
async fn symbol_file(
    image: &Image,
    given: &[PathBuf],
    store: Option<&Store>,
    preferred_job: Option<&str>,
) -> Result<(Symbols, String), String> {
    let uuid = image.uuid.to_uppercase();
    if uuid.is_empty() {
        return Err(String::new());
    }
    let uuids = &dwarf_uuids;
    for dsym in given {
        if let Some(found) = matching(dsym, &uuid, uuids).await {
            return Ok((found, "given dSYM".into()));
        }
    }
    if let Some(store) = store {
        let mut jobs = store.list_jobs().unwrap_or_default();
        jobs.sort_by_key(|j| preferred_job != Some(j.id.as_str()));
        for job in jobs {
            for dsym in job.output().into_iter().flat_map(|o| o.dsym_paths.iter()) {
                if let Some(found) = matching(dsym, &uuid, uuids).await {
                    return Ok((found, format!("dSYM of build {}", job.id)));
                }
            }
        }
    }
    let spotlight = run(
        Command::new("mdfind").arg(format!("com_apple_xcode_dsym_uuids == {uuid}")),
        None,
    )
    .await;
    for line in String::from_utf8_lossy(&spotlight.unwrap_or_default()).lines() {
        if let Some(found) = matching(Path::new(line), &uuid, uuids).await {
            return Ok((found, "dSYM found by Spotlight".into()));
        }
    }
    let binary = Path::new(&image.path);
    if binary.is_file()
        && let Some(found) = matching(binary, &uuid, uuids).await
    {
        return Ok((found, "the binary on this Mac".into()));
    }
    Err(if given.is_empty() {
        String::new()
    } else {
        "the given --dsym is a different build".into()
    })
}

/// Xcode's copy of the phone's system libraries, for system frames.
fn device_support(image: &Image, device: &DeviceInfo) -> Option<PathBuf> {
    if device.simulator || device.os_build.is_empty() {
        return None;
    }
    let base = dirs::home_dir()?.join("Library/Developer/Xcode/iOS DeviceSupport");
    let suffix = format!("({})", device.os_build);
    let dir = fs::read_dir(&base)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .find(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.ends_with(&suffix))
        })?;
    let file = dir.join("Symbols").join(image.path.trim_start_matches('/'));
    file.is_file().then_some(file)
}

/// Symbols for a system image, only from a file with its UUID.
async fn system_file(image: &Image, device: &DeviceInfo) -> Option<Symbols> {
    let uuid = image.uuid.to_uppercase();
    if uuid.is_empty() {
        return None;
    }
    let local = Path::new(&image.path);
    for file in device_support(image, device)
        .into_iter()
        .chain(local.is_file().then(|| local.to_path_buf()))
    {
        if let Some(found) = matching(&file, &uuid, &dwarf_uuids).await {
            return Some(found);
        }
    }
    None
}

/// `atos` for one image's addresses; one name per address, in order.
async fn atos((file, arch): &Symbols, load: &str, addresses: &[u64]) -> Vec<Option<String>> {
    let mut names = Vec::with_capacity(addresses.len());
    for chunk in addresses.chunks(400) {
        let output = run(
            Command::new("xcrun")
                .args(["atos", "-arch", arch, "-o"])
                .arg(file)
                .args(["-l", load])
                .args(chunk.iter().map(|a| format!("{a:#x}"))),
            None,
        )
        .await;
        let lines: Vec<String> = output
            .map(|o| {
                String::from_utf8_lossy(&o)
                    .lines()
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default();
        for i in 0..chunk.len() {
            let line = lines.get(i).cloned().unwrap_or_default();
            // atos echoes an address it can't name.
            names.push((!line.is_empty() && !line.starts_with("0x")).then_some(line));
        }
    }
    names
}

/// "Foo.bar() (in App) (Foo.swift:12)" → "Foo.bar() Foo.swift:12".
fn tidy(atos_line: &str) -> String {
    let mut name = atos_line.to_owned();
    if let Some(start) = name.find(" (in ")
        && let Some(end) = name[start + 5..].find(')')
    {
        name.replace_range(start..start + 5 + end + 1, "");
    }
    if name.ends_with(')')
        && let Some(open) = name.rfind(" (")
    {
        let location = name[open + 2..name.len() - 1].to_owned();
        if location.contains(':') {
            name = format!("{} {}", &name[..open], location);
        }
    }
    name
}

struct Resolved {
    frames: HashMap<u64, Frame>,
    sources: Vec<String>,
    missing: Vec<String>,
}

async fn resolve_frames(capture: &Capture, given: &[PathBuf], store: Option<&Store>) -> Resolved {
    let mut by_image: BTreeMap<usize, Vec<u64>> = BTreeMap::new();
    for (key, symbol) in &capture.symbols {
        if let Some(address) = parse_hex(key) {
            by_image.entry(symbol.image).or_default().push(address);
        }
    }
    let mut frames = HashMap::new();
    let mut sources = Vec::new();
    let mut missing = Vec::new();
    let preferred = capture.app.squircle_build_id.as_deref();
    for (index, addresses) in &mut by_image {
        addresses.sort_unstable();
        let Some(image) = capture.images.get(*index) else {
            continue;
        };
        let app = app_image(image);
        let file = if app {
            match symbol_file(image, given, store, preferred).await {
                Ok((file, source)) => {
                    sources.push(format!("{}: {source}", image.name));
                    Some(file)
                }
                Err(why) if why.is_empty() => {
                    missing.push(format!("{} (UUID {})", image.name, image.uuid));
                    None
                }
                Err(why) => {
                    missing.push(format!("{} (UUID {}; {why})", image.name, image.uuid));
                    None
                }
            }
        } else {
            system_file(image, &capture.device).await
        };
        let names = match &file {
            Some(f) => atos(f, &image.load_address, addresses).await,
            None => Vec::new(),
        };
        for (i, address) in addresses.iter().enumerate() {
            let exact = names.get(i).cloned().flatten();
            let phone = capture.symbols.get(&format!("{address:#x}"));
            let symbol = match (&exact, phone.and_then(|p| p.symbol.as_ref())) {
                (Some(line), _) => tidy(line),
                (None, Some(name)) => format!("{name} + {}", phone.map(|p| p.offset).unwrap_or(0)),
                (None, None) => format!(
                    "{} + {:#x}",
                    image.name,
                    address - parse_hex(&image.load_address).unwrap_or(0)
                ),
            };
            frames.insert(
                *address,
                Frame {
                    symbol,
                    image: image.name.clone(),
                    app,
                    exact: exact.is_some(),
                },
            );
        }
    }
    demangle(&mut frames).await;
    Resolved {
        frames,
        sources,
        missing,
    }
}

/// The phone only knows mangled exported names; make Swift and C++ ones readable.
async fn demangle(frames: &mut HashMap<u64, Frame>) {
    for (tool, args, prefixes) in [
        ("swift-demangle", vec!["--simplified"], vec!["$s", "_$s"]),
        ("c++filt", vec![], vec!["_Z", "__Z"]),
    ] {
        let keys: Vec<u64> = frames
            .iter()
            .filter(|(_, f)| prefixes.iter().any(|p| f.symbol.starts_with(p)))
            .map(|(k, _)| *k)
            .collect();
        if keys.is_empty() {
            continue;
        }
        let input: String = keys
            .iter()
            .map(|k| frames[k].symbol.clone() + "\n")
            .collect();
        let Some(output) = run(
            Command::new("xcrun").arg(tool).args(&args),
            Some(input.into_bytes()),
        )
        .await
        else {
            continue;
        };
        for (key, line) in keys.iter().zip(String::from_utf8_lossy(&output).lines()) {
            if let Some(frame) = frames.get_mut(key) {
                frame.symbol = line.to_owned();
            }
        }
    }
}

/// The run loop waiting for work: not time the app spent.
fn idle(stack: &[u64], frames: &HashMap<u64, Frame>) -> bool {
    stack.iter().take(4).any(|a| {
        frames.get(a).is_some_and(|f| {
            f.symbol.contains("mach_msg") || f.symbol.contains("__CFRunLoopServiceMachPort")
        })
    })
}

/// Frames of the run loop and event plumbing above the app's work.
fn plumbing(frame: &Frame) -> bool {
    const NAMES: [&str; 19] = [
        "start",
        "static App.main()",
        "dyld",
        "main",
        "UIApplicationMain",
        "GSEventRunModal",
        "CFRunLoopRun",
        "__CFRunLoopDoSource",
        "__CFRunLoopRun",
        "_UIApplicationMainPreparations",
        "__CFRUNLOOP_IS_",
        "__CFRunLoopDoObservers",
        "__CFRunLoopDoBlocks",
        "-[UIApplication _run]",
        "_dispatch_main_queue",
        "_dispatch_client_callout",
        "swift::runJobInEstablishedExecutorContext",
        "swift_job_run",
        "_dispatch_lane",
    ];
    const APP_ENTRY: [&str; 4] = [
        "$main()",
        "_entry_point",
        "UIApplicationDelegate.main()",
        "main ",
    ];
    if frame.app {
        return APP_ENTRY.iter().any(|n| frame.symbol.contains(n));
    }
    NAMES.iter().any(|n| frame.symbol.starts_with(n))
}

/// Root-first heaviest path through the samples' call tree, each sample
/// weighted (CPU time, or 1 for a wall-clock sample): at each level the
/// child that carried the most weight, with its share.
fn heaviest_path(stacks: &[(&[u64], f64)]) -> Vec<(u64, f64)> {
    let mut path = Vec::new();
    let mut current: Vec<(&[u64], f64)> = stacks.to_vec();
    let mut depth = 0;
    loop {
        let mut weights: HashMap<u64, f64> = HashMap::new();
        for (s, w) in &current {
            if s.len() > depth {
                *weights.entry(s[s.len() - 1 - depth]).or_default() += w;
            }
        }
        let Some((&address, &weight)) = weights
            .iter()
            .max_by(|a, b| a.1.total_cmp(b.1).then(b.0.cmp(a.0)))
        else {
            break;
        };
        path.push((address, weight));
        current.retain(|(s, _)| s.len() > depth && s[s.len() - 1 - depth] == address);
        depth += 1;
        if depth > 200 {
            break;
        }
    }
    path
}

/// Functions by weight: inclusive (each function once per sample) or the
/// leaf only (self time), optionally only the app's own code.
fn top_functions(
    stacks: &[(&[u64], f64)],
    frames: &HashMap<u64, Frame>,
    only_app: bool,
    leaf: bool,
    limit: usize,
) -> Vec<(String, f64, String)> {
    let mut weights: HashMap<String, (f64, String)> = HashMap::new();
    for (stack, weight) in stacks {
        let mut seen = std::collections::HashSet::new();
        let candidates = if leaf {
            &stack[..stack.len().min(1)]
        } else {
            stack
        };
        for address in candidates {
            let Some(frame) = frames.get(address) else {
                continue;
            };
            if only_app && (!frame.app || plumbing(frame)) {
                continue;
            }
            if seen.insert(frame.symbol.as_str()) {
                let entry = weights
                    .entry(frame.symbol.clone())
                    .or_insert((0.0, frame.image.clone()));
                entry.0 += weight;
            }
        }
    }
    let mut out: Vec<_> = weights.into_iter().map(|(n, (w, i))| (n, w, i)).collect();
    out.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.0.cmp(&b.0)));
    out.truncate(limit);
    out
}

/// A thread blocked rather than idle in its run loop: waiting on a lock,
/// a semaphore or condition (the GPU, a drawable), or a reply.
fn blocked(stack: &[u64], frames: &HashMap<u64, Frame>) -> bool {
    const WAITS: [&str; 9] = [
        "__psynch_cvwait",
        "__psynch_mutexwait",
        "semaphore_wait",
        "__semwait",
        "__ulock_wait",
        "mach_msg",
        "kevent",
        "nanosleep",
        "__workq_kernreturn",
    ];
    stack.first().is_some_and(|a| {
        frames
            .get(a)
            .is_some_and(|f| WAITS.iter().any(|w| f.symbol.contains(w)))
    })
}

/// A heaviest path for reading: run-loop plumbing above the work dropped,
/// and long runs of system frames between the app's own folded to their
/// ends (the call out of the app, and the frames above the next app frame
/// or the leaf).
fn compact(path: &[(u64, f64)], frames: &HashMap<u64, Frame>) -> Vec<Option<(u64, f64)>> {
    // Unnamed frames at the root are the loader's.
    let first = path
        .iter()
        .position(|(a, _)| frames.get(a).is_some_and(|f| !plumbing(f)))
        .unwrap_or(0);
    let path = &path[first..];
    let app = |a: &u64| frames.get(a).is_some_and(|f| f.app);
    let mut out = Vec::new();
    let mut i = 0;
    while i < path.len() {
        if app(&path[i].0) {
            out.push(Some(path[i]));
            i += 1;
            continue;
        }
        let run_end = path[i..]
            .iter()
            .position(|(a, _)| app(a))
            .map_or(path.len(), |n| i + n);
        let run = &path[i..run_end];
        let keep_tail = if run_end == path.len() { 3 } else { 1 };
        if run.len() > keep_tail + 2 {
            out.push(Some(run[0]));
            out.push(None);
            out.extend(run[run.len() - keep_tail..].iter().copied().map(Some));
        } else {
            out.extend(run.iter().copied().map(Some));
        }
        i = run_end;
    }
    out.truncate(40);
    out
}

fn percentile(values: &[f64], p: f64) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    sorted[((sorted.len() - 1) as f64 * p).round() as usize]
}

const WAIT_KINDS: [&str; 2] = ["wait-scheduled", "wait-completed"];

/// A thread sample: time, stack, thread ID, CPU seconds it stands for.
type ThreadSample<'a> = (f64, &'a [u64], u64, f64);

pub async fn show(root: &Path, which: &str, given: &[PathBuf]) -> Result<(String, Value)> {
    let path = resolve(root, which)?;
    let bytes = fs::read(&path).with_context(|| format!("Reading {}", path.display()))?;
    ensure!(bytes.len() <= MAX_PERF_BYTES, "Capture too large");
    let capture: Capture =
        serde_json::from_slice(&bytes).context("Not a Squircle performance capture")?;
    ensure!(
        capture.format == "squircle-perf",
        "Not a Squircle performance capture"
    );
    let store = Store::open(root.to_path_buf()).ok();
    let resolved = resolve_frames(&capture, given, store.as_ref()).await;
    let frames = &resolved.frames;
    let stacks: Vec<Vec<u64>> = capture
        .stacks
        .iter()
        .map(|s| s.iter().filter_map(|a| parse_hex(a)).collect())
        .collect();
    let samples: Vec<(f64, &[u64])> = capture
        .samples
        .iter()
        .filter_map(|(t, i)| stacks.get(*i as usize).map(|s| (*t, s.as_slice())))
        .collect();
    let interval = if samples.len() > 1 {
        (samples.last().unwrap().0 - samples[0].0) / (samples.len() - 1) as f64
    } else {
        0.001
    };
    // The main thread at each sample: idle in its run loop, blocked, or working.
    let working: Vec<(f64, &[u64])> = samples
        .iter()
        .filter(|(_, s)| !idle(s, frames) && !blocked(s, frames))
        .cloned()
        .collect();
    let blocked_samples: Vec<f64> = samples
        .iter()
        .filter(|(_, s)| !idle(s, frames) && blocked(s, frames))
        .map(|(t, _)| *t)
        .collect();
    let thread_samples: Vec<ThreadSample> = capture
        .thread_samples
        .iter()
        .filter(|v| v.len() >= 4)
        .filter_map(|v| {
            stacks
                .get(v[1] as usize)
                .map(|s| (v[0], s.as_slice(), v[2] as u64, v[3] / 1e6))
        })
        .collect();
    let main_id = capture.main_thread as u64;
    let period = 1.0 / capture.refresh_hz.max(1.0);
    let metal = &capture.metal;
    let drawables = metal.drawables();
    let buffers = metal.buffers();
    let waits = metal.waits();

    // What reached the screen.
    let (screen, source, dropped) = screen::screen_frames(metal, &capture.frames);
    let gaps = screen::gaps(&screen, period);
    let moving: Vec<f64> = gaps
        .iter()
        .filter(|g| g.moving)
        .map(|g| g.length())
        .collect();
    let moving_time: f64 = moving.iter().sum();
    let moving_fps = if moving_time > 0.0 {
        moving.len() as f64 / moving_time
    } else {
        0.0
    };
    let refreshes_per_frame = |n: usize| {
        moving
            .iter()
            .filter(|l| ((*l / period).round() as usize).max(1) == n)
            .count()
    };
    let distribution = [
        refreshes_per_frame(1),
        refreshes_per_frame(2),
        refreshes_per_frame(3),
        moving
            .iter()
            .filter(|l| (*l / period).round() >= 4.0)
            .count(),
    ];

    // Who does Metal work besides the main thread.
    let render_threads: std::collections::HashSet<u64> = buffers
        .iter()
        .map(|b| b.3)
        .chain(drawables.iter().map(|d| d.thread))
        .filter(|t| *t != main_id && *t != 0)
        .collect();
    let gpu_intervals: Vec<(f64, f64)> = buffers.iter().map(|b| (b.1, b.2)).collect();
    let main_work: Vec<(f64, f64)> = working.iter().map(|(t, _)| (*t, t + interval)).collect();
    let main_blocked: Vec<(f64, f64)> =
        blocked_samples.iter().map(|t| (*t, t + interval)).collect();
    let drawable_waits: Vec<(f64, f64)> = drawables
        .iter()
        .filter(|d| d.wait > 0.0005)
        .map(|d| (d.requested, d.requested + d.wait))
        .collect();
    let mut requests: Vec<f64> = drawables.iter().map(|d| d.requested).collect();
    requests.sort_by(f64::total_cmp);

    // Every late frame, with what its time went to.
    let late: Vec<(screen::Gap, screen::Breakdown, screen::Cause)> = gaps
        .iter()
        .filter(|g| g.late)
        .map(|g| {
            let (a, b) = (g.start, g.end);
            let first_request = requests.iter().find(|t| **t > a && **t < b);
            let breakdown = screen::Breakdown {
                main_work: screen::covered(&main_work, a, b),
                main_blocked: screen::covered(&main_blocked, a, b),
                drawable_wait: screen::covered(&drawable_waits, a, b),
                gpu: screen::covered(&gpu_intervals, a, b),
                longest_buffer: buffers
                    .iter()
                    .filter(|x| x.2 > a && x.1 < b)
                    .map(|x| x.2 - x.1)
                    .fold(0.0, f64::max),
                render_cpu: thread_samples
                    .iter()
                    .filter(|s| s.0 > a && s.0 <= b && render_threads.contains(&s.2))
                    .map(|s| s.3)
                    .sum(),
                request_delay: first_request.map_or(b - a, |t| t - a),
            };
            let cause = screen::cause(
                &breakdown,
                b - a,
                period,
                source != screen::Source::Refreshes,
            );
            (*g, breakdown, cause)
        })
        .collect();
    let mut by_cause: Vec<(screen::Cause, usize, f64)> = Vec::new();
    for (gap, _, cause) in &late {
        match by_cause.iter_mut().find(|c| c.0 == *cause) {
            Some(entry) => {
                entry.1 += 1;
                entry.2 += gap.length() - period;
            }
            None => by_cause.push((*cause, 1, gap.length() - period)),
        }
    }
    by_cause.sort_by(|a, b| b.2.total_cmp(&a.2));

    let frame_line = |address: u64, weight: f64, total: f64, unit: &str| -> String {
        let f = frames.get(&address);
        let name = f
            .map(|f| f.symbol.clone())
            .unwrap_or_else(|| format!("{address:#x}"));
        let tag = match f {
            Some(f) if f.app => "  [app]",
            Some(f) if !f.exact => "  [approx]",
            _ => "",
        };
        let share = if unit == "ms" {
            format!("{:.1}/{:.1} ms", weight * 1000.0, total * 1000.0)
        } else {
            format!("{weight:.0}/{total:.0}")
        };
        format!(
            "{name}  ({}){tag}  {share}",
            f.map(|f| f.image.as_str()).unwrap_or("?")
        )
    };
    let render_path = |text: &mut String,
                       path: &[(u64, f64)],
                       total: f64,
                       unit: &str,
                       indent: &str|
     -> Vec<Value> {
        let mut out = Vec::new();
        for entry in compact(path, frames) {
            match entry {
                Some((address, weight)) => {
                    let _ = writeln!(text, "{indent}{}", frame_line(address, weight, total, unit));
                    let f = frames.get(&address);
                    out.push(json!({"symbol": f.map(|f| f.symbol.clone()), "image": f.map(|f| f.image.clone()),
                        "app": f.map(|f| f.app), "weight": round(weight, 4)}));
                }
                None => {
                    let _ = writeln!(text, "{indent}…");
                }
            }
        }
        out
    };

    // Threads: names, CPU, roles.
    let mut thread_cpu: HashMap<u64, f64> = HashMap::new();
    for s in &thread_samples {
        *thread_cpu.entry(s.2).or_default() += s.3;
    }
    let mut thread_names: HashMap<u64, String> = HashMap::new();
    for t in &capture.threads {
        let id = t["id"].as_f64().unwrap_or(0.0) as u64;
        let name = t["name"].as_str().unwrap_or("").to_owned();
        thread_names.insert(id, name);
        if let Some(ms) = t["cpu_ms"].as_f64() {
            thread_cpu.insert(id, ms / 1000.0);
        }
    }
    let mut threads_by_cpu: Vec<(u64, f64)> = thread_cpu.iter().map(|(k, v)| (*k, *v)).collect();
    threads_by_cpu.sort_by(|a, b| b.1.total_cmp(&a.1));
    let thread_label = |id: u64| -> String {
        let name = thread_names.get(&id).cloned().unwrap_or_default();
        let mut label = if id == main_id {
            "main thread".to_owned()
        } else if !name.is_empty() {
            name
        } else {
            format!("thread {id}")
        };
        if render_threads.contains(&id) {
            label.push_str(" (encodes/presents Metal)");
        } else if id != main_id {
            // Where its time went: the library nearest each leaf that
            // isn't the kernel, threading or dispatch.
            let mut images: HashMap<&str, f64> = HashMap::new();
            for s in thread_samples.iter().filter(|s| s.2 == id) {
                let owner = s.1.iter().filter_map(|a| frames.get(a)).find(|f| {
                    !(f.image.starts_with("libsystem_")
                        || f.image.starts_with("libdispatch")
                        || f.image.starts_with("libobjc"))
                });
                if let Some(f) = owner {
                    *images.entry(f.image.as_str()).or_default() += s.3;
                }
            }
            if let Some((image, _)) = images.iter().max_by(|a, b| a.1.total_cmp(b.1)) {
                label.push_str(&format!(" (mostly in {image})"));
            }
        }
        label
    };
    let total_cpu: f64 = thread_cpu.values().sum();

    let mut text = String::new();
    let app = &capture.app;
    let _ = writeln!(
        text,
        "Performance recording · {} {} ({}) · {}{} · {} · {:.1} s",
        if app.name.is_empty() {
            &app.bundle_id
        } else {
            &app.name
        },
        app.version,
        app.build,
        capture.device.model,
        if capture.device.simulator {
            " simulator"
        } else {
            ""
        },
        capture.device.system,
        capture.duration
    );

    // 1. The honest number.
    let layers = &metal.layers;
    let source_text = match source {
        screen::Source::OnGlass => "Metal drawables' on-screen times".to_owned(),
        screen::Source::PresentCalls => "the app's Metal present calls (this device reports no on-screen times, so frames the compositor dropped can't be seen)".to_owned(),
        screen::Source::Refreshes if capture.version < 2 => "display refreshes: this recording predates presented-frame tracking, so this is NOT a frame rate".to_owned(),
        screen::Source::Refreshes if !drawables.is_empty() => "display refreshes the main thread was free for (its Metal layers cover too little of the screen to stand for it; animations the render server runs itself aren't seen in-process)".to_owned(),
        screen::Source::Refreshes => "display refreshes the main thread was free for (no Metal drawables; animations the render server runs itself aren't seen in-process)".to_owned(),
    };
    if capture.version < 2 {
        let _ = writeln!(
            text,
            "Screen: not measured. This recording predates presented-frame tracking: the display refreshed {} times ({:.0}/s), which is not a frame rate. Record again with a current build to see real frames, GPU time and every thread.",
            capture.frames.len(),
            capture.frames.len() as f64 / capture.duration.max(1e-9)
        );
    } else {
        let _ = writeln!(
            text,
            "Screen: {:.0} fps while moving ({} new frames in {:.1} s of motion; {} in {:.1} s overall) on a {:.0} Hz display. Source: {source_text}.",
            moving_fps,
            moving.len(),
            moving_time,
            screen.len(),
            capture.duration,
            capture.refresh_hz,
        );
        if !moving.is_empty() {
            let _ = writeln!(
                text,
                "Frame times while moving: median {:.1} ms, p95 {:.1} ms, worst {:.0} ms (budget {:.1} ms). On time {}, 2 refreshes {}, 3 refreshes {}, 4+ {}.",
                percentile(&moving, 0.5) * 1000.0,
                percentile(&moving, 0.95) * 1000.0,
                percentile(&moving, 1.0) * 1000.0,
                period * 1000.0,
                distribution[0],
                distribution[1],
                distribution[2],
                distribution[3]
            );
        }
    }
    let sanity = (source != screen::Source::Refreshes && capture.frames.len() as f64 > screen.len() as f64 * 1.15)
        .then(|| format!(
            "Check: the display refreshed {} times but only {} frames had new content. Refresh counts (what earlier recordings called \"drawn\") are not a frame rate.",
            capture.frames.len(),
            screen.len()
        ));
    if let Some(sanity) = &sanity {
        let _ = writeln!(text, "{sanity}");
    }
    if dropped > 0 {
        let _ = writeln!(
            text,
            "{dropped} drawables were presented but never reached the screen (dropped by the compositor)."
        );
    }

    // 2. Why frames were late.
    if !late.is_empty() {
        let _ = writeln!(
            text,
            "\nLate frames: {} of {} while moving, {:.0} ms past due in total. By cause:",
            late.len(),
            moving.len(),
            late.iter().map(|l| l.0.length() - period).sum::<f64>() * 1000.0
        );
        for (cause, count, overdue) in &by_cause {
            let _ = writeln!(
                text,
                "   {:<55} {:>4} frames  {:>6.0} ms past due",
                cause.label(),
                count,
                overdue * 1000.0
            );
        }
        if buffers.is_empty() {
            let _ = writeln!(
                text,
                "   (No GPU or render-thread data in this recording: a late frame without main-thread work may still be the GPU's.)"
            );
        }
    } else if !moving.is_empty() {
        let _ = writeln!(text, "\nNo late frames while moving.");
    }

    // 3. Heaviest CPU across all threads.
    let weighted: Vec<(&[u64], f64)> = thread_samples.iter().map(|s| (s.1, s.3)).collect();
    let running: Vec<(&[u64], f64)> = thread_samples
        .iter()
        .filter(|s| !blocked(s.1, frames) && !idle(s.1, frames))
        .map(|s| (s.1, s.3))
        .collect();
    let app_total = top_functions(&weighted, frames, true, false, 12);
    let self_time = top_functions(&running, frames, false, true, 12);
    let mut thread_json = Vec::new();
    if !thread_samples.is_empty() {
        let _ = writeln!(
            text,
            "\nCPU: {:.0} ms over {:.1} s across {} threads (every thread sampled, weighted by the CPU time it used). Busiest threads:",
            total_cpu * 1000.0,
            capture.duration,
            thread_cpu.len()
        );
        for (id, cpu) in threads_by_cpu.iter().take(6) {
            let _ = writeln!(
                text,
                "   {:>7.0} ms  {:>3.0}%  {}",
                cpu * 1000.0,
                cpu / total_cpu.max(1e-9) * 100.0,
                thread_label(*id)
            );
        }
        if !app_total.is_empty() {
            let _ = writeln!(
                text,
                "Heaviest app functions, all threads (total CPU incl. what they call)"
            );
            for (name, w, _) in &app_total {
                let _ = writeln!(text, "   {:>7.1} ms  {name}", w * 1000.0);
            }
        }
        if !self_time.is_empty() {
            let _ = writeln!(text, "Heaviest functions by self time, all threads");
            for (name, w, image) in &self_time {
                let _ = writeln!(text, "   {:>7.1} ms  {name}  ({image})", w * 1000.0);
            }
        }
        let _ = writeln!(
            text,
            "Heaviest stacks of the busiest threads (root → leaf, plumbing folded)"
        );
        for (id, cpu) in threads_by_cpu.iter().take(3) {
            let mine: Vec<(&[u64], f64)> = running
                .iter()
                .zip(
                    thread_samples
                        .iter()
                        .filter(|s| !blocked(s.1, frames) && !idle(s.1, frames)),
                )
                .filter(|(_, s)| s.2 == *id)
                .map(|(w, _)| *w)
                .collect();
            if mine.is_empty() {
                continue;
            }
            let total: f64 = mine.iter().map(|m| m.1).sum();
            let _ = writeln!(text, "  {} · {:.0} ms", thread_label(*id), cpu * 1000.0);
            let stack = render_path(&mut text, &heaviest_path(&mine), total, "ms", "     ");
            thread_json.push(json!({"id": id, "label": thread_label(*id), "cpu_ms": round(cpu * 1000.0, 1), "heaviest_stack": stack}));
        }
    }

    // 4. GPU.
    let mut pass_groups: BTreeMap<String, Vec<f64>> = BTreeMap::new();
    // Vertex and fragment stage time per group, for render passes.
    let mut stages: HashMap<String, (f64, f64)> = HashMap::new();
    for pass in &metal.passes {
        let key = if pass.label.is_empty() {
            format!(
                "{} pass → {}",
                pass.kind,
                if pass.target.is_empty() {
                    "?"
                } else {
                    &pass.target
                }
            )
        } else {
            pass.label.clone()
        };
        if let (Some(v), Some(f)) = (pass.vertex, pass.fragment) {
            let entry = stages.entry(key.clone()).or_default();
            entry.0 += v.1 - v.0;
            entry.1 += f.1 - f.0;
        }
        pass_groups
            .entry(key)
            .or_default()
            .push(pass.end - pass.start);
    }
    let mut passes: Vec<(String, Vec<f64>)> = pass_groups.into_iter().collect();
    passes.sort_by(|a, b| b.1.iter().sum::<f64>().total_cmp(&a.1.iter().sum::<f64>()));
    // GPU time per screen frame: the buffers committed in each gap.
    let per_frame_gpu: Vec<f64> = gaps
        .iter()
        .filter(|g| g.moving)
        .map(|g| {
            buffers
                .iter()
                .filter(|b| b.0 > g.start && b.0 <= g.end)
                .map(|b| b.2 - b.1)
                .sum()
        })
        .collect();
    let gpu_moving: f64 = gaps
        .iter()
        .filter(|g| g.moving)
        .map(|g| screen::covered(&gpu_intervals, g.start, g.end))
        .sum();
    if !buffers.is_empty() {
        let _ = writeln!(
            text,
            "\nGPU ({}): {} command buffers; busy {:.0}% of the time while moving; per frame median {:.1} ms, p95 {:.1} ms, worst {:.1} ms (budget {:.1} ms).",
            if metal.device.is_empty() {
                "?"
            } else {
                &metal.device
            },
            buffers.len(),
            gpu_moving / moving_time.max(1e-9) * 100.0,
            percentile(&per_frame_gpu, 0.5) * 1000.0,
            percentile(&per_frame_gpu, 0.95) * 1000.0,
            percentile(&per_frame_gpu, 1.0) * 1000.0,
            period * 1000.0
        );
        if passes.is_empty() {
            let _ = writeln!(
                text,
                "   Per-pass GPU time: not available ({}).",
                metal.counters
            );
        } else {
            let _ = writeln!(
                text,
                "Heaviest GPU passes (stage-boundary counters; label or kind → target)"
            );
            for (name, times) in passes.iter().take(12) {
                let split = stages
                    .get(name)
                    .map(|(v, f)| {
                        format!(
                            "  (vertex {:.1} ms, fragment {:.1} ms)",
                            v * 1000.0,
                            f * 1000.0
                        )
                    })
                    .unwrap_or_default();
                let _ = writeln!(
                    text,
                    "   {:>7.1} ms total  {:>5} passes  avg {:.2} ms  p95 {:.2} ms  {name}{split}",
                    times.iter().sum::<f64>() * 1000.0,
                    times.len(),
                    times.iter().sum::<f64>() / times.len() as f64 * 1000.0,
                    percentile(times, 0.95) * 1000.0
                );
            }
        }
    } else if source != screen::Source::Refreshes {
        let _ = writeln!(text, "\nGPU: no command buffer reported GPU times.");
    }
    let wait_summary = |kind: &str| -> Option<(usize, f64, f64)> {
        let w: Vec<f64> = waits
            .iter()
            .filter(|w| w.0 == kind)
            .map(|w| w.2 - w.1)
            .collect();
        (!w.is_empty()).then(|| (w.len(), w.iter().sum(), percentile(&w, 1.0)))
    };
    for (kind, what) in [
        ("wait-scheduled", "waitUntilScheduled"),
        ("wait-completed", "waitUntilCompleted"),
    ] {
        if let Some((n, total, worst)) = wait_summary(kind) {
            let on_main = waits
                .iter()
                .filter(|w| w.0 == kind && w.3 == main_id)
                .count();
            let _ = writeln!(
                text,
                "   CPU blocked in {what}: {n} times ({on_main} on the main thread), {:.0} ms total, worst {:.1} ms.",
                total * 1000.0,
                worst * 1000.0
            );
        }
    }
    if !drawables.is_empty() {
        let waits: Vec<f64> = drawables.iter().map(|d| d.wait).collect();
        let _ = writeln!(
            text,
            "   nextDrawable: {} calls, {} waited over 1 ms, {:.0} ms total, worst {:.1} ms.",
            waits.len(),
            waits.iter().filter(|w| **w > 0.001).count(),
            waits.iter().sum::<f64>() * 1000.0,
            percentile(&waits, 1.0) * 1000.0
        );
    }
    if !layers.is_empty() {
        let mut names: Vec<String> = Vec::new();
        for (i, layer) in layers.iter().enumerate() {
            let used = drawables.iter().filter(|d| d.layer == i).count();
            names.push(format!(
                "{} #{} {}×{} {:.0}% of screen, {} drawables{}, {} frames",
                layer.name,
                i + 1,
                layer.pixels.first().copied().unwrap_or(0.0),
                layer.pixels.get(1).copied().unwrap_or(0.0),
                layer.screen_share * 100.0,
                layer.max_drawables,
                if layer.presents_with_transaction {
                    ", presents with transaction"
                } else {
                    ""
                },
                used
            ));
        }
        let _ = writeln!(text, "   Metal layers: {}.", names.join("; "));
    }

    // Frame-rate caps and the app's own pacing.
    let display = &capture.display;
    let mut caps = Vec::new();
    if let Some(max) = display["max_fps"].as_f64() {
        caps.push(format!("display max {max:.0} fps"));
    }
    if display["promotion_unlocked"].as_bool() == Some(false)
        && display["max_fps"].as_f64().unwrap_or(60.0) > 60.0
    {
        caps.push("CADisableMinimumFrameDurationOnPhone is not set: the app's display links are capped at 60 Hz".into());
    }
    if display["low_power"].as_bool() == Some(true) {
        caps.push("Low Power Mode on (caps at 60 Hz)".into());
    }
    if let Some(thermal) = display["thermal"].as_str() {
        caps.push(format!("thermal {thermal} at start"));
    }
    let request_frames = screen::cluster(requests.clone(), 0.002);
    let request_gaps: Vec<f64> = request_frames
        .windows(2)
        .map(|w| w[1] - w[0])
        .filter(|g| *g < 0.1)
        .collect();
    if !request_gaps.is_empty() {
        let typical = percentile(&request_gaps, 0.5);
        caps.push(format!(
            "the app asked for drawables every {:.1} ms (≈{:.0} Hz) while moving",
            typical * 1000.0,
            1.0 / typical
        ));
    }
    // Changes, each run of the same value once.
    let mut changes: Vec<(String, String, f64, f64, usize)> = Vec::new();
    for e in capture.events.iter().filter(|e| {
        matches!(
            e["kind"].as_str(),
            Some("thermal" | "low-power" | "frame-rate-request")
        )
    }) {
        let kind = e["kind"].as_str().unwrap_or("").to_owned();
        let value = match kind.as_str() {
            "thermal" => e["state"].as_str().unwrap_or("").to_owned(),
            "low-power" => if e["on"].as_bool() == Some(true) {
                "on"
            } else {
                "off"
            }
            .to_owned(),
            _ => match (e["min"].as_f64(), e["max"].as_f64()) {
                (Some(min), Some(max)) => format!(
                    "{min:.0}–{max:.0} Hz, preferred {:.0}",
                    e["preferred"].as_f64().unwrap_or(0.0)
                ),
                _ => format!("{:.0} fps", e["preferred"].as_f64().unwrap_or(0.0)),
            },
        };
        let t = e["t"].as_f64().unwrap_or(0.0);
        match changes.last_mut() {
            Some(last) if last.0 == kind && last.1 == value => {
                last.3 = t;
                last.4 += 1;
            }
            _ => changes.push((kind, value, t, t, 1)),
        }
    }
    for (kind, value, from, to, count) in &changes {
        let what = match kind.as_str() {
            "thermal" => "thermal state",
            "low-power" => "Low Power Mode",
            _ => "a display link asked for",
        };
        caps.push(if *count > 1 {
            format!("{what} {value} ({count}× from {from:.2} to {to:.2} s)")
        } else {
            format!("{what} {value} at {from:.2} s")
        });
    }
    if !caps.is_empty() {
        let _ = writeln!(text, "\nPacing and caps: {}.", caps.join("; "));
    }

    for source in &resolved.sources {
        let _ = writeln!(text, "Symbols for {source}.");
    }
    for missing in &resolved.missing {
        let _ = writeln!(
            text,
            "No dSYM found for {missing}: its frames are addresses. Pass --dsym PATH."
        );
    }

    // Late frames, worst first.
    let mut worst = late.clone();
    worst.sort_by(|a, b| b.0.length().total_cmp(&a.0.length()));
    let touches: Vec<(f64, &Value)> = capture
        .events
        .iter()
        .filter(|e| e["kind"].as_str() == Some("touch-down"))
        .filter_map(|e| e["t"].as_f64().map(|t| (t, e)))
        .collect();
    if !worst.is_empty() {
        let _ = writeln!(
            text,
            "\nWorst late frames (screen time between frames; the cause, then the main thread's heaviest stack while working)"
        );
    }
    let mut hitch_json = Vec::new();
    for (rank, (gap, b, cause)) in worst.iter().enumerate() {
        let (a, e) = (gap.start, gap.end);
        let window: Vec<(&[u64], f64)> = working
            .iter()
            .filter(|(t, _)| *t >= a && *t <= e)
            .map(|(_, s)| (*s, 1.0))
            .collect();
        let screen_name = capture
            .hitches
            .iter()
            .find(|h| h.start >= a - period && h.start <= e)
            .map(|h| h.screen.clone())
            .unwrap_or_default();
        let others: Vec<(u64, f64)> = {
            let mut m: HashMap<u64, f64> = HashMap::new();
            for s in thread_samples
                .iter()
                .filter(|s| s.0 > a && s.0 <= e && s.2 != main_id)
            {
                *m.entry(s.2).or_default() += s.3;
            }
            let mut v: Vec<_> = m.into_iter().collect();
            v.sort_by(|x, y| y.1.total_cmp(&x.1));
            v.truncate(3);
            v
        };
        let path = heaviest_path(&window);
        let mut stack_json = Vec::new();
        if rank < 6 {
            let touch = touches
                .iter()
                .rev()
                .find(|(t, _)| *t <= e && *t >= a - 1.0)
                .map(|(t, _)| format!(", touch at {t:.2} s"))
                .unwrap_or_default();
            let short_screen = screen_name.split('<').next().unwrap_or("").to_owned();
            let _ = writeln!(
                text,
                "\n{}. {:.0} ms at {:.2} s{}{touch} — {}",
                rank + 1,
                gap.length() * 1000.0,
                a,
                if short_screen.is_empty() {
                    String::new()
                } else {
                    format!(" on {short_screen}")
                },
                cause.label()
            );
            let _ = writeln!(
                text,
                "   main working {:.0} ms, main blocked {:.0} ms, waiting for drawables {:.0} ms, GPU busy {:.0} ms (longest buffer {:.1} ms), render threads {:.0} ms CPU, first frame request after {:.0} ms",
                b.main_work * 1000.0,
                b.main_blocked * 1000.0,
                b.drawable_wait * 1000.0,
                b.gpu * 1000.0,
                b.longest_buffer * 1000.0,
                b.render_cpu.max(0.0) * 1000.0 + 0.0,
                b.request_delay * 1000.0
            );
            if !others.is_empty() {
                let _ = writeln!(
                    text,
                    "   other threads: {}",
                    others
                        .iter()
                        .map(|(id, cpu)| format!("{} {:.1} ms", thread_label(*id), cpu * 1000.0))
                        .collect::<Vec<_>>()
                        .join(", ")
                );
            }
            if !window.is_empty() {
                stack_json = render_path(&mut text, &path, window.len() as f64, "samples", "   ");
            }
        }
        hitch_json.push(json!({
            "start": round(a, 4), "end": round(e, 4), "duration_ms": round(gap.length() * 1000.0, 1),
            "overdue_ms": round((gap.length() - period) * 1000.0, 1), "cause": cause.key(), "cause_text": cause.label(),
            "screen": screen_name,
            "main_work_ms": round(b.main_work * 1000.0, 1), "main_blocked_ms": round(b.main_blocked * 1000.0, 1),
            "drawable_wait_ms": round(b.drawable_wait * 1000.0, 1), "gpu_busy_ms": round(b.gpu * 1000.0, 1),
            "longest_buffer_ms": round(b.longest_buffer * 1000.0, 2), "render_cpu_ms": round(b.render_cpu * 1000.0, 1),
            "request_delay_ms": round(b.request_delay * 1000.0, 1), "main_samples": window.len(),
            "other_threads": others.iter().map(|(id, cpu)| json!({"thread": thread_label(*id), "cpu_ms": round(cpu * 1000.0, 2)})).collect::<Vec<_>>(),
            "main_stack": stack_json,
            "app_functions": top_functions(&window, frames, true, false, 4).iter().map(|(n, c, _)| json!({"symbol": n, "samples": c})).collect::<Vec<_>>(),
        }));
    }
    if worst.len() > 6 {
        let _ = writeln!(
            text,
            "\n…and {} more late frames (in --json).",
            worst.len() - 6
        );
    }

    // One row per second.
    let seconds = capture.duration.ceil().max(1.0) as usize;
    let mut rows = Vec::new();
    let _ = writeln!(
        text,
        "\nTimeline (per second)\n   t  new  refresh  late_ms  gpu%  cpu%  main%  mem_MB  thermal  events"
    );
    for second in 0..seconds {
        let (from, to) = (second as f64, second as f64 + 1.0);
        let shown = screen.iter().filter(|t| **t >= from && **t < to).count();
        let refreshes = capture
            .frames
            .iter()
            .filter(|t| **t >= from && **t < to)
            .count();
        let late_ms: f64 = late
            .iter()
            .filter(|l| l.0.end >= from && l.0.end < to)
            .map(|l| (l.0.length() - period) * 1000.0)
            .sum::<f64>()
            + 0.0;
        let gpu = screen::covered(&gpu_intervals, from, to) * 100.0;
        let metrics: Vec<&Value> = capture
            .metrics
            .iter()
            .filter(|m| m["t"].as_f64().is_some_and(|t| t >= from && t < to))
            .collect();
        let average = |key: &str| -> Option<f64> {
            let values: Vec<f64> = metrics.iter().filter_map(|m| m[key].as_f64()).collect();
            (!values.is_empty()).then(|| values.iter().sum::<f64>() / values.len() as f64)
        };
        let thermal = metrics
            .last()
            .and_then(|m| m["thermal"].as_str())
            .unwrap_or("");
        let events: Vec<String> = capture
            .events
            .iter()
            .filter(|e| e["t"].as_f64().is_some_and(|t| t >= from && t < to))
            .filter_map(|e| e["kind"].as_str())
            .filter(|k| *k != "touch-up")
            .map(|k| k.replace("touch-down", "touch"))
            .collect();
        let fmt = |v: Option<f64>| v.map(|v| format!("{v:.0}")).unwrap_or_else(|| "-".into());
        let gpu_text = if buffers.is_empty() {
            "-".to_owned()
        } else {
            format!("{gpu:.0}")
        };
        let _ = writeln!(
            text,
            "{:>4}  {:>3}  {:>7}  {:>7.0}  {:>4}  {:>4}  {:>5}  {:>6}  {:>7}  {}",
            second,
            shown,
            refreshes,
            late_ms,
            gpu_text,
            fmt(average("cpu")),
            fmt(average("main_cpu")),
            fmt(average("memory_mb")),
            thermal,
            events.join(" ")
        );
        rows.push(json!({"t": second, "frames": shown, "refreshes": refreshes, "late_ms": round(late_ms, 1),
            "gpu_percent": (!buffers.is_empty()).then(|| round(gpu, 1)), "cpu": average("cpu"), "main_cpu": average("main_cpu"),
            "memory_mb": average("memory_mb"), "thermal": thermal, "events": events}));
    }
    if !capture.logs.is_empty() {
        let _ = writeln!(text, "\nApp log ({} lines; newest 15)", capture.logs.len());
        for line in capture
            .logs
            .iter()
            .rev()
            .take(15)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
        {
            let _ = writeln!(
                text,
                "   {:>6.2}  {}  {}",
                line["t"].as_f64().unwrap_or(0.0),
                line["level"].as_str().unwrap_or(""),
                line["message"].as_str().unwrap_or("").replace('\n', " ")
            );
        }
    }
    let _ = writeln!(
        text,
        "\nNot visible in-process: GPU hardware counters beyond pass timestamps (occupancy, bandwidth, shader cost per draw), the render server's own work, and kernel scheduling; those need Instruments with the phone attached. Raw capture: {} (--json has everything above). Times are seconds from the start.",
        path.display()
    );

    let data = json!({
        "path": path, "format_version": capture.version,
        "app": {"name": app.name, "bundle_id": app.bundle_id, "version": app.version, "build": app.build},
        "device": {"model": capture.device.model, "system": capture.device.system, "simulator": capture.device.simulator},
        "started_at": capture.started_at, "duration": round(capture.duration, 2), "refresh_hz": capture.refresh_hz,
        "screen": {
            "source": format!("{source:?}"), "source_text": source_text,
            "frames": screen.len(), "moving_frames": moving.len(), "moving_seconds": round(moving_time, 2),
            "fps_while_moving": round(moving_fps, 1),
            "frame_ms": {"median": round(percentile(&moving, 0.5) * 1000.0, 1), "p95": round(percentile(&moving, 0.95) * 1000.0, 1), "worst": round(percentile(&moving, 1.0) * 1000.0, 1)},
            "refreshes_per_frame": {"1": distribution[0], "2": distribution[1], "3": distribution[2], "4+": distribution[3]},
            "display_refreshes": capture.frames.len(), "sanity_check": sanity, "dropped_drawables": dropped,
            "frame_times": screen.iter().map(|t| round(*t, 4)).collect::<Vec<_>>(),
        },
        "late_frames": {"count": late.len(), "by_cause": by_cause.iter().map(|(c, n, ms)| json!({"cause": c.key(), "text": c.label(), "frames": n, "overdue_ms": round(ms * 1000.0, 1)})).collect::<Vec<_>>()},
        "hitches": hitch_json,
        "cpu": {
            "total_ms": round(total_cpu * 1000.0, 1),
            "threads": threads_by_cpu.iter().map(|(id, cpu)| json!({"id": id, "label": thread_label(*id), "cpu_ms": round(cpu * 1000.0, 1)})).collect::<Vec<_>>(),
            "app_functions_total": app_total.iter().map(|(n, w, i)| json!({"symbol": n, "image": i, "cpu_ms": round(w * 1000.0, 2)})).collect::<Vec<_>>(),
            "functions_self": self_time.iter().map(|(n, w, i)| json!({"symbol": n, "image": i, "cpu_ms": round(w * 1000.0, 2)})).collect::<Vec<_>>(),
            "busiest_threads": thread_json,
            "main_samples": samples.len(), "main_working_samples": working.len(), "main_blocked_samples": blocked_samples.len(),
            "sample_interval_ms": round(interval * 1000.0, 2),
        },
        "gpu": {
            "device": metal.device, "command_buffers": buffers.len(), "busy_percent_while_moving": round(gpu_moving / moving_time.max(1e-9) * 100.0, 1),
            "per_frame_ms": {"median": round(percentile(&per_frame_gpu, 0.5) * 1000.0, 2), "p95": round(percentile(&per_frame_gpu, 0.95) * 1000.0, 2), "worst": round(percentile(&per_frame_gpu, 1.0) * 1000.0, 2)},
            "pass_timing": if passes.is_empty() { json!(metal.counters) } else { json!("stage-boundary counters") },
            "passes": passes.iter().map(|(n, t)| json!({"name": n, "count": t.len(), "total_ms": round(t.iter().sum::<f64>() * 1000.0, 2), "p95_ms": round(percentile(t, 0.95) * 1000.0, 3),
                "vertex_ms": stages.get(n).map(|s| round(s.0 * 1000.0, 2)), "fragment_ms": stages.get(n).map(|s| round(s.1 * 1000.0, 2))})).collect::<Vec<_>>(),
            "waits": WAIT_KINDS.iter().filter_map(|k| wait_summary(k).map(|(n, t, w)| json!({"kind": k, "count": n, "total_ms": round(t * 1000.0, 1), "worst_ms": round(w * 1000.0, 2)}))).collect::<Vec<_>>(),
            "next_drawable_wait_ms": round(drawables.iter().map(|d| d.wait).sum::<f64>() * 1000.0, 1),
            "layers": layers.iter().map(|l| json!({"name": l.name, "pixels": l.pixels, "screen_share": l.screen_share, "max_drawables": l.max_drawables, "presents_with_transaction": l.presents_with_transaction, "format": l.format})).collect::<Vec<_>>(),
        },
        "pacing": caps,
        "symbol_sources": resolved.sources, "missing_symbols": resolved.missing,
        "timeline": rows,
        "report": text,
    });
    Ok((text, data))
}
