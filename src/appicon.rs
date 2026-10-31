//! A built app's own icon, read from its bundle (or its IPA) the way iOS
//! finds it: the `CFBundleIcons` file names in Info.plist, largest first.
//! The PNG is returned as Xcode wrote it; iOS decodes Apple's optimised
//! PNGs itself. Read-only.

use anyhow::{Context, Result, bail, ensure};
use std::fs;
use std::io::Read;
use std::path::Path;

/// Icons are small; anything larger is not an app icon.
const LIMIT: u64 = 2 << 20;
const PNG: &[u8] = b"\x89PNG\r\n\x1a\n";

/// The icon of an app bundle on disk.
pub fn from_app(app: &Path) -> Result<Vec<u8>> {
    let info = plist::Value::from_file(app.join("Info.plist"))
        .context("cannot read the app's Info.plist")?;
    for file in candidates(&info) {
        let path = app.join(&file);
        let Ok(meta) = fs::metadata(&path) else {
            continue;
        };
        if meta.is_file() && meta.len() <= LIMIT {
            let bytes = fs::read(&path)?;
            if bytes.starts_with(PNG) {
                return Ok(bytes);
            }
        }
    }
    bail!("the app has no icon file")
}

/// The icon inside an IPA's single `Payload/*.app`.
pub fn from_ipa(ipa: &Path) -> Result<Vec<u8>> {
    let mut archive = zip::ZipArchive::new(fs::File::open(ipa)?)?;
    let info_name = archive
        .file_names()
        .find(|name| {
            let parts: Vec<_> = name.split('/').collect();
            parts.len() == 3
                && parts[0] == "Payload"
                && parts[1].ends_with(".app")
                && parts[2] == "Info.plist"
        })
        .map(str::to_owned)
        .context("the IPA has no app")?;
    let app = info_name.trim_end_matches("Info.plist").to_owned();
    let info =
        plist::Value::from_reader(std::io::Cursor::new(read_entry(&mut archive, &info_name)?))?;
    for file in candidates(&info) {
        if let Ok(bytes) = read_entry(&mut archive, &format!("{app}{file}"))
            && bytes.starts_with(PNG)
        {
            return Ok(bytes);
        }
    }
    bail!("the app has no icon file")
}

fn read_entry(archive: &mut zip::ZipArchive<fs::File>, name: &str) -> Result<Vec<u8>> {
    let entry = archive.by_name(name)?;
    ensure!(entry.size() <= LIMIT, "{name} is too large");
    let mut bytes = Vec::new();
    entry.take(LIMIT).read_to_end(&mut bytes)?;
    Ok(bytes)
}

/// File names to try, largest first: each declared icon name with the
/// scales Xcode writes, then the legacy keys.
fn candidates(info: &plist::Value) -> Vec<String> {
    let dictionary = info.as_dictionary();
    let names = |value: Option<&plist::Value>| -> Vec<String> {
        value
            .and_then(plist::Value::as_array)
            .map(|array| {
                array
                    .iter()
                    .filter_map(plist::Value::as_string)
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default()
    };
    let primary = dictionary
        .and_then(|d| d.get("CFBundleIcons"))
        .and_then(plist::Value::as_dictionary)
        .and_then(|d| d.get("CFBundlePrimaryIcon"))
        .and_then(plist::Value::as_dictionary);
    let mut declared = names(primary.and_then(|d| d.get("CFBundleIconFiles")));
    declared.extend(names(dictionary.and_then(|d| d.get("CFBundleIconFiles"))));
    if let Some(file) = dictionary
        .and_then(|d| d.get("CFBundleIconFile"))
        .and_then(plist::Value::as_string)
    {
        declared.push(file.to_owned());
    }
    let mut files = Vec::new();
    for name in declared.iter().rev() {
        // Names come without a path; never leave the bundle.
        if name.contains('/') || name.contains("..") {
            continue;
        }
        let stem = name.strip_suffix(".png").unwrap_or(name);
        for suffix in ["@3x.png", "@2x.png", ".png", "@2x~ipad.png"] {
            files.push(format!("{stem}{suffix}"));
        }
    }
    files
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn candidates_skip_paths_and_try_largest_first() {
        let info = plist::Value::from_reader_xml(
            r#"<plist><dict><key>CFBundleIcons</key><dict><key>CFBundlePrimaryIcon</key><dict>
            <key>CFBundleIconFiles</key><array><string>../evil</string><string>AppIcon60x60</string></array>
            </dict></dict></dict></plist>"#
                .as_bytes(),
        )
        .unwrap();
        let files = candidates(&info);
        assert_eq!(files[0], "AppIcon60x60@3x.png");
        assert!(files.iter().all(|f| !f.contains("..")));
    }
}
