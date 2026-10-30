# Tasks (2026-10-14, user decision)

The user fires off many asks an hour and lost track of them; the agent did
too. Tasks are what the user asked an app's agent for, in their words, and
where each stands. The service owns them, the agent keeps them, the phone
shows and edits them.

**2026-10-24 (user decision): work items and sub-tasks.** "Each top level
big work item should get like a page and then small tasks should be tracked
under it as well as threads and builds and media. And I can swipe through
these. Allow agent to formally track these details or sub tasks inside the
task. No user asks should be acted on without being put in the tracker."
A task is now a work item; small items are sub-tasks under it (below).

## Work items and sub-tasks (2026-10-24)

A sub-task is an ordinary task with a `parent` (one level only, same app):
its own wording, status, note, linked workers and builds, media and history,
and the same following of linked work. `squircle task sub add ITEM --ask
...` adds one; `update`, `link`, `attach` and `show` take its ID like any
task's; `task update ID --under ITEM|none` moves a misfiled ask. Existing
`tasks.json` records load as work items with no sub-tasks (no `parent`).

**Roll-up** (`rollup` in `src/fsm/tasks/`): a work item with sub-tasks takes
the roll-up of its sub-tasks and its own linked work whenever a sub-task's
status changes (or its own linked work has news): any needs you → needs you;
any in progress, or some finished and some still queued → in progress; all
queued → queued; else any ready to try → ready to try; all closed → done if
the user closed the last one, ready to try if the agent or linked work did
(the user decides done), dropped if all were dropped. A status set on the
work item explicitly holds until then. A closed work item reopens only when
a sub-task has work again (added, queued, in progress, needs you). Closing a
work item (done or dropped) closes its open sub-tasks the same way. Sub-tasks
don't age on their own: they move to History with their work item, and any
change to one touches its work item.

**Tracker first.** The per-turn note, the plugin's instructions and worker
prompts say: put every user ask in the tracker, in their words, before any
work on it: a sub-task of the work item it clearly belongs to, otherwise a
new work item; never under an unrelated one; track your own breakdown as
sub-tasks. The note lists open work items with their open sub-tasks (`·`
lines). (Fresh agents' handoffs, which listed every open item, went with
fresh starts on 2026-10-30: the agent keeps one thread.)

## Questions and what waits on you (2026-10-26, user decision)

User: "It's real annoying when the main agent or the inner ones ask
questions and they get buried in an avalanche of responses, or the outer one
has to proxy the inner questions. Need questions to land consistently in the
task tracking … Not just plain text. I need to see everything waiting on me."

- **Questions live on tasks.** `squircle task ask ITEM --thread ID --question
  "..." [--option ...]` adds an open question to a work item or sub-task
  (`questions` on the record: text, up to 6 options, the asking thread,
  `open | answered {text, at} | withdrawn {at}`). While one is open the task
  is held at needs you (linked work can't move it off; an explicit open
  status is refused; closing the task withdraws it). Answering the last open
  one moves it to in progress. `task withdraw QUESTION_ID` takes one back.
- **The answer goes back as a message.** The phone answers with `POST
  /v1/questions/{id}/answer`; the asking thread gets an `[answer]` note
  (`squircle-answer`, label "Answered") through the outbox; when a worker
  asked, its app agent is told too.
- **Agents use it, not chat.** The plugin prompt and the per-turn note say to
  ask only with `task ask` and end the turn; the note lists open questions
  as `?` lines under their task. The app agent's guard refuses Claude's
  `AskUserQuestion` and points to `task ask`. Workers ask with their own
  question tool (or `task ask`).
- **Worker questions without proxying.** A worker's own T3 question or
  approval no longer wakes its app agent (`due_wakes` skips needs-you). It
  appears directly in the list below, linked to the task that links the
  worker, and is answered straight to the worker (`POST /v1/waiting/respond`,
  T3's `runtime-request.respond`); the app agent then gets an `[answer]` note.
- **One list.** `GET /v1/waiting` gives, per app with an agent: open tracker
  questions, threads' own pending questions and approvals (from each
  needs-you thread's projection), and needs-you tasks neither covers.
- **On the phone (2026-10-26, user: "the questions should show inline in
  the sheet in needs you. And the global needs you stuff across the apps
  should just be its own piece of UI on the Home Screen"; this replaced a
  separate Waiting sheet, then a Waiting tab).** In an app's Tasks sheet
  each open question sits under its work item's row in Needs you (a work
  item with a question is in Needs you whatever its status): the question
  in full, options as glass buttons in a row (wrapping only when they
  don't fit), a reply field; a worker's approval
  with its choices; a question about a sub-task names it; a needs-you
  sub-task shows under its item and opens its page; a question no task
  claims leads the section. The item's page shows its open questions under
  its note. Answered ones leave at once and the task moves on as the Mac
  says. Home lists everything waiting across apps above the devices
  (plain text, "Waiting on you" and a count, then each app's name and its
  first two items, then "N more in Tasks"): few-choice answers are buttons
  right there; tapping an item opens its app's Tasks sheet at its task.
  The counts strip and the checklist button open Tasks as before.
- **Notifications.** A new tracker question, and a worker's question or
  approval ("“title” asks: …"), go out through `src/push` with
  `"waiting": true`, the project and the thread in the payload; a tap opens
  that app's Tasks sheet at the task the thread's question is about (Home
  when the payload names no app). Untested on a phone: no APNs key is
  configured yet.

Verified 2026-10-26 on a simulator against the live service with
`SQUIRCLE_DRY_ANSWERS=1` (DEBUG: an answer leaves the list on the phone and
is sent nowhere): Home listed 8 real items (LanguageApp needs-you tasks,
Squircle's three tracker questions); "3 more in Tasks" and tapping a
question opened the app's sheet at its task; the questions showed under
their items in Needs you and on the page; a `{"waiting": true, project,
thread}` payload opened the sheet at the question; a dry "Not now" on Home
removed the row (the Mac still listed it). `SQUIRCLE_STRESS=1` 40 s:
`violations=0`. **Not verified:** a live worker T3 request (none was
pending), answering inside the sheet (the simulator driver times out over
the agent's conversation; the same answer path as Home), the strip tap, a
delivered push.

## Demands reach the tracker and every worker (2026-10-24)

User: "It needs to be writing the task with my demands and then doing
them." The Letters Abroad agent passed "Fold from bottom same as the
folder" on to a worker in a message but never recorded it; two hours later
it re-briefed the worker from a newer message alone, "bottom" was dropped,
and the worker went back to a top fold. It also reported visibly broken work
as done and promised to "check every ~20 min". So:

- **Every user message is accounted for before work is handed on.** A
  message is accounted for once a task records it, or a later one, as its
  `source` (`task add` / `task sub add` with `--thread`), or the agent marks
  it as asking for nothing (`task heard --thread ID`: a thanks, a question it
  answered; saved as the agent's `heard` message). `thread spawn`, `thread
  send` and `thread answer` from an app agent refuse while any of the user's
  messages after the last accounted one is not, quoting them
  (`src/agents/demands.rs`); the per-turn note lists them too. No timer: it
  is checked when the agent tries to hand work on.
- **Briefs carry the asks.** `thread spawn` requires `--task`. Its prompt,
  and every `thread send` to a worker linked to a task, ends with the
  work item's ask and the user's asks under it (dropped and replaced ones
  left out, done ones marked "still holds"; since 2026-10-26 not the agent's
  own sub-tasks, below), so a re-brief can't drop a correction the tracker
  has.
- **Instructions.** The plugin prompt and the per-turn note: one sub-task per
  demand, corrections and details ("from bottom") included, in the user's
  words, before acting; never present work as done without having looked at
  it (screenshots or a recording) against every ask of its work item; never
  promise timed check-ins (`[worker update]`s wake the agent).

## Only the current spec reaches workers (2026-10-26)

Letters Abroad's folder item had grown to ~70 sub-tasks over days, and every
brief carried all of them as "the user's words, every one holds": older asks
the user had since contradicted ("tall sheets curve around smaller items in
front" before "no wrapping, the card is covered by its flap"), and about
half the agent's own paraphrased steps. Workers couldn't tell what was
current, and the latest asks lost. So:

- **Replaced asks retire.** `task sub add ITEM --ask ... --replaces ID[,ID]`
  or `task update ID --replaced-by ID` drops the old ask with `replaced_by`
  set and the note "Replaced by a later ask" (the phone shows it like any
  dropped sub-task, ✕ and that note; history kept). A replaced task never
  reopens for its linked workers' new work, since they go on with the ask that
  replaced it; an explicit open status undoes the replacement. Adding a user
  ask beside open ones, the result's `next` lists them and asks the agent to
  mark any it replaces.
- **The block is the user's asks only.** It lists each work item, then its
  sub-tasks that have a source message and aren't dropped or replaced,
  oldest first, "each holds unless a later one changes it". The agent's
  breakdown stays out: the brief already says that in the agent's words.
- **Instructions.** When the user corrects or adds to work in progress, the
  agent retires what it replaces and sends the worker the whole current spec,
  not just the new piece; after many revisions it prefers a fresh worker
  briefed from the clean spec.

## Model

Kept per app (T3 project) in `<data>/tasks.json`; attachments in
`<data>/tasks/<id>/media`. A task has the ask, a status (`queued`,
`in_progress`, `needs_you`, `ready_to_try`, `done`, `dropped`), a few-word
note, the chat message it came from (the agent's latest user message when it
adds the task), linked worker threads and builds, an order within its group,
attached screenshots and clips, and a history of status changes (by agent,
user or auto).

**Status follows linked work** (`Signals::implied`): a linked worker waiting
on a question → needs you; a worker working or a build queued/running → in
progress; the newest linked build succeeded → ready to try. An explicit
status from the agent or the user holds until a linked worker's or build's
state changes after the moment it was chosen. A link going missing (an
archived worker, or a shell that isn't current) is no fact at all and
doesn't count. Once done or dropped, a task reopens only for new work: a new
linked worker or build, a new turn of a linked worker (T3's
`latestTurn.turnId`), or a linked worker working or asking again; old work
finishing leaves it closed (2026-10-14, after the user's Done kept
reverting). The service checks every 3 s.

**History:** done and dropped tasks leave the active list after a day, open
ones that nothing touched for three days too. Nothing is deleted; any change
to the task, or new linked work, brings it back. History tasks keep
following their linked workers (and builds still running); only ones whose
links are all finished builds are skipped.

**Saved state (review B, 2026-10-15; `src/tasks.rs`).** Each record keeps:

- `revision`, raised by every saved change, including what linked work was
  seen doing.
- `observed {revision, workers: {id: {turn, phase}}, builds: {id: phase}}`,
  the last known state of each link. It always advances, whatever the
  status, so a closed task still sees the next turn start; a link without a
  current fact keeps its last known state.
- `placement`: `active` or `history {since}`, independent of status (open
  tasks age into History too).

An explicit status records the observation the caller read with it
(`hold`), unless a newer one was already recorded. A tick reads signals
outside the lock and applies them only to tasks still at the revision it
read; anything changed meanwhile waits for the next tick. Every change is
saved to `tasks.json` first and becomes visible only once saved; a change
that can't be saved is not seen. The decisions are the M17 reducer in
`src/fsm/tasks/`, saved through the C00 commit gate
([state machines](fsm-architecture.md)); the file carries a `transaction` and
`revision` stamp so a failed save can tell whether it landed. One whose
outcome is unknown stays hidden and is written again before the next change. Older files with `seen` and `archived_at`
are read and converted on load. The wire keeps `archived_at` (set while in
History) and adds `revision`; `observed` stays internal.

**Paging.** `GET /v1/tasks` returns all active tasks and one page of
History, newest first (`history_limit`, 1–100, default 20;
`history_before`, the previous reply's `history_next` cursor). Only the
returned tasks are expanded with linked work and media. `squircle task list
--all [--history-before CURSOR]` pages the same way; without `--all` History
is not fetched.

## Agent

`squircle task add|sub add|update|link|attach|list|show|heard` (`--help`,
`--json`); `thread spawn --task` (required) and `build start --task` link as
they start. The
per-turn `[squircle]` note lists the open tasks (also after compaction) and
asks the agent to add one per new ask, link workers and builds, attach
pictures worth seeing and keep status and note current. The plugin's
instructions say the same.

## Phone

**Overview and pages (2026-10-24, user decision, superseding the
page-per-item pager the same morning).** The pager alone was "absolutely
unusable" on a real list (LanguageApp: 24 open items, long asks): 24 pages
swiped blind with no way to scan, find or compare. The Tasks tab now opens
on an overview of every work item: a search field (once there are more than
six tasks; it looks through History too), then groups Needs you, Ready to
try, In progress, Queued, Done (today's) and History (folded). Rows are
compact: the round tick in the status colour (one tap marks it done; the
batch, 0.65 s settle and the 4 s Undo capsule are back), the ask's first two
lines, then sub-task progress ("2/5") and the note on one line, and the
worker's jelly while one is alive or Install. Swipe left: Done / Drop;
swipe right: Top; long press: any status. Tapping a row pushes that item's
page (route `.overview | .item(id)` and one spring; the overview and the
pages slide side by side, the destination takes touches at once). Pages
swipe sideways through the overview's rows in its order ("3 of 24" at the
top right); back is the chevron where the close button was, or a swipe
right that starts at the left edge (a plain pan limited to the edge band:
a screen-edge recogniser never fires inside the sheet). Only the shown page
and its neighbours exist. The page itself is as below (status menu, ask,
note, Install, sub-task checklist, threads, pictures). DEBUG:
`SQUIRCLE_DEMO_TASKS=PATH` loads a real list (`squircle task list --json`)
kept on the phone; validated on a simulator with the LanguageApp snapshot
(24 open, 2 done, 20 History): find by search, open, page, back, swipe Done,
tick and Undo.

**Pages (2026-10-24 morning, superseded above).** The Tasks tab was
a horizontal pager (native paging; the page follows the finger, dots at the
foot also move it): one page per open work item, needs you first, then in
progress, ready to try, queued. A page shows its status (tap: any status, or
Move to Front), the ask large, the note, Install when a linked build (its
own or a sub-task's) is ready, the sub-tasks as a checklist (tap the circle
to tick one done, again to reopen it; the rest of the row opens its thread),
its and its sub-tasks' threads (live workers with their jelly, finished
ones as chips; tap pushes the thread) and their screenshots and clips at a
readable size (tap opens). The last page was Done and History.

The grouped list (2026-10-15), kept for the record:

- **Tasks button** replaces Threads beside Builds on the app's agent. The
  sheet has a Tasks | Threads switch; Threads is the old list.
- **Tasks tab:** groups Needs you, In progress, Ready to try, Queued, then
  Done (today's). Rows show the ask, the note, linked threads as chips (tap
  opens the thread), thumbnails (tap opens the picture or plays the clip) and
  Install when a linked build is ready. Tapping a row opens its most relevant
  thread. **One-tap Done (2026-10-15, user-requested):** a round circle at
  each open row's leading edge (like Reminders) ticks it with a haptic; the
  list holds still while you tick down it and the ticked rows move to Done
  together 0.65 s after the last tick (tap again before then to untick). A
  small glass "N marked done · Undo" capsule stays 4 s and puts them back.
  No pull to refresh: the sheet's lease keeps the list current, so pulling
  down at the top dismisses the sheet. Swipe (UIKit's own actions): Done / Drop (the row moves at once
  and holds until the Mac confirms), or Top; the list holds still while a
  swipe is open and catches up when it closes; long press:
  any status, Move to Top. History folds at the bottom, with search; it
  loads a page at a time as its last row shows, and search covers the pages
  loaded so far. A swiped or chosen status is laid over the Mac's list until
  a reply with that task's `revision` (or newer) arrives. No +:
  tasks come only from what you tell the agent (user, 2026-10-14). The
  header is the close button and the switch on glass over a soft scroll
  edge; group names are small labels that scroll with their rows.
- **Strip** above the message field on the agent while tasks are open:
  "1 needs you · 5 working · 3 to try" in a small glass capsule as wide as
  its text, centred over the field (2026-10-15, was a full-width bar);
  tapping opens Tasks. The conversation
  keeps clear of it (it counts as part of the field for the bottom inset).
