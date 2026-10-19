//! T3 0.0.45 projection schema: static reads only. Values are always bound.

pub(crate) const CURRENT_STEP: &str = "select json_extract(payload_json,'$.data.toolName') as tool,
                json_extract(payload_json,'$.data.input') as input,
                json_extract(payload_json,'$.title') as title
         from projection_thread_activities
         where thread_id=?1 and kind in ('tool.started','tool.updated','tool.completed','task.progress','task.started')
         order by sequence desc, created_at desc limit 12";

pub(crate) const SIMULATOR_COMMANDS: &str = "select thread_id as thread, created_at,
    coalesce(case when json_type(payload_json,'$.data.command')='text' then json_extract(payload_json,'$.data.command') end,
             case when json_type(payload_json,'$.data.input.command')='text' then json_extract(payload_json,'$.data.input.command') end, '') as command,
    coalesce(case when json_type(payload_json,'$.data.rawOutput.content')='text' then json_extract(payload_json,'$.data.rawOutput.content') end, '') as output
from projection_thread_activities
where created_at > ?1 and (payload_json like '%simctl %' or payload_json like '%xcodebuild%' or payload_json like '%agent-device%')
order by created_at limit 5000";

pub(crate) const STEPS: &str = "select json_extract(payload_json,'$.toolCallId') as id,
                json_extract(payload_json,'$.data.toolName') as tool,
                json_extract(payload_json,'$.data.input') as input,
                (select count(*) from json_each(case when json_type(payload_json,'$.data.result.content')='array' then json_extract(payload_json,'$.data.result.content') else '[]' end)
                   where (case when type='object' then json_extract(value,'$.type') end)='image') as images,
                created_at, turn_id, kind, tone,
                json_extract(payload_json,'$.status') as status,
                case when instr(json_extract(payload_json,'$.data.input.command'),'squircle') > 0
                     then substr(json_extract(payload_json,'$.data.result.content'),1,4000) end as result
         from projection_thread_activities
         where thread_id=?1 and kind in ('tool.started','tool.updated','tool.completed') and (?2 is null or created_at > ?2)
           and (json_extract(payload_json,'$.data.input') is not null or images > 0)
         order by created_at";

pub(crate) const IMAGES: &str = "select json_extract(value,'$.source.media_type') as media_type,
                json_extract(value,'$.source.data') as data
         from projection_thread_activities, json_each(case when json_type(payload_json,'$.data.result.content')='array' then json_extract(payload_json,'$.data.result.content') else '[]' end)
         where thread_id=?1 and json_extract(payload_json,'$.toolCallId')=?2
           and (case when type='object' then json_extract(value,'$.type') end)='image'
         order by created_at desc, activity_id, json_each.key";

pub(crate) const PROJECT_SCREENSHOTS: &str = "select a.activity_id as activity, j.key as idx, a.created_at as created_at,
                json_extract(a.payload_json,'$.data.toolName') as tool,
                json_extract(j.value,'$.source.media_type') as media_type,
                substr(json_extract(j.value,'$.source.data'),1,87380) as head
         from projection_threads t
         join projection_thread_activities a on a.thread_id=t.thread_id,
              json_each(case when json_type(payload_json,'$.data.result.content')='array' then json_extract(payload_json,'$.data.result.content') else '[]' end) j
         where t.project_id=?1 and t.deleted_at is null and a.kind='tool.completed'
           and json_extract(a.payload_json,'$.data.toolName')='mcp__t3-code__device_screenshot'
           and (case when j.type='object' then json_extract(j.value,'$.type') end)='image'
         order by a.created_at desc limit 40";

pub(crate) const SCREENSHOT_DATA: &str = "select json_extract(payload_json,?2) as data
             from projection_thread_activities where activity_id=?1";

pub(crate) const THREAD_PROJECT: &str = "select p.project_id, p.title, p.workspace_root from projection_threads t \
            join projection_projects p using(project_id) where t.thread_id=?1";

pub(crate) const PROJECT: &str = "select project_id, title, workspace_root from projection_projects where deleted_at is null and project_id=?1";

pub(crate) const PROJECT_PLACES: &str = "select project_id, title, workspace_root, workspace_root place from (select project_id, title, workspace_root from projection_projects where deleted_at is null) union all \
        select t.project_id, p.title, p.workspace_root, t.worktree_path from projection_threads t join projection_projects p using(project_id) \
        where t.worktree_path is not null and t.deleted_at is null and p.deleted_at is null";

pub(crate) const SEARCH: &str = "select * from (select 'msg' src, m.message_id id, m.thread_id thread, t.title title, m.role role, m.created_at at,
    substr(m.text,1,8000) text, instr(coalesce(m.context_json,''),'\"squircle-')>0 marked
    from projection_thread_messages m join projection_threads t using(thread_id)
    where ?4 and t.project_id=?1 and t.deleted_at is null and m.role in ('user','assistant')
      and (?2 is null or m.created_at >= ?2)
      and exists(select 1 from json_each(?3) terms where instr(lower(m.text), terms.value)>0)
    order by m.created_at desc limit 1500)
union all
select * from (select 'thread' src, thread_id id, thread_id thread, title, coalesce(branch,'') role, created_at at,
    title || ' ' || coalesce(branch,'') text, 0 marked from projection_threads
    where ?5 and project_id=?1 and deleted_at is null and (?2 is null or updated_at >= ?2)
      and exists(select 1 from json_each(?3) terms where instr(lower(title || ' ' || coalesce(branch,'')), terms.value)>0)
    order by created_at desc limit 300)
union all
select * from (select 'act' src, a.activity_id id, a.thread_id thread, t.title title, a.kind role, a.created_at at,
    substr(a.summary || ': ' || coalesce(json_extract(a.payload_json,'$.detail'), json_extract(a.payload_json,'$.message'), ''),1,2000) text, 0 marked
    from projection_thread_activities a join projection_threads t using(thread_id)
    where ?6 and t.project_id=?1 and t.deleted_at is null and a.kind in ('tool.completed','tool.denied','runtime.error')
      and (?2 is null or a.created_at >= ?2)
      and exists(select 1 from json_each(?3) terms where instr(lower(a.summary || ' ' || coalesce(json_extract(a.payload_json,'$.detail'), json_extract(a.payload_json,'$.message'), '')), terms.value)>0)
    order by a.created_at desc limit 500)";

pub(crate) const MESSAGE: &str = "select m.message_id, m.thread_id, t.title, m.role, m.created_at, m.text, \
                (select text from projection_thread_messages p where p.thread_id=m.thread_id and p.created_at<m.created_at and p.role!=m.role and p.role in ('user','assistant') order by p.created_at desc limit 1) before_text, \
                (select message_id from projection_thread_messages p where p.thread_id=m.thread_id and p.created_at<m.created_at and p.role!=m.role and p.role in ('user','assistant') order by p.created_at desc limit 1) before_id, \
                (select text from projection_thread_messages p where p.thread_id=m.thread_id and p.created_at>m.created_at and p.role!=m.role and p.role in ('user','assistant') order by p.created_at limit 1) after_text, \
                (select message_id from projection_thread_messages p where p.thread_id=m.thread_id and p.created_at>m.created_at and p.role!=m.role and p.role in ('user','assistant') order by p.created_at limit 1) after_id \
                from projection_thread_messages m join projection_threads t using(thread_id) where m.message_id=?1";

pub(crate) const THREAD: &str = "select title, branch, created_at, updated_at, archived_at, \
                (select count(*) from projection_thread_messages m where m.thread_id=t.thread_id and m.role in ('user','assistant')) total \
                from projection_threads t where thread_id=?1";

pub(crate) const ACTIVITY: &str = "select a.thread_id, t.title, a.kind, a.summary, a.created_at, \
                coalesce(json_extract(a.payload_json,'$.detail'),'') detail, \
                substr(coalesce(json_extract(a.payload_json,'$.data.input'),''),1,?2) input \
                from projection_thread_activities a join projection_threads t using(thread_id) where a.activity_id=?1";

pub(crate) const MESSAGES: &str = "select * from (select message_id, role, created_at, substr(text,1,2000) text from projection_thread_messages \
                where thread_id=?1 and role in ('user','assistant') order by created_at desc limit ?2) order by created_at";

pub(crate) const CONTEXT_READING: &str = "select
    (select created_at from projection_thread_activities where thread_id=?1 and kind='context-window.updated' order by created_at desc limit 1) reading_at,
    (select json_extract(payload_json,'$.usedTokens') from projection_thread_activities where thread_id=?1 and kind='context-window.updated' order by created_at desc limit 1) used,
    max(coalesce((select max(created_at) from projection_thread_messages where thread_id=?1),''),
        coalesce((select max(created_at) from projection_thread_activities where thread_id=?1),'')) last_at";
