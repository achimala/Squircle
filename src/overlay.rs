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

use anyhow::{Context, Result, bail, ensure};
use fs2::FileExt;
use sha2::{Digest, Sha256};
use tokio::{process::Command, sync::watch, time::Instant};

use crate::xcode::run_command;

pub const FRAMEWORK: &str = "SquircleOverlay.framework";
const LOAD_PATH: &str = "@executable_path/Frameworks/SquircleOverlay.framework/SquircleOverlay";
const SHARED_GROUP: &str = "ai.dreamslate.squircle.shared";
/// Squircle itself is the source of the shared connection, never a host.
const SQUIRCLE_BUNDLE_ID: &str = "ai.dreamslate.Squircle";

/// Export methods whose builds carry a provisioning profile and stay off the
/// App Store.
pub fn allowed_method(method: &str) -> bool {
    matches!(
        method,
        "development" | "debugging" | "ad-hoc" | "release-testing"
    )
}

pub fn skips_bundle(bundle_id: &str) -> bool {
    bundle_id == SQUIRCLE_BUNDLE_ID
}

fn overlay_project() -> PathBuf {
    std::env::var_os("SQUIRCLE_OVERLAY_PROJECT")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            Path::new(env!("CARGO_MANIFEST_DIR")).join("app/Squircle/Squircle.xcodeproj")
        })
}

/// Hash of everything the framework is compiled from.
fn source_key(project: &Path) -> Result<String> {
    let root = project.parent().context("overlay project has no parent")?;
    let mut files = Vec::new();
    fn walk(dir: &Path, files: &mut Vec<PathBuf>) -> Result<()> {
        for entry in fs::read_dir(dir)? {
            let path = entry?.path();
            if path.is_dir() {
                walk(&path, files)?;
            } else if matches!(
                path.extension().and_then(|e| e.to_str()),
                Some("swift" | "c" | "h" | "metal")
            ) {
                files.push(path);
            }
        }
        Ok(())
    }
    walk(&root.join("Sources"), &mut files)?;
    walk(&root.join("Overlay"), &mut files)?;
    files.push(project.join("project.pbxproj"));
    files.sort();
    let mut hash = Sha256::new();
    for file in files {
        hash.update(file.strip_prefix(root)?.to_string_lossy().as_bytes());
        hash.update([0]);
        hash.update(fs::read(&file).with_context(|| format!("cannot read {}", file.display()))?);
        hash.update([0]);
    }
    Ok(hash
        .finalize()
        .iter()
        .take(12)
        .map(|b| format!("{b:02x}"))
        .collect())
}

/// The device framework for the current overlay sources, built once and cached
/// under `<data-dir>/overlay/<source hash>/`.
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
    let lock = fs::File::create(cache.join(".lock"))?;
    tokio::task::block_in_place(|| lock.lock_exclusive())?;
    let key = source_key(&project)?;
    let product = cache.join(&key).join(FRAMEWORK);
    if product.join("SquircleOverlay").is_file() {
        return Ok(product);
    }
    let scratch = cache.join(format!("build-{key}"));
    let _ = fs::remove_dir_all(&scratch);
    let mut symroot = OsString::from("SYMROOT=");
    symroot.push(&scratch);
    let mut objroot = OsString::from("OBJROOT=");
    objroot.push(scratch.join("obj"));
    let args: Vec<OsString> = vec![
        "-project".into(),
        project.into_os_string(),
        "-target".into(),
        "SquircleOverlay".into(),
        "-configuration".into(),
        "Release".into(),
        "-sdk".into(),
        "iphoneos".into(),
        symroot,
        objroot,
        "DEPLOYMENT_POSTPROCESSING=YES".into(),
        "build".into(),
    ];
    run_command(&args, log, None, deadline, cancel).await?;
    let built = scratch.join("Release-iphoneos").join(FRAMEWORK);
    ensure!(
        built.join("SquircleOverlay").is_file(),
        "overlay build produced no framework"
    );
    // Module interfaces are for compilers, not for the device.
    let _ = fs::remove_dir_all(built.join("Modules"));
    fs::create_dir_all(product.parent().unwrap())?;
    fs::rename(&built, &product)?;
    let _ = fs::remove_dir_all(&scratch);
    Ok(product)
}

/// Embeds the framework into an archived app, loads it from the main binary
/// and re-signs the app with the shared Keychain group added, ready for export.
pub async fn inject(app: &Path, framework: &Path, log_path: &Path) -> Result<()> {
    let mut log = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path)?;
    writeln!(log, "\n== Squircle overlay: injecting into {}", app.display())?;
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
    let mut info = info;
    if let Some(dict) = info.as_dictionary_mut() {
        if dict.get(FRAME_RATE_KEY).and_then(|v| v.as_boolean()) != Some(true) {
            dict.insert(FRAME_RATE_KEY.into(), true.into());
            info.to_file_binary(app.join("Info.plist"))?;
            writeln!(log, "Allowed 120 Hz display links ({FRAME_RATE_KEY})")?;
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

    let identity = signing_identity(app).await?;
    let mut entitlements = entitlements(app).await?;
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
    let shared = format!("{team}.{SHARED_GROUP}");
    if !groups.iter().any(|g| g.as_string() == Some(&shared)) {
        groups.push(shared.into());
    }
    entitlements.insert("keychain-access-groups".into(), groups.into());
    let entitlements_path = log_path.with_file_name("overlay-entitlements.plist");
    plist::Value::Dictionary(entitlements).to_file_xml(&entitlements_path)?;

    codesign(&["-f", "-s", &identity], &destination, &mut log).await?;
    codesign(
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
    codesign(&["--verify", "--strict"], app, &mut log).await?;
    writeln!(log, "== Squircle overlay injected (signed by {identity})")?;
    Ok(())
}

async fn codesign(args: &[&str], path: &Path, log: &mut fs::File) -> Result<String> {
    writeln!(log, "$ /usr/bin/codesign {} {}", args.join(" "), path.display())?;
    let output = Command::new("/usr/bin/codesign")
        .args(args)
        .arg(path)
        .output()
        .await
        .context("cannot run /usr/bin/codesign")?;
    log.write_all(&output.stderr)?;
    ensure!(
        output.status.success(),
        "codesign {} failed: {}",
        args.join(" "),
        String::from_utf8_lossy(&output.stderr).trim()
    );
    Ok(String::from_utf8_lossy(&output.stderr).into_owned())
}

/// The certificate that signed the archive, reused for the injected parts.
async fn signing_identity(app: &Path) -> Result<String> {
    let output = Command::new("/usr/bin/codesign")
        .args(["-dvv"])
        .arg(app)
        .output()
        .await?;
    String::from_utf8_lossy(&output.stderr)
        .lines()
        .find_map(|l| l.strip_prefix("Authority=").map(str::to_owned))
        .context("archived app is not signed with a certificate")
}

async fn entitlements(app: &Path) -> Result<plist::Dictionary> {
    let output = Command::new("/usr/bin/codesign")
        .args(["-d", "--entitlements", "-", "--xml"])
        .arg(app)
        .output()
        .await?;
    ensure!(output.status.success(), "cannot read app entitlements");
    let value = plist::Value::from_reader_xml(output.stdout.as_slice())
        .context("app entitlements are not a property list")?;
    value
        .into_dictionary()
        .context("app entitlements are not a dictionary")
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

/// Adds a weak `LC_LOAD_WEAK_DYLIB` to every 64-bit slice, in the header
/// padding Xcode leaves before the first section. Returns false if present.
pub fn add_weak_dylib(bytes: &mut [u8], path: &str) -> Result<bool> {
    let be = |b: &[u8], o: usize| u32::from_be_bytes(b[o..o + 4].try_into().unwrap());
    if be(bytes, 0) == FAT_MAGIC {
        let count = be(bytes, 4) as usize;
        let mut added = false;
        for i in 0..count {
            let entry = 8 + i * 20;
            let offset = be(bytes, entry + 8) as usize;
            let size = be(bytes, entry + 12) as usize;
            ensure!(offset + size <= bytes.len(), "truncated universal binary");
            added |= add_to_slice(&mut bytes[offset..offset + size], path)?;
        }
        return Ok(added);
    }
    add_to_slice(bytes, path)
}

fn add_to_slice(slice: &mut [u8], path: &str) -> Result<bool> {
    let le = |b: &[u8], o: usize| u32::from_le_bytes(b[o..o + 4].try_into().unwrap());
    ensure!(slice.len() >= 32, "binary too small");
    if le(slice, 0) != MH_MAGIC_64 {
        bail!("only 64-bit Mach-O executables are supported");
    }
    let ncmds = le(slice, 16) as usize;
    let sizeofcmds = le(slice, 20) as usize;
    let mut offset = 32;
    let mut first_data = slice.len();
    for _ in 0..ncmds {
        let cmd = le(slice, offset);
        let size = le(slice, offset + 4) as usize;
        ensure!(size >= 8 && offset + size <= slice.len(), "malformed load command");
        if cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB {
            let name = le(slice, offset + 8) as usize;
            let raw = &slice[offset + name..offset + size];
            let end = raw.iter().position(|&b| b == 0).unwrap_or(raw.len());
            if &raw[..end] == path.as_bytes() {
                return Ok(false);
            }
        }
        if cmd == LC_SEGMENT_64 {
            let sections = le(slice, offset + 64) as usize;
            for s in 0..sections {
                let section = offset + 72 + s * 80;
                let size = u64::from_le_bytes(slice[section + 40..section + 48].try_into().unwrap());
                let file_offset = le(slice, section + 48) as usize;
                if file_offset != 0 && size != 0 {
                    first_data = first_data.min(file_offset);
                }
            }
        }
        offset += size;
    }
    let name = path.as_bytes();
    let command_size = (24 + name.len() + 1).div_ceil(8) * 8;
    let start = 32 + sizeofcmds;
    ensure!(
        start + command_size <= first_data,
        "no header space to add the overlay load command"
    );
    ensure!(
        slice[start..start + command_size].iter().all(|&b| b == 0),
        "header padding is not empty"
    );
    let command = &mut slice[start..start + command_size];
    command[0..4].copy_from_slice(&LC_LOAD_WEAK_DYLIB.to_le_bytes());
    command[4..8].copy_from_slice(&(command_size as u32).to_le_bytes());
    command[8..12].copy_from_slice(&24u32.to_le_bytes());
    command[12..16].copy_from_slice(&2u32.to_le_bytes());
    command[24..24 + name.len()].copy_from_slice(name);
    slice[16..20].copy_from_slice(&((ncmds + 1) as u32).to_le_bytes());
    slice[20..24].copy_from_slice(&((sizeofcmds + command_size) as u32).to_le_bytes());
    Ok(true)
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
    fn app_store_is_never_injected() {
        assert!(!allowed_method("app-store"));
        assert!(!allowed_method("app-store-connect"));
        assert!(!allowed_method("enterprise"));
        assert!(allowed_method("release-testing"));
        assert!(skips_bundle("ai.dreamslate.Squircle"));
    }
}
