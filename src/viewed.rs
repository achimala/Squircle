//! Pictures a Claude agent looked at with its Read tool. T3 records that the
//! call viewed an image (its path and size) but not the bytes, so they come
//! from Claude's own session transcript, which keeps the exact image the
//! agent saw even after the file is changed or gone; else from the file, if
//! it is still there. Read-only: neither is ever written.

use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};

use base64::Engine;
use serde_json::{Value, json};

/// Larger files on disk are not sent to the phone.
const MAX_FILE: u64 = 40 << 20;

/// `CLAUDE_CONFIG_DIR`, else `~/.claude`: where Claude keeps transcripts.
fn claude_home() -> Option<PathBuf> {
    std::env::var_os("CLAUDE_CONFIG_DIR")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| dirs::home_dir().map(|h| h.join(".claude")))
}

/// Claude's transcript of a session: `projects/<its cwd>/<session>.jsonl`.
fn transcript(session: &str) -> Option<PathBuf> {
    if !crate::t3steps::valid(session, &[]) {
        return None;
    }
    let name = format!("{session}.jsonl");
    std::fs::read_dir(claude_home()?.join("projects"))
        .ok()?
        .flatten()
        .map(|dir| dir.path().join(&name))
        .find(|path| path.is_file())
}

/// Whether the picture can be had, without reading it.
pub(crate) fn available(session: Option<&str>, path: Option<&str>) -> bool {
    session.and_then(transcript).is_some() || path.is_some_and(|p| Path::new(p).is_file())
}

/// The picture as `{media_type, data}` (base64), or none.
pub(crate) async fn image(
    session: Option<String>,
    call: String,
    path: Option<String>,
) -> Option<Value> {
    tokio::task::spawn_blocking(move || {
        let found = session
            .as_deref()
            .and_then(transcript)
            .and_then(|file| std::fs::File::open(file).ok())
            .and_then(|file| from_transcript(BufReader::new(file), &call))
            .or_else(|| path.as_deref().and_then(from_disk))?;
        Some(json!({ "media_type": found.0, "data": found.1 }))
    })
    .await
    .ok()
    .flatten()
}

/// The first image in the tool result for `call`: Claude records it as the
/// result message's image block, and again as the tool's own `file`.
fn from_transcript(mut reader: impl BufRead, call: &str) -> Option<(String, String)> {
    let finder = memchr::memmem::Finder::new(call.as_bytes());
    let mut line = Vec::new();
    loop {
        line.clear();
        if reader.read_until(b'\n', &mut line).ok()? == 0 {
            return None;
        }
        // The call's own request names it too; only its result has the image.
        if finder.find(&line).is_none() || memchr::memmem::find(&line, b"tool_result").is_none() {
            continue;
        }
        let Ok(entry) = serde_json::from_slice::<Value>(&line) else {
            continue;
        };
        let mut blocks = entry["message"]["content"].as_array().into_iter().flatten();
        let Some(result) = blocks.find(|b| b["type"] == "tool_result" && b["tool_use_id"] == call)
        else {
            continue;
        };
        let image = result["content"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|b| b["type"] == "image" && b["source"]["data"].is_string())
            .map(|b| (&b["source"]["media_type"], &b["source"]["data"]));
        let file = &entry["toolUseResult"]["file"];
        let (kind, data) = image.unwrap_or((&file["type"], &file["base64"]));
        let data = data.as_str().filter(|d| !d.is_empty())?;
        let kind = kind
            .as_str()
            .filter(|k| k.starts_with("image/"))
            .unwrap_or("image/png");
        return Some((kind.to_owned(), data.to_owned()));
    }
}

/// The file, if it is still an image.
fn from_disk(path: &str) -> Option<(String, String)> {
    let file = std::fs::File::open(path).ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() || metadata.len() > MAX_FILE {
        return None;
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(MAX_FILE).read_to_end(&mut bytes).ok()?;
    let kind = sniff(&bytes)?;
    Some((
        kind.to_owned(),
        base64::engine::general_purpose::STANDARD.encode(bytes),
    ))
}

/// An image type from its first bytes; none for anything else.
fn sniff(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("image/png")
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some("image/jpeg")
    } else if bytes.starts_with(b"GIF8") {
        Some("image/gif")
    } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some("image/webp")
    } else if bytes.len() >= 12
        && &bytes[4..8] == b"ftyp"
        && [b"heic", b"heix", b"mif1"].contains(&&bytes[8..12].try_into().ok()?)
    {
        Some("image/heic")
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_the_result_image_not_the_request_or_other_calls() {
        let transcript = [
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_A","name":"Read","input":{"file_path":"/tmp/a.png"}}]}}"#,
            r#"{"type":"user","message":{"content":[{"tool_use_id":"toolu_B","type":"tool_result","content":[{"type":"image","source":{"type":"base64","data":"BBBB","media_type":"image/png"}}]}]}}"#,
            r#"{"type":"user","message":{"content":[{"tool_use_id":"toolu_A","type":"tool_result","content":[{"type":"text","text":"toolu_B"},{"type":"image","source":{"type":"base64","data":"AAAA","media_type":"image/jpeg"}}]}]},"toolUseResult":{"file":{"base64":"ZZZZ","type":"image/jpeg"}}}"#,
        ]
        .join("\n");
        assert_eq!(
            from_transcript(transcript.as_bytes(), "toolu_A"),
            Some(("image/jpeg".into(), "AAAA".into()))
        );
        assert_eq!(
            from_transcript(transcript.as_bytes(), "toolu_B"),
            Some(("image/png".into(), "BBBB".into()))
        );
        assert_eq!(from_transcript(transcript.as_bytes(), "toolu_C"), None);
    }

    #[test]
    fn falls_back_to_the_tools_own_file() {
        let line = r#"{"type":"user","message":{"content":[{"tool_use_id":"toolu_A","type":"tool_result","content":"[image]"}]},"toolUseResult":{"type":"image","file":{"base64":"ZZZZ","type":"image/jpeg"}}}"#;
        assert_eq!(
            from_transcript(line.as_bytes(), "toolu_A"),
            Some(("image/jpeg".into(), "ZZZZ".into()))
        );
        let failed = r#"{"type":"user","message":{"content":[{"tool_use_id":"toolu_A","type":"tool_result","is_error":true,"content":"File does not exist."}]}}"#;
        assert_eq!(from_transcript(failed.as_bytes(), "toolu_A"), None);
    }

    #[test]
    fn serves_only_images_from_disk() {
        assert_eq!(sniff(b"\x89PNG\r\n\x1a\n...."), Some("image/png"));
        assert_eq!(sniff(&[0xFF, 0xD8, 0xFF, 0xE0]), Some("image/jpeg"));
        assert_eq!(sniff(b"-----BEGIN OPENSSH PRIVATE KEY-----"), None);
        assert_eq!(sniff(b""), None);
    }
}
