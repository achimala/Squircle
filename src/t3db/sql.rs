//! T3's state schema (0.1.0, `statev2.sqlite`): static reads only. Values
//! are always bound. Current data is in the `orchestration_v2_*` projection
//! tables (a thread's runs, messages and turn items, rows keeping their
//! whole value in `payload_json`). The same file keeps the 0.0.45
//! projection tables (`projection_threads`, `projection_thread_messages`,
//! `projection_thread_activities`) as they stood when T3 migrated, which no
//! longer change: history reads them for what is not in the V2 tables
//! (tool calls, and messages T3 did not import). Projects are still in
//! `projection_projects`, which T3 keeps current.

/// A V2 tool call's turn item as 0.0.45's tool activities read: Claude's
/// tool name and input. T3 records shell commands, file edits and searches
/// as their own item types and every other tool as `dynamic_tool`.
macro_rules! tool_columns {
    () => {
        "case i.type when 'command_execution' then 'Bash' when 'file_change' then 'Edit'
              when 'file_search' then 'Grep' when 'web_search' then 'WebSearch'
              else json_extract(i.payload_json,'$.toolName') end as tool,
         case i.type when 'command_execution' then json_object('command', json_extract(i.payload_json,'$.input'))
              when 'file_change' then json_object('file_path', json_extract(i.payload_json,'$.fileName'),
                   'old_string', json_extract(i.payload_json,'$.oldStr'), 'new_string', json_extract(i.payload_json,'$.newStr'))
              when 'file_search' then json_object('pattern', json_extract(i.payload_json,'$.pattern'))
              when 'web_search' then json_object('query', json_extract(i.payload_json,'$.patterns[0]'))
              when 'dynamic_tool' then case when json_type(i.payload_json,'$.input')='object' then json_extract(i.payload_json,'$.input') end
         end as input"
    };
}

/// The image blocks of a V2 tool item's output: a list of blocks or an MCP
/// result's `content` list. T3 keeps the bytes of the first eight images,
/// as `{data, mimeType}` or Claude's `{source: {media_type, data}}`.
macro_rules! output_blocks {
    () => {
        "json_each(i.payload_json, case json_type(i.payload_json,'$.output') when 'array' then '$.output'
              when 'object' then case when json_type(i.payload_json,'$.output.content')='array' then '$.output.content' end end) b"
    };
}

/// An image a Claude agent looked at with Read: T3 keeps its path and size
/// but not its bytes. `session` is the Claude session whose transcript has
/// them.
macro_rules! viewed_columns {
    () => {
        "case when json_extract(i.payload_json,'$.toolName')='Read' and json_extract(i.payload_json,'$.output.type')='image'
              then json_extract(i.payload_json,'$.viewedImagePath') end as viewed,
         case when json_extract(i.payload_json,'$.viewedImagePath') is not null
              then (select json_extract(p.payload_json,'$.nativeThreadRef.nativeId') from orchestration_v2_projection_provider_threads p
                    where p.provider_thread_id=i.provider_thread_id and p.driver='claudeAgent') end as session"
    };
}

pub(crate) const CURRENT_STEP: &str = concat!(
    "select ",
    tool_columns!(),
    ", json_extract(i.payload_json,'$.title') as title
     from orchestration_v2_projection_turn_items i
     where i.thread_id=?1 and i.type in ('dynamic_tool','command_execution','file_change','file_search','web_search')
     order by i.ordinal desc limit 12"
);

pub(crate) const SIMULATOR_COMMANDS: &str = "select i.thread_id as thread,
    coalesce(json_extract(i.payload_json,'$.startedAt'), i.updated_at) as created_at,
    coalesce(json_extract(i.payload_json,'$.input'), '') as command,
    coalesce(json_extract(i.payload_json,'$.output'), '') as output
from orchestration_v2_projection_turn_items i
where i.type='command_execution' and i.updated_at > ?1
  and (instr(i.payload_json,'simctl ')>0 or instr(i.payload_json,'xcodebuild')>0 or instr(i.payload_json,'agent-device')>0)
order by created_at limit 5000";

/// A thread's tool calls, keyed by the provider's own call ID where it has
/// one (Claude's `toolu_…`, as 0.0.45 keyed them), else the turn item's ID.
pub(crate) const STEPS: &str = concat!(
    "select coalesce(json_extract(i.payload_json,'$.nativeItemRef.nativeId'), i.turn_item_id) as id, ",
    tool_columns!(),
    ", (select count(*) from ",
    output_blocks!(),
    " where (case when b.type='object' then json_extract(b.value,'$.type') end)='image'
           and coalesce(json_extract(b.value,'$.source.data'), json_extract(b.value,'$.data')) is not null) as images,
       coalesce(json_extract(i.payload_json,'$.startedAt'), i.updated_at) as created_at, i.run_id as turn_id, ",
    viewed_columns!(),
    ", case when i.status in ('completed','failed') then 'tool.completed' else 'tool.updated' end as kind,
       case when i.status='failed' then 'error' end as tone, i.status as status,
       case when i.type='command_execution' and instr(json_extract(i.payload_json,'$.input'),'squircle') > 0
            then substr(json_extract(i.payload_json,'$.output'),1,4000) end as result
     from orchestration_v2_projection_turn_items i
     where i.thread_id=?1 and i.type in ('dynamic_tool','command_execution','file_change','file_search','web_search')
       and (?2 is null or i.updated_at > ?2)
     order by i.ordinal"
);

/// The images a tool call returned: a V2 item's, by call or item ID, else a
/// 0.0.45 activity's.
pub(crate) const IMAGES: &str = concat!(
    "select * from (select coalesce(json_extract(b.value,'$.source.media_type'), json_extract(b.value,'$.mimeType')) as media_type,
            coalesce(json_extract(b.value,'$.source.data'), json_extract(b.value,'$.data')) as data
     from orchestration_v2_projection_turn_items i, ",
    output_blocks!(),
    " where i.thread_id=?1 and (i.turn_item_id=?2 or json_extract(i.payload_json,'$.nativeItemRef.nativeId')=?2)
       and (case when b.type='object' then json_extract(b.value,'$.type') end)='image'
     order by b.key)
     union all
     select * from (select json_extract(value,'$.source.media_type') as media_type,
            json_extract(value,'$.source.data') as data
     from projection_thread_activities, json_each(case when json_type(payload_json,'$.data.result.content')='array' then json_extract(payload_json,'$.data.result.content') else '[]' end)
     where thread_id=?1 and json_extract(payload_json,'$.toolCallId')=?2
       and (case when type='object' then json_extract(value,'$.type') end)='image'
     order by created_at desc, activity_id, json_each.key)"
);

/// The image a Read call looked at, by call or item ID.
pub(crate) const VIEWED: &str = concat!(
    "select ",
    viewed_columns!(),
    ", json_extract(i.payload_json,'$.nativeItemRef.nativeId') as call
     from orchestration_v2_projection_turn_items i
     where i.thread_id=?1 and (i.turn_item_id=?2 or json_extract(i.payload_json,'$.nativeItemRef.nativeId')=?2)
       and i.type='dynamic_tool' limit 1"
);

/// T3's simulator screenshots in a project's threads, newest first: `src`
/// says which table `item` is in, and `path` is the image block's JSON path
/// in its `payload_json`.
pub(crate) const PROJECT_SCREENSHOTS: &str = concat!(
    "select * from (select 'v2' as src, i.turn_item_id as item, b.fullkey as path,
            coalesce(json_extract(i.payload_json,'$.completedAt'), i.updated_at) as created_at,
            json_extract(i.payload_json,'$.toolName') as tool,
            coalesce(json_extract(b.value,'$.source.media_type'), json_extract(b.value,'$.mimeType')) as media_type,
            substr(coalesce(json_extract(b.value,'$.source.data'), json_extract(b.value,'$.data')),1,87380) as head
     from orchestration_v2_projection_threads t
     join orchestration_v2_projection_turn_items i on i.thread_id=t.thread_id, ",
    output_blocks!(),
    " where t.project_id=?1 and t.deleted_at is null and i.type='dynamic_tool' and i.status='completed'
       and json_extract(i.payload_json,'$.toolName')='mcp__t3-code__device_screenshot'
       and (case when b.type='object' then json_extract(b.value,'$.type') end)='image'
     order by created_at desc limit 40)
     union all
     select * from (select 'v1' as src, a.activity_id as item, j.fullkey as path, a.created_at as created_at,
            json_extract(a.payload_json,'$.data.toolName') as tool,
            json_extract(j.value,'$.source.media_type') as media_type,
            substr(json_extract(j.value,'$.source.data'),1,87380) as head
     from projection_threads t
     join projection_thread_activities a on a.thread_id=t.thread_id,
          json_each(a.payload_json, case when json_type(a.payload_json,'$.data.result.content')='array' then '$.data.result.content' end) j
     where t.project_id=?1 and t.deleted_at is null and a.kind='tool.completed'
       and json_extract(a.payload_json,'$.data.toolName')='mcp__t3-code__device_screenshot'
       and (case when j.type='object' then json_extract(j.value,'$.type') end)='image'
     order by a.created_at desc limit 40)"
);

/// One screenshot's whole image, by `PROJECT_SCREENSHOTS`' item and path.
pub(crate) const SCREENSHOT_DATA_V2: &str = "select coalesce(json_extract(payload_json, ?2 || '.source.data'), json_extract(payload_json, ?2 || '.data')) as data
             from orchestration_v2_projection_turn_items where turn_item_id=?1";

pub(crate) const SCREENSHOT_DATA: &str =
    "select json_extract(payload_json, ?2 || '.source.data') as data
             from projection_thread_activities where activity_id=?1";

/// Tool calls and errors: 0.0.45's activities and V2's turn items, with a
/// one-line `summary`, its `detail` and its input, and `text` to search.
macro_rules! activities {
    () => {
        "(select activity_id as id, thread_id, kind, created_at as at, summary,
                 coalesce(json_extract(payload_json,'$.detail'), json_extract(payload_json,'$.message'), '') as detail,
                 coalesce(json_extract(payload_json,'$.data.input'),'') as input,
                 summary || ': ' || coalesce(json_extract(payload_json,'$.detail'), json_extract(payload_json,'$.message'), '') as text
          from projection_thread_activities where kind in ('tool.completed','tool.denied','runtime.error')
          union all
          select turn_item_id as id, thread_id,
                 case when type='error' then 'runtime.error' when status='failed' then 'tool.failed' else 'tool.completed' end as kind,
                 updated_at as at,
                 coalesce(json_extract(payload_json,'$.title'), json_extract(payload_json,'$.toolName'),
                          json_extract(payload_json,'$.fileName'), json_extract(payload_json,'$.failure.message'), type) as summary,
                 coalesce(case when json_type(payload_json,'$.output')='text' then json_extract(payload_json,'$.output') end,
                          json_extract(payload_json,'$.failure.message'), json_extract(payload_json,'$.diffStr'), '') as detail,
                 coalesce(json_extract(payload_json,'$.input'),'') as input,
                 coalesce(json_extract(payload_json,'$.title'), json_extract(payload_json,'$.toolName'), json_extract(payload_json,'$.fileName'), '')
                   || ' ' || coalesce(case when json_type(payload_json,'$.input')='text' then json_extract(payload_json,'$.input') end, '')
                   || ': ' || coalesce(case when json_type(payload_json,'$.output')='text' then substr(json_extract(payload_json,'$.output'),1,2000) end,
                                       json_extract(payload_json,'$.failure.message'), '') as text
          from orchestration_v2_projection_turn_items
          where type in ('dynamic_tool','command_execution','file_change','error') and status in ('completed','failed'))"
    };
}

/// Every thread, V2 first: a 0.0.45 thread T3 did not import (one deleted
/// before the migration) only from the old table.
macro_rules! threads {
    () => {
        "(select thread_id, project_id, title, json_extract(payload_json,'$.branch') as branch,
                 json_extract(payload_json,'$.worktreePath') as worktree_path,
                 created_at, updated_at, archived_at, deleted_at
          from orchestration_v2_projection_threads
          union all
          select thread_id, project_id, title, branch, worktree_path, created_at, updated_at, archived_at, deleted_at
          from projection_threads o
          where not exists (select 1 from orchestration_v2_projection_threads v where v.thread_id=o.thread_id))"
    };
}

/// Every message, V2 first (T3 imported 0.0.45 messages under their IDs),
/// with `marked` set for one Squircle's notes mark.
macro_rules! messages {
    () => {
        "(select message_id, thread_id, role, created_at, json_extract(payload_json,'$.text') as text,
                 instr(coalesce(json_extract(payload_json,'$.context'),''),'\"squircle-')>0 as marked
          from orchestration_v2_projection_messages
          union all
          select message_id, thread_id, role, created_at, text,
                 instr(coalesce(context_json,''),'\"squircle-')>0 as marked
          from projection_thread_messages o
          where not exists (select 1 from orchestration_v2_projection_messages v where v.message_id=o.message_id))"
    };
}

/// A thread's messages, V2 first: as `messages!` for one thread (`?1`).
macro_rules! thread_messages {
    () => {
        "(select message_id, thread_id, role, created_at, json_extract(payload_json,'$.text') as text
          from orchestration_v2_projection_messages where thread_id=?1
          union all
          select message_id, thread_id, role, created_at, text from projection_thread_messages o
          where thread_id=?1 and not exists (select 1 from orchestration_v2_projection_messages v where v.message_id=o.message_id))"
    };
}

/// Whether an assistant message of thread `?1` names a path, as `?2` or `?3`.
pub(crate) const THREAD_LINKS: &str = concat!(
    "select 1 linked from ",
    thread_messages!(),
    " where role='assistant' and (instr(text,?2)>0 or instr(text,?3)>0) limit 1"
);

pub(crate) const THREAD_PROJECT: &str = concat!(
    "select p.project_id, p.title, p.workspace_root from ",
    threads!(),
    " t join projection_projects p using(project_id) where t.thread_id=?1 limit 1"
);

pub(crate) const PROJECT: &str = "select project_id, title, workspace_root from projection_projects where deleted_at is null and project_id=?1";

pub(crate) const PROJECT_PLACES: &str = concat!(
    "select project_id, title, workspace_root, workspace_root place from (select project_id, title, workspace_root from projection_projects where deleted_at is null) union all
     select t.project_id, p.title, p.workspace_root, t.worktree_path from ",
    threads!(),
    " t join projection_projects p using(project_id)
     where t.worktree_path is not null and t.deleted_at is null and p.deleted_at is null"
);

/// Messages, threads and tool calls or errors of a project matching every
/// term. Tool calls are 0.0.45 activities and V2 turn items.
pub(crate) const SEARCH: &str = concat!(
    "select * from (select 'msg' src, m.message_id id, m.thread_id thread, t.title title, m.role role, m.created_at at,
    substr(m.text,1,8000) text, m.marked marked
    from ",
    messages!(),
    " m join ",
    threads!(),
    " t using(thread_id)
    where ?4 and t.project_id=?1 and t.deleted_at is null and m.role in ('user','assistant')
      and (?2 is null or m.created_at >= ?2)
      and exists(select 1 from json_each(?3) terms where instr(lower(m.text), terms.value)>0)
    order by m.created_at desc limit 1500)
union all
select * from (select 'thread' src, thread_id id, thread_id thread, title, coalesce(branch,'') role, created_at at,
    title || ' ' || coalesce(branch,'') text, 0 marked from ",
    threads!(),
    " where ?5 and project_id=?1 and deleted_at is null and (?2 is null or updated_at >= ?2)
      and exists(select 1 from json_each(?3) terms where instr(lower(title || ' ' || coalesce(branch,'')), terms.value)>0)
    order by created_at desc limit 300)
union all
select * from (select 'act' src, a.id id, a.thread_id thread, t.title title, a.kind role, a.at at,
    substr(a.text,1,2000) text, 0 marked
    from ",
    activities!(),
    " a join ",
    threads!(),
    " t using(thread_id)
    where ?6 and t.project_id=?1 and t.deleted_at is null
      and (?2 is null or a.at >= ?2)
      and exists(select 1 from json_each(?3) terms where instr(lower(a.text), terms.value)>0)
    order by a.at desc limit 500)"
);

pub(crate) const MESSAGE: &str = concat!(
    "with m as (select * from ",
    messages!(),
    " where message_id=?1 limit 1),
     around as (select p.* from ",
    messages!(),
    " p, m where p.thread_id=m.thread_id and p.role!=m.role and p.role in ('user','assistant'))
     select m.message_id, m.thread_id, t.title, m.role, m.created_at, m.text,
        (select text from around where created_at<m.created_at order by created_at desc limit 1) before_text,
        (select message_id from around where created_at<m.created_at order by created_at desc limit 1) before_id,
        (select text from around where created_at>m.created_at order by created_at limit 1) after_text,
        (select message_id from around where created_at>m.created_at order by created_at limit 1) after_id
     from m join ",
    threads!(),
    " t using(thread_id)"
);

pub(crate) const THREAD: &str = concat!(
    "select title, branch, created_at, updated_at, archived_at,
        (select count(*) from ",
    thread_messages!(),
    " where role in ('user','assistant')) total
     from ",
    threads!(),
    " t where thread_id=?1 limit 1"
);

pub(crate) const ACTIVITY: &str = concat!(
    "select a.thread_id, t.title, a.kind, a.summary, a.at as created_at, a.detail, substr(a.input,1,?2) input
     from (select * from ",
    activities!(),
    " where id=?1) a join ",
    threads!(),
    " t using(thread_id) limit 1"
);

pub(crate) const MESSAGES: &str = concat!(
    "select * from (select message_id, role, created_at, substr(text,1,2000) text from ",
    thread_messages!(),
    " where role in ('user','assistant') order by created_at desc limit ?2) order by created_at"
);

/// The agent's context use as its provider last reported it (V2 records it
/// on each provider turn) and when the thread last changed.
pub(crate) const CONTEXT_READING: &str = "select
    (select json_extract(payload_json,'$.tokenUsage.updatedAt') from orchestration_v2_projection_provider_turns
       where thread_id=?1 and json_extract(payload_json,'$.tokenUsage') is not null
       order by coalesce(completed_at, started_at) desc limit 1) reading_at,
    (select json_extract(payload_json,'$.tokenUsage.usedTokens') from orchestration_v2_projection_provider_turns
       where thread_id=?1 and json_extract(payload_json,'$.tokenUsage') is not null
       order by coalesce(completed_at, started_at) desc limit 1) used,
    (select message_id from orchestration_v2_projection_messages where thread_id=?1 and role='user'
       order by created_at desc, rowid desc limit 1) latest,
    max(coalesce((select max(created_at) from orchestration_v2_projection_messages where thread_id=?1),''),
        coalesce((select max(updated_at) from orchestration_v2_projection_turn_items where thread_id=?1),'')) last_at";
