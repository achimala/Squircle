# Agent-friendly CLI

Executable name: `squircle`. See [workflow](verification.md) (also
`squircle help workflow`) for runnable examples.

## Boundary and discovery

The same deterministic build/install/diagnostic operations serve T3's app agents and
workers, other agents such as OpenClaw, CI, and a human terminal. Callers need access to this Mac and its
signing environment. The calling agent supplies planning, identity, and memory.

1. `squircle --help`: purpose, command groups, next help command.
2. `squircle build start --help`: arguments and side effects.
3. `squircle help workflow`: build → installation → diagnostics walkthrough.
4. `squircle capabilities --json`: implemented operations, limits and
   `invocation`, the exact command line (binary, `--data-dir`, `--server`) to
   call this CLI with.
5. `squircle doctor --json`: read-only Xcode and signing inventory.

A future short skill can point agents at this live help. MCP and coordinator
plugins are optional adapters; neither belongs in the core dependency graph.

## Implemented commands

| Command | Result |
| --- | --- |
| `init`, `serve` | Private state/credentials; foreground HTTP service |
| `service install`, `service start`, `service uninstall` | Install writes and loads a launchd user agent (`dev.squircle.service`, RunAtLoad, KeepAlive unless it exited cleanly) from the running service's serve arguments and environment, handing its sessions over. launchd runs a signed copy from `~/Library/Application Support/dev.squircle.service` (one TCC grant survives rebuilds); each install, restart and start first checks the copy can read the data directory under launchd and otherwise says what to grant. Restart re-copies the source binary, then `launchctl kickstart -k`; a stop stays stopped until `service start` |
| `service restart`, `service stop` | Restart hands simulator sessions over to a new process running the same command line (recorders keep going, T3 device sessions stay open), builds nothing and returns once it answers; stop ends them. SIGTERM to `serve` is the handover, SIGINT a stop |
| `auth show --scope diagnostics` | Explicitly reveal the phone upload credential |
| `build start` | Durable job ID; archive/export or unsigned simulator mode. Non-App-Store device exports get the debug overlay injected unless `--no-overlay` |
| `build list`, `build status ID` | Job records (flat, as saved, plus `revision`, and `persistence_error` when a finished result couldn't be saved) and launch acknowledgement; `status` of a failed job adds `failure` (failing step, exit status, Xcode `error:` lines with file, line and source excerpt, failed commands) read from its log |
| `build wait ID --timeout 60` | Completion or bounded timeout; no implicit cancellation |
| `build cancel ID` | Cancel that queued/running job |
| `build log ID --offset N --limit N` | Bounded compiler log, byte cursor |
| `build import --ipa PATH` | Private copy of an existing IPA; no signature certification |
| `app browse --path PATH` | Browse one Mac directory; omit the path to start at the service user's home |
| `app inspect --project PATH --scheme SCHEME` | Discover schemes and inspect iOS application/signing settings without building |
| `app import --project PATH --scheme SCHEME --name NAME` | Persist app identity and its archive recipe without starting a build |
| `app list`, `app show ID`, `app register` | Persistent app catalog; `register` adds metadata only, without a build recipe |
| `app update ID --name NAME --summary TEXT` | Edit app metadata without replacing its identity or preview |
| `app preview ID --file PATH` | Publish a real PNG as the app's latest immutable preview artifact |
| `preview capture BUILD_ID --simulator UUID` | Build-associated capture on an explicitly selected simulator |
| `install-link ID --ttl-seconds 3600` | Expiring HTML page, manifest and IPA URLs |
| `media add --thread T3_ID --file PATH --caption TEXT` | Publish an mp4/mov/png/jpg into a T3 thread; Squircle shows it inline. Writes this Mac's data directory (private whatever the umask) and refuses a non-loopback `--server`; the service's `POST /v1/t3/threads/{thread}/media` does the same remotely. Simulator flows use `sim start`/`sim stop`, which file their own recordings |
| `media list --thread T3_ID` | Media published into that thread |
| `sim start --thread T3_ID [--device NAME\|UDID]` | Open, boot and record a simulator for that thread; returns the agent-device command. The phone shows it live. Past `SQUIRCLE_MAX_SIMULATORS` it returns `status: queued` with the thread's place in a first-come line; the service wakes the thread with a `[simulator ready]` message when a slot is held for it, and the next `sim start` takes it |
| `sim stop --thread T3_ID`, `sim status [--thread T3_ID]`, `sim devices` | File the recording in the turn, close T3's device session and shut the simulator down (or leave the line) (also when T3 currently shows the turn ended for 8 s; an unknown T3 state, or a turn waiting on the user, never ends it); every booted simulator with its owner (session, T3 device session, agent outside a session, or unowned: not proven created or booted by Squircle or its agents) plus sessions; simulators in use. JSON keeps its flat session keys plus `device_session` (`{phase: opening\|open\|close_owed\|closed, …}`; a close is never given up) |
| `sim cleanup [--dry-run]` | Apply the simulator policy now: shut down simulators Squircle or its agents booted that nothing holds, delete agent-created ones unused for a day. The service applies it every minute (`SQUIRCLE_SIM_IDLE_MINUTES`, default 10); at most `SQUIRCLE_MAX_SIMULATORS` sessions (default 3) |
| `sim prune [--dry-run]`, `sim keep add\|remove\|list DEVICE` | Delete shut-down simulators unused for `SQUIRCLE_SIM_STALE_DAYS` (default 14) whoever made them, never one on the owner's keep list (`DATA_DIR/sim-keep.json`, exact name or UDID), booted, in a session or open in T3; the dry run lists them with `bytes` and `freed`. The service applies it every minute |
| `logs ID --since N --limit N` | Persisted diagnostic events, record cursor |
| `crashes ID --since N --limit N` | Crash events only, same record cursor |
| `symbolicate --report PATH --dsym PATH` | Local Xcode symbolication attempt for Apple-text reports |
| `diagnostics send --file PATH` | Upload one diagnostic JSON fixture |
| `perf show PATH\|ID [--dsym PATH]` | A performance recording from the phone's overlay: worst hitches with symbolicated main-thread stacks, heaviest functions, per-second timeline, app log (older captures only); text, or `--json` |
| `perf list` | Performance captures and screen recordings uploaded from the phone (`POST /v1/captures`: authenticated before the body is read, each streamed to its own private file) |

`install-link` does not install or remotely launch an app. Its ticket records
`download_started_at` when the service opens the IPA and `downloaded_at` once
every byte was handed to the connection (`GET /v1/install-links/{token}`).
Neither is installation: iOS fetches the IPA after the person confirms the
prompt, and may still fail. A `launch_observed` flag reflects an authenticated
diagnostic event, not independent OS attestation.

## One agent per app

The app agent is a T3 thread on T3's "squircle" Claude instance, in the
project's folder; workers are T3 threads in their own worktrees. How it works
is up to what you tell it. Once per
Mac: `squircle t3 connect` (pipe a T3 pairing token on stdin; restart
`serve`), then `squircle agent setup` (installs `plugin/squircle` into the data
directory and adds the T3 instance; `--remove` takes it out).

| Command | Result |
| --- | --- |
| `t3 connect --url URL`, `t3 status` | Service's own T3 session; connection state |
| `agent start --project T3_ID [--message TEXT] [--runtime-mode MODE]` | Create or find the app's agent and send it a message. `MODE` (`approval-required`, `auto-accept-edits`, `auto`, `full-access`) applies when the thread is created, before its first turn; default `full-access`. Concurrent first sends create one agent |
| `agent restart --project ID\|--thread ID` | Relaunch the agent's Claude session on the same thread; its next turn gets the current instructions (once, in the turn note) with history kept. Runs when the agent's turn ends |
| `agent fresh --project ID\|--thread ID [--handoff TEXT]` | Replace the agent with a new thread seeded by a handoff (app, recent commits, workers, recent user messages, last reply, the note); the old thread is renamed "… (until DATE)" and stays in Threads; workers move over. Runs when the agent's turn ends |
| `agent compact --project ID\|--thread ID` | Claude's `/compact` now, keeping tasks, decisions, running work and recent exchanges; refused while a turn runs. The service also compacts or starts fresh idle agents with a large context by itself (see [agent memory](t3-native-migration.md#2026-10-15-agent-memory); `SQUIRCLE_COMPACT_TOKENS`, `SQUIRCLE_COMPACT_IDLE_MINUTES`, `SQUIRCLE_FRESH_TOKENS`, `SQUIRCLE_FRESH_IDLE_MINUTES`, `SQUIRCLE_NIGHTLY_FRESH_HOUR`, `SQUIRCLE_NIGHTLY_FRESH_TOKENS`) |
| `history search WORDS [--in SOURCES] [--since 7d] [--limit N]`, `history show REF [--max-chars N]` | Read-only search of the app's past where it lives: T3 messages, thread titles and tool activity (`state.sqlite`, read-only), tasks, builds, git commits and Markdown docs, read on each search (no index or copy) and ranked; short snippets with references (`msg:`, `thread:`, `act:`, `task:`, `build:`, `commit:`, `doc:PATH#L12`) that `show` expands. The app is the project of `--thread`/`--project`, else of the current folder. Text, or `--json` |
| `notes show\|add TEXT\|edit N TEXT\|remove N [--thread ID]` | The app agent's few durable notes (preferences, decisions, gotchas; 300 characters each, 4000 in all), listed in each turn's note |
| `agent list`, `agent context [--hook]` | Agents (with `cli`, the service's own invocation); the per-turn note (thread ID, live workers) its hook injects, for the deepest project root containing the folder |
| `thread spawn --coordinator ID --title T --branch B --prompt P [--provider codex] [--model M] [--effort E] [--runtime-mode M]` | Worker thread in its own worktree, branched from the checkout's current branch; Claude by default, any ready T3 provider/model/effort (checked against T3's server config); runs in its agent's runtime mode unless overridden (`auto` stays auto on Claude, Codex, Cursor and Grok; Antigravity takes auto-edit), and the result's `permissions` says what that allows on the provider; an approval prompt makes it needs-you. The worker is saved with its thread and message IDs before T3 is asked; if T3 doesn't confirm, running the same spawn again finishes that worker (`existing: true`) instead of starting another |
| `thread send ID TEXT`, `thread read ID`, `thread answer ID TEXT` | Message, inspect (last reply, diff stat, pending question), answer |
| `thread status [--coordinator ID]`, `thread archive ID [--discard]` | Worker states; archive after merge removes the worktree and deletes the branch, refusing unmerged work or uncommitted changes unless `--discard`. Merged means the base contains the tip, or `git cherry` matches every commit and the branch has no merge commits; only the inspected tip is deleted. A worker still working or waiting on a question needs `--discard`; an idle session is stopped first. Files go only after T3 shows the session stopped (30 s limit, otherwise nothing is removed), and only while the service's view of T3 is current ("try again" otherwise). `status` shows `starting` for a reserved worker T3 hasn't confirmed and `archiving` between file removal and T3's archive |
| `thread cleanup --coordinator ID [--dry-run]` | Archive finished workers whose work is merged, delete merged branches of earlier archived workers, prune stale worktrees; lists what it leaves and why |

The service wakes the agent with a `[worker update]` turn when a worker
finishes, errors or needs input, once per turn outcome (a second question in
the same turn wakes it again). Wake-ups and restart/fresh requests are saved
and retried until T3 accepts them, under the same message ID. `agent
restart`/`fresh` run only while T3 currently shows the agent's turn ended;
a turn that starts in the meantime defers them again. Agents never poll.

## Notifications

The service sends the phone notifications and its Live Activity directly to
APNs with your own auth key (no relay; a relay would replace only the
transport). See [notifications](t3-native-migration.md#2026-10-14-notifications-and-the-live-activity-030-51)
for creating the key.

| Command | Result |
| --- | --- |
| `push setup --key-file AuthKey_ID.p8 --key-id ID --team-id TEAM [--remove]` | Check and store the key owner-only in the data directory; never printed. Works without the service |
| `push test [--live-activity]` | Send a test notification (and start a test Live Activity) to registered phones; per-device result |
| `push status` | Whether a key is set, registered phones (environment, notifications, Live Activity), no tokens |

## Import an existing app

The native **+ → Mac browser or pasted path → scheme/name → Add** flow uses the
same service operations available to any agent:

```sh
squircle app browse --path ~/Projects --json
squircle app inspect --project /path/Atlas.xcworkspace --json
squircle app import --project /path/Atlas.xcworkspace --scheme Atlas --name Atlas --json
```

Inspection accepts optional `--scheme` and `--configuration`; import defaults to
`Release` and also accepts `--configuration`. Paths refer to the service's Mac.
The authenticated APIs are `GET /v1/projects?path=…`,
`GET /v1/projects/inspect?project=…&scheme=…&configuration=…` and
`POST /v1/apps/import` with `project`, `scheme`, `name` and optional
`configuration`. Responses use the ordinary `ok`/`data` envelope.

Import inspects the project and persists a `build_request` in its app record.
The client prefers that recipe over historical jobs, enabling the first build
without an earlier CLI build. Reimporting the same canonical project/scheme
keeps its app identity. Import does not start Xcode compilation or publish a
preview. A missing signing team can return `can_import: true` with an `issue`
warning; unsupported/non-iOS schemes cannot be imported. Device signing is
proven only by an actual successful build with Xcode configured.

Real CLI/API inspection and native import, browsing and relaunch checks pass.
Saved archive recipes allow Xcode provisioning updates when a later build is
requested; import itself does not change signing or register a device.
Existing `app register` remains a metadata-only operation.

## App metadata and previews

The Mac catalog is the source of truth for app names, summaries and screenshots.
Discover an app with `app list`. Use `app import` to save a build recipe, or
`app register --project PATH --scheme SCHEME --name NAME` for metadata alone.
Re-registration is idempotent and preserves edited text. Use
`app update ID --summary TEXT` after meaningful changes; `--name` is optional.

After UI work, capture the running app's actual simulator screen, inspect it,
then publish `app preview ID --file PATH --caption TEXT`. This publication needs
no new build. The ID is the persistent **app ID**, not a build or preview ID.
Optional `--build BUILD_ID` and `--source-revision REV` provenance must describe
the supplied pixels accurately. A source label is recorded provenance, not independent proof
of what the screenshot contains. Read each command's `--help` for current flags.

Each publication validates a regular PNG file (signature, bounded chunks and
nonzero dimensions; maximum 20 MiB), makes a private copy and assigns a new preview
UUID. Existing image files are immutable. The app record points to the latest
preview and retains timestamp, caption and optional build/revision association.
`captured_at` is simulator capture-completion time for built-in captures; for
agent-supplied files it is server publication time, not an inferred file-creation
time. `updated_at` records app metadata changes. Published files use source
`agent`; built-in captures use `simulator`. Supplying a build ID checks the app
association but does not establish that the pixels came from that exact binary.
The client fetches the image through authenticated HTTP. It displays an empty or
unavailable state when there is no capture; it must not substitute generated UI.
An app whose preview file has gone missing still lists, with
`preview_unavailable: true`; publishing a new preview repairs it.

Build capture is optional (`build start --preview`), runs in the same worker lane
as Xcode, and requires a dedicated simulator configured by UUID. Capture failure
preserves the IPA and any previous image. Simulator builds reuse their product;
archive previews rebuild the current working tree, so they must not claim to be
pixels from a frozen archived revision. App synchronization accepts only newer
captures and does not overwrite edited names/summaries. 

## Output and persistence contract

- `--json` emits one versioned result on stdout: `schema_version: 1`, `ok`, and
  `data` or `error`. Default output is pretty JSON. Help is human-readable text.
- Exit 0 means command success; exit 2 means invalid input, failed operation, or
  unsuccessful/timed-out wait. Successful submission is not build completion.
- Errors contain `code`, `message`, `retryable`, and `next_step`, from the CLI
  and from every service route (including malformed query, path, body, size
  and method). `retryable: true` means the request was refused before any side
  effect and may be sent again unchanged (`service_draining`,
  `inspection_busy`); a failed mutation whose outcome is unknown is not
  retryable. Build logs live in files rather than expanding tool-result context.
- Stable request IDs deduplicate identical build submissions; changed arguments
  with an existing ID are rejected. Records and artifacts survive agent sessions.
- Git revision/dirty state are best-effort submission-time observations. The
  working tree is not snapshotted; queued builds may see later edits.
- Jobs retain app identity, archive/IPA/app paths and associated dSYMs. The service
  reports unfinished jobs as interrupted after restart; it does not resume Xcode.
- Saved job records are validated on load (origin, state, output and preview
  must agree); a contradictory one is skipped with a stderr message, not
  repaired. The service reads `jobs/` once at start and serves builds from
  memory afterwards.
- Log/diagnostic reads are bounded and paginated. `build list` currently returns
  all records. `task list --all` returns History a page at a time (see
  [tasks](task-tracking.md#model)). There is no streaming CLI mode, retention deletion or log rotation.

`SQUIRCLE_DATA_DIR`/`--data-dir` select the private store. `SQUIRCLE_SERVER`/
`--server` select the API address. Credentials come from the local store; they are
not placed in command-line arguments. Control requests use a different token from
phone uploads. The service defaults to loopback and requires user-provided HTTPS
for phone access. See [lifecycle limits](verification.md#limits-and-lifecycle).

## Compatibility acceptance

Automated CLI tests run with an empty `PATH`, without an agent executable or
running service for discovery. HTTP tests exercise the same core implementation
used by the phone. T3's app agents and workers use it for builds, simulators
and tasks; earlier Hermes runs used it too
([archived evidence](archive/validation.md)). OpenClaw invocation has not been
tried. No agent installation is required to use Squircle directly.
