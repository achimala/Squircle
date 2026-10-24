//! T3 owns this database. Each read gets its own read-only connection on the
//! blocking pool; no shared connection, lock, writable handle or copied store.
//! See `sql` for the T3 0.1.0 schema used by the consumers.

pub(crate) mod sql;
use anyhow::{Context, Result, bail, ensure};
macro_rules! params {
    ($($value:expr),* $(,)?) => {{
        let borrowed = rusqlite::params![$($value),*];
        $crate::t3db::bindings(borrowed)
    }};
}
pub(crate) use params;
use rusqlite::types::{ToSqlOutput, Value as SqlValue, ValueRef};
use rusqlite::{Connection, InterruptHandle, OpenFlags, ToSql, params_from_iter};
use serde_json::{Map, Value};
use std::{
    io::Write,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

const MAX_OUTPUT: usize = 64 * 1024 * 1024;

/// `SQUIRCLE_T3_STATE`, else T3's default `~/.t3/userdata/statev2.sqlite`
/// (T3 0.1.0 moved to it; the old `state.sqlite` no longer changes).
pub fn state_path() -> PathBuf {
    std::env::var_os("SQUIRCLE_T3_STATE")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            dirs::home_dir()
                .unwrap_or_default()
                .join(".t3/userdata/statev2.sqlite")
        })
}

/// One item each time T3 writes its database, as the kernel reports writes
/// to the file or its write-ahead log; a log that is removed or replaced is
/// watched again once it appears. Ends if T3's folder can't be watched.
pub fn changes() -> futures_util::stream::BoxStream<'static, ()> {
    use futures_util::StreamExt;
    let path = state_path();
    let (told, heard) = tokio::sync::mpsc::channel(1);
    tokio::spawn(async move {
        let Some(folder) = path.parent().map(PathBuf::from) else {
            return;
        };
        let mut log = path.clone().into_os_string();
        log.push("-wal");
        let files = [path, PathBuf::from(log)];
        loop {
            let Ok(entries) = crate::kq::Changes::watch(&folder) else {
                return;
            };
            let watched: Vec<_> = files
                .iter()
                .filter_map(|file| crate::kq::Changes::watch(file).ok())
                .collect();
            loop {
                let written = async {
                    if watched.is_empty() {
                        return std::future::pending().await;
                    }
                    let writes = watched.iter().map(|file| Box::pin(file.next()));
                    futures_util::future::select_all(writes).await.0
                };
                let replaced = tokio::select! {
                    _ = entries.next() => true,
                    _ = written => false,
                };
                // Full: a change is already waiting to be read, which covers this one.
                if let Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) = told.try_send(()) {
                    return;
                }
                if replaced {
                    break;
                }
            }
        }
    });
    futures_util::stream::unfold(heard, |mut heard| async move {
        heard.recv().await.map(|()| ((), heard))
    })
    .boxed()
}

/// Convert within the params! block, so non-Send ToSql references never
/// remain alive across a consumer's await.
pub(crate) fn bindings(params: &[&dyn ToSql]) -> Result<Vec<SqlValue>> {
    params
        .iter()
        .map(|p| match p.to_sql()? {
            ToSqlOutput::Borrowed(v) => Ok(SqlValue::try_from(v)?),
            ToSqlOutput::Owned(v) => Ok(v),
            _ => bail!("Unsupported T3 query parameter"),
        })
        .collect()
}

/// Static SQL cannot contain caller values; all bindings are already owned.
/// The read runs until it finishes or this future is dropped (the request
/// or loop that wanted it is gone), which interrupts SQLite at once.
pub(crate) async fn query(sql: &'static str, params: Result<Vec<SqlValue>>) -> Result<Vec<Value>> {
    query_at(state_path(), sql, params?, MAX_OUTPUT).await
}

/// Covers cancellation both before the blocking job starts and while SQLite
/// runs. Drop never waits; the progress handler also closes the small gap
/// between an interrupt arriving and the first sqlite3_step.
struct CancelRead {
    cancelled: Arc<AtomicBool>,
    interrupt: Option<InterruptHandle>,
}
impl Drop for CancelRead {
    fn drop(&mut self) {
        self.cancelled.store(true, Ordering::Release);
        if let Some(handle) = &self.interrupt {
            handle.interrupt();
        }
    }
}

async fn query_at(
    path: PathBuf,
    sql: &'static str,
    params: Vec<SqlValue>,
    max_output: usize,
) -> Result<Vec<Value>> {
    let cancelled = Arc::new(AtomicBool::new(false));
    let mut guard = CancelRead {
        cancelled: cancelled.clone(),
        interrupt: None,
    };
    let (ready, receive) = tokio::sync::oneshot::channel();
    let work = tokio::task::spawn_blocking(move || {
        ensure!(
            !cancelled.load(Ordering::Acquire),
            "T3 database read cancelled"
        );
        let connection = Connection::open_with_flags(
            &path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .with_context(|| format!("Opening T3 state database read-only at {}", path.display()))?;
        // Like the former CLI, refuse a busy DB rather than sleeping in its
        // busy handler.
        connection.busy_timeout(Duration::ZERO)?;
        connection.set_limit(
            rusqlite::limits::Limit::SQLITE_LIMIT_LENGTH,
            max_output.min(i32::MAX as usize) as i32,
        )?;
        let stopped = cancelled.clone();
        connection.progress_handler(1000, Some(move || stopped.load(Ordering::Acquire)))?;
        ready
            .send(connection.get_interrupt_handle())
            .map_err(|_| anyhow::anyhow!("T3 database read cancelled"))?;
        read_rows(&connection, sql, params, max_output, || {
            cancelled.load(Ordering::Acquire)
        })
    });
    // If opening failed, await the job to preserve its useful path/error.
    guard.interrupt = receive.await.ok();
    work.await.context("T3 database reader stopped")?
}

fn read_rows(
    connection: &Connection,
    sql: &str,
    params: Vec<SqlValue>,
    max_output: usize,
    stopped: impl Fn() -> bool,
) -> Result<Vec<Value>> {
    let mut statement = connection.prepare(sql).context(
        "T3 database schema/query is incompatible with the supported schema (T3 0.1.0, statev2.sqlite)",
    )?;
    ensure!(
        statement.readonly(),
        "T3 database queries must be read-only"
    );
    let names: Vec<String> = statement
        .column_names()
        .into_iter()
        .map(str::to_owned)
        .collect();
    let mut rows = statement.query(params_from_iter(params))?;
    let mut result = Vec::new();
    let mut budget = Budget(max_output.saturating_sub(2)); // JSON array brackets
    loop {
        ensure!(!stopped(), "T3 database read cancelled or timed out");
        let Some(row) = rows.next()? else { break };
        let mut object = Map::new();
        for (i, name) in names.iter().enumerate() {
            let value = match row.get_ref(i)? {
                ValueRef::Null => Value::Null,
                ValueRef::Integer(v) => Value::from(v),
                ValueRef::Real(v) => Value::from(v),
                ValueRef::Text(v) => Value::String(
                    std::str::from_utf8(v)
                        .context("T3 database contains non-UTF-8 text")?
                        .to_owned(),
                ),
                ValueRef::Blob(_) => bail!("Unexpected binary value in T3 projection"),
            };
            object.insert(name.clone(), value);
        }
        let value = Value::Object(object);
        if !result.is_empty() {
            budget.write_all(b",")?;
        }
        serde_json::to_writer(&mut budget, &value)
            .context("T3 database output exceeds its limit")?;
        result.push(value);
    }
    Ok(result)
}

/// Count encoded bytes without building a second copy of a screenshot's JSON.
struct Budget(usize);
impl Write for Budget {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if bytes.len() > self.0 {
            return Err(std::io::Error::other(
                "T3 database output exceeds its limit",
            ));
        }
        self.0 -= bytes.len();
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fixture() -> (tempfile::TempDir, PathBuf) {
        let directory = tempfile::tempdir().unwrap();
        // A literal filename, not a SQLite URI. Quotes and ? must stay literal.
        let path = directory.path().join("state ' ? #.sqlite");
        let db = Connection::open(&path).unwrap();
        db.execute_batch(
            "create table data (id text, value text); insert into data values ('one', 'hello');",
        )
        .unwrap();
        (directory, path)
    }

    #[tokio::test]
    async fn nulls_numbers_empty_results_and_output_budget_are_preserved() {
        let (_directory, path) = fixture();
        let rows = query_at(
            path.clone(),
            "select null n, 123 i, 1.5 r, 'hello' t",
            vec![],
            MAX_OUTPUT,
        )
        .await
        .unwrap();
        assert_eq!(
            rows,
            vec![serde_json::json!({"n":null,"i":123,"r":1.5,"t":"hello"})]
        );
        assert!(
            query_at(
                path.clone(),
                "select value from data where 0",
                vec![],
                MAX_OUTPUT
            )
            .await
            .unwrap()
            .is_empty()
        );
        let error = query_at(path, "with recursive n(x) as (values(1) union all select x+1 from n where x<1000) select value from data, n", vec![], 1024)
            .await
            .unwrap_err();
        assert!(format!("{error:#}").contains("limit"), "{error:#}");
    }
    /// Sanitized projection fixture: V2 tables beside the 0.0.45 ones T3
    /// leaves in the same file. Checks SQLite JSON typing, IDs, limits,
    /// literal search terms, the V2 / 0.0.45 merge and every query against
    /// the same schema.
    #[test]
    fn projection_queries_preserve_json_and_scope() {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch(r#"
            create table projection_projects (project_id text, title text, workspace_root text, deleted_at text);
            create table projection_threads (thread_id text, project_id text, title text, branch text, worktree_path text, created_at text, updated_at text, archived_at text, deleted_at text);
            create table projection_thread_messages (message_id text, thread_id text, role text, created_at text, text text, context_json text);
            create table projection_thread_activities (activity_id text, thread_id text, sequence integer, created_at text, turn_id text, kind text, tone text, summary text, payload_json text);
            create table orchestration_v2_projection_threads (thread_id text primary key, project_id text, title text, default_provider text, runtime_mode text, interaction_mode text, active_provider_thread_id text, created_at text, updated_at text, archived_at text, deleted_at text, payload_json text, provider_instance_id text);
            create table orchestration_v2_projection_messages (message_id text primary key, thread_id text, run_id text, node_id text, role text, streaming integer, created_at text, updated_at text, payload_json text);
            create table orchestration_v2_projection_turn_items (turn_item_id text primary key, thread_id text, run_id text, node_id text, provider_thread_id text, provider_turn_id text, parent_item_id text, ordinal integer, type text, status text, updated_at text, payload_json text);
            create table orchestration_v2_projection_provider_threads (provider_thread_id text primary key, thread_id text, owner_node_id text, provider text, provider_session_id text, status text, first_run_ordinal integer, last_run_ordinal integer, updated_at text, payload_json text, driver text, provider_instance_id text);
            create table orchestration_v2_projection_provider_turns (provider_turn_id text primary key, thread_id text, provider_thread_id text, node_id text, run_attempt_id text, ordinal integer, status text, started_at text, completed_at text, payload_json text);
            insert into projection_projects values ('p','App','/app',null);
            insert into projection_threads values ('t','p','old title',null,null,'2026-10-18','2026-10-18',null,null);
            insert into orchestration_v2_projection_threads values ('t','p','test_name','claudeAgent','auto','default',null,'2026-10-18','2026-10-19',null,null,
                '{"branch":"work","worktreePath":"/app/work"}','claudeAgent');
            insert into projection_thread_messages values ('m','t','user','2026-10-18','test_name imported',null);
            insert into projection_thread_messages values ('m0','t','assistant','2026-10-18T01','test_name not imported','{"records":[{"kind":"squircle-task"}]}');
            insert into orchestration_v2_projection_messages values ('m','t',null,null,'user',0,'2026-10-18','2026-10-18','{"text":"test_name"}');
            insert into projection_thread_activities values ('a','t',1,'2026-10-18','turn','tool.completed',null,'test_name',
                '{"toolCallId":"call","data":{"toolName":"mcp__t3-code__device_screenshot","input":{"command":"simctl list"},"result":{"content":[{"type":"image","source":{"media_type":"image/png","data":"AAAA"}}]}}}');
            insert into orchestration_v2_projection_turn_items values ('i1','t','r',null,null,null,null,1,'command_execution','completed','2026-10-19',
                '{"title":"test_name","startedAt":"2026-10-19","input":"xcrun simctl list","output":"done","nativeItemRef":{"nativeId":"toolu_1"}}');
            insert into orchestration_v2_projection_turn_items values ('i2','t','r',null,null,null,null,2,'dynamic_tool','completed','2026-10-19',
                '{"toolName":"mcp__t3-code__device_screenshot","input":{"deviceId":"D"},"output":{"content":[{"type":"text","text":"x"},{"type":"image","data":"BBBB","mimeType":"image/png"}]},"nativeItemRef":{"nativeId":"toolu_2"}}');
            insert into orchestration_v2_projection_turn_items values ('i3','t','r',null,'pth',null,null,3,'dynamic_tool','completed','2026-10-19',
                '{"toolName":"Read","input":{"file_path":"/tmp/five.png"},"viewedImagePath":"/tmp/five.png","output":{"type":"image","file":{"type":"image/jpeg"}},"nativeItemRef":{"nativeId":"toolu_3"}}');
            insert into orchestration_v2_projection_provider_threads values ('pth','t',null,'claudeAgent','s','active',1,1,'2026-10-19',
                '{"nativeThreadRef":{"driver":"claudeAgent","nativeId":"session-1"}}','claudeAgent','squircle');
            insert into orchestration_v2_projection_provider_turns values ('pt','t','pth','n',null,1,'completed','2026-10-19','2026-10-19',
                '{"tokenUsage":{"usedTokens":1200,"updatedAt":"2026-10-19T00:00:01Z"}}');
        "#).unwrap();
        let text = |s: &str| SqlValue::Text(s.into());
        let read = |sql: &str, params: Vec<SqlValue>| {
            read_rows(&db, sql, params, MAX_OUTPUT, || false).unwrap()
        };
        for (sql, params) in [
            (sql::CURRENT_STEP, vec![text("t")]),
            (sql::SIMULATOR_COMMANDS, vec![text("")]),
            (sql::STEPS, vec![text("t"), SqlValue::Null]),
            (sql::IMAGES, vec![text("t"), text("call")]),
            (sql::IMAGES, vec![text("t"), text("toolu_2")]),
            (sql::VIEWED, vec![text("t"), text("toolu_3")]),
            (sql::PROJECT_SCREENSHOTS, vec![text("p")]),
            (
                sql::SCREENSHOT_DATA,
                vec![text("a"), text("$.data.result.content[0]")],
            ),
            (
                sql::SCREENSHOT_DATA_V2,
                vec![text("i2"), text("$.output.content[1]")],
            ),
            (sql::THREAD_PROJECT, vec![text("t")]),
            (sql::PROJECT, vec![text("p")]),
            (sql::PROJECT_PLACES, vec![]),
            (sql::MESSAGE, vec![text("m")]),
            (sql::THREAD, vec![text("t")]),
            (sql::MESSAGES, vec![text("t"), 1.into()]),
            (sql::ACTIVITY, vec![text("a"), 100.into()]),
            (sql::ACTIVITY, vec![text("i1"), 100.into()]),
            (sql::CONTEXT_READING, vec![text("t")]),
        ] {
            let rows = read(sql, params);
            assert!(
                !rows.is_empty()
                    && rows
                        .iter()
                        .all(|r| r.as_object().unwrap().values().any(|v| !v.is_null())),
                "{sql}"
            );
        }
        let steps = read(sql::STEPS, vec![text("t"), SqlValue::Null]);
        assert_eq!(steps[0]["id"], "toolu_1");
        assert_eq!(
            serde_json::from_str::<Value>(steps[0]["input"].as_str().unwrap()).unwrap()["command"],
            "xcrun simctl list"
        );
        assert_eq!(steps[1]["images"], 1);
        assert_eq!(
            (
                &steps[1]["viewed"],
                &steps[2]["viewed"],
                &steps[2]["session"]
            ),
            (&Value::Null, &json!("/tmp/five.png"), &json!("session-1"))
        );
        assert_eq!(
            read(sql::VIEWED, vec![text("t"), text("i3")])[0]["call"],
            "toolu_3"
        );
        assert_eq!(
            read(sql::IMAGES, vec![text("t"), text("toolu_2")])[0]["data"],
            "BBBB"
        );
        let shots = read(sql::PROJECT_SCREENSHOTS, vec![text("p")]);
        assert_eq!(
            (&shots[0]["src"], &shots[0]["path"], &shots[0]["head"]),
            (&json!("v2"), &json!("$.output.content[1]"), &json!("BBBB"))
        );
        assert_eq!(
            read(
                sql::SCREENSHOT_DATA_V2,
                vec![text("i2"), text("$.output.content[1]")]
            )[0]["data"],
            "BBBB"
        );
        // One thread, its V2 metadata; a message T3 imported once.
        let thread = read(sql::THREAD, vec![text("t")]);
        assert_eq!(
            (
                &thread[0]["title"],
                &thread[0]["branch"],
                &thread[0]["total"]
            ),
            (&json!("test_name"), &json!("work"), &json!(2))
        );
        assert_eq!(read(sql::MESSAGE, vec![text("m")])[0]["after_id"], "m0");
        assert_eq!(read(sql::CONTEXT_READING, vec![text("t")])[0]["used"], 1200);
        for (terms, expected) in [
            // V2 and 0.0.45 messages, the thread, an activity and a turn item.
            (r#"["test_name"]"#, 5),
            (r#"["test%name"]"#, 0),
            (r#"["' OR 1=1 --"]"#, 0),
        ] {
            let rows = read(
                sql::SEARCH,
                vec![
                    text("p"),
                    SqlValue::Null,
                    text(terms),
                    true.into(),
                    true.into(),
                    true.into(),
                ],
            );
            assert_eq!(rows.len(), expected, "{terms}: {rows:?}");
        }
    }
}
