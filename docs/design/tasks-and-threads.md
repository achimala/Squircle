# Tasks and threads (design pass, 2026-10-31)

**Status: the user picked A · Outline (2026-10-31: "task list A seems best,
others too cluttered"); [the design deck](README.md#tasks-and-threads) is
the guide, and building it follows the deck's rules. This page keeps the
pass's audit and model.** The renders came from a DEBUG-only prototype on
the unmerged `tasks-threads-design` branch, against the Mac's real tasks and
threads (LanguageApp, Squircle); none of it ships.

User: "We need to see each task clearly up front with live status. When I
drill into each I want to see the active threads and what they're doing with
a small preview, then be able to jump into any one. If there's only one
thread just show it directly inside the task UI. Shouldn't need a separate
thread UI … threads are clearly visible and part of the task list."

## What's wrong today (audit)

Pictures: `/Users/anshu/.t3/userdata/attachments/tasks-design/audit-*.png`.

- **Questions swamp the list.** In LanguageApp's Needs you, the first screen
  is two asks plus a question's full text and its option buttons; the other
  eight items are below the fold (`audit-la-tasks`).
- **Pages open on the wrong thing.** The folder item's page (106 sub-tasks)
  opens on its *dropped* sub-tasks, oldest first (`audit-la-page`).
- **Two lists for one thing.** The sheet's Tasks | Threads switch splits work
  items from the threads doing them. Threads is a flat, newest-first list of
  every thread of the app (Squircle: 72, of which 65 are linked to no task:
  old agent threads, audits, lookups), so the live ones drown.
- **Status is a colour, not a sentence.** A row says "Needs you" by the tint
  of a circle and a note the agent last wrote, which is often stale; nothing
  says what is happening right now.
- **Threads are chips of archived work.** LanguageApp's folder item links
  22 threads; 18 are archived but still listed as chips on its page. The live
  one looks the same as the dead ones.
- **Sub-tasks bury the page.** The same item has 105 sub-tasks (43 dropped,
  13 done); the page lists all of them before its threads and pictures.
- **Opening a thread leaves the hierarchy.** It dismisses the sheet and pushes
  the thread over the agent; back goes to the agent, not the task.

## The model (common to all directions)

- **Hierarchy:** app (its agent's conversation, the screen you came from) →
  work items → sub-tasks → threads. A thread belongs to the work item or
  sub-task it was spawned for (`thread spawn --task`); a thread linked to a
  sub-task is shown under its work item too.
- **Live vs earlier threads.** Live = not archived (needs you, working,
  stopped, finished but not archived). Archived threads fold into one
  "Earlier threads N" line on the item's page; never chips.
- **Status rolls up as today** (service `rollup`): the work item's status is
  the headline; its threads say why. Threads sort needs you → working →
  stopped → finished.
- **"What it's doing"**: one line per thread. Needs you: the question or
  approval it is asking. Working: its live step ("Running the folder
  tests"), the same sentence its conversation's live line shows. Finished:
  the first line of its last reply. Stopped: "Stopped with an error".
  *Prototype:* the phone follows each shown thread's events for this. *To
  build:* the service should add `step` and `said` to each linked thread in
  `GET /v1/tasks` (it already reads T3's database for the Live Activity's
  step), so the list doesn't hold a subscription per thread.
- **Small preview**: the thread's simulator, live, while it holds one (the
  same feed as the PiP); otherwise the newest picture attached to the task
  or sub-task it is for; otherwise none (no placeholder art).
- **One thread**: a work item with exactly one live thread *is* that thread
  on its page: a short header (status, ask, sub-task count) over the
  conversation, whose field talks to that worker.
- **Jumping in** pushes the thread inside the hierarchy; its glass crumb
  names the task; back (edge swipe) returns to the task, not the agent.
- **Threads on no task**: the app agent is the root screen, not a row.
  Working loose threads (the user's own, or older workers) show as rows at
  the foot of the overview; idle ones fold into "Not on a task N".
- **Needs you and questions**: unchanged from 2026-10-26: questions sit under
  their task in Needs you and on its page; a worker's own question also shows
  as that thread's "what it's doing" line, answerable inline.
- **History**: a folded line at the foot, as today; search looks through it.
- **No Threads tab, no Threads list.** The Tasks button pushes Tasks (a flat
  push from the agent, edge swipe back), instead of a sheet: a thread with
  its own field and keyboard inside a sheet fights the sheet's drag.
- **Motion:** overview → item → thread are flat pushes driven by one
  interruptible spring, edge swipe back at each level; item pages swipe
  sideways in the overview's order (as today). The prototype only places the
  levels, for stills.

## The direction: A, Outline

Overview rows carry their live threads nested underneath (sprout, title,
what it's doing, a tiny preview). The item page lists threads first, then
the open sub-tasks with closed ones folded. Not picked: B, Tiles (a portrait
tile per thread) and C, Checklist (one line of ask and one of the lead
thread).

## What the renders showed (2026-10-31, simulator, iOS 27, live Mac data)

- Live step lines work and read well ("Running desk-sim", "Looking at the
  simulator"), but a raw step can be noise ("Looking at s.png", "Running
  python"); the service's `step` should prefer the step's written
  description, as the conversation's live line does.
- Live simulator previews come through as real feeds in rows (A) and tiles
  (B). Most threads have neither a simulator nor a picture, so B's tiles are
  often empty boxes (`B-la-item`); A and C just leave the preview out.
- No real item had two threads *working* at once during the pass; the
  several-threads page uses LanguageApp's Astra item (3 finished, 22
  archived). Archived threads fold to one line, which fixes the 18-chip page.
- C's one-line overview fits the most items (LanguageApp: all 10 open on one
  screen) but hides how many threads an item has and shows only its lead.

## Against the design deck

The deck ([README.md](README.md)) landed after these renders. Building the chosen direction follows it; the
prototype departs from it in these places, all to fix when built:

- **Type:** rows use 16 semibold asks, 13 to 14 second lines and 12 section
  labels. Build with the six roles: ask = Body 17, thread line and a row's
  second line = Line 15 (thread title as its semibold name), section labels
  = Caption 13, page ask = Title 22.
- **Glyphs:** status marks are filled circles at their own size. Use the
  20-point slot with a flat SF Symbol in Line for a work item's status, and
  the thread's Sprout in the same slot for a thread line (no 16 to 24-point
  sprouts). Nested thread lines then hang at x = 48, under the ask's text.
- **Colour:** neutral system colours here; use the deck's `working`,
  `warning` (needs you), `success`, `failure` roles.
- **Questions:** shown here as a one-line summary under the item; build them
  as the deck's question card under their task.

What the deck doesn't cover yet and this screen needs: thumbnail sizes in
rows (here 22×46 nested, 54×116 on the page; the deck's radius 8 applies),
the indent and spacing of a thread line nested under a row, the folded line
("History 20 ›", "Earlier threads 22 ›") as a row type, and a status
glyph per task status for the slot.
