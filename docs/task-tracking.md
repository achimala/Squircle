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
lines). A fresh agent's handoff lists every open work item and sub-task,
History's open ones included, uncapped (after an ask filed under an
unrelated task was lost across a fresh start).

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

`squircle task add|sub add|update|link|attach|list|show` (`--help`, `--json`);
`thread spawn --task` and `build start --task` link as they start. The
per-turn `[squircle]` note lists the open tasks (also after compaction) and
asks the agent to add one per new ask, link workers and builds, attach
pictures worth seeing and keep status and note current. The plugin's
instructions say the same.

## Phone

**Pages (2026-10-24, superseding the grouped list below).** The Tasks tab is
a horizontal pager (native paging; the page follows the finger, dots at the
foot also move it): one page per open work item, needs you first, then in
progress, ready to try, queued. A page shows its status (tap: any status, or
Move to Front), the ask large, the note, Install when a linked build (its
own or a sub-task's) is ready, the sub-tasks as a checklist (tap the circle
to tick one done, again to reopen it; the rest of the row opens its thread),
its and its sub-tasks' threads (live workers with their jelly, finished
ones as chips; tap pushes the thread) and their screenshots and clips at a
readable size (tap opens). The last page is Done (today's) and History,
searchable and paged as before, with the old rows; long press for any
status. No swipe actions there (the pager owns horizontal swipes), no undo
toast (a tick is undone by tapping again). The Tasks | Threads switch stays.
DEBUG: `SQUIRCLE_DEMO_TASKS=1` has work items with sub-tasks;
`SQUIRCLE_DEMO_PAGES=1` swipes through the pages.

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
