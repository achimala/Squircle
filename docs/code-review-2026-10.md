# Squircle code review — October 2026

Reviewed 2026-10-14 on `code-review`, against source commit `31692b2e267be51ed9e9928f456e03d9623bf8e7`. This is a fresh source review, not a list of earlier reported problems. Only this document is changed.

**46 findings: 0 critical, 10 high, 30 medium, 6 low.**

## Status (2026-10-14)

Fix waves W1–W10 are merged into main (source version 0.3.0 (56)). Everything
below this section is the original review, kept as the baseline. Current
contracts: [architecture](architecture.md#boundaries-after-the-october-2026-review)
and [CLI design](cli.md).

| Findings | Status | Where |
| --- | --- | --- |
| H01–H05 | Fixed | W1 (`deb9f8b`) |
| A01–A08 | Fixed | W2 (`833b3c4`) |
| T01–T03 | Fixed | W3 (`823c717`) |
| R01–R04 | Fixed | W4 (`e4c3fe0`); W1 calls `Sims::shutdown` on service shutdown |
| N01–N11 | Fixed | W5 (`4502217`); N11's invocation comes from `GET /v1/agents` (W1) and `capabilities` (W9) |
| U01–U03 | Fixed | W6 (`19207cd`), overlay side W7 (`a6ad1f7`): `ConversationHost`, overlay live simulators are previews |
| O01–O03 | Fixed | W7 (`6914444`, `a6ad1f7`) |
| B01–B03 | Fixed | W8 (`9f5a712`) |
| D01–D03, C01 | Fixed | W9 (`dfbc242`); C01 refuses a non-loopback `--server` and adds `POST /v1/t3/threads/{thread}/media` |
| C03 | Fixed | W9 (media help) and W10 (active docs) |
| C02 | **Deferred, in part** | The ownership boundaries it asked for landed with their fixes (thread-addressed sends, `ConversationHost`, one rejection mapping, `DiskCache`). The large files were not split and grew (`SquircleModel.swift` 1,433, `ThreadViewController.swift` 1,625, `SquircleOverlay.swift` 1,449, `server.rs` 2,392 lines); `PhonePose.interpolate`/`visible` are still unused |

**Not yet verified:** step 4 of the fix plan, the coordinated phone and
simulator check (rapid navigation during a delayed send, background/foreground,
Home with live simulators, scene replacement during capture, Reduce Motion,
app/overlay parity), and O03's draw-cost profiling on the phone. N05's and
U01's effect on frame time and bandwidth is not measured. On 2026-10-14 the
Rust suite passed: 100 unit, 6 CLI, 13 HTTP contract and 3 service lifecycle
tests. The CLI's deadline tests, flaky on main, were made deterministic in W10.

## Scope, evidence and severity

The review covers the Rust service and CLI (`src/`), native client (`app/Squircle/Sources/`, including `UI/`), injected overlay, Claude plugin, build configuration, concurrency check, existing tests and relevant architecture/CLI documentation. AGENTS.md and README.md supplied the constraints. Findings below identify concrete control flow, ownership or contract defects; static performance concerns are not presented as measured phone latency.

Validation performed:

- All **82 Rust tests passed**: 64 library tests, 5 CLI tests, 10 HTTP contract tests and 3 service lifecycle tests. The existing toolchain was used offline, with a separate temporary target directory. Execution after compilation took approximately three seconds across the test binaries.
- `scripts/check-swift-concurrency` passed against its existing four-use baseline. This does **not** mean there are no Dispatch calls; see H04.
- An isolated Git fixture reproduced A01: `git cherry main worker` was empty while the trees differed in a unique merge resolution.
- A small harness linked the unmodified Rust library: a request to `/v1/captures?kind=video` without a token polled its body before returning 401 (H01); `add_weak_dylib` panicked for zero- and three-byte input (B01).
- The exact UTF-8 slicing expression in T01 panicked for a JSON string containing 400 `é` characters: byte 700 was not a character boundary. This was an isolated expression probe, not a live T3 response.
- An isolated catalog fixture linked to the unmodified library confirmed that deleting a published preview makes both catalog listing and replacement publication fail (H03). The compiled CLI, run against a fresh temporary media root with umask 022 and an unreachable selected server, returned success while creating a 0755 root and 0644 metadata (C01).

No live T3 commands, builds, simulator sessions, device interaction, credentials, or private app data were used. Native tests require an iOS test destination and were not run. UIKit/Metal findings are source-verified; transitions, GPU timing and physical-device behavior were not visually or experimentally verified. Temporary fixtures and compilation output were removed before delivery.

**Severity:** critical = immediate severe compromise/data destruction with broad exposure; high = data-loss, permission, wrong-destination, or substantial lifecycle failure; medium = bounded reliability/security/performance defect; low = maintainability, portability or accessibility debt. **Effort:** S = localized change; M = a component plus meaningful regression checks; L = ownership/protocol redesign across components. Effort is per finding, with shared work consolidated in the fix plan.

No critical finding was established. T3 ownership remains intact: the enrichment query opens SQLite read-only (`src/t3steps.rs:42`); no service writes to T3's database or independent model runner were found. Existing control/diagnostic token separation, no-follow private-store helpers, immutable preview artifacts, redirect refusal, and process-group cancellation in the main Xcode runner are useful foundations. No APNs registration, token handling or delivery implementation was found to assess. The explicitly accepted team-shared Keychain design is not itself reported as a vulnerability.

## HTTP service, storage and installation

### H01 — Capture bodies are buffered before authentication

**Severity: high · Effort: M**

**Evidence:** `src/server.rs:185-186`, `src/server.rs:1343-1351`, `src/perf.rs:25`. The handler takes `bytes: axum::body::Bytes`; `auth(...)` runs inside the handler, after Axum extracts the entire body. This route allows 300 MiB. The linked-library probe confirmed that an unauthenticated body's producer runs before the 401.

**Impact:** any client able to reach the service can force large allocations without knowing a token. Concurrent requests multiply the cost; deployment behind a private network reduces reachability but does not repair the boundary.

**Fix:** authenticate at router middleware/extractor level before polling request bodies; stream accepted uploads to bounded private temporary files, with upload concurrency limits and cleanup on cancellation. Add an in-process test asserting that rejected credentials never poll the body, plus a bounded accepted-upload test. No large allocation is needed in the tests.

### H02 — File I/O under the global Store mutex blocks authentication and unrelated routes

**Severity: medium · Effort: L**

**Evidence:** `src/server.rs:117` locks the same `std::sync::Mutex<Store>` used by preview publication at `src/server.rs:748-754`. Publication holds it while copying, validating and syncing the preview. Status also scans diagnostic records while holding it (`src/server.rs:299-308`); diagnostic ingestion performs its persistent append under the lock (`src/server.rs:1375-1379`).

**Impact:** moving publication into `spawn_blocking` does not make callers of `auth` nonblocking: their executor threads synchronously wait for that mutex. Slow storage, a large preview or diagnostics file can stall unrelated chat-adjacent service requests. Failed-build status additionally reads the entire build log (`src/server.rs:311-314`) before parsing it, despite bounded paging elsewhere.

**Fix:** separate immutable authentication settings from mutable storage; give independent records/catalog operations their own serialization and perform filesystem work on blocking workers. Bound failure-log reads by tail bytes. Keep durability and concurrent-update checks; do not simply remove the mutex around read/modify/write operations.

### H03 — One missing preview disables the catalog and prevents its own repair

**Severity: medium · Effort: M**

**Evidence:** `src/apps.rs:90` calls `get` for every app and propagates its error. `get` requires the stored preview file to open successfully (`src/apps.rs:111-124`). Re-registration calls `list` (`src/apps.rs:147`), and publishing a replacement starts with `get` (`src/apps.rs:280`; also `src/server.rs:753`).

**Impact:** after an artifact disappears, the app record cannot be listed normally or repaired through preview publication. A broken preview for one app also blocks registration/listing of unrelated apps. A missing screenshot becomes a catalog outage. Both list and replacement failure were reproduced with the unmodified library.

**Fix:** keep metadata identity/path validation separate from artifact availability. Return the app with an unavailable preview state; fail only the artifact download. Permit a new publication to repair missing bytes. Add a fixture that deletes one preview, lists both apps, and successfully republishes the damaged app's preview.

### H04 — A download request is treated as installation progress before any bytes are served

**Severity: medium · Effort: M**

**Evidence:** `src/server.rs:1291-1298` persists `downloaded_at` before opening the IPA; even an ensuing file-open error leaves that flag set. The native install loop consumes this signal (`app/Squircle/Sources/SquircleModel.swift:1014-1017`), and `app/Squircle/Sources/UI/UpdateCurtain.swift:69-75` schedules a Dispatch callback that invokes the private `suspend` selector.

**Impact:** a failed or merely started transfer can make Squircle show the update curtain and background itself. The state name overstates the evidence. The unstructured 2.2-second callback also owns UI behavior outside route/lifecycle state, and is a production Dispatch use retained in the baseline, not DEBUG-only scaffolding.

**Fix:** distinguish requested/opened/transfer-completed/launch-observed evidence; never infer installation from an HTTP request. Make the curtain's lifetime an explicit cancellable state and replace Dispatch when touching this code. Keep user-driven installation/manual launch as the confirmation boundary. Test a missing IPA and an aborted download; inspect the UI manually.

### H05 — New routes bypass the documented JSON error contract

**Severity: medium · Effort: M**

**Evidence:** `src/server.rs:1325` and `src/server.rs:1346-1347` use direct query/body extraction, unlike the explicit rejection conversion at `src/server.rs:1833-1836`. Missing `kind` on `/v1/captures` returns Axum's 400 before the handler and therefore outside Squircle's versioned envelope. Oversized `Bytes` extraction has the same problem. `src/model.rs:146-149` also marks every error `retryable: false`, including temporary service unavailability.

**Impact:** clients cannot uniformly parse or classify failures. Automation gets inconsistent behavior depending on which handler/extractor rejected an otherwise similar request. Authentication is also ordered differently across routes.

**Fix:** use a protected router boundary and shared rejection mapping for query, path, body, size and method errors. Represent retryability as an explicit error property, distinguishing safe read retries from mutations whose acknowledgement is ambiguous. Extend HTTP contract fixtures to malformed/new-route requests; do not retry mutations blindly.

## App-agent coordination and worker cleanup

### A01 — Automatic cleanup can delete unique merge-resolution work

**Severity: high · Effort: M**

**Evidence:** `src/agents.rs:221-223` treats the count of `+` lines from `git cherry base branch` as the complete unmerged-work check. `src/agents.rs:247-250` then uses `git branch -D`, including the non-discard path. `git cherry` does not account for merge commits' unique resolutions.

**Reproduction/impact:** the isolated fixture made conflicting left/right commits, merged them into both `main` and `worker` with different resolutions, and obtained empty `git cherry main worker` output while `git diff main worker -- value` showed distinct content. Cleanup would consider that clean branch safe and force-delete its reference/worktree, dropping unique work without `--discard`.

**Fix:** default to ancestry-safe deletion. If supporting rebased/cherry-picked equivalents, explicitly account for merge commits and reject ambiguous histories; do not treat patch equivalence of non-merge commits as proof for the whole branch. Bind validation and deletion to expected object IDs and recheck worktree state. Add this Git fixture beside the existing cleanup test.

### A02 — Concurrent first use can create multiple agents for one app

**Severity: high · Effort: L**

**Evidence:** `src/agents.rs:479-485` reads the registry, releases its mutex, and awaits `create`; `create` awaits configuration and T3 dispatch before installing the entry (`src/agents.rs:495-515`). No per-project creation reservation exists. The existence filter also treats an agent absent from the not-yet-updated shell projection as nonexistent (`src/agents.rs:482`).

**Impact:** two concurrent initial submissions can create separate T3 agents and send each its own message; the last registry write wins, hiding the other conversation. A sequential retry before shell catch-up can take the same path. This breaks the one-agent-per-app invariant.

**Fix:** serialize per-project creation/reset operations and persist a `creating(threadID)` reservation with stable command identity. Reconcile its outcome after timeout/restart rather than creating a new ID. Distinguish projection lag from confirmed deletion. Test two requests with a gated fake dispatch and delayed shell delivery.

### A03 — The selected approval mode is ignored when an app agent is created or replaced

**Severity: high · Effort: M**

**Evidence:** the native draft supports choosing a runtime mode, but sends only project/message/model to `startAgent` (`app/Squircle/Sources/SquircleModel.swift:674-683`). `EnsureAgent` has no mode field (`src/server.rs:1771-1787`). The service creates the thread with `"runtimeMode": "full-access"` (`src/agents.rs:505-510`); the fresh-thread path also hardcodes it (`src/agents.rs:624`).

**Impact:** choosing Ask before the first message does not constrain that message's execution; the service can start it with full access before the phone has an opportunity to change the thread. Freshening an existing restricted agent likewise loses its saved policy. Defaulting new drafts to Auto is authorized; overriding an explicit selection is not.

**Fix:** carry the chosen mode end-to-end and apply it in the creation command before starting any turn. Preserve the prior agent's mode during replacement; define worker policy explicitly rather than inferring that all threads should be unrestricted. Test first send and fresh replacement with a non-default mode using command fixtures.

### A04 — Worker wake-ups can duplicate and have no reliable retry

**Severity: high · Effort: L**

**Evidence:** `src/agents.rs:398` clears `flush_scheduled` **before** awaiting `flush`. Another shell event can schedule a second flush while the first is in flight. Both read unnotified workers (`src/agents.rs:405-427`) and dispatch fresh random message IDs (`src/agents.rs:453-459`); acknowledgement is followed by a separate registry save (`src/agents.rs:460-466`). Failure is only logged (`src/agents.rs:399-400`).

**Impact:** a slow dispatch, ambiguous timeout or crash after acceptance can send the same completion more than once and trigger extra agent work. Conversely, a failed flush with no subsequent shell event has no scheduled retry, so the agent may never be woken.

**Fix:** one serialized durable outbox per coordinator, with stable event/message identities, explicit in-flight state and bounded backoff. Record/reconcile delivery independently of transient shell traffic. Test overlapping flush triggers, acknowledgement loss, restart between dispatch/save, and retry with no new events.

### A05 — Deferred resets are erased before they succeed

**Severity: medium · Effort: L**

**Evidence:** `src/agents.rs:565-568` takes and persists away `agent.pending` before launching `perform`. `src/agents.rs:576-577` only logs a failure. The replacement sequence performs multiple external operations and registry changes (`src/agents.rs:583-647`) without a recoverable operation record.

**Impact:** a transient T3 failure loses a user-requested restart/fresh start. Failure partway through freshening can leave the new thread selected in the registry without a delivered handoff. The response promising an after-turn reset has no persisted success/failure result the phone can inspect.

**Fix:** model reset as a durable operation with phases and stable old/new thread IDs. Mark it complete only after its required dispatches/handoff are confirmed; retain a retryable or actionable failure. Serialize with A02 and wake delivery. Test failure after each external step, entirely with a fake transport.

### A06 — A second question in the same worker turn can be suppressed

**Severity: medium · Effort: M**

**Evidence:** `src/agents.rs:125-130` forms the wake key from turn ID and coarse worker state. `src/agents.rs:413-415` suppresses a notification when that key equals the saved one. A working interval does not replace the saved needs-you notification with a new request identity.

**Impact:** question/approval A and later question/approval B in the same turn both produce the same needs-you key. Once A has been notified, B can remain waiting without another wake-up.

**Fix:** include the pending request's identity/version in the wake key and persist the exact notified event. Add a pure state fixture for needs-you A → working → needs-you B within one turn, plus duplicate delivery of A.

### A07 — Nested project folders can receive the wrong app-agent context

**Severity: medium · Effort: S**

**Evidence:** `src/agents.rs:681-688` chooses the first agent whose root equals or prefixes the supplied cwd. It does not prioritize exact matches or the deepest root. The plugin invokes this lookup on prompt submission and compaction (`plugin/squircle/hooks/hooks.json:4-7`).

**Impact:** with projects `/repo` and `/repo/examples/App`, the example's agent can receive the parent's thread/worker context depending on registry order. Worker commands copied from that note then use the wrong coordinator. This is a routing defect, not merely a misleading label.

**Fix:** prefer a verified session/thread identity from the hook when available; otherwise canonicalize roots/cwd and choose an unambiguous deepest match, reporting ambiguity. Add nested-root and symlink-alias fixtures.

### A08 — Discard removes a working thread's files before stopping its execution

**Severity: medium · Effort: M**

**Evidence:** `src/agents.rs:879-880` permits a working worker when `discard` is true. Its worktree/branch are removed at `src/agents.rs:892-898`; only afterward is `thread.archive` dispatched (`src/agents.rs:901-902`). No interrupt/stop acknowledgement precedes filesystem removal.

**Impact:** the provider/build process can still be writing in a directory the service deletes. If the later archive command fails, T3 retains an active thread referencing the removed checkout. Authorization to discard work does not give the implementation a coherent process lifecycle.

**Fix:** stop the T3 session and confirm its terminal state before destructive cleanup; journal and report partial cleanup so it can resume safely. Re-read expected branch/worktree identities under the same per-worker operation lock. A fake command-order test should assert that removal is unreachable before stop acknowledgement.

## Rust T3 transport

### T01 — A non-ASCII error can panic the RPC reader and poison pending requests

**Severity: high · Effort: S**

**Evidence:** `src/t3.rs:285-291` slices the JSON error string at `min(len, 700)` **bytes**. Byte 700 need not be a UTF-8 boundary. The slicing expression runs in the body of the `if let` holding the pending-map mutex guard. The isolated probe reproduced the panic.

**Impact:** an ordinary long localized/non-ASCII error can kill the detached reader task and poison the mutex used for subsequent calls. This affects agent/simulator service operations, rather than just truncating one error message.

**Fix:** truncate at a valid character boundary and release map guards before formatting/delivering responses. Add a real receiver unit fixture for multibyte text crossing the limit; assert an error response and successful subsequent request, not only a helper's string length.

### T02 — Heartbeats do not detect a silent connection and writer failure does not close it

**Severity: medium · Effort: M**

**Evidence:** `src/t3.rs:140-142` awaits WebSocket establishment without a surrounding deadline. The heartbeat only queues Ping (`src/t3.rs:158-166`), with no Pong/read deadline. A writer error simply exits that task (`src/t3.rs:149-155`); only the reader sets the shared closed signal (`src/t3.rs:171-191`). Individual request timeouts at `src/t3.rs:211-216` do not invalidate the connection.

**Impact:** a silent peer or one-way socket failure can leave the service believing it is connected while every operation times out and worker updates stop arriving. A send-only heartbeat is not proof of liveness.

**Fix:** supervise connect/read/write/heartbeat as one connection lifetime; bound establishment and unanswered heartbeats, propagate either half's failure, and reconnect with backoff. Use a local fake peer for silent, write-failed and missing-Pong cases; no live T3 tests.

### T03 — Dropping a Rust T3 client does not stop its spawned connection tasks

**Severity: medium · Effort: M**

**Evidence:** `src/t3.rs:149-192` detaches writer, heartbeat and reader tasks without storing handles or a shutdown guard. Both reader and heartbeat retain sender clones; dropping the returned client (`src/t3.rs:193`) does not close that channel or cancel a live socket. Subscriptions also live in the reader's captured map.

**Impact:** abandoning a connection after subscription failure can leave its heartbeat/socket running until the remote end closes, retaining resources across reconnect attempts. Separately, dropping a pending `call` future before its timeout bypasses the explicit timeout-removal path (`src/t3.rs:203-217`), retaining its entry until a response or disconnection.

**Fix:** give the client an owned cancellation lifetime and supervise/join its tasks; remove pending entries with a request guard on all exit paths. Bound the outbound queue. Test client drop and request cancellation against a controllable local peer.

## Simulator service lifecycle

### R01 — Restart recovery can signal an unrelated process through PID reuse

**Severity: high · Effort: M**

**Evidence:** the ledger stores only `recorder_pid` (`src/sims.rs:230`). On recovery, `finish` falls back to that saved number (`src/sims.rs:279-283`); `alive` checks PID existence, not process identity (`src/sims.rs:123-126`). Startup applies this path to old active records (`src/sims.rs:346-350`).

**Impact:** if the original recorder exited and macOS reused its PID, restarting Squircle sends SIGINT to an unrelated process owned by the same user. This was source-traced; no live process was signaled during review.

**Fix:** preserve/validate process creation identity and expected recorder command/device before any recovery signal. Prefer an owned child handle in-process; if recovered identity cannot be established, record an unresolved orphan rather than kill by PID. Test identity-match/mismatch decisions using injected process metadata.

### R02 — Simulator startup is not a rollback-safe transaction

**Severity: high · Effort: L**

**Evidence:** `src/sims.rs:207` opens T3's device session before boot-status checks, file creation and recorder startup. Failures at `src/sims.rs:211-225` do not close it. The child is `kill_on_drop(false)` (`src/sims.rs:220`) and is spawned before a 1.2-second await and durable session registration (`src/sims.rs:222-238`).

**Impact:** cancellation or an error between those operations can leave an open T3 device session and/or a recorder absent from the saved ledger. The watchdog cannot recover an unregistered recorder. The boot timeout drops a subprocess future without configuring child termination as well.

**Fix:** persist an explicit starting reservation before side effects and own all provisional resources in a rollback guard. Commit the recording state only after startup succeeds; on cancellation/failure, reap the child and durably schedule device close. Test each failure/cancellation boundary through an injected process/device interface.

### R03 — Graceful service shutdown leaves recorders running

**Severity: medium · Effort: M**

**Evidence:** `src/server.rs:233-235` detaches agent and simulator service loops. Shutdown signals/waits only for the build cancellation registry (`src/server.rs:257-270`). Simulator recorders explicitly survive handle drop (`src/sims.rs:220`), and their duration watchdog lives in `Sims::run` (`src/sims.rs:352-357`).

**Impact:** stopping the service can leave `simctl recordVideo` recording beyond the normal duration limit until a later service restart performs recovery. T3 device sessions also remain open. Existing service lifecycle tests exercise build recovery, not this ownership path.

**Fix:** add service-wide draining/shutdown, reject new simulator starts, finish or safely cancel/reap active recorders and close their sessions before releasing ownership. Track background task handles. Test with fake recorder processes/session operations, not a simulator.

### R04 — Finalization reports success even when T3 device close fails

**Severity: medium · Effort: M**

**Evidence:** `src/sims.rs:308-310` ignores both unavailable connection and `device.close` errors. `src/sims.rs:312-323` then clears the PID and marks the session finished based solely on media publication; a ledger-update error returns the previous session. There is no pending-close state to retry. Finalization also holds the global operation lock while awaiting compaction (`src/sims.rs:259`, `src/sims.rs:299`).

**Impact:** a temporary disconnect can leave a permanent T3 device session after Squircle claims the recording finished. A slow encoder serializes unrelated simulator starts/stops behind that finalization.

**Fix:** represent stop requested, recorder reaped, media filed and device closed separately in a recoverable finalization record. Retry outstanding close/persistence work; publish precise partial failure. Use per-session exclusion and do encoding outside the global admission lock. Test reconnect during close and ledger-write failure.

## Native model, transport and data ownership

Paths in this section are relative to `app/Squircle/`.

### N01 — Sending an attachment can deliver its message to a different thread after navigation

**Severity: high · Effort: L**

**Evidence:** `Sources/SquircleModel.swift:659-672` captures attachments but not destination/model/mode before awaiting capture upload. After that await it branches on current `selectedSessionID`/`draftIsAgent`, then dispatches using the current ID and settings (`:674-708`). Agent creation and normal creation can select a thread after awaiting (`:680-686`, `:612-620`). The controller then adopts `model.selectedSessionID` after send (`Sources/UI/ThreadViewController.swift:1102-1105`).

**Impact:** start a recording upload in A, navigate to B before it finishes, and A's text/media can be sent to B with A's project instructions. Late creation can also pull selection back. Failed sends restore attachments into the global field (`Sources/SquircleModel.swift:666-668`), potentially another conversation's draft. A MainActor does not prevent this reentrancy.

**Fix:** immutable send context containing destination/draft identity, project, model, mode and attachments; per-conversation draft state; typed send outcome addressed to the initiating controller. Network completion must not implicitly change navigation. Test a gated upload/create with navigation between suspension and completion, including a failed send.

### N02 — Tool details can be merged into the wrong thread after the second await

**Severity: medium · Effort: M**

**Evidence:** `Sources/SquircleModel.swift:721-723` checks the selected thread after `threadSteps`. It then awaits `published` (`:724`). That branch checks selection only for media assignment, while the following details merge and `detailsSince` update (`:729-735`) have no renewed cancellation/identity guard.

**Impact:** if navigation occurs while the media request finishes, old-thread details pollute the new state and advance its cursor. Later legitimate details can be omitted because the new thread's watermark came from another thread.

**Fix:** collect both results first, then commit once to an identity/generation-checked thread state; or update a cache addressed by captured thread ID, never a mutable selected-state slot. Add a two-stage gated response fixture with navigation between the two awaits.

### N03 — Subscription rejection silently leaves the phone connected but stale

**Severity: medium · Effort: M**

**Evidence:** `Sources/T3Gateway.swift:164-168` reports subscription success after writing its request. On an Exit, `:184-188` resumes only ordinary request continuations and silently removes the subscription callback. There is no terminal/error callback to its owner. `Sources/SquircleModel.swift:316-323` marks the connection ready after subscriptions are written.

**Impact:** T3 can reject/end a shell or thread subscription while the socket remains alive; the phone displays Connected and never receives further updates or a reason to resubscribe. This is distinct from socket-disconnect recovery.

**Fix:** typed subscription lifecycle with first-value/readiness and terminal failure/completion. Feed failures into connection or per-thread state with bounded recovery and user-visible persistent errors. Test Exit failure and unexpected success after subscription, without closing the fake socket.

### N04 — HTTP delegates and background observers lack an explicit teardown lifetime

**Severity: medium · Effort: M**

**Evidence:** `Sources/T3Gateway.swift:20-25` and `Sources/SquircleClient.swift:7-16` create URLSessions whose delegate is their owning object; each owner also stores the session. Neither exposes invalidation. `Sources/SquircleModel.swift:968-971` starts a weak-self loop that continues sleeping/iterating even after self disappears. Its network monitor task is also untracked (`Sources/SquircleModel.swift:365-378`): it can exit when another path event discovers the owner is gone, but owner teardown cannot directly cancel its wait.

**Impact:** URLSession retains its delegate until invalidation, so simply releasing the model does not break the cycle. Re-created model/overlay lifetimes can accumulate sessions and dormant observation tasks. Weak captures alone do not cancel an infinite sequence or a session's delegate ownership.

**Fix:** a model-owned explicit close/cancel boundary that invalidates sessions and cancels all watcher tasks; notification loops must return when their weak owner is gone. Avoid relying solely on a delegate's deinit to invalidate its own retaining session. Test repeated create/close with weak lifetime sentinels and stub transports.

### N05 — Cache loading and full conversation reduction execute on the main actor

**Severity: medium · Effort: M**

**Evidence:** model initialization synchronously calls `loadHome` (`Sources/SquircleModel.swift:219`, `:526-528`); selecting a thread synchronously reads/decodes its JSON (`:443`, `:550-552`). `nonisolated` synchronous helpers still execute on their caller's thread. Every consumed thread event reconstructs `messages = conversation()` (`:582`), including sorting/derivation in `Sources/T3ThreadState.swift:57-111` and the model's conversation builder.

**Impact:** cache size and accumulated history directly add work to launch, navigation and streaming frames. These histories contain tool details, not just small labels. This is a verified blocking path; no particular hitch duration is claimed.

**Fix:** load/decode on a cache actor/background task and apply an identity-checked result; maintain incremental thread/message state so a delta does not reparse/sort the full history. Bound records retained for immediate presentation. Measure on a long offline fixture and on-device before claiming a frame-rate improvement.

### N06 — Media and conversation caches grow for the lifetime of the process

**Severity: medium · Effort: M**

**Evidence:** `Sources/AgentStep.swift:177-193` defines unbounded global dictionaries for image bytes, video URLs and media metadata with only getters/setters. `Sources/SquircleModel.swift:99` retains every opened thread; `:983-993` caches each distinct preview version. `Sources/UI/ThreadViewController.swift:92` holds per-thread height maps globally. There is no eviction/memory-warning budget for these stores.

**Impact:** opening many image-rich threads or repeatedly updating previews retains old data indefinitely. Downloaded video cache entries also have no owned disposal policy. In an injected overlay this competes with the host app's memory. The `nonisolated(unsafe)` dictionaries suppress isolation checking rather than establish ownership; no current concurrent-access crash is asserted.

**Fix:** bounded byte/cost-aware caches with explicit MainActor/actor isolation, per-thread retention limits and reference-aware video file cleanup. Clear discardable caches on memory pressure. Test eviction/active-file retention policy, not layout or screenshots.

### N07 — Detached cache writers can overwrite newer state with an older snapshot

**Severity: medium · Effort: M**

**Evidence:** `Sources/SquircleModel.swift:574-577` starts independent detached encode/write tasks for the same thread filename. Neither generation nor sequence is checked before replacement. Home snapshots use the same pattern (`:538-540`), and `Sources/UI/ScreenshotBinding.swift:125-133` independently persists screenshot versions.

**Impact:** atomic writes prevent a torn file but not out-of-order writers. A slower old snapshot can replace a newer one, so offline reopening restores stale conversation or capture state. Canceling the scheduling task does not cancel a writer already detached.

**Fix:** one serial cache writer per key (or one cache actor), coalescing by generation/sequence; reject superseded writes before publishing the file. Test deliberately reversed encode completion and reload the resulting file. Keep this separate from rendering.

### N08 — Failed enrichment and idle-thread media publication have no refresh trigger

**Severity: medium · Effort: M**

**Evidence:** `Sources/SquircleModel.swift:586` advances `stepDetailsCount` when scheduling, before success. `:722-723` swallows a failed request. The regular refresh fetches builds/catalog/agents/simulators, not thread media (`:975-981`); a simulator ending provides one special trigger (`:959-964`). Meanwhile `src/main.rs:913-914` promises `media add` will appear within seconds, but this local file write generates no T3 activity.

**Impact:** a failed final enrichment request can leave tool inputs/screenshots absent until another activity occurs. Publishing ordinary media into an already-idle selected thread likewise need not appear until reselecting or unrelated activity.

**Fix:** advance successful watermarks only after commit; retry failures with bounded backoff while the thread is visible. Provide an explicit media revision/event or visible-thread conditional refresh for independently published media. Test final-event failure/retry and publication with no new T3 activity.

### N09 — Keychain replacement deletes working credentials before an unchecked add

**Severity: medium · Effort: M**

**Evidence:** `Sources/AppConfiguration.swift:51-56` performs `SecItemDelete` followed by `SecItemAdd`, ignoring both statuses. `load` still returns success (`:23-28`). `Sources/T3Gateway.swift:29-35` repeats the delete/add pattern for the T3 credential.

**Impact:** an add failure after a successful delete removes the working shared configuration while the main app continues using its in-memory copy. The injected overlay subsequently appears unpaired, with no actionable error on the app that wrote the configuration. Repeated starts also create avoidable replacement races.

**Fix:** use `SecItemUpdate` with add only for item-not-found; check/report statuses and preserve previous data on failure. Make absence of a sharing group distinct from an update failure. Test the status-handling state machine with a Keychain adapter; preserve the user-approved access group and accessibility class.

### N10 — Signed asset URLs validate host but not origin before adding the T3 bearer

**Severity: medium · Effort: S**

**Evidence:** `Sources/SquircleModel.swift:850-854` accepts any resolved asset URL with the same `host`; `:860-864` attaches the T3 bearer. An absolute `http://same-host/...` or `https://same-host:other-port/...` passes that check. The stricter configured-origin validation does not validate this returned asset URL.

**Impact:** a malformed/compromised asset response can route the credential to a different origin or a plaintext request where transport policy permits it. No hostile response from the installed T3 server was observed; the defect is the incomplete credential boundary in this client.

**Fix:** require a relative asset path or compare HTTPS scheme, normalized host and effective port; reject userinfo and unexpected URL forms. Apply the same check to authenticated downloads. Add pure URL fixtures for protocol-relative URLs, alternate ports, downgrade and valid same-origin paths.

### N11 — Native instructions hardcode one Mac's executable and data directory

**Severity: low · Effort: M**

**Evidence:** `Sources/SquircleModel.swift:694` and `:899-901` embed `/Users/anshu/Documents/ChatGPT/RemoteAppDev/...` in worker prompts. By contrast, `src/agents.rs:160-165` constructs an invocation for the actual executable, data root and server.

**Impact:** a client paired to a relocated checkout/service or another Mac can send workers to a nonexistent binary or the wrong data store. Two instruction generators also drift independently.

**Fix:** expose the service's canonical invocation/capabilities as structured configuration and let both native and plugin instructions use it. Keep host execution details in the agent-neutral service/CLI layer, not UIKit model source. Test a non-default executable/root/server tuple.

## Native presentation and simulator playback

### U01 — Hidden or discarded simulator consumers do not reliably release feeds

**Severity: medium · Effort: L**

**Evidence:** `app/Squircle/Sources/UI/StudioViewController.swift:398-403` keeps updating the selected app's dock without checking that the route is still an app; returning Home only sets its alpha to zero (`:721`). `app/Squircle/Sources/UI/SimulatorViews.swift:591-619` attaches live cells during configuration but pauses only movie players on reuse/window removal. `app/Squircle/Sources/UI/ThreadViewController.swift:932-934` does not detach feeds when cells stop displaying. `SimulatorFeeds` has no owned teardown for streams/notification tasks (`app/Squircle/Sources/UI/SimulatorViews.swift:93-109`, `:134-147`). `app/Squircle/Sources/T3DeviceStream.swift:248-260` retains self across its long-running connection operation until explicitly stopped.

**Impact:** invisible Home/docked/cached cells can keep downloading and decoding simulator video. Discarding a feed owner can leave the stream task alive: its callback sees a dead weak feed and returns, without stopping the task. This wastes cellular traffic and host-app resources; exact bandwidth was not measured.

**Fix:** derive subscriptions from route plus visible consumers, with explicit attach/detach tokens; stop feeds at owner teardown and cancel observer tasks. Keep shared streams only while at least one real consumer is visible. Test subscriber counts and stream close with fake frames; verify Home/overlay transitions by running the app afterward.

### U02 — Home/PiP rendering can be indefinitely postponed by frequent updates

**Severity: medium · Effort: S**

**Evidence:** `app/Squircle/Sources/UI/StudioViewController.swift:129-137` cancels and restarts an 80 ms delay for **every** model update. Rendering therefore requires an 80 ms quiet interval, rather than a bounded refresh cadence.

**Impact:** sustained stream updates arriving faster than that interval can prevent app state/PiP changes from rendering until streaming pauses. The model's observer path used elsewhere already demonstrates a different coalescing approach.

**Fix:** schedule at most one pending frame/bounded-interval render and render the latest state when it fires; do not reset its deadline for every event. This is UI scheduling: inspect it with a sustained synthetic stream and the existing navigation audit, without adding layout-number tests.

### U03 — Live simulator rows in the overlay have a tappable control with no action

**Severity: low · Effort: S**

**Evidence:** `app/Squircle/Sources/UI/ThreadViewController.swift:866` handles a live simulator tap solely with `onExpandSimulator?(use)` and returns. The overlay's shared-controller setup sets feeds/full-screen/attachment callbacks but never sets that callback (`app/Squircle/Overlay/SquircleOverlay.swift:943-963`). Its comment deliberately omits PiP, but that does not provide the inline control's action.

**Impact:** the overlay presents the same live simulator row/button as the app, yet tapping it does nothing and offers no touchable simulator. Shared cell rendering has not guaranteed shared interaction behavior.

**Fix:** provide a host capability for inline simulator expansion/input, or deliberately render a noninteractive preview if that is the chosen overlay behavior. Make required capabilities explicit in the conversation host interface rather than optional callbacks silently defaulting to no-op. Verify both hosts manually.

## Injected overlay, capture and Metal

### O01 — Capture resources can outlive the overlay or skip finalization entirely

**Severity: high · Effort: L**

**Evidence:** `app/Squircle/Overlay/CaptureSession.swift:16-19` stores recording/recorder objects independently. Its screen-stop guard requires a poster **before** calling `finish` (`:50`); a missing poster returns through the defer that drops the recorder. `app/Squircle/Overlay/ScreenRecorder.swift:58-61` registers a display link, but only `finish` invalidates it/detaches touches (`:110-118`). Neither capture owner has a teardown fallback. `app/Squircle/Overlay/SquircleOverlay.swift:50-57` replaces the window when another scene activates; no capture teardown accompanies replacement. The performance sampler's stop is likewise explicit (`app/Squircle/Overlay/PerfRecorder.swift:70`, `:367-372`).

**Impact:** failed/no-frame capture or scene replacement can abandon recorder work, temporary files and display-link/observer resources. The performance sampler's running thread continues until stopped, so the impact extends into the host application's lifetime. The timeout callback has a weak owner and cannot rescue an already-discarded overlay.

**Fix:** model capture as `idle / recording(owned resource) / stopping / completed-or-failed`, with one cancel/finalize path that always stops the producer before deciding whether a thumbnail/result exists. Close captures when changing/disconnecting scenes. Make teardown safe even without a first frame; clean temporary files. Test no-poster, failed-writer and owner-close transitions with resource adapters.

### O02 — Hitch classification applies the final refresh rate to the whole recording

**Severity: medium · Effort: M**

**Evidence:** `app/Squircle/Overlay/PerfRecorder.swift:54-55` overwrites `refresh` every display-link tick. At finish, all frame gaps are reclassified with that final value (`:72-75`, `:114-119`). Background/foreground events are recorded (`:37-41`) but not excluded from that gap classification.

**Impact:** a recording that transitions between 60 and 120 Hz can classify ordinary earlier frames as hitches, or miss earlier late frames. A background interval can be reported as a giant main-thread hitch. The report can direct debugging toward work that did not actually miss its expected frame deadline.

**Fix:** store the expected deadline/period with each frame interval and segment recording on inactive/background boundaries. Export those intervals so the Mac and thumbnail use the same definition. Add tiny deterministic cadence/background fixtures, not visual/performance golden tests.

### O03 — Jelly ignores Reduce Motion and runs a full-rate loop while idle

**Severity: low · Effort: M**

**Evidence:** `app/Squircle/Overlay/GlassJelly.swift:181-195` intentionally runs a preferred 120 Hz display link whenever mounted for breathing/blinking/glancing. Unlike `LiveCapsule`/`SpringDriver`, this path has no Reduce Motion branch. Its main-thread draw also calls `nextDrawable` and `waitUntilScheduled` (`:629-648`).

**Impact:** a user's motion preference does not disable continuous decorative overlay motion. The injected framework also imposes a permanent rendering cost on an otherwise-idle host. The synchronous GPU submission path is a cost to measure; its comments document why transaction-coupled presentation was chosen, so blindly moving `present` would risk reviving that bug.

**Fix:** observe Reduce Motion and provide a still/decoratively quiet state; suspend or lower idle cadence where appropriate, retaining full responsiveness during interaction. Profile the draw/submission cost on the phone before changing transaction synchronization, then verify appearance and motion manually.

## Build tools and binary handling

### B01 — The Mach-O editor panics on malformed headers instead of returning an error

**Severity: medium · Effort: M**

**Evidence:** `src/overlay.rs:303-310` slices magic/fat headers before validating their length. `src/overlay.rs:330-348` reads command headers, dylib-name offsets and segment sections before proving that all those subranges fit the command/slice. The linked-library probe confirmed panics on zero- and three-byte input.

**Impact:** a malformed/truncated archived executable can unwind the build task instead of producing the normal failed-job result. This is an archive-parser robustness issue; the input is not asserted to be an unauthenticated upload/RCE vector.

**Fix:** checked range/arithmetic readers for every header/table/command/section, bounded counts and name offsets, and `Result` errors throughout. Validate all slices before modifying any. Extend the existing parser tests with truncated fat/thin headers, short segment commands and out-of-command name offsets.

### B02 — Overlay signing escapes the build deadline and cancellation machinery

**Severity: medium · Effort: M**

**Evidence:** `src/xcode.rs:80-81` passes cancellation/deadline into framework building but not `overlay::inject`. Its `codesign` helpers await unbounded `Command::output` calls (`src/overlay.rs:232-239`, `:251-268`) without kill-on-drop/process-group ownership. Waiting for the framework lock is also uncancellable (`src/overlay.rs:101-102`).

**Impact:** a stuck signing/keychain subprocess or lock can hold the single build lane after cancellation or past the advertised deadline. The robust main Xcode process runner does not protect these auxiliary subprocesses.

**Fix:** use one bounded subprocess runner for build, injection and metadata helpers, with propagated remaining deadline/cancellation, output limits, child/group reaping and structured errors. Make lock acquisition cancellable. Test with a fake sleeping child and cancellation; no signing/build operation belongs in the tests.

### B03 — Overlay binary reuse is keyed only by source, not the toolchain

**Severity: low · Effort: S**

**Evidence:** `src/overlay.rs:48-82` hashes Sources, Overlay and the pbxproj; `:103-106` trusts any existing framework with that key. It does not include selected Xcode/SDK/compiler version or validate the cached product beyond file existence.

**Impact:** switching Xcode/SDK with unchanged sources silently reuses an older compiled overlay. A partial/damaged cache product can also be selected by existence alone. Build provenance is not reproducible from the cache key.

**Fix:** include effective toolchain/SDK/build-settings identity and a completed-cache manifest/product validation. Publish completed cache directories atomically. Test cache-key changes and incomplete-product rejection using metadata fixtures.

## Tool media, performance reports and local CLI storage

### D01 — Image deduplication conflates different images with the same prefix and length

**Severity: medium · Effort: S**

**Evidence:** `src/t3steps.rs:170-174` identifies an image by base64 length plus its first 64 characters. That is not a content identity; same-format/same-dimension images can share their header and encoded length while differing later.

**Impact:** distinct screenshots from one tool call can disappear or the requested index can resolve to the wrong screenshot. Existing images need not be byte-identical for this filter to collapse them.

**Fix:** hash complete decoded bytes, or at minimum the complete canonical base64 representation; preserve deterministic first-occurrence ordering. Add two same-length, same-prefix, different-payload images and a genuine duplicate to a pure fixture.

### D02 — Home's screenshot fallback accepts arbitrary phone-shaped tool images

**Severity: medium · Effort: M**

**Evidence:** `src/t3steps.rs:239-245` accepts either a named capture tool **or any phone-shaped image**. `app/Squircle/Sources/UI/ScreenshotBinding.swift:31-44` selects the thread-image fallback when no catalog/build preview exists.

**Impact:** a worker reading a phone-shaped mockup/reference/generated image can make that image the app's Home screen, even though no simulator screenshot was taken. This violates the explicit real-screenshot/catalog rule; dimensions cannot establish provenance. No such image was published during this review.

**Fix:** publish/select only verified simulator captures tied to the correct app/session, or use the agreed placeholder until the catalog has a capture. Do not infer capture provenance from aspect ratio or a generic browser snapshot alone. Test source classification with capture and ordinary image-read records; inspect the displayed result manually.

### D03 — An explicitly supplied symbol file bypasses UUID matching

**Severity: medium · Effort: M**

**Evidence:** `src/perf.rs:220-229` returns any `--dsym` path that is a regular file, without checking the capture image's UUID. Directory candidates are UUID-filtered (`:225`), but the file branch is not. `resolve_frames` labels nonempty atos results as exact (`src/perf.rs:337-346`).

**Impact:** passing a DWARF/binary from the wrong build can produce plausible but wrong function attribution presented as exact. With multiple app images, that same first file can be selected for each image. This undermines the performance report's main diagnostic purpose.

**Fix:** UUID/architecture validation for files as well as bundles; only mark resolution exact when the image identity matches. Report mismatches instead of falling back to the supplied file. Bound `dwarfdump`/`atos`/demangling subprocesses too (`src/perf.rs:205-209`, `:274-276`, `:361-367`). Test symbol-source selection with injected tool output, not installed live builds.

### C01 — Direct media commands bypass private-store initialization

**Severity: medium · Effort: M**

**Evidence:** `src/main.rs:909-916` passes `root(cli)` directly to media operations, without `Store::open`. `src/media.rs:90-99` uses ordinary `create_dir_all`/copy and `:119` uses ordinary `fs::write`, unlike the store's private/no-follow helpers. The local path is also used even when `--server` identifies a different service.

**Impact:** on a new data directory with a conventional permissive umask, `media add` can create traversable directories/readable metadata or media instead of enforcing the private-store contract. A successful command against a different local root is not publication to the selected server, despite its success message. The compiled-CLI fixture confirmed success with an unreachable selected server and a 0755 new root/0644 metadata under umask 022. Existing restrictive parent permissions mitigate the first case only after proper initialization.

**Fix:** share canonical private-root initialization, checked paths and private atomic media writes; explicitly distinguish local-only commands from remote publication, or route publication through the authenticated service. Test under a permissive umask in a temporary root and with non-default server/root arguments.

## Structure and documentation debt

### C02 — Presentation hosts and service handlers still have implicit, oversized ownership boundaries

**Severity: low · Effort: L**

**Evidence:** `SquircleModel.swift` is 1,072 lines spanning connection/reconnect, selected navigation data, drafts, cache storage, assets, build installation and app import. `ThreadViewController.swift` is 1,384 lines; `Overlay/SquircleOverlay.swift` is 1,400. App conversation mounting/callback wiring (`Sources/UI/StudioViewController.swift:573` onward) is repeated in the overlay (`Overlay/SquircleOverlay.swift:910-963`). `src/server.rs` is 1,950 lines mixing routes, DTOs, filesystem/build work, lifecycle and tests; agent/simulator handlers are appended after its earlier test section.

**Impact:** the specific failures above show the cost: selected global state leaks across async operations (N01/N02), optional host capabilities diverge (U03), and authentication/extractor contracts vary (H01/H05). This finding is architectural debt, not an additional runtime failure for every long file. `PhonePose.interpolate` and `visible` also remain without consumers beyond their declaration (`Sources/UI/DeviceStage.swift:21-29`), remnants of the retired live stage.

**Fix:** extract ownership boundaries while fixing their defects: a thread-addressed store/send coordinator, connection lifetime, cache/media owner, conversation host capability interface, and feature routers with shared protection/rejections. Keep one actual conversation implementation and small route/spring state. Remove proven unused stage members. Do not mechanically split files into extensions while retaining the same mutable global ownership.

### C03 — Active documentation and CLI help describe superseded implementation/workflows

**Severity: low · Effort: S**

**Evidence:** `docs/architecture.md:60-72` describes the earlier stage/preview arrangement; `app/Squircle/README.md:55` assigns conversation rows to `ThreadViews.swift`, and `:77` labels build 19 as current source. Current code uses `ThreadCells.swift`, still portraits, app-agent-first navigation and later design decisions in AGENTS.md. `src/main.rs:294` also tells media users to run agent-device recording directly, contrary to the current `sim start`/`sim stop` ownership instructions.

**Impact:** a contributor following the required README → relevant-detail workflow gets conflicting guidance about ownership/layout and current validation. CLI help can send a worker around the session recording/visibility workflow. Historical build evidence is useful, but a historical milestone must not be labeled the present implementation.

**Fix:** refresh only active architecture/source pointers and clearly label the old validation entries as history. Describe current code separately from what was physically/visually validated; do not upgrade old evidence into new verification. Documentation review is sufficient.

## Fix plan

The packages below have **exclusive existing-file ownership**, so separate workers can prepare changes without editing the same files. New test files must be package-specific. Cross-boundary signatures should be agreed first; the owning worker implements each side. The finding list is not a request to add broad UI tests or CI.

| Package | Exclusive files/area | Findings and deliverable |
| --- | --- | --- |
| W1 — HTTP/storage boundary | `src/server.rs`, `src/store.rs`, `src/apps.rs`, `src/model.rs`; `tests/http_contract.rs`, `tests/service_lifecycle.rs` | H01–H05; server side of A03/R03/N11. Authenticate before extraction, consistent errors, storage isolation, repairable catalog and honest install evidence. Own server shutdown integration; W4 provides the lifecycle API. |
| W2 — Agent operations | `src/agents.rs`, `plugin/squircle/**` | A01–A08. Conservative cleanup first; then per-project operation serialization, durable wake/reset records and correct context/mode semantics. Add fake-transport and temporary-Git regressions in this module. |
| W3 — Rust connection | `src/t3.rs` | T01–T03. UTF-8 fix first, then supervised connection/request lifetimes, liveness deadlines and bounded queues. Fake peers only. |
| W4 — Simulator service | `src/sims.rs` | R01–R04. Safe process identity, transactional startup, recoverable stop/close, shutdown API and per-session ownership. Agree W1's shutdown call and W3's connection behavior first. |
| W5 — Native state/transport/cache | `app/Squircle/Sources/*.swift` **except `T3DeviceStream.swift`**; `app/Squircle/Tests/T3Tests.swift`, `AppProjectTests.swift`; new state/transport test files; `app/Squircle/project.yml` and `Squircle.xcodeproj/project.pbxproj` if test registration is needed | N01–N11; native side of A03/H04; cache definitions for N06. Thread-addressed operations and typed outcomes, reliable subscriptions, explicit model/session teardown, bounded ordered caches. Return explicit host/stream capabilities for W6/W7; integrate any new test-file registration centrally. |
| W6 — Native presentation/playback | `app/Squircle/Sources/UI/**`, `app/Squircle/Sources/T3DeviceStream.swift`, `app/Squircle/concurrency-baseline.txt` | U01–U03 app/playback side, H04 curtain, N06 height/media-consumer retention, N07 screenshot persistence, N01 controller send completion, D02 fallback. Own shared conversation-host interface for W7. Remove the touched Dispatch use and lower the baseline. Run the app and require navigation stress `violations=0`; inspect transitions frame by frame. |
| W7 — Overlay/capture | `app/Squircle/Overlay/**`; new capture-policy test files | O01–O03; U03 overlay adapter and overlay side of U01. Explicit scene/capture teardown, always-stop recording resources, cadence-correct diagnostics and Reduce Motion. Use W6's interface without editing W6 files. |
| W8 — Build/injection | `src/xcode.rs`, `src/overlay.rs`, `src/preview.rs`, `src/projects.rs`, `src/artifact.rs`, `src/symbolicate.rs` | B01–B03. Checked binary parsing, cancellable bounded helper runner and toolchain-aware cache. Consolidate process helpers only within this owned area; expose an API for W9 if useful. |
| W9 — Media, performance and CLI | `src/t3steps.rs`, `src/media.rs`, `src/perf.rs`, `src/main.rs`, `tests/cli.rs` | D01–D03, C01; CLI side of A03/N11/C03. Correct image identity/provenance and symbol identity; private/local-vs-remote publication contracts and current recording help. Use W1's storage/API interfaces. |
| W10 — Active docs | `README.md`, `docs/architecture.md`, `docs/cli.md`, `docs/t3-native-migration.md`, `app/Squircle/README.md` | C03; document the final boundaries from C02 and new contracts after integration, without changing preserved product decisions or claiming unperformed validation. Leave this review as the baseline. |

**Suggested order:**

1. Land small safety fixes first: H01, A01, A03, T01 and R01. W1/W2/W3/W4/W5 can prepare their owned changes concurrently after agreeing the approval-mode and lifecycle DTOs. Do not bundle large refactors into these fixes.
2. Finish durable agent/recorder/transport lifetimes (W2–W4), native send/state ownership (W5) and capture teardown (W7). W6 owns the UI integration of W5/W7 interfaces. Recoverability tests should cover ambiguous acknowledgements, cancellation and restart, not live agents.
3. Complete HTTP/storage isolation, media/performance/parser work and bounded caches (W1/W5/W8/W9). W8's parser/cancellation work is independent and can start in the first wave. Preserve working authentication, process-group and artifact-integrity checks.
4. Integrate W6/W7 presentation changes and perform one coordinated device/simulator verification through Squircle, including rapid navigation during delayed send, background/foreground, Home with live simulators, scene replacement during capture, Reduce Motion and app/overlay parity. Static review and passing unit tests do not satisfy these visual/lifecycle checks.
5. W10 updates active documentation from the actual integrated result. Keep the regression suite short: byte/protocol parsers, security boundaries, operation journals, identity routing and reconnect/cancellation state deserve tests; layout constants, screenshots, view text and speculative live integration suites do not.
