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

**Roll-up** (`rollup` in `src/fsm/tasks/`; since 2026-10-31 over resting
stages, below): a work item with sub-tasks rests at the roll-up of its
sub-tasks and its own linked work whenever a sub-task's status changes (or
its own linked work has news): all queued (and no work of its own) → queued;
else any still open → ready to try; all closed → done if the user closed the
last one, ready to try if the agent or linked work did (the user decides
done), dropped if all were dropped. A status set on the work item explicitly
holds until then. A closed work item reopens only when a sub-task has work
again (added, queued, its work running, asked about). Needs you and in
progress are not rolled up but shown (below): an item shows in progress
while any of its open sub-tasks' work runs. Closing a
work item (done or dropped) closes its open sub-tasks the same way. Sub-tasks
don't age on their own: they move to History with their work item, and any
change to one touches its work item.

**Tracker first.** The per-turn note, the plugin's instructions and worker
prompts say: put every user ask in the tracker, in their words, before any
work on it: a sub-task of the work item it clearly belongs to, otherwise a
new work item; never under an unrelated one; track your own breakdown as
sub-tasks. The note doesn't list the tracker (2026-11-01, below); the agent
reads it with `task list` when it needs it. (Fresh agents' handoffs, which listed every open item, went with
fresh starts on 2026-10-30: the agent keeps one thread.)

## Titles (2026-10-31, user decision)

User: "I don't like that all the task titles are literally my message
verbatim. It should be writing sensible tasks." Every row and page showed
the raw ask ("I don't think the LA agent got the memo on the brevity
thing…"). So:

- **A task has a title and an ask.** The title is the agent's: a few words
  in sentence case naming the work ("App agents reply briefly"), one line,
  at most 80 characters. The ask stays the user's words verbatim: the
  record, carried into worker briefs (the work item's line reads
  "Title: ask") and never paraphrased away.
- **CLI.** `task add` and `task sub add` require `--title` (the service
  refuses a task without one); `task update ID --title` renames. The
  per-turn note names tasks by title; one without a title shows as
  `untitled, asked "…"` (`task list` shows its ask), and the note asks the
  agent to name those when it next touches them. The plugin prompt says the
  same.
- **No migration, no generated titles.** The service runs no model. Stored
  records without `title` load with an empty one (and are saved without the
  key), so older `tasks.json` files read unchanged.
- **On the phone** rows, sub-task rows, Home's waiting cards and the name
  over a thread show the title, else the ask. A page shows the title (Title
  22) with the ask beneath it quoted, in Body secondary, as the user's
  words. The conversation's tracker lines read "Added task: <title>" and
  "Named a task “…”". `GET /v1/waiting` adds `task_title` (and
  `item_title`) beside `ask`.

Checked 2026-10-31 on a simulator (iOS 27.0, DEBUG) with
`SQUIRCLE_DEMO_TASKS` set to a copy of Squircle's real list (37 work items)
given titles as an agent would, one left untitled: Tasks listed the titles,
the untitled one its ask, and a page showed its title over the quoted ask.

## Needs you is derived, never set (2026-10-31, user decision)

User, on the Tasks outline: "Needs you is really bad here it is completely
unclear what needs me or what I need to do." Its Needs you group held work
items with no question at all, only a title and "0/2": 13 tasks across
Squircle and LanguageApp were kept at needs you with nothing open, set by
hand by an agent (`task update --status needs_you --note ...`) or left
behind after a question was answered or withdrawn. So:

- **A task is kept at a stage** (`Stage`: queued, in progress, ready to try,
  done, dropped) and **shows as needs you** (`Book::shown`) exactly while
  something waits on the user: an open question on it or one of its
  sub-tasks, or, while it is open, a linked thread T3 shows waiting on a
  question or approval of its own (the same threads Home's Waiting on you
  lists). When the last of those is answered or withdrawn it shows its stage
  again; an answer also sets it in progress, since the asker goes on.
- **It can't be set.** `task add|sub add|update --status needs_you`, and the
  phone, are refused with a message pointing to `task ask` (the value is
  hidden from the CLI's choices). The status menu on the phone has no Needs
  you.
- **Migrated once.** Records kept at needs you load as the stage their
  linked work implies, else the last other status in their history, else in
  progress (a history entry by `auto` records it), and the service saves
  that at startup (`Event::Migrate`, which also rolls up work items among
  them). Checked on a copy of the Mac's `tasks.json` (456 tasks): the 13
  stale ones came back as ready to try, in progress or queued, none showed
  needs you, and a second read had nothing left to migrate.
- **On the phone**, Needs you holds only work items with something to answer
  in the waiting list, each followed by its questions and approvals as the
  [question card](design/README.md#the-question-card) in its compact form:
  who asks, the question in three lines (tap it to open the conversation at
  the spot), what it is about as a short strip, the answers and a write-in
  row. A task that shows needs you but whose question hasn't reached the
  phone yet sits in In progress until it does.

## In progress is derived, never set (2026-10-31, user decision)

User: "I think working tasks with live threads should sort to top", then:
"working only while a linked thread or build is actually running, sorted to
the top; everything else falls to queued or ready to try." Agents set in
progress by hand ("Merged; build coming"), and sub-tasks left there rolled
up, so tasks showed as working with nothing live: 41 of the Mac's 464 tasks
were kept at in progress.

- **A task rests at a stage** (`Stage`: queued, ready to try, done,
  dropped) and **shows as in progress** (`Book::shown`, after needs you)
  exactly while it is open and a linked thread is running (T3's run state:
  the shell row's `status` is a running one, `Phase::Working`) or a linked
  build is queued or running; a work item also while one of its open
  sub-tasks does. A thread T3's current shell no longer has (archived or
  deleted) is `Gone`, not running; a shell that isn't current is no fact and
  keeps what was last seen.
- **Resting.** When linked work with news stops, an open task rests at queued
  if no work has happened yet (no linked work ever seen, never ready to try
  or done), otherwise ready to try. A failed build or a stopped worker rests
  it at ready to try too. While its work runs, its stage doesn't move (no
  history entry for it starting); a done or dropped task still reopens only
  for new work, to where it rests. Answering a question no longer sets
  anything: the asker running again shows it.
- **It can't be set.** `task add|sub add|update --status in_progress` is
  refused with a message to link the work instead (hidden from the CLI's
  choices); the phone's status menu has no In progress. Agents still set
  queued, ready to try (work done themselves), done and dropped.
- **Migrated once.** Records kept at in progress load where they rest (by
  the rule above) and are saved at startup (`Event::Migrate`, which also
  rolls up the work items among or above them). Checked on a copy of the
  Mac's `tasks.json` (464 tasks): the 41 came back as 26 ready to try, 11
  queued and 4 still shown in progress (each with a linked worker last seen
  running); a second read had nothing left to migrate.
- **On the phone** the outline puts In progress first, right under Needs you,
  each with its live threads nested under it; then Ready to try, Queued,
  Done and History as before.

## Newest first (2026-11-01, user decision)

User: "Can we sort recent tasks to top not bottom it's confusing. Or what is
the order? I'm confused." Within a group rows went by a stored `order`, each
new task after the last, so new ones landed at the bottom (and Move to Top
put one above). So:

- **One order: most recent activity first.** A task keeps `active_at`, its
  latest activity the user can see: added, its status changing, a question
  asked, answered or withdrawn, a thread or build linked, or linked work
  having news (a worker starting, finishing, asking; a build ending). A
  sub-task's activity is its work item's too. Notes, titles, asks and
  pictures don't move it (they still move `updated_at`, which ages tasks into
  History), so rows don't shuffle for edits. Ties go to the newest added.
- **The service orders, everyone follows.** `Book::list` returns work items
  and their sub-tasks in that order; `GET /v1/tasks` keeps it, the phone
  groups by status without re-sorting (rows, and the pages' swipe order,
  follow), and `task list` keeps it. History still pages by when tasks moved there, newest first.
- **`order` is gone**, with Move to Top / Move to Front on the phone and
  `task update --top`. Migrated once: records without `active_at` take
  their last status change (else when they were added), work items the
  latest of theirs and their sub-tasks', saved at startup (`Event::Migrate`).
  Checked on a copy of the Mac's `tasks.json`: Squircle's 38 open items came
  out newest first with no violations, and a second read had nothing left to
  migrate. About 17 items share one minute from the 2026-10-31 in-progress
  migration's status changes, so among those the newest added leads until
  they see new activity.

Checked 2026-11-01 on a simulator (iOS 27.0, DEBUG) with
`SQUIRCLE_DEMO_TASKS` set to Squircle's live list in the new order: In
progress, then Ready to try led by the most recently active items.

## Questions and what waits on you (2026-10-26, user decision)

User: "It's real annoying when the main agent or the inner ones ask
questions and they get buried in an avalanche of responses, or the outer one
has to proxy the inner questions. Need questions to land consistently in the
task tracking … Not just plain text. I need to see everything waiting on me."

- **Questions live on tasks.** `squircle task ask ITEM --thread ID --question
  "..." [--option ...]` adds an open question to a work item or sub-task
  (`questions` on the record: text, up to 6 options, the asking thread,
  `open | answered {text, at} | withdrawn {at}`). **2026-10-31 (user: "questions
  need to support attached clips"; LanguageApp's questions said "clip attached"
  about clips that sat only on the task):** `--file PATH` (repeatable) attaches
  the screenshots, clips and documents the question is about, with `task
  attach`'s checks; they are stored in the task's media folder and listed by
  ID on the question (`media`), shown on the question card and not among the
  task's own media while it is open (after that they are the task's). While one is open the task
  shows as needs you (since 2026-10-31 derived, above: linked work and an
  explicit status move only the stage under it; closing the task withdraws
  it). Answering one moves the task to in progress. `task withdraw QUESTION_ID` takes one back.
- **The answer goes back as a message.** The phone answers with `POST
  /v1/questions/{id}/answer`; the asking thread gets an `[answer]` note
  (`squircle-answer`, label "Answered") through the outbox; when a worker
  asked, its app agent is told too. The answer is saved with its delivery
  owed (`answered {text, at, owed}`); the service's task loop hands owed
  answers to the outbox and then clears `owed`, so a restart or failure in
  between delivers it later, once. The phone sending the same answer again
  is accepted (a different one is refused). An open question stays in
  Waiting on you even after its task ages into History.
- **Agents use it, not chat.** The plugin prompt and the per-turn note say to
  ask only with `task ask` and end the turn; the note lists open questions
  as `?` lines with their task. The app agent's guard refuses Claude's
  `AskUserQuestion` and points to `task ask`. Workers ask with their own
  question tool (or `task ask`).
- **Worker questions without proxying.** A worker's own T3 question or
  approval no longer wakes its app agent (`due_wakes` skips needs-you). It
  appears directly in the list below, linked to the task that links the
  worker, and is answered straight to the worker (`POST /v1/waiting/respond`,
  T3's `runtime-request.respond`); the app agent then gets an `[answer]` note.
- **One list.** `GET /v1/waiting` gives, per app with an agent: open tracker
  questions, threads' own pending questions and approvals (from each
  needs-you thread's projection). **2026-10-31 (user: "it should just have
  blocking questions"):** only what blocks an agent; a task at needs you
  with only a note is no longer listed (it stays a row in Tasks).
- **On the phone (2026-10-26, user: "the questions should show inline in
  the sheet in needs you. And the global needs you stuff across the apps
  should just be its own piece of UI on the Home Screen"; this replaced a
  separate Waiting sheet, then a Waiting tab).** In an app's Tasks sheet
  each open question sits under its work item's row in Needs you (a work
  item with a question is in Needs you whatever its status): the question
  in full, options as glass buttons in a row (wrapping only when they
  don't fit), a reply field; a worker's approval
  with its choices; a question about a sub-task names it; a question no task
  claims leads the section. The item's page shows its open questions under
  its note. Answered ones leave at once and the task moves on as the Mac
  says. Home shows everything waiting across apps above the devices as
  the design deck's **B · Deck** (2026-10-31): "Waiting on you" and
  "N of M", then one shared question card at a time, its app's name first,
  the next a native page swipe sideways; it keeps the tallest card's height
  so the devices stay put, and answers there like anywhere.
  **2026-10-31 (user-requested): tapping a question's text opens the
  conversation that asked it at the spot**: the app's agent, or a worker's
  thread pushed over it (from Home, it covers the agent and Back goes
  straight to Home). A tracker question shows in its asking thread as a
  plain card under that thread's "Asked you" line (or, if that line isn't
  loaded, at the end of the turn it was asked in, by `asked_at`), answerable
  in place with the same shared drafts. The conversation waits for T3 to
  catch up, puts the card low on screen with what led up to it above, holds
  it there until you scroll, and marks it with a fading accent ring (no
  crossfade, touches pass). A thread's own question or approval is its
  newest thing: the jump lands at the end and marks the card over the
  field. Tapping a question's text in the Tasks sheet's Needs you does the
  same.
  The counts strip and the checklist button open Tasks as before.
- **Notifications.** A new tracker question, and a worker's question or
  approval ("“title” asks: …"), go out through `src/push` with
  `"waiting": true`, the project and the thread in the payload; a tap opens
  that app's Tasks sheet at the task the thread's question is about (Home
  when the payload names no app). Untested on a phone: no APNs key is
  configured yet.

Jump verified 2026-10-31 on a simulator (iOS 27.0, DEBUG build) against
the live service: LanguageApp's agent question (asked about 50 minutes
earlier, under the agent's "Asked you" line) from a cold launch, and a
worker's tracker question, landed at the card with the ring; Back from the
worker went to Home; answering from the chat card reached the worker. The
Tasks-sheet tap was built but not driven (the UI runner stalled on the
sheet). `SQUIRCLE_STRESS=1` with jumps mixed in: violations=0. No question
older than that was open, so a jump far up a long thread is untested.

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
`<data>/tasks/<id>/media` (screenshots, clips, and documents: pdf, md, txt, json, csv, which the phone opens in Quick Look). A task has a title (the agent's few words; empty on older ones), the ask (the user's words), a status (`queued`,
`in_progress` and `needs_you` shown only, `ready_to_try`, `done`, `dropped`), a few-word
note, the chat message it came from (the agent's latest user message when it
adds the task), linked worker threads and builds, when it was last active
(`active_at`, [above](#newest-first-2026-11-01-user-decision)), attached
screenshots and clips, and a history of status changes (by agent,
user or auto).

**Status follows linked work** (since 2026-10-31 shown, above: a worker
waiting → needs you, running work → in progress; once linked work with news
stops it rests at ready to try). An explicit
status from the agent or the user holds until a linked worker's or build's
state changes after the moment it was chosen. A link going missing (an
archived worker, or a shell that isn't current) is no fact at all and
doesn't count. Once done or dropped, a task reopens only for new work: a new
linked worker or build, a new run of a linked worker (T3's `latestRunId`),
or a linked worker working or asking again; old work finishing leaves it
closed (2026-10-14, after the user's Done kept reverting). The service looks
again whenever T3's view of the threads, a build or the tasks change, and when
the next task is due to age into History; it never polls.

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
(`hold`), unless a newer one was already recorded. A tick reads signals from
the published tasks, without the tasks' owner, and the owner applies them
only to tasks still at the revision they were read at; anything changed
meanwhile waits for the next tick. Every change is
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
they start. The per-turn `[squircle]` note (also after compaction) asks the
agent to add one per new ask, link workers and builds, attach pictures worth
seeing and keep status and note current, and to read the tracker with `task
list` when it needs it. The plugin's instructions say the same.

**The note carries only what needs action now (2026-11-01, user decision).**
User: "What? We give it the entire task list every turn? What??? Why?",
then: "Only what needs action now: unrecorded messages, open questions,
running work. The agent looks up the rest with task list". LanguageApp's note
had grown to 51 KB, 42 KB of it the full open list (25 items, 144 sub-tasks
with verbatim asks). Besides the role, reply and tracker rules and the app's
notes, it now holds only: the user's messages not yet in the tracker, the
agent's open questions to the user (`?` lines, with the task they are on,
History included), and running work: workers that are working, starting or
waiting on their own question, and builds queued or running that are linked
to one of the app's tasks or started by the agent or its workers, each with
the task it serves (title and ID; a sub-task before its work item).
Finished workers are left to `thread status`. `task list` answers in brief:
per task its ID, title, status, note and open questions, the ask only when
untitled (`--asks` for all), sub-tasks the same; `--full` gives the whole
records (`GET /v1/tasks`), as the phone's demo list wants. Rendered from
the Mac's data: LanguageApp's note went from 51 KB to about 8 KB and
Squircle's from 16 KB to 8 KB; LanguageApp's `task list --json` from 417 KB
to 46 KB.

## Phone

**Overview and pages (2026-10-24, user decision, superseding the
page-per-item pager the same morning).** The pager alone was "absolutely
unusable" on a real list (LanguageApp: 24 open items, long asks): 24 pages
swiped blind with no way to scan, find or compare. The Tasks tab now opens
on an overview of every work item: a search field (once there are more than
six tasks; it looks through History too), then groups Needs you, Ready to
try, In progress, Queued, Done (today's) and History (folded; since 2026-10-31 In progress comes right after Needs you, above). Rows are
compact: the round tick in the status colour (one tap marks it done; the
batch, 0.65 s settle and the 4 s Undo capsule are back), the ask's first two
lines, then sub-task progress ("2/5") and the note on one line, and the
worker's jelly while one is alive or Install. Swipe left: Done / Drop;
long press: any status (since 2026-11-01 rows run newest first and Top is
gone). Tapping a row pushes that item's
page (route `.overview | .item(id)` and one spring; the overview and the
pages slide side by side, the destination takes touches at once). Pages
swipe sideways through the overview's rows in its order ("3 of 24" at the
top right); back is the chevron where the close button was, or a swipe
right that starts at the left edge (a plain pan limited to the edge band:
a screen-edge recogniser never fires inside the sheet). Only the shown page
and its neighbours exist. The page itself is as below (status menu, ask,
note, Install, sub-task checklist, threads, pictures). DEBUG:
`SQUIRCLE_DEMO_TASKS=PATH` loads a real list (`squircle task list --full --json`)
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
