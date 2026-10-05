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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trims_to_describing_fields() {
        let input = json!({"command":"ls","description":"List files","timeout":5,"content":"x".repeat(200_000)});
        let out = trim_input(&input);
        assert_eq!(out["description"], "List files");
        assert!(out.get("timeout").is_none());
        assert_eq!(out["content"].as_str().unwrap().len(), 100_000);
    }

    #[test]
    fn rejects_injection_in_identifiers() {
        assert!(valid("c3e60882-f28f-4656-879d-99b3e2dcddbb", &[]));
        assert!(!valid("x' or 1=1 --", &[]));
        assert!(valid("toolu_01H4gxVXp7szmDMV2t15BWjB", &['_']));
    }
}
