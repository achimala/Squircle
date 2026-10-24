use crate::model::BuildOutput;
use anyhow::{Context, Result, bail};
use plist::{Dictionary, Value};
use std::{fs::File, io::Read, path::Path};
use url::Url;

/// Reads metadata without extracting the IPA or executing any of its contents.
/// This does not validate the Apple signature or device provisioning.
pub fn inspect_ipa(path: &Path) -> Result<BuildOutput> {
    let mut zip = zip::ZipArchive::new(File::open(path).context("Cannot open IPA")?)?;
    let candidates: Vec<_> = zip
        .file_names()
        .filter(|name| {
            let parts: Vec<_> = name.split('/').collect();
            parts.len() == 3
                && parts[0] == "Payload"
                && parts[1].ends_with(".app")
                && parts[2] == "Info.plist"
        })
        .map(str::to_owned)
        .collect();
    if candidates.len() != 1 {
        bail!("Expected exactly one top-level Payload/*.app/Info.plist");
    }
    let mut bytes = Vec::new();
    zip.by_name(&candidates[0])?
        .take(2 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > 2 * 1024 * 1024 {
        bail!("IPA Info.plist exceeds 2 MiB");
    }
    let value = Value::from_reader(std::io::Cursor::new(bytes))?;
    let dict = value
        .as_dictionary()
        .context("IPA Info.plist must be a dictionary")?;
    let required = |name: &str| -> Result<String> {
        let text = dict
            .get(name)
            .and_then(Value::as_string)
            .filter(|s| !s.trim().is_empty())
            .with_context(|| format!("IPA missing {name}"))?;
        if text.len() > 1024 {
            bail!("IPA metadata field too long: {name}");
        }
        Ok(text.to_string())
    };
    let bundle_id = required("CFBundleIdentifier")?;
    let build_number = required("CFBundleVersion")?;
    let version = dict
        .get("CFBundleShortVersionString")
        .and_then(Value::as_string)
        .unwrap_or(&build_number)
        .to_owned();
    let title = dict
        .get("CFBundleDisplayName")
        .or_else(|| dict.get("CFBundleName"))
        .and_then(Value::as_string)
        .unwrap_or(&bundle_id)
        .to_owned();
    Ok(BuildOutput {
        archive_path: None,
        ipa_path: Some(path.to_path_buf()),
        app_path: None,
        dsym_paths: vec![],
        bundle_id,
        version,
        build_number,
        title,
    })
}

pub fn validate_public_url(input: &str) -> Result<String> {
    let url = Url::parse(input)?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.path() != "/"
    {
        bail!(
            "Public URL must be an HTTPS origin, e.g. https://mac.example.ts.net (no path, credentials, query or fragment)"
        );
    }
    Ok(url.as_str().trim_end_matches('/').to_owned())
}

pub fn manifest(output: &BuildOutput, ipa_url: &str) -> Result<Vec<u8>> {
    let mut asset = Dictionary::new();
    asset.insert("kind".into(), Value::String("software-package".into()));
    asset.insert("url".into(), Value::String(ipa_url.into()));
    let mut metadata = Dictionary::new();
    metadata.insert(
        "bundle-identifier".into(),
        Value::String(output.bundle_id.clone()),
    );
    metadata.insert(
        "bundle-version".into(),
        Value::String(output.build_number.clone()),
    );
    metadata.insert("kind".into(), Value::String("software".into()));
    metadata.insert("title".into(), Value::String(output.title.clone()));
    let mut item = Dictionary::new();
    item.insert(
        "assets".into(),
        Value::Array(vec![Value::Dictionary(asset)]),
    );
    item.insert("metadata".into(), Value::Dictionary(metadata));
    let mut root = Dictionary::new();
    root.insert("items".into(), Value::Array(vec![Value::Dictionary(item)]));
    let mut xml = Vec::new();
    Value::Dictionary(root).to_writer_xml(&mut xml)?;
    Ok(xml)
}

pub fn install_url(manifest_url: &str) -> String {
    let query = url::form_urlencoded::Serializer::new(String::new())
        .append_pair("action", "download-manifest")
        .append_pair("url", manifest_url)
        .finish();
    format!("itms-services://?{query}")
}

pub fn escape_html(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_unsafe_or_ambiguous_origins() {
        for input in [
            "http://mac.test",
            "https://u:p@mac.test",
            "https://mac.test/path",
            "https://mac.test/?token=x",
            "https://mac.test/#x",
        ] {
            assert!(validate_public_url(input).is_err(), "{input}");
        }
        assert_eq!(
            validate_public_url("https://mac.test:443/").unwrap(),
            "https://mac.test"
        );
    }
}
