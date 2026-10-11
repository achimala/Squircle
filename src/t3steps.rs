//! Read-only details of a T3 thread's tool calls that T3 removes from what it
//! sends to clients: a command's own description, an edit's old and new text
//! and the screenshots a tool returned. T3 stays the owner of the thread; this
//! only reads its local state database, through the system `sqlite3` in
//! read-only mode, and never writes to it.

use anyhow::{Context, Result, bail};
use serde_json::{Map, Value, json};
use std::path::PathBuf;

/// `SQUIRCLE_T3_STATE`, else T3's default `~/.t3/userdata/state.sqlite`.
pub fn state_path() -> PathBuf {
    std::env::var_os("SQUIRCLE_T3_STATE")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            dirs::home_dir()
                .unwrap_or_default()
                .join(".t3/userdata/state.sqlite")
        })
}

fn valid(id: &str, extra: &[char]) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || extra.contains(&c))
}

/// A tool result's content blocks, or nothing when the result is plain text;
/// guarded so free text is never parsed as JSON.
const CONTENT: &str = "case when json_type(payload_json,'$.data.result.content')='array' \
    then json_extract(payload_json,'$.data.result.content') else '[]' end";
const IS_IMAGE: &str = "(case when type='object' then json_extract(value,'$.type') end)='image'";

async fn query(sql: &str) -> Result<Vec<Value>> {
    let path = state_path();
    if !path.exists() {
        bail!("T3 state database not found at {}", path.display());
    }
    let uri = format!("file:{}?mode=ro", path.display());
    let output = tokio::process::Command::new("/usr/bin/sqlite3")
        .args(["-readonly", "-json", &uri, sql])
        .output()
        .await
        .context("running sqlite3")?;
    if !output.status.success() {
        bail!(
            "sqlite3 failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    if output.stdout.iter().all(u8::is_ascii_whitespace) {
        return Ok(Vec::new());
    }
    Ok(serde_json::from_slice(&output.stdout).context("decoding sqlite3 output")?)
}

/// Keeps what describes a step; long text is capped so a large file write
/// cannot make the response unbounded.
fn trim_input(input: &Value) -> Value {
    const TEXT: &[&str] = &["old_string", "new_string", "content", "new_source"];
    const KEEP: &[&str] = &[
        "description", "command", "file_path", "notebook_path", "path", "pattern", "query", "url",
        "skill", "prompt", "deviceId", "replace_all", "glob",
    ];
    fn cap(text: &str, limit: usize) -> Value {
        Value::String(text.chars().take(limit).collect())
    }
    let mut out = Map::new();
    let Some(object) = input.as_object() else {
        return Value::Object(out);
    };
    for (key, value) in object {
        if TEXT.contains(&key.as_str()) {
            if let Some(text) = value.as_str() {
                out.insert(key.clone(), cap(text, 100_000));
            }
        } else if key == "edits" {
            let edits: Vec<Value> = value
                .as_array()
                .into_iter()
                .flatten()
                .take(50)
                .map(trim_input)
                .collect();
            out.insert(key.clone(), Value::Array(edits));
        } else if KEEP.contains(&key.as_str()) {
            out.insert(
                key.clone(),
                match value {
                    Value::String(text) => cap(text, 2_000),
                    other => other.clone(),
                },
            );
        }
    }
    Value::Object(out)
}

/// One entry per tool call that has an input or returned images, keyed by
/// T3's `toolCallId`. `since` (an ISO timestamp) limits to newer activity.
pub async fn steps(thread: &str, since: Option<&str>) -> Result<Value> {
    if !valid(thread, &[]) {
        bail!("invalid thread id");
    }
    let since = since.filter(|s| s.chars().all(|c| c.is_ascii_alphanumeric() || "-:.TZ+".contains(c)));
    let since = since.map(|s| format!("and created_at > '{s}'")).unwrap_or_default();
    let rows = query(&format!(
        "select json_extract(payload_json,'$.toolCallId') as id,
                json_extract(payload_json,'$.data.toolName') as tool,
                json_extract(payload_json,'$.data.input') as input,
                (select count(*) from json_each({CONTENT})
                   where {IS_IMAGE}) as images,
                created_at
         from projection_thread_activities
         where thread_id='{thread}' and kind in ('tool.started','tool.updated','tool.completed') {since}
           and (json_extract(payload_json,'$.data.input') is not null or images > 0)
         order by created_at"
    ))
    .await?;
    let mut order: Vec<String> = Vec::new();
    let mut steps: std::collections::HashMap<String, Map<String, Value>> = Default::default();
    for row in rows {
        let Some(id) = row["id"].as_str().map(str::to_owned) else { continue };
        let entry = steps.entry(id.clone()).or_insert_with(|| {
            order.push(id.clone());
            let mut m = Map::new();
            m.insert("id".into(), json!(id));
            m
        });
        if let Some(tool) = row["tool"].as_str() {
            entry.insert("tool".into(), json!(tool));
        }
        if let Some(input) = row["input"].as_str().and_then(|s| serde_json::from_str::<Value>(s).ok()) {
            let trimmed = trim_input(&input);
            if trimmed.as_object().is_some_and(|o| !o.is_empty()) {
                entry.insert("input".into(), trimmed);
            }
        }
        let images = row["images"].as_u64().unwrap_or(0);
        if images > entry.get("images").and_then(Value::as_u64).unwrap_or(0) {
            entry.insert("images".into(), json!(images));
        }
        if let Some(at) = row["created_at"].as_str() {
            entry.insert("updated_at".into(), json!(at));
        }
    }
    let list: Vec<Value> = order
        .into_iter()
        .filter_map(|id| steps.remove(&id).map(Value::Object))
        .collect();
    Ok(json!({ "thread_id": thread, "steps": list }))
}

/// The `index`th distinct image a tool call returned, as base64 with its type.
pub async fn image(thread: &str, call: &str, index: usize) -> Result<Option<Value>> {
    if !valid(thread, &[]) || !valid(call, &['_']) {
        bail!("invalid identifier");
    }
    let rows = query(&format!(
        "select json_extract(value,'$.source.media_type') as media_type,
                json_extract(value,'$.source.data') as data
         from projection_thread_activities, json_each({CONTENT})
         where thread_id='{thread}' and json_extract(payload_json,'$.toolCallId')='{call}'
           and {IS_IMAGE}
         order by created_at desc"
    ))
    .await?;
    let mut seen = std::collections::HashSet::new();
    let distinct: Vec<Value> = rows
        .into_iter()
        .filter(|row| row["data"].as_str().is_some_and(|d| seen.insert(d.len().to_string() + &d[..d.len().min(64)])))
        .collect();
    Ok(distinct.into_iter().nth(index).map(|row| {
        json!({
            "media_type": row["media_type"].as_str().unwrap_or("image/png"),
            "data": row["data"],
        })
    }))
}

/// Pixel size from an image's header: PNG's IHDR or a JPEG start-of-frame.
fn dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    if bytes.len() >= 24 && bytes.starts_with(b"\x89PNG") {
        let w = u32::from_be_bytes(bytes[16..20].try_into().ok()?);
        let h = u32::from_be_bytes(bytes[20..24].try_into().ok()?);
        return Some((w, h));
    }
    if !bytes.starts_with(&[0xFF, 0xD8]) {
        return None;
    }
    let mut i = 2;
    while i + 9 < bytes.len() {
        if bytes[i] != 0xFF {
            return None;
        }
        let marker = bytes[i + 1];
        let length = u16::from_be_bytes([bytes[i + 2], bytes[i + 3]]) as usize;
        if (0xC0..=0xCF).contains(&marker) && ![0xC4, 0xC8, 0xCC].contains(&marker) {
            let h = u16::from_be_bytes([bytes[i + 5], bytes[i + 6]]) as u32;
            let w = u16::from_be_bytes([bytes[i + 7], bytes[i + 8]]) as u32;
            return Some((w, h));
        }
        i += 2 + length;
    }
    None
}

/// A single portrait phone screen, not a contact sheet or a desktop window.
fn phone_shaped((w, h): (u32, u32)) -> bool {
    w > 0 && (1.8..=2.4).contains(&(h as f64 / w as f64))
}

/// The newest real screenshot an agent captured in any of a T3 project's
/// threads: a device or preview capture, or an image it read that has a
/// phone screen's shape. Stands in on Home for apps with no published preview.
pub async fn project_screenshot(project: &str) -> Result<Option<Value>> {
    use base64::Engine;
    if !valid(project, &[]) {
        bail!("invalid project id");
    }
    // Only a prefix of each image is read: enough for its header.
    let rows = query(&format!(
        "select a.activity_id as activity, j.key as idx, a.created_at as created_at,
                json_extract(a.payload_json,'$.data.toolName') as tool,
                json_extract(j.value,'$.source.media_type') as media_type,
                substr(json_extract(j.value,'$.source.data'),1,87380) as head
         from projection_threads t
         join projection_thread_activities a on a.thread_id=t.thread_id,
              json_each({CONTENT}) j
         where t.project_id='{project}' and t.deleted_at is null and a.kind='tool.completed'
           and (case when j.type='object' then json_extract(j.value,'$.type') end)='image'
         order by a.created_at desc limit 40"
    ))
    .await?;
    let engine = base64::engine::general_purpose::STANDARD;
    for row in rows {
        let tool = row["tool"].as_str().unwrap_or_default();
        let capture = tool.ends_with("device_screenshot") || tool.ends_with("preview_snapshot");
        let Some(head) = row["head"].as_str() else { continue };
        let head = &head[..head.len() / 4 * 4];
        let Some(size) = engine.decode(head).ok().as_deref().and_then(dimensions) else { continue };
        if !(capture && size.0 > 0 && size.1 > 0) && !phone_shaped(size) {
            continue;
        }
        let (Some(activity), Some(index)) = (row["activity"].as_str(), row["idx"].as_u64()) else { continue };
        if !valid(activity, &['_', ':']) {
            continue;
        }
        let full = query(&format!(
            "select json_extract(payload_json,'$.data.result.content[{index}].source.data') as data
             from projection_thread_activities where activity_id='{activity}'"
        ))
        .await?;
        let Some(data) = full.first().and_then(|r| r["data"].as_str()) else { continue };
        return Ok(Some(json!({
            "media_type": row["media_type"].as_str().unwrap_or("image/png"),
            "data": data,
            "captured_at": row["created_at"],
            "width": size.0,
            "height": size.1,
        })));
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;


    #[test]
    fn reads_image_dimensions() {
        let mut png = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
        png.extend_from_slice(&[0, 0, 1, 230, 0, 0, 4, 32]);
        assert_eq!(dimensions(&png), Some((486, 1056)));
        assert!(phone_shaped((486, 1056)));
        let jpeg = [0xFF, 0xD8, 0xFF, 0xE0, 0, 4, 0, 0, 0xFF, 0xC0, 0, 17, 8, 5, 0x70, 2, 0x80, 0, 0];
        assert_eq!(dimensions(&jpeg), Some((640, 1392)));
        assert!(!phone_shaped((1600, 1392)), "A contact sheet is not a screen.");
    }

    #[test]
    fn rejects_injection_in_identifiers() {
        assert!(valid("c3e60882-f28f-4656-879d-99b3e2dcddbb", &[]));
        assert!(!valid("x' or 1=1 --", &[]));
        assert!(valid("toolu_01H4gxVXp7szmDMV2t15BWjB", &['_']));
    }
}
