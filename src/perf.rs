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
    path::{Path, PathBuf},
    io::{Read as _, Write as _},
    process::{Command, Stdio},
    time::{Duration, Instant, UNIX_EPOCH},
};

use anyhow::{Context, Result, bail, ensure};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::store::Store;

const MAX_PERF_BYTES: usize = 64 * 1024 * 1024;
pub const MAX_UPLOAD_BYTES: usize = 300 * 1024 * 1024;

pub fn captures_dir(root: &Path) -> PathBuf {
    root.join("captures")
}

/// Stores an upload; returns its absolute path. `kind` is "video" or
/// "performance".
pub fn store(root: &Path, kind: &str, bytes: &[u8]) -> Result<PathBuf> {
    ensure!(!bytes.is_empty() && bytes.len() <= MAX_UPLOAD_BYTES, "A capture must be between 1 byte and 300 MB");
    let staged = staging_path(root)?;
    let stored = crate::media::create_private(&staged)
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
    ensure!(size > 0 && size <= MAX_UPLOAD_BYTES, "A capture must be between 1 byte and 300 MB");
    let extension = match kind {
        "video" => {
            let mut head = [0u8; 12];
            let read = fs::File::open(staged)?.read(&mut head)?;
            ensure!(size > 12 && read == 12 && &head[4..8] == b"ftyp", "A screen recording must be an MP4 file");
            "mp4"
        }
        "performance" => {
            ensure!(size <= MAX_PERF_BYTES, "A performance capture must be at most 64 MB");
            let capture: Capture = serde_json::from_slice(&fs::read(staged)?).context("A performance capture must be Squircle perf JSON")?;
            ensure!(capture.format == "squircle-perf", "Not a Squircle performance capture");
            "perf.json"
        }
        _ => bail!("kind must be video or performance"),
    };
    let path = private_captures(root)?.join(format!("{}.{extension}", uuid::Uuid::new_v4()));
    fs::rename(staged, &path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
    }
    Ok(path)
}

/// A capture by path, or by the ID in its file name.
pub fn resolve(root: &Path, which: &str) -> Result<PathBuf> {
    let path = Path::new(which);
    if path.is_file() {
        return Ok(path.to_path_buf());
    }
    let id = uuid::Uuid::parse_str(which.trim_end_matches(".perf.json")).context("Pass a capture path or ID (squircle perf list)")?;
    let path = captures_dir(root).join(format!("{id}.perf.json"));
    ensure!(path.is_file(), "No performance capture {id}");
    Ok(path)
}

pub fn list(root: &Path) -> Result<Vec<Value>> {
    let Ok(entries) = fs::read_dir(captures_dir(root)) else { return Ok(Vec::new()) };
    let mut out = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("").to_owned();
        if name.starts_with('.') {
            continue;
        }
        let modified = entry.metadata().and_then(|m| m.modified()).ok()
            .and_then(|m| m.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
        if name.ends_with(".perf.json") {
            let Ok(capture) = fs::read(&path).map_err(anyhow::Error::from)
                .and_then(|b| serde_json::from_slice::<Capture>(&b).map_err(anyhow::Error::from)) else { continue };
            out.push(json!({"id":name.trim_end_matches(".perf.json"),"kind":"performance","path":path,"created_at":modified,
                "app":capture.app.name,"bundle_id":capture.app.bundle_id,"duration":round(capture.duration, 1),
                "hitches":capture.hitches.len()}));
        } else if name.ends_with(".mp4") {
            out.push(json!({"id":name.trim_end_matches(".mp4"),"kind":"video","path":path,"created_at":modified}));
        }
    }
    out.sort_by_key(|v| std::cmp::Reverse(v["created_at"].as_u64().unwrap_or(0)));
    Ok(out)
}

#[derive(Deserialize)]
struct Capture {
    format: String,
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
    duration: f64,
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
    image.main || (image.path.contains(".app/") && !image.path.contains("SquircleOverlay.framework"))
}

/// Runs a symbol tool in its own process group with a deadline, so a wedged
/// `atos` or `dwarfdump` cannot hang `perf show`; its stdout, or nothing if it
/// failed, timed out or wrote more than 16 MiB. The leader is reaped only
/// after its group is killed (as in `xcode::run_bounded`), so nothing it started
/// outlives it and the output is read within the same deadline.
fn run(command: &mut Command, input: Option<Vec<u8>>, limit: Duration) -> Option<Vec<u8>> {
    use std::os::unix::process::CommandExt as _;
    const MAX_OUTPUT: u64 = 16 * 1024 * 1024;
    let deadline = Instant::now() + limit;
    let mut child = command
        .stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .ok()?;
    let pid = child.id() as libc::pid_t;
    if let (Some(mut stdin), Some(input)) = (child.stdin.take(), input) {
        std::thread::spawn(move || { let _ = stdin.write_all(&input); });
    }
    let (sender, output) = std::sync::mpsc::channel();
    let stdout = child.stdout.take()?;
    std::thread::spawn(move || {
        let mut out = Vec::new();
        let read = stdout.take(MAX_OUTPUT + 1).read_to_end(&mut out);
        let _ = sender.send(read.ok().filter(|_| out.len() as u64 <= MAX_OUTPUT).map(|_| out));
    });
    let ended = loop {
        if crate::xcode::leader_exited(pid) {
            break true;
        }
        if Instant::now() >= deadline {
            break false;
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    crate::xcode::kill_group(pid);
    let status = child.wait().ok()?;
    let out = output.recv_timeout(deadline.saturating_duration_since(Instant::now())).ok()??;
    (ended && status.success()).then_some(out)
}

/// A symbol file whose identity matches the image: the file, and the
/// architecture of the slice with that UUID.
type Symbols = (PathBuf, String);

/// `dwarfdump --uuid`: each slice's (UUID, architecture).
fn dwarf_uuids(path: &Path) -> Vec<(String, String)> {
    run(Command::new("xcrun").arg("dwarfdump").arg("--uuid").arg(path), None, Duration::from_secs(30))
        .map(|out| parse_uuids(&String::from_utf8_lossy(&out)))
        .unwrap_or_default()
}

/// "UUID: 1A2B… (arm64) /path" lines.
fn parse_uuids(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|l| {
            let mut words = l.strip_prefix("UUID: ")?.split_whitespace();
            let uuid = words.next()?.to_uppercase();
            let arch = words.next()?.trim_start_matches('(').trim_end_matches(')').to_owned();
            Some((uuid, arch))
        })
        .collect()
}

/// `file` (a DWARF file or binary) or the DWARF files in a dSYM bundle, if
/// one has `uuid`. A file is checked like a bundle: a path is no identity.
fn matching(path: &Path, uuid: &str, uuids: &dyn Fn(&Path) -> Vec<(String, String)>) -> Option<Symbols> {
    let candidates: Vec<PathBuf> = if path.is_file() {
        vec![path.to_path_buf()]
    } else {
        fs::read_dir(path.join("Contents/Resources/DWARF")).ok()?.flatten().map(|e| e.path()).collect()
    };
    candidates.into_iter().find_map(|file| {
        let arch = uuids(&file).into_iter().find(|(u, _)| u == uuid)?.1;
        Some((file, arch))
    })
}

/// Where `image`'s symbols come from: a given dSYM, a Squircle build's, one
/// Spotlight knows, or the binary itself when it is on this Mac (simulator).
/// Each must carry the image's UUID. `Err` names given files that didn't.
fn symbol_file(image: &Image, given: &[PathBuf], store: Option<&Store>, preferred_job: Option<&str>) -> Result<(Symbols, String), String> {
    let uuid = image.uuid.to_uppercase();
    if uuid.is_empty() {
        return Err(String::new());
    }
    let uuids = &dwarf_uuids;
    if let Some(found) = given.iter().find_map(|dsym| matching(dsym, &uuid, uuids)) {
        return Ok((found, "given dSYM".into()));
    }
    if let Some(store) = store {
        let mut jobs = store.list_jobs().unwrap_or_default();
        jobs.sort_by_key(|j| preferred_job != Some(j.id.as_str()));
        for job in jobs {
            for dsym in job.output.iter().flat_map(|o| o.dsym_paths.iter()) {
                if let Some(found) = matching(dsym, &uuid, uuids) {
                    return Ok((found, format!("dSYM of build {}", job.id)));
                }
            }
        }
    }
    let spotlight = run(Command::new("mdfind").arg(format!("com_apple_xcode_dsym_uuids == {uuid}")), None, Duration::from_secs(15));
    for line in String::from_utf8_lossy(&spotlight.unwrap_or_default()).lines() {
        if let Some(found) = matching(Path::new(line), &uuid, uuids) {
            return Ok((found, "dSYM found by Spotlight".into()));
        }
    }
    let binary = Path::new(&image.path);
    if binary.is_file() {
        if let Some(found) = matching(binary, &uuid, uuids) {
            return Ok((found, "the binary on this Mac".into()));
        }
    }
    Err(if given.is_empty() { String::new() } else { "the given --dsym is a different build".into() })
}

/// Xcode's copy of the phone's system libraries, for system frames.
fn device_support(image: &Image, device: &DeviceInfo) -> Option<PathBuf> {
    if device.simulator || device.os_build.is_empty() {
        return None;
    }
    let base = dirs::home_dir()?.join("Library/Developer/Xcode/iOS DeviceSupport");
    let suffix = format!("({})", device.os_build);
    let dir = fs::read_dir(&base).ok()?.flatten().map(|e| e.path())
        .find(|p| p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.ends_with(&suffix)))?;
    let file = dir.join("Symbols").join(image.path.trim_start_matches('/'));
    file.is_file().then_some(file)
}

/// Symbols for a system image, only from a file with its UUID.
fn system_file(image: &Image, device: &DeviceInfo) -> Option<Symbols> {
    let uuid = image.uuid.to_uppercase();
    if uuid.is_empty() {
        return None;
    }
    let local = Path::new(&image.path);
    device_support(image, device)
        .into_iter()
        .chain(local.is_file().then(|| local.to_path_buf()))
        .find_map(|file| matching(&file, &uuid, &dwarf_uuids))
}

/// `atos` for one image's addresses; one name per address, in order.
fn atos((file, arch): &Symbols, load: &str, addresses: &[u64]) -> Vec<Option<String>> {
    let mut names = Vec::with_capacity(addresses.len());
    for chunk in addresses.chunks(400) {
        let output = run(Command::new("xcrun").args(["atos", "-arch", arch, "-o"]).arg(file).args(["-l", load])
            .args(chunk.iter().map(|a| format!("{a:#x}"))), None, Duration::from_secs(60));
        let lines: Vec<String> = output.map(|o| String::from_utf8_lossy(&o).lines().map(str::to_owned).collect()).unwrap_or_default();
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
    if let Some(start) = name.find(" (in ") {
        if let Some(end) = name[start + 5..].find(')') {
            name.replace_range(start..start + 5 + end + 1, "");
        }
    }
    if name.ends_with(')') {
        if let Some(open) = name.rfind(" (") {
            let location = name[open + 2..name.len() - 1].to_owned();
            if location.contains(':') {
                name = format!("{} {}", &name[..open], location);
            }
        }
    }
    name
}

struct Resolved {
    frames: HashMap<u64, Frame>,
    sources: Vec<String>,
    missing: Vec<String>,
}

fn resolve_frames(capture: &Capture, given: &[PathBuf], store: Option<&Store>) -> Resolved {
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
        let Some(image) = capture.images.get(*index) else { continue };
        let app = app_image(image);
        let file = if app {
            match symbol_file(image, given, store, preferred) {
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
            system_file(image, &capture.device)
        };
        let names = file.as_ref().map(|f| atos(f, &image.load_address, addresses)).unwrap_or_default();
        for (i, address) in addresses.iter().enumerate() {
            let exact = names.get(i).cloned().flatten();
            let phone = capture.symbols.get(&format!("{address:#x}"));
            let symbol = match (&exact, phone.and_then(|p| p.symbol.as_ref())) {
                (Some(line), _) => tidy(line),
                (None, Some(name)) => format!("{name} + {}", phone.map(|p| p.offset).unwrap_or(0)),
                (None, None) => format!("{} + {:#x}", image.name, address - parse_hex(&image.load_address).unwrap_or(0)),
            };
            frames.insert(*address, Frame { symbol, image: image.name.clone(), app, exact: exact.is_some() });
        }
    }
    demangle(&mut frames);
    Resolved { frames, sources, missing }
}

/// The phone only knows mangled exported names; make Swift and C++ ones readable.
fn demangle(frames: &mut HashMap<u64, Frame>) {
    for (tool, args, prefixes) in [("swift-demangle", vec!["--simplified"], vec!["$s", "_$s"]), ("c++filt", vec![], vec!["_Z", "__Z"])] {
        let keys: Vec<u64> = frames.iter().filter(|(_, f)| prefixes.iter().any(|p| f.symbol.starts_with(p))).map(|(k, _)| *k).collect();
        if keys.is_empty() {
            continue;
        }
        let input: String = keys.iter().map(|k| frames[k].symbol.clone() + "\n").collect();
        let Some(output) = run(Command::new("xcrun").arg(tool).args(&args), Some(input.into_bytes()), Duration::from_secs(30)) else { continue };
        for (key, line) in keys.iter().zip(String::from_utf8_lossy(&output).lines()) {
            if let Some(frame) = frames.get_mut(key) {
                frame.symbol = line.to_owned();
            }
        }
    }
}

/// The run loop waiting for work: not time the app spent.
fn idle(stack: &[u64], frames: &HashMap<u64, Frame>) -> bool {
    stack.iter().take(4).any(|a| frames.get(a).is_some_and(|f| {
        f.symbol.contains("mach_msg") || f.symbol.contains("__CFRunLoopServiceMachPort")
    }))
}

/// Frames of the run loop and event plumbing above the app's work.
fn plumbing(frame: &Frame) -> bool {
    const NAMES: [&str; 17] = ["start", "main", "UIApplicationMain", "GSEventRunModal", "CFRunLoopRun", "__CFRunLoopDoSource",
        "__CFRunLoopRun", "_UIApplicationMainPreparations", "__CFRUNLOOP_IS_", "__CFRunLoopDoObservers",
        "__CFRunLoopDoBlocks", "-[UIApplication _run]", "_dispatch_main_queue", "_dispatch_client_callout",
        "swift::runJobInEstablishedExecutorContext", "swift_job_run", "_dispatch_lane"];
    const APP_ENTRY: [&str; 4] = ["$main()", "_entry_point", "UIApplicationDelegate.main()", "main "];
    if frame.app {
        return APP_ENTRY.iter().any(|n| frame.symbol.contains(n));
    }
    NAMES.iter().any(|n| frame.symbol.starts_with(n))
}

/// Root-first heaviest path through the samples' call tree: at each level the
/// child most samples went through, with its share.
fn heaviest_path(stacks: &[&[u64]]) -> Vec<(u64, usize)> {
    let mut path = Vec::new();
    let mut current: Vec<&[u64]> = stacks.to_vec();
    let mut depth = 0;
    loop {
        let mut counts: HashMap<u64, usize> = HashMap::new();
        for s in &current {
            if s.len() > depth {
                *counts.entry(s[s.len() - 1 - depth]).or_default() += 1;
            }
        }
        let Some((&address, &count)) = counts.iter().max_by_key(|(a, c)| (**c, std::cmp::Reverse(**a))) else { break };
        path.push((address, count));
        current.retain(|s| s.len() > depth && s[s.len() - 1 - depth] == address);
        depth += 1;
        if depth > 200 {
            break;
        }
    }
    path
}

fn top_functions(stacks: &[&[u64]], frames: &HashMap<u64, Frame>, only_app: bool, leaf: bool, limit: usize) -> Vec<(String, usize)> {
    let mut counts: HashMap<String, usize> = HashMap::new();
    for stack in stacks {
        let mut seen = std::collections::HashSet::new();
        let candidates: Box<dyn Iterator<Item = &u64>> = if leaf { Box::new(stack.iter().take(1)) } else { Box::new(stack.iter()) };
        for address in candidates {
            let Some(frame) = frames.get(address) else { continue };
            if only_app && (!frame.app || plumbing(frame)) {
                continue;
            }
            let name = frame.symbol.clone();
            if seen.insert(name.clone()) {
                *counts.entry(name).or_default() += 1;
            }
        }
    }
    let mut out: Vec<_> = counts.into_iter().collect();
    out.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    out.truncate(limit);
    out
}

pub fn show(root: &Path, which: &str, given: &[PathBuf]) -> Result<(String, Value)> {
    let path = resolve(root, which)?;
    let bytes = fs::read(&path).with_context(|| format!("Reading {}", path.display()))?;
    ensure!(bytes.len() <= MAX_PERF_BYTES, "Capture too large");
    let capture: Capture = serde_json::from_slice(&bytes).context("Not a Squircle performance capture")?;
    ensure!(capture.format == "squircle-perf", "Not a Squircle performance capture");
    let store = Store::open(root.to_path_buf()).ok();
    let resolved = resolve_frames(&capture, given, store.as_ref());
    let frames = &resolved.frames;
    let stacks: Vec<Vec<u64>> = capture.stacks.iter().map(|s| s.iter().filter_map(|a| parse_hex(a)).collect()).collect();
    let samples: Vec<(f64, &[u64])> = capture.samples.iter()
        .filter_map(|(t, i)| stacks.get(*i as usize).map(|s| (*t, s.as_slice()))).collect();
    let busy: Vec<(f64, &[u64])> = samples.iter().filter(|(_, s)| !idle(s, frames)).cloned().collect();
    let interval = if samples.len() > 1 { (samples.last().unwrap().0 - samples[0].0) / (samples.len() - 1) as f64 } else { 0.001 };
    let period = 1.0 / capture.refresh_hz.max(1.0);

    let frame_line = |address: u64, count: usize, total: usize| -> String {
        let f = frames.get(&address);
        let name = f.map(|f| f.symbol.clone()).unwrap_or_else(|| format!("{address:#x}"));
        let tag = match f { Some(f) if f.app => "  [app]", Some(f) if !f.exact => "  [approx]", _ => "" };
        format!("{name}  ({}){tag}  {count}/{total}", f.map(|f| f.image.as_str()).unwrap_or("?"))
    };

    // Hitches, worst first, each with what the main thread was doing.
    let mut hitches = capture.hitches.clone();
    hitches.sort_by(|a, b| b.duration.total_cmp(&a.duration));
    let total_hitch: f64 = capture.hitches.iter().map(|h| h.duration).sum();
    let touches: Vec<(f64, &Value)> = capture.events.iter()
        .filter(|e| e["kind"].as_str() == Some("touch-down")).filter_map(|e| e["t"].as_f64().map(|t| (t, e))).collect();
    let mut hitch_json = Vec::new();
    let mut text = String::new();
    let app = &capture.app;
    let _ = writeln!(text, "Performance recording · {} {} ({}) · {} · {} · {:.1} s",
        if app.name.is_empty() { &app.bundle_id } else { &app.name }, app.version, app.build,
        capture.device.model, capture.device.system, capture.duration);
    let fps = if capture.duration > 0.0 { capture.frames.len() as f64 / capture.duration } else { 0.0 };
    let _ = writeln!(text, "Frames: {:.0} Hz display, {} drawn ({fps:.0} fps average), {} hitches totalling {:.0} ms{}.",
        capture.refresh_hz, capture.frames.len(), capture.hitches.len(), total_hitch * 1000.0,
        hitches.first().map(|h| format!(" (worst {:.0} ms)", h.duration * 1000.0)).unwrap_or_default());
    let _ = writeln!(text, "Main thread: {} samples every {:.1} ms, busy in {:.0}% of them.",
        samples.len(), interval * 1000.0, if samples.is_empty() { 0.0 } else { busy.len() as f64 / samples.len() as f64 * 100.0 });
    for source in &resolved.sources {
        let _ = writeln!(text, "Symbols for {source}.");
    }
    for missing in &resolved.missing {
        let _ = writeln!(text, "No dSYM found for {missing}: its frames are addresses. Pass --dsym PATH.");
    }
    if !hitches.is_empty() {
        let _ = writeln!(text, "\nWorst hitches (late frames; main-thread stack root → leaf, plumbing above the app's work omitted)");
    }
    for (rank, hitch) in hitches.iter().take(5).enumerate() {
        let end = hitch.start + period + hitch.duration;
        let window: Vec<&[u64]> = busy.iter().filter(|(t, _)| *t >= hitch.start && *t <= end).map(|(_, s)| *s).collect();
        let touch = touches.iter().rev().find(|(t, _)| *t <= end && *t >= hitch.start - 1.0)
            .map(|(t, e)| format!(", touch at {:.2} s ({:.0}, {:.0})", t, e["x"].as_f64().unwrap_or(0.0), e["y"].as_f64().unwrap_or(0.0)))
            .unwrap_or_default();
        let screen = if hitch.screen.is_empty() { String::new() } else { format!(" on {}", hitch.screen) };
        let _ = writeln!(text, "\n{}. {:.0} ms at {:.2} s{screen}{touch}", rank + 1, hitch.duration * 1000.0, hitch.start);
        let path = heaviest_path(&window);
        let first = path.iter().position(|(a, _)| frames.get(a).is_none_or(|f| !plumbing(f))).unwrap_or(0);
        let shown: Vec<_> = path[first..].iter().take(30).collect();
        if window.is_empty() {
            let _ = writeln!(text, "   No busy main-thread samples: the delay was outside the main thread (render server, GPU) or the app was suspended.");
        }
        for (address, count) in &shown {
            let _ = writeln!(text, "   {}", frame_line(*address, *count, window.len()));
        }
        let app_top = top_functions(&window, frames, true, false, 4);
        if !app_top.is_empty() {
            let _ = writeln!(text, "   App code in this hitch: {}", app_top.iter().map(|(n, c)| format!("{n} ({c})")).collect::<Vec<_>>().join(", "));
        }
        hitch_json.push(json!({
            "start": round(hitch.start, 3), "duration_ms": round(hitch.duration * 1000.0, 1), "screen": hitch.screen,
            "samples": window.len(),
            "stack": shown.iter().map(|(a, c)| {
                let f = frames.get(a);
                json!({"symbol": f.map(|f| f.symbol.clone()), "image": f.map(|f| f.image.clone()), "app": f.map(|f| f.app), "exact": f.map(|f| f.exact), "samples": c})
            }).collect::<Vec<_>>(),
            "app_functions": app_top.iter().map(|(n, c)| json!({"symbol": n, "samples": c})).collect::<Vec<_>>(),
        }));
    }
    if hitches.len() > 5 {
        let _ = writeln!(text, "\n…and {} more hitches (in --json).", hitches.len() - 5);
    }

    let busy_stacks: Vec<&[u64]> = busy.iter().map(|(_, s)| *s).collect();
    let app_inclusive = top_functions(&busy_stacks, frames, true, false, 12);
    let leaves = top_functions(&busy_stacks, frames, false, true, 10);
    if !app_inclusive.is_empty() {
        let _ = writeln!(text, "\nHeaviest app functions over the whole recording (main thread, inclusive samples)");
        for (name, count) in &app_inclusive {
            let _ = writeln!(text, "   {count:>6}  {:.0} ms  {name}", *count as f64 * interval * 1000.0);
        }
    }
    if !leaves.is_empty() {
        let _ = writeln!(text, "\nWhere the main thread spent its time (leaf functions)");
        for (name, count) in &leaves {
            let _ = writeln!(text, "   {count:>6}  {:.0} ms  {name}", *count as f64 * interval * 1000.0);
        }
    }

    // One row per second.
    let seconds = capture.duration.ceil().max(1.0) as usize;
    let mut rows = Vec::new();
    let _ = writeln!(text, "\nTimeline (per second)\n   t  fps  hitch_ms  cpu%  main%  mem_MB  thermal  events");
    for second in 0..seconds {
        let (from, to) = (second as f64, second as f64 + 1.0);
        let drawn = capture.frames.iter().filter(|t| **t >= from && **t < to).count();
        let late: f64 = capture.hitches.iter().filter(|h| h.start >= from && h.start < to).map(|h| h.duration * 1000.0).sum::<f64>().max(0.0);
        let metrics: Vec<&Value> = capture.metrics.iter().filter(|m| m["t"].as_f64().is_some_and(|t| t >= from && t < to)).collect();
        let average = |key: &str| -> Option<f64> {
            let values: Vec<f64> = metrics.iter().filter_map(|m| m[key].as_f64()).collect();
            (!values.is_empty()).then(|| values.iter().sum::<f64>() / values.len() as f64)
        };
        let thermal = metrics.last().and_then(|m| m["thermal"].as_str()).unwrap_or("");
        let events: Vec<String> = capture.events.iter().filter(|e| e["t"].as_f64().is_some_and(|t| t >= from && t < to))
            .filter_map(|e| e["kind"].as_str()).filter(|k| *k != "touch-up").map(|k| k.replace("touch-down", "touch")).collect();
        let fmt = |v: Option<f64>| v.map(|v| format!("{v:.0}")).unwrap_or_else(|| "-".into());
        let _ = writeln!(text, "{:>4}  {:>3}  {:>8.0}  {:>4}  {:>5}  {:>6}  {:>7}  {}", second, drawn, late,
            fmt(average("cpu")), fmt(average("main_cpu")), fmt(average("memory_mb")), thermal, events.join(" "));
        rows.push(json!({"t":second,"frames":drawn,"hitch_ms":round(late,1),"cpu":average("cpu"),"main_cpu":average("main_cpu"),
            "memory_mb":average("memory_mb"),"thermal":thermal,"events":events}));
    }
    if !capture.logs.is_empty() {
        let _ = writeln!(text, "\nApp log ({} lines; newest 15)", capture.logs.len());
        for line in capture.logs.iter().rev().take(15).collect::<Vec<_>>().into_iter().rev() {
            let _ = writeln!(text, "   {:>6.2}  {}  {}", line["t"].as_f64().unwrap_or(0.0), line["level"].as_str().unwrap_or(""),
                line["message"].as_str().unwrap_or("").replace('\n', " "));
        }
    }
    let _ = writeln!(text, "\nRaw capture: {} (JSON: frames, hitches, samples → stacks of addresses, symbols, images with UUIDs and load addresses, metrics, events, logs). Times are seconds from the start.", path.display());

    let data = json!({
        "path": path, "app": {"name": app.name, "bundle_id": app.bundle_id, "version": app.version, "build": app.build},
        "device": {"model": capture.device.model, "system": capture.device.system, "simulator": capture.device.simulator},
        "started_at": capture.started_at, "duration": round(capture.duration, 2), "refresh_hz": capture.refresh_hz, "frames": capture.frames.len(),
        "hitch_count": capture.hitches.len(), "hitch_total_ms": round(total_hitch * 1000.0, 1),
        "samples": samples.len(), "busy_samples": busy.len(), "sample_interval_ms": round(interval * 1000.0, 2),
        "symbol_sources": resolved.sources, "missing_symbols": resolved.missing,
        "hitches": hitch_json,
        "app_functions": app_inclusive.iter().map(|(n, c)| json!({"symbol": n, "samples": c})).collect::<Vec<_>>(),
        "leaf_functions": leaves.iter().map(|(n, c)| json!({"symbol": n, "samples": c})).collect::<Vec<_>>(),
        "timeline": rows,
        "report": text,
    });
    Ok((text, data))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn symbol_tools_finish_within_their_deadline_and_leave_nothing_running() {
        let started = Instant::now();
        // The background sleep holds stdout after the shell exits.
        let out = run(Command::new("/bin/sh").args(["-c", "cat; sleep 30 & echo $!"]), Some(b"in ".to_vec()), Duration::from_secs(10)).unwrap();
        assert!(started.elapsed() < Duration::from_secs(5));
        let out = String::from_utf8(out).unwrap();
        let left: libc::pid_t = out.trim_start_matches("in ").trim().parse().unwrap();
        let gone = (0..150).any(|_| {
            std::thread::sleep(Duration::from_millis(20));
            (unsafe { libc::kill(left, 0) }) != 0
        });
        assert!(gone);

        let started = Instant::now();
        assert!(run(Command::new("/bin/sleep").arg("30"), None, Duration::from_millis(300)).is_none());
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn heaviest_path_follows_the_busiest_child() {
        // Leaf first, as captured: main → a → b (3 samples), main → c (1).
        let s1: &[u64] = &[3, 2, 1];
        let s2: &[u64] = &[4, 1];
        let path = heaviest_path(&[s1, s1, s1, s2]);
        assert_eq!(path, vec![(1, 4), (2, 3), (3, 3)]);
    }

    #[test]
    fn symbol_files_must_carry_the_image_uuid() {
        let dir = tempfile::tempdir().unwrap();
        let wrong = dir.path().join("Old");
        let right = dir.path().join("App.dSYM/Contents/Resources/DWARF/App");
        fs::create_dir_all(right.parent().unwrap()).unwrap();
        fs::write(&wrong, b"").unwrap();
        fs::write(&right, b"").unwrap();
        let text = "UUID: 1111AAAA-0000-0000-0000-000000000000 (arm64) x\nUUID: 2222bbbb-0000-0000-0000-000000000000 (arm64e) x";
        assert_eq!(parse_uuids(text)[1], ("2222BBBB-0000-0000-0000-000000000000".into(), "arm64e".into()));
        let uuids = |p: &Path| -> Vec<(String, String)> {
            if p.ends_with("App") { parse_uuids(text) } else { vec![("9999".into(), "arm64".into())] }
        };
        assert_eq!(matching(&wrong, "1111AAAA-0000-0000-0000-000000000000", &uuids), None, "A given file from another build is not used.");
        let bundle = dir.path().join("App.dSYM");
        assert_eq!(matching(&bundle, "2222BBBB-0000-0000-0000-000000000000", &uuids), Some((right, "arm64e".into())));
    }

    #[test]
    fn tidies_atos_lines() {
        assert_eq!(tidy("Feed.layout() (in Letters) (Feed.swift:88)"), "Feed.layout() Feed.swift:88");
        assert_eq!(tidy("-[UIView layoutSubviews] (in UIKitCore) + 12"), "-[UIView layoutSubviews] + 12");
    }

    #[test]
    fn rejects_uploads_that_are_not_captures() {
        let root = tempfile::tempdir().unwrap();
        assert!(store(root.path(), "video", b"not a movie at all").is_err());
        assert!(store(root.path(), "performance", b"{\"format\":\"other\",\"duration\":1}").is_err());
        assert!(store(root.path(), "elf", b"x").is_err());
        let ok = store(root.path(), "performance", b"{\"format\":\"squircle-perf\",\"duration\":1}").unwrap();
        assert!(ok.to_string_lossy().ends_with(".perf.json"));
    }
}
