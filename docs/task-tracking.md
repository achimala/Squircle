# Task tracking (proposal, 2026-10-14)

**Status: proposal, not built.** The user asked for a way for them and the app
agent to keep track of the many requests they send. Only a DEBUG prototype of
the phone UI exists (`TasksPrototype.swift`, `SQUIRCLE_TASKS=sheet|strip|strip-open`,
hard-coded with the Squircle agent's real requests of 2026-10-14).

## Model (service-owned, persisted, per app)

A task is one ask from the user, kept in their own words.

- `id`, `app`, `ask` (the user's words, trimmed), `source_message` (the chat
  message it came from), `created_at`, `order` (user-reorderable)
- `status`: `queued` / `in_progress` / `needs_you` / `ready_to_try` / `done` / `dropped`
- `note`: a few words on what it waits for ("pick a layout", "after: X")
- `threads`: linked worker threads; `builds`: linked builds
- `history`: status changes with time and who made them (agent or user)

## Agent side

An agent-neutral `squircle task` CLI with `--help` and `--json`:
`add`, `update ID --status --note`, `link ID --thread|--build`, `list [--open]`.
The plugin tells the agent it can use it; no imposed workflow. The service's
per-turn note lists open tasks, so they survive compaction. Linking a thread or
build could move status by itself (worker running → in progress, build
ready → ready to try), but the agent or user always has the final word.

## Phone

Two prototype layouts:

- **A, Tasks sheet:** a button beside Threads and Builds; grouped
  Needs you / In progress / Ready to try / Queued; Done folds into one line;
  Install inline; "All threads" at the bottom (Tasks absorbing Threads).
- **B, strip above the field:** one glass line of counts in the conversation;
  tapping it rises into the open tasks, one line each.

Both: tap opens the linked thread or build; swipe to drop; drag to reorder;
+ adds a task directly.
