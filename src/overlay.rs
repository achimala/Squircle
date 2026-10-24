//! The Squircle debug overlay: a framework compiled from the Squircle app's own
//! sources and injected into device builds Squircle signs, so any app shows
//! its agent threads, builds and simulator without source changes. Injection
//! happens between `archive` and `exportArchive`; Xcode's export then signs it
//! like any embedded framework. App Store exports are never injected.

use std::{
    ffi::OsString,
    fs,
    io::Write,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, anyhow, bail, ensure};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::{process::Command, sync::watch, time::Instant};

use crate::process::{Finished, RunError, Sink, cancelled, run_bounded};
use crate::xcode::run_command;

pub const FRAMEWORK: &str = "SquircleOverlay.framework";
const LOAD_PATH: &str = "@executable_path/Frameworks/SquircleOverlay.framework/SquircleOverlay";
/// Info.plist keys naming Squircle's namespace (app/Squircle/Config): the
/// app and the overlay framework both carry them.
const APP_BUNDLE_ID_KEY: &str = "SquircleAppBundleID";
const SHARED_GROUP_KEY: &str = "SquircleSharedKeychainGroup";

/// Export methods whose builds carry a provisioning profile and stay off the
/// App Store.
pub fn allowed_method(method: &str) -> bool {
    matches!(
        method,
        "development" | "debugging" | "ad-hoc" | "release-testing"
    )
}

fn info_string(info: &plist::Value, key: &str) -> Option<String> {
    info.as_dictionary()?
        .get(key)?
        .as_string()
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

/// Squircle itself is the source of the shared connection, never a host: an
/// app whose Info.plist names itself as Squircle's app.
pub fn is_squircle(app: &Path) -> Result<bool> {
    let info = plist::Value::from_file(app.join("Info.plist"))?;
    let own = info_string(&info, APP_BUNDLE_ID_KEY);
    Ok(own.is_some() && own == info_string(&info, "CFBundleIdentifier"))
}

fn overlay_project() -> PathBuf {
    std::env::var_os("SQUIRCLE_OVERLAY_PROJECT")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            Path::new(env!("CARGO_MANIFEST_DIR")).join("app/Squircle/Squircle.xcodeproj")
        })
}

/// Settings the framework is always built with; part of the cache key.
const BUILD_SETTINGS: [&str; 7] = [
    "-target",
    "SquircleOverlay",
    "-configuration",
    "Release",
    "-sdk",
    "iphoneos",
    "DEPLOYMENT_POSTPROCESSING=YES",
];

const MANIFEST: &str = "manifest.json";

/// Written last into a cache entry; an entry without a matching one is ignored.
#[derive(Serialize, Deserialize)]
struct Manifest {
    key: String,
    toolchain: String,
    framework_sha256: String,
}

fn hex(digest: &[u8], bytes: usize) -> String {
    digest
        .iter()
        .take(bytes)
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Key for everything the framework is compiled from and with: the overlay
/// sources, the project, the selected toolchain and the fixed build settings.
fn cache_key(project: &Path, toolchain: &str) -> Result<String> {
    let root = project.parent().context("overlay project has no parent")?;
    let mut files = Vec::new();
    fn walk(dir: &Path, files: &mut Vec<PathBuf>) -> Result<()> {
        for entry in fs::read_dir(dir)? {
            let path = entry?.path();
            if path.is_dir() {
                walk(&path, files)?;
            } else if matches!(
                path.extension().and_then(|e| e.to_str()),
                Some("swift" | "c" | "h" | "metal" | "xcconfig")
            ) {
                files.push(path);
            }
        }
        Ok(())
    }
    walk(&root.join("Sources"), &mut files)?;
    walk(&root.join("Overlay"), &mut files)?;
    // The namespace the framework is compiled with.
    walk(&root.join("Config"), &mut files)?;
    files.push(project.join("project.pbxproj"));
    files.sort();
    let mut hash = Sha256::new();
    for file in files {
        hash.update(file.strip_prefix(root)?.to_string_lossy().as_bytes());
        hash.update([0]);
        hash.update(fs::read(&file).with_context(|| format!("cannot read {}", file.display()))?);
        hash.update([0]);
    }
    hash.update(toolchain.as_bytes());
    hash.update([0]);
    for setting in BUILD_SETTINGS {
        hash.update(setting.as_bytes());
        hash.update([0]);
    }
    Ok(hex(&hash.finalize(), 12))
}

/// Digest of every file and link in a built framework.
fn tree_digest(root: &Path) -> Result<String> {
    fn walk(root: &Path, dir: &Path, hash: &mut Sha256) -> Result<()> {
        let mut entries = fs::read_dir(dir)?.collect::<std::io::Result<Vec<_>>>()?;
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            let path = entry.path();
            let kind = entry.file_type()?;
            hash.update(path.strip_prefix(root)?.to_string_lossy().as_bytes());
            hash.update([0]);
            if kind.is_symlink() {
                hash.update(b"link\0");
                hash.update(fs::read_link(&path)?.to_string_lossy().as_bytes());
            } else if kind.is_dir() {
                hash.update(b"dir\0");
                walk(root, &path, hash)?;
            } else {
                hash.update(b"file\0");
                hash.update(fs::read(&path)?);
            }
            hash.update([0]);
        }
        Ok(())
    }
    let mut hash = Sha256::new();
    walk(root, root, &mut hash)?;
    Ok(hex(&hash.finalize(), 32))
}

/// The framework in a cache entry, if the entry was completely published for
/// this key and is unchanged since.
fn cached(entry: &Path, key: &str) -> Option<PathBuf> {
    let manifest: Manifest = serde_json::from_slice(&fs::read(entry.join(MANIFEST)).ok()?).ok()?;
    let product = entry.join(FRAMEWORK);
    (manifest.key == key
        && product.join("SquircleOverlay").is_file()
        && tree_digest(&product).ok()? == manifest.framework_sha256)
        .then_some(product)
}

/// Moves a built framework into `<cache>/<key>/` with its manifest, all or
/// nothing: it is staged beside the entry and renamed into place.
fn publish(cache: &Path, key: &str, toolchain: &str, built: &Path) -> Result<PathBuf> {
    let staging = cache.join(format!("staging-{key}"));
    let _ = fs::remove_dir_all(&staging);
    fs::create_dir_all(&staging)?;
    fs::rename(built, staging.join(FRAMEWORK))?;
    let manifest = Manifest {
        key: key.to_owned(),
        toolchain: toolchain.to_owned(),
        framework_sha256: tree_digest(&staging.join(FRAMEWORK))?,
    };
    fs::write(
        staging.join(MANIFEST),
        serde_json::to_vec_pretty(&manifest)?,
    )?;
    let entry = cache.join(key);
    if entry.exists() {
        fs::remove_dir_all(&entry)?;
    }
    fs::rename(&staging, &entry)?;
    Ok(entry.join(FRAMEWORK))
}

/// What selects the compiler and SDK: the Xcode build, the iOS SDK build and
/// any toolchain override in the service's environment.
async fn toolchain(deadline: Instant, cancel: &watch::Receiver<bool>) -> Result<String> {
    let deadline = deadline.min(Instant::now() + std::time::Duration::from_secs(60));
    let mut identity = String::new();
    for args in [
        &["xcodebuild", "-version"][..],
        &["xcrun", "--sdk", "iphoneos", "--show-sdk-build-version"],
    ] {
        let mut command = Command::new(Path::new("/usr/bin").join(args[0]));
        command.args(&args[1..]);
        let finished = finished(
            run_bounded(
                command,
                Sink::Capture(64 * 1024),
                Sink::Discard,
                deadline,
                Some(cancel.clone()),
            )
            .await,
            args[0],
        )?;
        ensure!(
            finished.status.success(),
            "{} failed ({}); check the selected Xcode",
            args.join(" "),
            finished.status
        );
        identity.push_str(String::from_utf8_lossy(&finished.stdout).trim());
        identity.push('\n');
    }
    for variable in ["DEVELOPER_DIR", "TOOLCHAINS"] {
        if let Some(value) = std::env::var_os(variable) {
            identity.push_str(&format!("{variable}={}\n", value.to_string_lossy()));
        }
    }
    Ok(identity)
}

/// The overlay cache lock, waited for without blocking a thread or outliving
/// the build's cancellation and deadline.
async fn lock(path: &Path, deadline: Instant, cancel: &watch::Receiver<bool>) -> Result<fs::File> {
    let file = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(path)?;
    loop {
        match file.try_lock() {
            Ok(()) => return Ok(file),
            Err(fs::TryLockError::WouldBlock) => {}
            Err(fs::TryLockError::Error(error)) => {
                return Err(error).context("cannot lock the overlay cache");
            }
        }
        tokio::select! {
            _ = cancelled(Some(cancel.clone())) => bail!("build cancelled while waiting for the overlay cache"),
            _ = tokio::time::sleep_until(deadline) => bail!("build exceeded the 30-minute timeout waiting for the overlay cache"),
            _ = tokio::time::sleep(std::time::Duration::from_millis(200)) => {}
        }
    }
}

fn finished(result: Result<Finished, RunError>, tool: &str) -> Result<Finished> {
    result.map_err(|error| match error {
        RunError::Cancelled => anyhow!("build cancelled while running {tool}"),
        RunError::TimedOut => anyhow!("build exceeded its timeout while running {tool}"),
        RunError::Failed(error) => error.context(format!("{tool} did not complete")),
    })
}

/// The device framework for the current overlay sources and toolchain, built
/// once and cached under `<data-dir>/overlay/<key>/`.
pub async fn framework(
    data_root: &Path,
    log: &Path,
    deadline: Instant,
    cancel: watch::Receiver<bool>,
) -> Result<PathBuf> {
    let project = overlay_project();
    ensure!(
        project.join("project.pbxproj").is_file(),
        "overlay project not found at {}; set SQUIRCLE_OVERLAY_PROJECT",
        project.display()
    );
    let cache = data_root.join("overlay");
    fs::create_dir_all(&cache)?;
    let _lock = lock(&cache.join(".lock"), deadline, &cancel).await?;
    let toolchain = toolchain(deadline, &cancel).await?;
    let key = cache_key(&project, &toolchain)?;
    if let Some(product) = cached(&cache.join(&key), &key) {
        return Ok(product);
    }
    let scratch = cache.join(format!("build-{key}"));
    let _ = fs::remove_dir_all(&scratch);
    let mut symroot = OsString::from("SYMROOT=");
    symroot.push(&scratch);
    let mut objroot = OsString::from("OBJROOT=");
    objroot.push(scratch.join("obj"));
    let mut args: Vec<OsString> = vec!["-project".into(), project.into_os_string()];
    args.extend(BUILD_SETTINGS.map(OsString::from));
    args.extend([symroot, objroot, "build".into()]);
    run_command(&args, log, None, deadline, cancel).await?;
    let built = scratch.join("Release-iphoneos").join(FRAMEWORK);
    ensure!(
        built.join("SquircleOverlay").is_file(),
        "overlay build produced no framework"
    );
    // Module interfaces are for compilers, not for the device.
    let _ = fs::remove_dir_all(built.join("Modules"));
    let product = publish(&cache, &key, &toolchain, &built)?;
    let _ = fs::remove_dir_all(&scratch);
    Ok(product)
}

/// Embeds the framework into an archived app, loads it from the main binary
/// and re-signs the app with the shared Keychain group added, ready for export.
pub async fn inject(
    app: &Path,
    framework: &Path,
    build_id: &str,
    log_path: &Path,
    deadline: Instant,
    cancel: watch::Receiver<bool>,
) -> Result<()> {
    let mut log = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path)?;
    writeln!(
        log,
        "\n== Squircle overlay: injecting into {}",
        app.display()
    )?;
    let info = plist::Value::from_file(app.join("Info.plist"))?;
    let executable = info
        .as_dictionary()
        .and_then(|d| d.get("CFBundleExecutable"))
        .and_then(|v| v.as_string())
        .context("app Info.plist has no CFBundleExecutable")?;
    let binary = app.join(executable);

    // The overlay's creature animates on a display link, which iOS caps at
    // 60 Hz on ProMotion iPhones unless the app opts in.
    const FRAME_RATE_KEY: &str = "CADisableMinimumFrameDurationOnPhone";
    // The overlay reports the host's launch under this build, as Squircle
    // and apps built with SQUIRCLE_BUILD_ID do; without it an injected
    // build never shows whether its overlay started.
    const BUILD_ID_KEY: &str = "SquircleBuildID";
    let mut info = info;
    if let Some(dict) = info.as_dictionary_mut() {
        let mut changed = false;
        if dict.get(FRAME_RATE_KEY).and_then(|v| v.as_boolean()) != Some(true) {
            dict.insert(FRAME_RATE_KEY.into(), true.into());
            writeln!(log, "Allowed 120 Hz display links ({FRAME_RATE_KEY})")?;
            changed = true;
        }
        if dict.get(BUILD_ID_KEY).and_then(|v| v.as_string()) != Some(build_id) {
            dict.insert(BUILD_ID_KEY.into(), build_id.into());
            writeln!(
                log,
                "Overlay reports launches as build {build_id} ({BUILD_ID_KEY})"
            )?;
            changed = true;
        }
        if changed {
            info.to_file_binary(app.join("Info.plist"))?;
        }
    }

    let destination = app.join("Frameworks").join(FRAMEWORK);
    if destination.exists() {
        fs::remove_dir_all(&destination)?;
    }
    fs::create_dir_all(app.join("Frameworks"))?;
    copy_dir(framework, &destination)?;

    let mut bytes = fs::read(&binary)?;
    let added = add_weak_dylib(&mut bytes, LOAD_PATH)?;
    if added {
        fs::write(&binary, &bytes)?;
    }

    let signer = Signer {
        deadline,
        cancel: &cancel,
    };
    let identity = signer.identity(app, &mut log).await?;
    let mut entitlements = signer.entitlements(app, &mut log).await?;
    let team = entitlements
        .get("com.apple.developer.team-identifier")
        .and_then(|v| v.as_string())
        .context("app signature has no team identifier")?
        .to_owned();
    let application = entitlements
        .get("application-identifier")
        .and_then(|v| v.as_string())
        .context("app signature has no application identifier")?
        .to_owned();
    let mut groups: Vec<plist::Value> = entitlements
        .get("keychain-access-groups")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    // Without explicit groups the app's own Keychain items default to its
    // application identifier; keep that first so its behavior is unchanged.
    if groups.is_empty() {
        groups.push(application.into());
    }
    let framework_info = plist::Value::from_file(framework.join("Info.plist"))?;
    let group = info_string(&framework_info, SHARED_GROUP_KEY)
        .with_context(|| format!("overlay framework's Info.plist has no {SHARED_GROUP_KEY}"))?;
    let shared = format!("{team}.{group}");
    if !groups.iter().any(|g| g.as_string() == Some(&shared)) {
        groups.push(shared.into());
    }
    entitlements.insert("keychain-access-groups".into(), groups.into());
    let entitlements_path = log_path.with_file_name("overlay-entitlements.plist");
    plist::Value::Dictionary(entitlements).to_file_xml(&entitlements_path)?;

    signer
        .sign(&["-f", "-s", &identity], &destination, &mut log)
        .await?;
    signer
        .sign(
            &[
                "-f",
                "-s",
                &identity,
                "--generate-entitlement-der",
                "--entitlements",
                &entitlements_path.to_string_lossy(),
            ],
            app,
            &mut log,
        )
        .await?;
    signer
        .sign(&["--verify", "--strict"], app, &mut log)
        .await?;
    writeln!(log, "== Squircle overlay injected (signed by {identity})")?;
    Ok(())
}

/// Runs `codesign` within the build's deadline and cancellation.
struct Signer<'a> {
    deadline: Instant,
    cancel: &'a watch::Receiver<bool>,
}

impl Signer<'_> {
    async fn run(&self, args: &[&str], path: &Path, log: &mut fs::File) -> Result<Finished> {
        writeln!(
            log,
            "$ /usr/bin/codesign {} {}",
            args.join(" "),
            path.display()
        )?;
        let mut command = Command::new("/usr/bin/codesign");
        command.args(args).arg(path);
        let output = finished(
            run_bounded(
                command,
                Sink::Capture(4 * 1024 * 1024),
                Sink::Capture(1024 * 1024),
                self.deadline,
                Some(self.cancel.clone()),
            )
            .await,
            "codesign",
        )?;
        log.write_all(&output.stderr)?;
        Ok(output)
    }

    async fn sign(&self, args: &[&str], path: &Path, log: &mut fs::File) -> Result<()> {
        let output = self.run(args, path, log).await?;
        ensure!(
            output.status.success(),
            "codesign {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        );
        Ok(())
    }

    /// The certificate that signed the archive, reused for the injected parts.
    async fn identity(&self, app: &Path, log: &mut fs::File) -> Result<String> {
        let output = self.run(&["-dvv"], app, log).await?;
        String::from_utf8_lossy(&output.stderr)
            .lines()
            .find_map(|l| l.strip_prefix("Authority=").map(str::to_owned))
            .context("archived app is not signed with a certificate")
    }

    async fn entitlements(&self, app: &Path, log: &mut fs::File) -> Result<plist::Dictionary> {
        let output = self
            .run(&["-d", "--entitlements", "-", "--xml"], app, log)
            .await?;
        ensure!(output.status.success(), "cannot read app entitlements");
        let value = plist::Value::from_reader_xml(output.stdout.as_slice())
            .context("app entitlements are not a property list")?;
        value
            .into_dictionary()
            .context("app entitlements are not a dictionary")
    }
}

fn copy_dir(from: &Path, to: &Path) -> Result<()> {
    fs::create_dir_all(to)?;
    for entry in fs::read_dir(from)? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        let kind = entry.file_type()?;
        if kind.is_dir() {
            copy_dir(&entry.path(), &target)?;
        } else if kind.is_symlink() {
            std::os::unix::fs::symlink(fs::read_link(entry.path())?, &target)?;
        } else {
            fs::copy(entry.path(), &target)?;
        }
    }
    Ok(())
}

const MH_MAGIC_64: u32 = 0xfeed_facf;
const FAT_MAGIC: u32 = 0xcafe_babe;
const LC_SEGMENT_64: u32 = 0x19;
const LC_LOAD_WEAK_DYLIB: u32 = 0x8000_0018;
const LC_LOAD_DYLIB: u32 = 0xc;
const HEADER_64: usize = 32;
const FAT_ARCH: usize = 20;
const MAX_FAT_ARCHS: usize = 64;
const SEGMENT_64: usize = 72;
const SECTION_64: usize = 80;
const DYLIB_COMMAND: usize = 24;

fn field<const N: usize>(bytes: &[u8], offset: usize) -> Result<[u8; N]> {
    offset
        .checked_add(N)
        .and_then(|end| bytes.get(offset..end))
        .map(|b| b.try_into().unwrap())
        .context("truncated Mach-O header")
}

fn be32(bytes: &[u8], offset: usize) -> Result<u32> {
    field(bytes, offset).map(u32::from_be_bytes)
}

fn le32(bytes: &[u8], offset: usize) -> Result<u32> {
    field(bytes, offset).map(u32::from_le_bytes)
}

/// The edit for one slice: a new load command and the header counts after it.
struct Insertion {
    start: usize,
    command: Vec<u8>,
    ncmds: u32,
    sizeofcmds: u32,
}

/// Adds a weak `LC_LOAD_WEAK_DYLIB` to every 64-bit slice, in the header
/// padding Xcode leaves before the first section. Returns false if present.
/// Every slice is validated before any byte changes.
pub fn add_weak_dylib(bytes: &mut [u8], path: &str) -> Result<bool> {
    let slices = if be32(bytes, 0)? == FAT_MAGIC {
        let count = be32(bytes, 4)? as usize;
        ensure!(
            (1..=MAX_FAT_ARCHS).contains(&count),
            "universal binary has an unsupported slice count"
        );
        let table_end = 8 + count * FAT_ARCH;
        let mut slices = Vec::with_capacity(count);
        for i in 0..count {
            let entry = 8 + i * FAT_ARCH;
            let offset = be32(bytes, entry + 8)? as usize;
            let size = be32(bytes, entry + 12)? as usize;
            let end = offset
                .checked_add(size)
                .filter(|&end| offset >= table_end && end <= bytes.len())
                .context("truncated universal binary")?;
            slices.push(offset..end);
        }
        slices.sort_by_key(|slice| slice.start);
        ensure!(
            slices.windows(2).all(|w| w[0].end <= w[1].start),
            "universal binary slices overlap"
        );
        slices
    } else {
        std::iter::once(0..bytes.len()).collect()
    };
    let insertions = slices
        .iter()
        .map(|slice| plan_slice(&bytes[slice.clone()], path))
        .collect::<Result<Vec<_>>>()?;
    let mut added = false;
    for (slice, insertion) in slices.into_iter().zip(insertions) {
        let Some(insertion) = insertion else { continue };
        let slice = &mut bytes[slice];
        let end = insertion.start + insertion.command.len();
        slice[insertion.start..end].copy_from_slice(&insertion.command);
        slice[16..20].copy_from_slice(&insertion.ncmds.to_le_bytes());
        slice[20..24].copy_from_slice(&insertion.sizeofcmds.to_le_bytes());
        added = true;
    }
    Ok(added)
}

/// Where the load command goes in one thin slice, or `None` if it is there.
fn plan_slice(slice: &[u8], path: &str) -> Result<Option<Insertion>> {
    ensure!(slice.len() >= HEADER_64, "binary too small");
    if le32(slice, 0)? != MH_MAGIC_64 {
        bail!("only 64-bit Mach-O executables are supported");
    }
    let ncmds = le32(slice, 16)?;
    let sizeofcmds = le32(slice, 20)? as usize;
    let commands_end = HEADER_64
        .checked_add(sizeofcmds)
        .filter(|&end| end <= slice.len())
        .context("load commands exceed the binary")?;
    ensure!(
        ncmds as usize <= sizeofcmds / 8,
        "malformed load command count"
    );
    let mut offset = HEADER_64;
    let mut first_data = slice.len();
    for _ in 0..ncmds {
        let cmd = le32(slice, offset)?;
        let size = le32(slice, offset + 4)? as usize;
        let end = offset
            .checked_add(size)
            .filter(|&end| size >= 8 && end <= commands_end)
            .context("malformed load command")?;
        let command = &slice[offset..end];
        if cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB {
            let name = le32(command, 8)? as usize;
            ensure!(
                (DYLIB_COMMAND..=command.len()).contains(&name),
                "dylib name lies outside its load command"
            );
            let raw = &command[name..];
            let end = raw.iter().position(|&b| b == 0).unwrap_or(raw.len());
            if &raw[..end] == path.as_bytes() {
                return Ok(None);
            }
        }
        if cmd == LC_SEGMENT_64 {
            ensure!(size >= SEGMENT_64, "short segment load command");
            let sections = le32(command, 64)? as usize;
            sections
                .checked_mul(SECTION_64)
                .and_then(|n| n.checked_add(SEGMENT_64))
                .filter(|&end| end <= size)
                .context("segment sections exceed their load command")?;
            for s in 0..sections {
                let section = SEGMENT_64 + s * SECTION_64;
                let size = u64::from_le_bytes(field(command, section + 40)?);
                let file_offset = le32(command, section + 48)? as usize;
                if file_offset != 0 && size != 0 {
                    first_data = first_data.min(file_offset);
                }
            }
        }
        offset = end;
    }
    let name = path.as_bytes();
    let command_size = (DYLIB_COMMAND + name.len() + 1).div_ceil(8) * 8;
    let start = commands_end;
    let end = start + command_size;
    ensure!(
        end <= first_data && end <= slice.len(),
        "no header space to add the overlay load command"
    );
    ensure!(
        slice[start..end].iter().all(|&b| b == 0),
        "header padding is not empty"
    );
    let mut command = vec![0u8; command_size];
    command[0..4].copy_from_slice(&LC_LOAD_WEAK_DYLIB.to_le_bytes());
    command[4..8].copy_from_slice(&(command_size as u32).to_le_bytes());
    command[8..12].copy_from_slice(&(DYLIB_COMMAND as u32).to_le_bytes());
    command[12..16].copy_from_slice(&2u32.to_le_bytes());
    command[DYLIB_COMMAND..DYLIB_COMMAND + name.len()].copy_from_slice(name);
    Ok(Some(Insertion {
        start,
        command,
        ncmds: ncmds.checked_add(1).context("too many load commands")?,
        sizeofcmds: u32::try_from(sizeofcmds + command_size).context("load commands too large")?,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A minimal arm64 executable header with one __TEXT section at 0x4000.
    fn thin() -> Vec<u8> {
        let mut b = vec![0u8; 0x4000 + 16];
        b[0..4].copy_from_slice(&MH_MAGIC_64.to_le_bytes());
        b[16..20].copy_from_slice(&1u32.to_le_bytes());
        b[20..24].copy_from_slice(&152u32.to_le_bytes());
        let seg = 32;
        b[seg..seg + 4].copy_from_slice(&LC_SEGMENT_64.to_le_bytes());
        b[seg + 4..seg + 8].copy_from_slice(&152u32.to_le_bytes());
        b[seg + 64..seg + 68].copy_from_slice(&1u32.to_le_bytes());
        let sect = seg + 72;
        b[sect + 40..sect + 48].copy_from_slice(&16u64.to_le_bytes());
        b[sect + 48..sect + 52].copy_from_slice(&0x4000u32.to_le_bytes());
        b
    }

    #[test]
    fn adds_load_command_once() {
        let mut b = thin();
        assert!(add_weak_dylib(&mut b, LOAD_PATH).unwrap());
        assert_eq!(u32::from_le_bytes(b[16..20].try_into().unwrap()), 2);
        let start = 32 + 152;
        assert_eq!(
            u32::from_le_bytes(b[start..start + 4].try_into().unwrap()),
            LC_LOAD_WEAK_DYLIB
        );
        assert!(!add_weak_dylib(&mut b, LOAD_PATH).unwrap());
    }

    #[test]
    fn refuses_without_header_space() {
        let mut b = thin();
        b[20..24].copy_from_slice(&(0x4000u32 - 40).to_le_bytes());
        assert!(add_weak_dylib(&mut b, LOAD_PATH).is_err());
    }

    #[test]
    fn malformed_headers_are_errors_not_panics() {
        let fat = |count: u32, offset: u32, size: u32| {
            let mut b = vec![0u8; 64];
            b[0..4].copy_from_slice(&FAT_MAGIC.to_be_bytes());
            b[4..8].copy_from_slice(&count.to_be_bytes());
            b[16..20].copy_from_slice(&offset.to_be_bytes());
            b[20..24].copy_from_slice(&size.to_be_bytes());
            b
        };
        let mut cases: Vec<Vec<u8>> = vec![
            vec![],
            vec![0xfe, 0xed, 0xfa],
            FAT_MAGIC.to_be_bytes().to_vec(),
            fat(1, 28, u32::MAX),
            fat(1, 0, 32),
            fat(0x4000_0000, 28, 4),
        ];
        // Commands larger than the file.
        let mut b = thin();
        b[20..24].copy_from_slice(&u32::MAX.to_le_bytes());
        cases.push(b);
        // A segment command too short for its own header.
        let mut b = thin();
        b[36..40].copy_from_slice(&16u32.to_le_bytes());
        cases.push(b);
        // Sections beyond the segment command.
        let mut b = thin();
        b[32 + 64..32 + 68].copy_from_slice(&u32::MAX.to_le_bytes());
        cases.push(b);
        // A dylib name offset outside its command.
        let mut b = thin();
        b[32..36].copy_from_slice(&LC_LOAD_DYLIB.to_le_bytes());
        b[32 + 8..32 + 12].copy_from_slice(&0xffff_fff0u32.to_le_bytes());
        cases.push(b);
        for mut case in cases {
            assert!(add_weak_dylib(&mut case, LOAD_PATH).is_err());
        }
    }

    #[test]
    fn universal_binaries_change_only_when_every_slice_is_valid() {
        let slice = thin();
        let universal = |second: &[u8]| {
            let mut b = vec![0u8; 0x8000];
            b[0..4].copy_from_slice(&FAT_MAGIC.to_be_bytes());
            b[4..8].copy_from_slice(&2u32.to_be_bytes());
            for (i, (offset, len)) in [(0x1000, slice.len()), (0x6000, second.len())]
                .into_iter()
                .enumerate()
            {
                let entry = 8 + i * 20;
                b[entry + 8..entry + 12].copy_from_slice(&(offset as u32).to_be_bytes());
                b[entry + 12..entry + 16].copy_from_slice(&(len as u32).to_be_bytes());
            }
            b[0x1000..0x1000 + slice.len()].copy_from_slice(&slice);
            b.resize(0x6000 + second.len(), 0);
            b[0x6000..].copy_from_slice(second);
            b
        };
        let mut broken = thin();
        broken.truncate(100);
        let mut b = universal(&broken);
        let before = b.clone();
        assert!(add_weak_dylib(&mut b, LOAD_PATH).is_err());
        assert_eq!(b, before);

        let mut b = universal(&slice);
        assert!(add_weak_dylib(&mut b, LOAD_PATH).unwrap());
        for start in [0x1000, 0x6000] {
            assert_eq!(le32(&b, start + 16).unwrap(), 2);
        }
        assert!(!add_weak_dylib(&mut b, LOAD_PATH).unwrap());
    }

    fn overlay_fixture() -> (tempfile::TempDir, PathBuf) {
        let root = tempfile::tempdir().unwrap();
        let project = root.path().join("Squircle.xcodeproj");
        fs::create_dir_all(&project).unwrap();
        fs::write(project.join("project.pbxproj"), "{}").unwrap();
        for dir in ["Sources", "Overlay"] {
            fs::create_dir_all(root.path().join(dir)).unwrap();
            fs::write(root.path().join(dir).join("A.swift"), dir).unwrap();
        }
        fs::create_dir_all(root.path().join("Config")).unwrap();
        fs::write(root.path().join("Config/Signing.xcconfig"), "A = 1").unwrap();
        (root, project)
    }

    #[test]
    fn cache_key_follows_sources_and_toolchain() {
        let (root, project) = overlay_fixture();
        let key = cache_key(&project, "Xcode 26.0\nBuild 17A1\n23A1\n").unwrap();
        assert_eq!(
            key,
            cache_key(&project, "Xcode 26.0\nBuild 17A1\n23A1\n").unwrap()
        );
        assert_ne!(
            key,
            cache_key(&project, "Xcode 26.1\nBuild 17B1\n23B1\n").unwrap()
        );
        fs::write(root.path().join("Overlay/A.swift"), "changed").unwrap();
        let changed = cache_key(&project, "Xcode 26.0\nBuild 17A1\n23A1\n").unwrap();
        assert_ne!(key, changed);
        // A different namespace is a different framework.
        fs::write(root.path().join("Config/Local.xcconfig"), "B = 2").unwrap();
        assert_ne!(
            changed,
            cache_key(&project, "Xcode 26.0\nBuild 17A1\n23A1\n").unwrap()
        );
    }

    #[test]
    fn only_complete_unchanged_cache_entries_are_reused() {
        let cache = tempfile::tempdir().unwrap();
        let built = cache.path().join("build").join(FRAMEWORK);
        fs::create_dir_all(&built).unwrap();
        fs::write(built.join("SquircleOverlay"), "binary").unwrap();
        fs::write(built.join("Info.plist"), "info").unwrap();

        // A product without a manifest, as an interrupted publish leaves it.
        let entry = cache.path().join("abc");
        copy_dir(&built, &entry.join(FRAMEWORK)).unwrap();
        assert!(cached(&entry, "abc").is_none());

        let product = publish(cache.path(), "abc", "Xcode 26", &built).unwrap();
        assert_eq!(cached(&entry, "abc"), Some(product.clone()));
        assert!(cached(&entry, "other").is_none());
        assert!(!cache.path().join("staging-abc").exists());

        fs::write(product.join("SquircleOverlay"), "truncat").unwrap();
        assert!(cached(&entry, "abc").is_none());
    }
}
