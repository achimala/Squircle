# Squircle: second code review

2026-10-15. Reviewed `6d12e9911539ed649e9abb62142837f6a6b2d7ce` on `code-review-b` (build 57), including the ten packages following [the first review](code-review-2026-10.md), tasks, push/Live Activity, chat actions, simulator stacking, reconnect, provider configuration, install tracking and worker runtime modes.

**28 findings: 0 critical, 4 high, 22 medium, 2 low.** No application, service, CLI, plugin or test source was changed. References below are repository-relative `file:line` locations at the reviewed commit. The `B-` prefix distinguishes these findings from the first review. The state-ownership section incorporates the user's addendum and is part of the review, not an optional style appendix.

Main advanced during the review through `48fbe45` (build 59: Home portrait recovery, the delegated-work guard and Tasks swipe handling). Diffs touching cited agent/model/Studio code were checked for overlap; they do not resolve these findings. The new guard and swipe implementations are outside the behavioral review's snapshot and must be preserved when implementing these packages. Connection-speed profiling belongs to another worker: no connection timings were collected here.

## Scope and evidence

AGENTS.md and README.md were read first, followed by the relevant migration, task, CLI and previous-review documentation. The review follows ownership and failure paths across `src/`, the native model/gateway, `Sources/UI/`, app push registration, shared ActivityKit types/widgets, the overlay/capture/Metal code and the Claude plugin. Performance findings identify actual repeated operations or unbounded resources; they are not estimates of measured latency, battery drain or frame time.

Validation against unmodified source:

- **124 Rust tests passed:** 102 library, 6 CLI, 13 HTTP contract and 3 service-lifecycle tests. Used the existing local toolchain offline and a temporary target directory. Two initially sandbox-blocked tests passed when allowed their local fake HTTP socket and process inspection. No live server was involved.
- `scripts/check-swift-concurrency` passed. This is the repository's baseline check, not a claim that every concurrency/lifetime path is correct.
- A temporary harness using the production task implementation reproduced B-T01, B-T02 and B-T03. It also compiled the unmodified `src/xcode.rs` runner and reproduced B-B01 with a shell-owned child; that child was explicitly killed afterward.
- A temporary Swift executable compiled the unmodified `SquircleAction.swift` and reproduced B-U01.
- No live T3 commands, builds, simulator sessions, APNs requests, phone profiling or private app-state queries were performed. Native XCTest requires an iOS destination and was not run. UIKit/Metal behavior is source-reviewed, not visually verified. Temporary probes and compilation output were removed before delivery.

Severity: **high** means loss of work, wrong execution lifecycle or a substantially broken core flow; **medium** means a bounded correctness, reliability or resource-cost defect; **low** means maintainability debt. **S/M/L** estimates a localized fix / component-level change / ownership or persistence redesign, including useful validation. No critical issue was established. T3 still owns execution; enrichment opens its SQLite database read-only. The accepted shared Keychain group is not a new security finding.

## Invalid states and single sources of truth

**Yes: several core paths still require separately mutable values to agree.** The clearest failures are model/controller conversation identity (B-N01), a cached state paired with unrelated rendered rows (B-S01 below), execution lifetime inferred from a display status (B-A01/B-A02), tasks comparing stale observations (B-T01–B-T03), and “sent” push state committed before delivery (B-P01). These are ownership problems; adding another completion-handler guard will not establish the invariant.

A cache or replica is not inherently a second authority. T3 owns thread execution; Squircle owns its task records, operation journals and recordings; UIKit owns presentation mechanics. A replica should carry an origin, revision and freshness, and have a single reducer. Desired state and observed state can differ legitimately, but that difference must be an explicit pending operation. Types can prevent local contradictions; distributed acceptance still needs stable operation IDs, persistence and reconciliation.

### B-S01 — Cached thread state and rendered messages can describe different revisions

**Severity: medium · Effort: M**

**Evidence:** `CachedThread` independently stores `state` and `messages` (`app/Squircle/Sources/SquircleModel.swift:136`). `consumeThread` updates state and starts asynchronous reduction, then immediately caches the current state with the previous messages (`781`–`782`, `739`–`741`). When a reduction completes, it also pairs its captured snapshot's rows with **current** `model.state` (`766`–`772`), which may already have advanced. `show` trusts cached rows without deriving them again (`612`–`618`).

**Failure/impact:** receive revision N+1 while N's row conversion is in flight, then navigate away before conversion catches up. The cache can claim state N+1 while carrying rows N (or earlier). Reopening uses those rows alongside requests/running state derived from N+1. Without a subsequent live update, the missing content is not repaired. This follows directly from assignment order; no phone reproduction is claimed.

**Concrete ownership change:** cache `ThreadSnapshot(threadID, revision, state)` as the authority. A `RenderedTranscript(snapshotIdentity, rows)` may only be paired with that exact immutable snapshot; use a private initializer or reducer that accepts the snapshot, not two unrelated arguments. On async completion, either install the matching snapshot/render pair or discard the obsolete render. Never stamp old rows with a new state's revision. Include a gated old-render/new-state/reopen fixture.

**Previous review:** an incomplete **N05** fix: off-actor work introduced a revision boundary that its cache representation does not encode. N07's ordered disk writes do not fix this in-memory mismatch. **Owner: W6**, with W7 consuming the versioned render value.

### B-S02 — Lifecycle invariants remain conventions across flags, optionals and string statuses

**Severity: low · Effort: L**

**Evidence and concrete changes:** the inventory below records each distinct ownership boundary found in the requested areas. It is a decomposition of this architectural finding and the already-counted behavioral findings, **not another 30 independent bug claims**. Entries linked to a behavioral ID inherit that finding's severity; entries marked **low** are source-confirmed representational debt without a reproduced failure. Each entry gives its own implementation effort. This keeps speculative symptoms out of the severity totals.

#### iPhone model, navigation and rendering

| Boundary and evidence | Bad state currently representable; concrete replacement | Finding / effort / owner |
| --- | --- | --- |
| **Conversation identity:** `SquircleModel.swift:19`, `32`; `UI/ThreadViewController.swift:113`, `116`; `UI/StudioViewController.swift:70`–`76`. | Route, selected project, model `open`, controller `sessionID` and mounted thread key must agree. Nil means every draft to the controller, while the model distinguishes draft UUIDs. Give host and controller the same `ConversationID = draft(DraftID, AppID, Kind) / thread(ThreadID, AppID)`; model access is through that addressed store. Creation returns an identity transition even on send failure. A controller must never infer its identity from whichever conversation is globally selected. | B-N01; **M**, W6/W7 |
| **Pending sends:** `SquircleModel.swift:129`, `852`, `887`; `UI/ThreadViewController.swift:118`, `1339`–`1352`. | Model `submitting`, controller `sending`, pending echo, cleared composer and restored attachment fields are separate records of one operation. Use one `PendingSend` keyed by stable message ID with `preparing / creating / awaitingAcceptance / accepted / rejected / outcomeUnknown` associated data. Composer availability and echo are projections. A lost acknowledgement cannot become a fresh message by accident. | B-N01/B-N05; **M**, W6/W7 |
| **Connection/subscriptions:** `SquircleModel.swift:34`–`38`, `108`–`123`, `413`; `T3Gateway.swift:205`. | `connected`, loading/status text, socket existence, subscription IDs, connector task and suspended state can disagree. Use `ConnectionPhase = stopped / suspended / connecting(Attempt) / ready(Session) / retrying(Failure, deadline)`; a ReadySession requires live shell/device leases and owns the optional addressed thread subscription. Derive labels/buttons. Every callback carries the attempt ID. | B-N02; **M**, W6 |
| **Thread projections and optimistic choices:** `SquircleModel.swift:52`–`57`, `100`, `612`–`621`, `780`–`800`, `1171`. | Requests, changes and running state are copied from `T3ThreadState`, then independently edited; model/mode also exist in live JSON, pending maps and current fields. Keep `ObservedThread` plus typed `PendingCommand`/`DraftPreferences`, and derive the displayed requests/phase/selection. An approval response becomes `responding(requestID, commandID)` until observed acceptance, not deletion from one copied request list. Pending model choice is legitimate local intent, not a second server fact. | low; **M**, W6 |
| **Rendered/cached/live revisions:** `SquircleModel.swift:136`, `734`, `741`, `766`–`772`; `T3ThreadState.swift:5`, `18`. | Raw state, row array, memory cache and disk cache lack a shared render revision; `sequence = -1` plus `fromCache` encodes provenance indirectly. Use `ThreadSnapshot<Origin>` with `cached / live(connectionEpoch, sequence)`, and a render keyed to that snapshot. Disk data is a versioned projection and never promotes itself to live authority. | B-S01/B-E03; **M**, W6/W7 |
| **Phone task edits versus service tasks:** `SquircleModel.swift:1277`–`1287` mutates the local task status before the HTTP result; `ClientModels.swift:326` is the service projection. | The displayed task and authoritative task are independently mutable, with an error/refresh expected to reconcile them. Keep `ObservedTask(revision)` immutable and overlay `PendingTaskEdit(commandID, baseRevision, change, outcome)` in one selector. Apply responses only to their edit generation; represent rejection/unknown acceptance explicitly. The later build-59 `taskEdits` map improves refresh masking but should adopt this same generation/receipt contract, not become another authority. | low; **M**, W6/W3 |
| **Provider/config and metadata freshness:** `SquircleModel.swift:119`–`120`, `451`, `1247`. | Empty providers cannot distinguish not requested, valid empty or failed; timestamp and loader task are separate. Metadata ownership is represented by timers and retained selection rather than consumers. Use `ResourceState<Value> = absent / loading(previous, attempt) / ready(value, version, fetchedAt) / failed(previous, failure, retryAt)`, plus a set of active consumer leases. One refresh owner derives due work. | B-N03/B-E01; **M**, W6 |
| **Media/upload state:** `SquircleModel.swift:41`, `829`, `1289`–`1302`; `AgentStep.swift:231`. | Attachment existence, upload Task, successful receipt, downloaded Data and file URL live in unrelated maps. Use `AttachmentTransfer = local(source) / uploading(operation) / remote(receipt) / failed(source, reason)` and a single `MediaFileLease` owner for downloads/player retention. Cached thumbnails are derived by media content/version identity. | B-N04/B-M01/B-M02; **M**, W6 |
| **Mounting versus destination:** `UI/StudioViewController.swift:70`–`81`, `456`; `UI/ThreadViewController.swift:588`. | The destination route and currently mounted offscreen content are legitimately different during a transition, but `(selectedID?, agent?)` and `(threadKey?, thread?)` can be half-present. Replace each pair with `MountedConversation(id, controller, host)` or nil; keep `Destination` separate from `Presentation`. `sync()` is the only mount reconciler and only replaces offscreen content. Controllers receive activation from this owner, not an empty `deactivate()` convention. | low; **M**, W7 |
| **Chat row/action identity:** `UI/ThreadViewController.swift:699`, `758`; `SquircleAction.swift:123`, `202`. | Rows are rebuilt and resolved from mutable global worker/build catalogs; shell text serves as an ersatz operation receipt. Use immutable `TurnPresentation(revision)` and `ActionReceipt(operationID, kind, typed target, outcome)`; unresolved shell output remains an unresolved action. No generic UUID can masquerade as a worker or build target. | B-E03/B-U01; **M**, W7 |
| **Simulator deck destination/presentation/visibility:** `UI/SimulatorViews.swift:211`–`215`, `393`, `507`, `517`. | `wantFanned`, `expanded`, `wantExpanded`, alpha and input/feed eligibility use different predicates. Replace desired flags with `DockRoute = collapsed / fanned / expanded(SessionID)` and retain a separate typed presentation slot for outgoing/incoming pictures. Derive a single `FrameProjection` containing frame, visibility, input owner and required feed leases. Use the route for immediate input ownership and presentation only for geometry/occlusion. | B-U02/B-U03; **M**, W8 |
| **Simulator source/playback:** `UI/SimulatorViews.swift:6`–`16`, `81`–`93`, `723`–`725`. | `live` plus optional recording permits “recorded but no recording”; `player`, `looper`, `playing` URL and stream consumer state are separate. Use `SimulatorContent = live(SessionID, Target) / filing(SessionID) / recording(MediaID) / unavailable(reason)` and `Playback = stopped / live(FeedLease) / recorded(PlayerBundle)`. App activity and terminal close should be `FeedOwnerState`, not competing active/closed booleans. | low, with B-U02 resource consequence; **M**, W8 |

Paths without a directory in this table are under `app/Squircle/Sources/`. `StudioViewController` already demonstrates the intended destination/spring/reconcile pattern; this inventory recommends completing it, not replacing native scroll/spring physics with a new navigation framework.

#### Overlay, capture and Metal

| Boundary and evidence | Bad state currently representable; concrete replacement | Finding / effort / owner |
| --- | --- | --- |
| **Scene ownership:** `Overlay/SquircleOverlay.swift:20`–`21`, `28`–`43`, `48`–`78`. | The singleton's model, window, observers and scene activity are separate. Global scene notifications can operate on the current model without a typed scene lease. Use `OverlayHostState = unconfigured / attached(SceneLease, Model, Window) / detached(Model)`; route lifecycle events through the owning scene ID. The lease owns teardown and cancels its activity work. Current explicit detach remains valuable. | low; **M**, W9 |
| **Overlay route and mounted content:** `Overlay/SquircleOverlay.swift:95`–`101`, `184`–`189`, `903`–`947`. | `open/full/thread?` and the `draft:` string convention mix current mode, remembered mode and conversation identity; thread/controller/key are independent. Closed+full is a legitimate remembered preference, so do not call it an invalid screen. Encode `visibility = bubble(ResumeTarget) / panel(PanelMode, ConversationID)` and one `MountedConversation`. Preserve resume state explicitly instead of overloading current flags. | low; **M**, W9 |
| **Resize/morph state:** `Overlay/SquircleOverlay.swift:157`–`181`, `494`, `737`–`753`. | `panelSize`, `panelSafe`, `clipLayout?`, `liveLayout`, drag zone and outgoing snapshot can describe incompatible layout regimes. Completion callbacks clear regimes and remove snapshots. Use `PanelPresentation = settled(Layout) / resizing(DragContext, Layout) / morphing(from, to, snapshotLease)`; derive every frame and switch regime only through one reducer when its spring reaches the boundary. Keep snapshot cleanup inside that owner's offscreen reconciliation, not scattered callbacks. | low; **M**, W9 |
| **Attachment flight/flash:** `Overlay/SquircleOverlay.swift:208`–`218`, `296`–`299`, `795`–`810`, `880`–`884`. | Flyer view, attachment ID, flight source and hidden attachment state are independently assigned; rest callbacks remove the view and clear holds. Use `CapturePresentation = none / flying(attachmentID, conversationID, sourceRect, viewLease)` with flash as a derived effect. The originating controller's attachment visibility follows that identity and presentation progress. No stale completion may clear a later flight. No actual stuck-flight case is asserted here. | low; **M**, W9/W7 contract |
| **Completion status inferred from rendering:** `Overlay/SquircleOverlay.swift:199`–`201`, `365`–`377`. | The last rendered `working` dictionary is diffed to invent a Done event, which starts an unowned delayed render. A row disappearing/archiving can therefore stand in for completion; a missed working interval cannot be recovered. Use versioned `TurnCompletion(turnID, endedAt, outcome)` from observed thread state and `TransientNotice(eventID, expiresAt)`. One cancellable deadline requests a render; it does not decide whether work completed. | low; **M**, W9, observed-event interface W6 |
| **Capture producer lifetime:** `Overlay/CaptureSession.swift:42`–`46`, `88`–`98`, `119`–`129`. | **This fix is a good model:** idle/recording/stopping owns its producer and stop completion verifies producer identity. Retain it. Extend an output with originating `ConversationID` if attachment delivery must remain tied to the initiating conversation; do not reintroduce separate `isRecording` flags. | no new defect; retain, W9 |
| **Jelly animation cadence:** `Overlay/GlassJelly.swift:122`–`126`, `253`–`267`, `299`. | Cadence is already an enum and next cadence is derived from spring state, which is good. Remaining display-link/alarm/sleep timestamp resources are separate. Consolidate as `CadenceLease = detached / running(link, rate) / sleeping(link, since, wakeDeadline, alarm)` if touching lifecycle. Frame time, tone elapsed time and spring values are distinct physical state, not redundant truths. Reduced Motion should remain an input to derivation. | low; **S**, W9; O03 profiling still unverified |

All paths in this table are under `app/Squircle/`. UIKit necessarily mounts views imperatively; the architectural rule is that a single reconciler derives those mutations from state. The existing `sync/applyScene` approach and offscreen replacement are useful. The remaining concern is state/ownership changed independently by `onRest`, notification and async-completion closures, not the mere presence of `addSubview` or `isHidden` assignments.

#### Rust tasks, agents, workers, simulators, builds and installs

| Boundary and evidence | Bad state currently representable; concrete replacement | Finding / effort / owner |
| --- | --- | --- |
| **Task observations versus explicit status:** `src/tasks.rs:72`–`99`, `147`, `324`; `src/server.rs:2228`. | One string `seen` serves as last observation, manual hold baseline and restart detector. Use typed `TaskObservation { revision, workers: Map<WorkerID, TurnObservation>, builds: Map<BuildID, BuildObservation> }` and `StatusPolicy = following / held(status, baseline)`. Keep last observed state advancing even while held. Apply only against the captured task revision. | B-T01/B-T03; **M**, W2/W3 |
| **Task History/current/history-log copies:** `src/tasks.rs:94`, `99`, `129`–`176`, `325`. | Status and its history are separately writable, while `archived_at` also disables observation. Use one transition API that produces the record and appended change; `Placement = active / history(since)` is orthogonal to status and never disables linked-work observation. New work revives placement in the same transition. Do not make History synonymous with Done: old open tasks legitimately enter it. | B-T02, otherwise low; **M**, W2 |
| **Task memory/disk commit:** `src/tasks.rs:246`–`247`, `270`–`280`, `332`–`337`. | Mutations alter the in-memory book before a fallible save. A returned error can leave memory ahead of disk with no task-level dirty/reconciliation state. Stage an immutable revision, durably commit then publish, or retain an explicit `Persisting/Dirty(revision)` owner with retry. Readers must know which revision was acknowledged. Do not solve it by treating two stores as equal. | low; **M**, W2 |
| **Agent creation/reset/replacement:** `src/agents.rs:28`–`75`, `990`, `1041`. | `creating`, `pending?`, `replacing?`, `reset_error?`, `refresh` and the external retry map form an implicit state machine. Use `AgentLifecycle = creating(CreateIntent) / ready(ThreadID, InstructionsRevision) / resetQueued(ResetIntent, TurnFence) / resetting(ResetPhase)`; replacement phases own old/new IDs and handoff receipt. Retry metadata belongs to its operation; no replacement exists without a Fresh operation. | B-A02/B-A03; **L**, W1 |
| **Worker execution and archival:** `src/agents.rs:79`–`92`, `246`, `1425`, `1469`. | Display strings (`working`, `needs-you`, `done`) stand in for provider lifetime; service `archived` and T3 archive state can diverge during partial work. Use `ObservedExecution = unknown(epoch) / stopped / live(sessionID, turnID, activity)` where activity includes waiting input. `ArchiveOperation = stopRequested / stopped(StopReceipt) / filesRemoved / t3Archived`; only a StopReceipt permits filesystem removal. `WorkerOrigin`/creation intent owns bootstrap identity. | B-A01/B-A03; **L**, W1 |
| **Wake outbox versus last-notified key:** `src/agents.rs:90`, `98`–`106`. | Stable delivery already improved, but colon-delimited event strings, `attempted` and worker `notified` still require convention. Use `WorkerEventID(turnID, kind, requestID?)` and `DeliveryState = queued / outcomeUnknown / acknowledged(receipt)`. Acknowledge delivery and advance worker observation in one registry transition. Do not infer successful delivery from attempted dispatch. | low; **M**, W1; preserve A04/A06 fixes |
| **Shell readiness and all derived service views:** `src/agents.rs:299`–`302`, `518`–`520`, `582`–`609`; `src/sims.rs:136`. | Shell maps survive a disconnect while `ready` is false, but raw row access can omit freshness. Consumers independently collapse unknown/missing/busy into booleans or strings. Return `Observed<T> = unavailable / stale(epoch, value) / current(epoch, revision, value)` and decode T3's thread phase once. Tasks, sims and push may display stale facts but must not authorize destructive actions from them. | low, related B-A01/B-A04; **M**, W1 with consumer contracts W2/W4/W8 |
| **Simulator lifecycle and recorder ownership:** `src/sims.rs:46`–`108`, `449`–`496`. | A state String, PID option, `Child` map, end time, media ID and filing/error fields can disagree. Use serialized `SessionPhase = starting(StartIntent) / recording(RecorderIdentity) / stopping(StopIntent) / filing(StoppedRecording) / finished(MediaReceipt) / failed(Failure)` plus runtime `RecorderOwnership = owned(Child) / recovered(Identity)`. A phase change moves its owned resources; PID alone is never ownership. | low; **L**, W8; retain R01–R03 safeguards |
| **Simulator close obligation and turn grace:** `src/sims.rs:70`, `106`, `601`–`647`. | `close_pending`, close error and retry map describe one obligation in three places; `idle_since` and a poll-derived bool describe another. Use `DeviceLease = opening / open / closeOwed(RetryState) / closed` and `StopPolicy = active(turnID) / awaitingEnd(since, observedRevision) / stopDue(reason)`. Explicitly distinguish unknown T3 state from confirmed idle. Grace/deadline timers may remain; they are policy clocks, not evidence that a turn ended. | low; **M**, W8; preserve R04 retry |
| **Build job/output/origin:** `src/model.rs:15`–`86`; `src/server.rs:563`–`605`, `654`. | `state`, `request?`, `output?`, `error?`, mode and source String permit succeeded-without-artifacts and running-without-recipe locally. Use `BuildOrigin = project(ValidatedRecipe, Provenance) / imported(ArtifactSource)` and `JobPhase = queued(Recipe) / running(RunLease) / succeeded(BuildArtifacts) / failed(Failure) / cancelled / interrupted(RecoveryInfo)`. `BuildArtifacts = archive(SignedIPA, metadata, symbols) / simulator(AppBundle, metadata)`. Legacy JSON gets a validating adapter; invalid persisted records are reported, not defaulted. | low; **L**, W3/W5 contract |
| **Preview is a separate operation:** `src/model.rs:34`–`43`; `src/server.rs:579`–`595`, `666`–`706`. | Optional path/state/error/time/source and cancellation-map membership encode preview progress independently. Use `PreviewState = absent / queued(OperationID) / capturing(OperationID, priorPreview?) / ready(PreviewArtifact) / failed(reason, priorPreview?)`. This remains orthogonal to successful build artifacts, so failed preview does not invalidate an installable build. | low; **M**, W3/W5 |
| **Build repository, runtime map and recovery overlay:** `src/server.rs:34`–`46`, `400`–`418`, `609`–`628`, `2221`. | Persisted job files, task-local job copies, cancellation senders and `recovery_jobs` are different sources used by different readers. List/show can overlay an unpersisted terminal result while task projection directly reads old disk state. One `JobRepository` owns `Committed(revision)` versus `UnpersistedTerminal(revision, reason)` and runtime operation leases; every view reads its projection. Cancellation is an operation on a live lease, not an independently maintained membership test. | B-E02 plus low representation debt; **L**, W3 |
| **Install transfer versus installation/launch:** `src/model.rs:97`–`110`; `src/server.rs:1461`; `app/Squircle/Sources/SquircleModel.swift:1333`–`1355`; `app/Squircle/Sources/UI/UpdateCurtain.swift:20`. | Two independent timestamps, phone `confirmed` bool, install-watch Task and `updatingTo?` encode different evidence. Use service `TransferEvidence = notStarted / opened(startedAt) / completed(startedAt, completedAt)` and phone `InstallAttempt = requestingLink / prompting(ticket) / watching(ticket, deadline) / transferred(build) / ended(reason)`. Separate launch-observed evidence is authoritative only when a launch report arrives. Derive the curtain from the attempt; never make “transferred” a synonym for installed. | low; **M**, W3/W6/W7; H04's evidence split remains correct |
| **Push desired/observed/delivered state:** `src/push.rs:480`–`487`, `822`, `895`, `922`, `929`. | Cached step, global last-sent state, per-device tokens/start throttles, deferred flag and timers each mutate independently. Use a versioned `DesiredActivity` derived from current agent/worker observations, and per-device `ActivityDelivery = absent / startPending / active(token, acknowledgedRevision) / endPending(token, revision) / ended`. Enrichment and retry effects carry the same generation. Working and needs-you can coexist across different workers; derive both from typed worker phases instead of forcing a false exclusive enum. | B-P01–B-P03; **L**, W4/W5 |
| **Phone push presence versus service expiry:** `app/Squircle/App/PushCenter.swift:16`–`25`; `src/push.rs` device registration/presence. | Foreground, visible thread, token availability, started/watched sets and presence-loop Task represent independent capabilities and one ownership lifecycle. Use `DeviceRegistration(tokens, revision)` plus `Presence = background / foreground(VisibleConversation?)`; publish versioned presence with a lease expiry, derived from the scene/navigation owner. Local registration state explicitly distinguishes unavailable, pending and acknowledged. The service's expiry is valid distributed uncertainty, not a second authoritative UI state. | low; **M**, W4/W7 contract |

The Rust `Status`, `BuildState` and `Reset` enums are useful starts, but an enum next to unrelated optional payloads does not encode the whole invariant. Similarly, unknown external protocol values must remain **unknown**; decoding them to “done”, “idle”, Auto or a default target would hide uncertainty. Use distinct `ThreadID`, `ProjectID`, `TaskID`, `BuildID`, `SessionID`, `MessageID` and `OperationID` wrappers at internal boundaries; serialize to existing wire strings through adapters.

**Previous review:** C02 discussed ownership/structure broadly; N01–N08, A02–A08, R01–R04 and H04 fixed individual symptoms. B-S02 makes the remaining type/authority work explicit without declaring those successful fixes undone. Its concrete changes belong to the existing package owners in the tables. W9 coordinates the contracts, not a cross-repository rewrite.

## Agent coordination and worker lifecycle

### B-A01 — Archiving a worker waiting for input can remove its live worktree

**Severity: high · Effort: M**

**Evidence:** `src/agents.rs:246` gives pending questions/approvals the state `needs-you` before considering running execution. `src/agents.rs:1425` stops a session only when that summary equals `working`; removal follows at `src/agents.rs:1445`. Even `wait_stopped` accepts any state other than `working` (`src/agents.rs:1469`).

**Failure/impact:** a worker blocked on approval is still an active provider session. Archive, especially `--discard`, bypasses stop and can delete its files while that session remains resumable. A stop followed by a stale `needs-you` projection also passes the purported stop confirmation. The final `thread.archive` happens after deletion.

**Fix direction:** distinguish presentation status from execution lifetime. Refuse or explicitly stop every nonterminal session, then require authoritative stopped/absent execution before deleting the expected worktree. Cover a running session with pending input and a delayed stop projection in a fake-peer fixture.

**Previous review:** **A08 partially fixed**. The ordinary `working` branch now stops first; the input-waiting branch and stop predicate remain unsafe. A01's merge-resolution protection is a separate fix and holds in the inspected cleanup logic.

### B-A02 — A deferred/retrying reset can stop a newer user turn

**Severity: high · Effort: M**

**Evidence:** `src/agents.rs:990` decides that a pending reset is due from the current shell row. `spawn_reset` subsequently waits for a delay and operation lock (`src/agents.rs:1002`); `perform` never repeats the idle decision and stops any live session (`src/agents.rs:1041`, `1051`, `1061`). Failed operations schedule another attempt at `src/agents.rs:1029` without a turn guard.

**Failure/impact:** after a reset is deferred until a turn ends, another message can begin a turn before the scheduled operation acquires its lock, or during its retry backoff. The old request then stops this new work. Phone-originated T3 turns do not acquire the service's project lock. A `needs-you` turn also passes the current non-working check.

**Fix direction:** persist the turn/reset phase the request belongs to; revalidate execution immediately before the stop. A reset not yet begun should defer again when a newer turn is active. Reconcile a partially executed reset separately from an operation that merely became eligible. Test idle-to-working while gated on readiness and while retrying.

**Previous review:** **A05's persistence/retry fix holds, but introduces an incomplete retry lifecycle**. Keeping the request is correct; retrying it without checking which turn would be stopped is not.

### B-A03 — Worker bootstrap has no durable reservation before dispatch

**Severity: high · Effort: L**

**Evidence:** `src/agents.rs:1262` creates a new worker identity; `src/agents.rs:1292` dispatches the bootstrap/first turn with a new message identity. The worker is inserted into the registry only after the acknowledgement (`src/agents.rs:1303`–`1310`).

**Failure/impact:** T3 can accept the bootstrap and start work, then lose the acknowledgement. The function returns before registering the worker. A registry write failure after acceptance has the same durable gap. The worker/worktree is real but absent from Squircle's worker registry and completion-wake bookkeeping; retry has no identity with which to reconcile it and can conflict with the branch or create another worker.

**Fix direction:** persist a worker-creation intent, stable thread/message IDs and intended branch before the external command. Reconcile accepted/unknown outcomes through T3 and resume the same operation. Register completion monitoring before it can race the first turn's end. Test acceptance followed by lost acknowledgement and restart before registry completion.

**Previous review:** related to **A02/A04**, but a **newly identified uncovered path**. Durable app-agent creation and wake delivery do not protect worker bootstrap.

### B-A04 — Service reconnect backoff never resets after a healthy session

**Severity: medium · Effort: S**

**Evidence:** `src/agents.rs:508` resets `delay` only when `session()` returns `Ok`. A successfully connected session loops until disconnect and then always returns an error (`src/agents.rs:525`–`544`). Every disconnect therefore increases the same lifetime backoff to 30 seconds.

**Impact:** unrelated disconnects hours apart eventually incur the maximum delay even after long healthy operation. Agent/task/simulator projections and wake dispatch remain unavailable during that artificial wait. This is control-flow evidence, not a connection-speed measurement.

**Fix direction:** reset backoff on an established, sufficiently stable subscription, using a connection generation or duration rather than the unreachable successful return.

**Previous review:** **T02 transport supervision holds**; this adjacent coordinator retry-policy defect was not covered.

## Tasks

### B-T01 — A closed task can miss new work on the same worker

**Severity: medium · Effort: M**

**Evidence:** `src/tasks.rs:147` compares `seen` before processing news; closed tasks return without updating `seen` when old work finishes (`src/tasks.rs:159`–`162`). The service signature contains only worker/build IDs and coarse states, not turn identity (`src/server.rs:2228`).

**Reproduction/impact:** set Done with `seen = w:working`; observe `w:done`; then observe `w:working` for the next turn. The probe returned `changed=false, status=Done`. The first observation was intentionally ignored, but its baseline was also discarded; the next turn appears identical to the old one. A complete intervening turn between ticks is likewise indistinguishable. The user's closed task stays closed when new work starts.

**Fix direction:** keep the latest observed signal independently of the explicit-status hold, and include execution generation/turn IDs. Suppress old completion without erasing the observation needed to recognize a restart.

**Previous review:** new task feature; not previously covered.

### B-T02 — History tasks never observe their linked work again

**Severity: medium · Effort: S**

**Evidence:** `src/tasks.rs:324`–`327` filters archived tasks out before calling the signal provider. There is no worker/build event path that unarchives these excluded tasks.

**Reproduction/impact:** the probe loaded an archived task, supplied new working signals to `tick`, and observed zero signal calls and `archived_at` unchanged. A linked worker restarting after the task ages into History cannot bring it back, contrary to the documented new-work/any-change behavior. Only an explicit task mutation can revive it.

**Fix direction:** retain observation for linked work in History, preferably by an indexed worker/build change feed rather than rescanning every historical task. On actual new work, unarchive and update the task.

**Previous review:** new feature; not covered. This is independent of B-T01's stale baseline.

### B-T03 — An old tick can overwrite a newer explicit task status

**Severity: medium · Effort: M**

**Evidence:** `Tasks::tick` clones tasks and calculates signals outside the book lock (`src/tasks.rs:324`–`327`), then applies those decisions to current records without checking their revision (`src/tasks.rs:328`–`332`). Explicit changes update `seen` at `src/tasks.rs:270`.

**Reproduction/impact:** while the probe's tick computed an older `w:working` result, it applied an explicit Needs You change with the newer `w:done` signature. The tick subsequently replaced Needs You with In Progress. HTTP handling and the background loop can interleave in the same way. The rule that an explicit choice holds until subsequent linked activity is violated by earlier activity.

**Fix direction:** add a monotonic task revision and conditionally apply the computed decision against the captured revision; discard/recompute stale results. Also preserve observation ordering at the HTTP update boundary. Do not move slow file reads under the task mutex to solve this.

**Previous review:** new feature; not covered.

## Push and Live Activities

### B-P01 — Failed push delivery is recorded as sent, including final activity teardown

**Severity: medium · Effort: M**

**Evidence:** notification flush removes the pending batch before sending (`src/push.rs:690`). `deliver` logs rejection/network failure without retry (`src/push.rs:641`–`664`). Activity state is assigned to `entry.sent` before delivery (`src/push.rs:895`, `922`); identical state subsequently returns at `905`. End removes saved activity tokens before the HTTP result (`src/push.rs:927`–`935`).

**Impact:** a transient APNs/network failure permanently loses an alert or state transition. A failed End also discards the token needed to retry, leaving the phone's activity out of sync. A later unchanged shell state cannot repair it.

**Fix direction:** separate desired, in-flight and acknowledged delivery state, per device/activity. Retain tokens until End is accepted or definitively invalid. Retry transient outcomes with bounded backoff and stable collapse/event identities; persist pending terminal events where restart recovery is required. Extend fake-APNs checks to failure followed by success.

**Previous review:** push did not exist in the first review's snapshot; new finding.

### B-P02 — A late current-step read can revive a finished activity

**Severity: medium · Effort: M**

**Evidence:** `src/push.rs:822`–`832` captures app/thread state. `refresh_activities` spawns an asynchronous step lookup (`848`–`850`), then applies the captured `LiveState` after the await (`858`) with no current-thread, turn or generation check.

**Impact:** a lookup started while working may finish after the shell reports completion, a new turn, or a fresh agent. It can publish Working for the old turn and clear the idle/end progression. Overlapping lookups can also apply step text in reverse order. A sufficiently late completion can start an activity again after End.

**Fix direction:** key lookups by app, agent thread and turn generation; cancel/coalesce obsolete work and validate its identity on completion. Apply returned text to current state only when it still belongs to that generation.

**Previous review:** new feature. The same generation discipline used for N02's thread enrichment has not been applied here.

### B-P03 — Push continuously launches SQLite reads even when nobody can receive them

**Severity: medium · Effort: M**

**Evidence:** `Push::run` calls activity refresh every eight seconds (`src/push.rs:864`); working app agents launch `current_step` reads at `src/push.rs:846`–`858`. This path does not first require a configured transport or any eligible device. Shell updates also trigger it (`816`), and there is no in-flight lookup marker. Each read launches `/usr/bin/sqlite3` with fully captured output, no deadline and no kill-on-drop (`src/t3steps.rs:36`–`56`).

**Impact:** with push unconfigured or zero registered phones, working agents still cause process launches and database scans solely for unused Live Activity text. Slow/empty lookups remain stale and permit additional concurrent reads on shell events. A stalled helper has no resource bound.

**Fix direction:** gate enrichment on eligible recipients, share one in-flight lookup per current thread/turn, and refresh on relevant events with a bounded fallback interval. Use a supervised read-only query path with output/deadline limits; reuse results/connections where appropriate. Never write T3's database.

**Previous review:** new push-driven load; the read-only architecture is correct. This is not a request to add another model/backend.

### B-P04 — Failed-build notifications have no usable navigation target

**Severity: medium · Effort: S**

**Evidence:** `src/push.rs:753`–`767` derives the bundle only from successful build output and supplies no project ID. A failed job without output therefore sends just the build ID. `StudioViewController.open` resolves an app using only project or bundle, then returns (`app/Squircle/Sources/UI/StudioViewController.swift:492`–`497`); it does not resolve a build-only target.

**Impact:** tapping a failed-build alert does nothing once a nonempty catalog is loaded, and the pending target is discarded. The build failure that most needs inspection cannot be opened from its own notification.

**Fix direction:** retain authoritative app/project identity with the build request or resolve the build ID before routing. Preserve a pending target until its lookup completes or a real not-found result is shown. Use the same route contract for both success and failure.

**Previous review:** new feature; not covered.

## Native connection and sending

### B-N01 — A draft is stranded when creation succeeds but its first send fails

**Severity: high · Effort: M**

**Evidence:** `app/Squircle/Sources/SquircleModel.swift:923`–`931` creates a thread and selects it before starting the turn. Failure at `953` returns only `.failed(String)`; attachments are restored to the new thread (`891`). The controller adopts a created thread only for `.sent` (`app/Squircle/Sources/UI/ThreadViewController.swift:1347`–`1352`). Its active predicate compares selected thread with its still-nil session ID (`113`), and render returns when they differ (`591`).

**Failure/impact:** ordinary draft creation succeeds, then the first turn request fails. The model owns a real thread, the controller still owns a draft, and the restored content is split between them. Further sends with nil thread are rejected as a draft that is no longer open (`SquircleModel.swift:871`–`873`); rendering can leave the composer disabled. The agent-draft path with images has the same create-then-send boundary.

**Fix direction:** represent creation and delivery as separate outcomes carrying the stable conversation identity even on failure. Atomically adopt that identity in the host/controller and retain a retryable pending message under it. Do not reconstruct ownership from selected-session equality.

**Previous review:** **N01 partially fixed**. Capturing the send destination protects navigation during a send; failure after successful creation still leaves invalid UI/model state.

### B-N02 — Subscription termination during connection setup is silently ignored

**Severity: medium · Effort: M**

**Evidence:** `T3Gateway.subscribe` returns after writing the request (`app/Squircle/Sources/T3Gateway.swift:205`–`210`), not after an initial stream value. Exit removes the subscription and invokes its callback (`236`). Setup installs subscriptions, awaits `device.list`, then sets `connected = true` (`app/Squircle/Sources/SquircleModel.swift:417`–`427`). Both termination handlers require `connected` (`438`, `647`).

**Failure/impact:** a shell/device/thread subscription can reject or finish while `device.list` is outstanding. Its handler returns because setup has not marked the model connected; the socket remains open, so setup then declares success with that subscription gone. Live state can remain stale indefinitely.

**Fix direction:** track subscriptions as part of a connection attempt, and fail that attempt on termination regardless of the final UI connection flag. Require initial subscription readiness or an explicit valid generation before publishing Connected. Test Exit before the final setup RPC completes.

**Previous review:** **N03 partially fixed**. Runtime termination after Connected is handled; setup termination is not.

### B-N03 — A failed provider-list fetch can block sending for the entire connection

**Severity: medium · Effort: S**

**Evidence:** the new service-backed provider fetch is launched only from connection setup (`app/Squircle/Sources/SquircleModel.swift:431`, `451`–`458`). Failure is swallowed and retried only on another connection. Manual reconnect while already connected merely refreshes services (`400`), which does not call `loadConfig`. Send requires a valid catalog entry (`877`).

**Impact:** if T3 is healthy but the service's provider endpoint transiently fails on a cold start, the model list remains empty and sending fails with “Choose an available model.” Recovery of the service and normal metadata refresh do not repair it. The ten-minute cache condition is also only evaluated on reconnect, so a long connection never refreshes changed providers.

**Fix direction:** give provider loading its own retry/expiry state, invoke it on service recovery/explicit refresh, and expose a recoverable loading failure. Do not require tearing down a healthy T3 socket to reload a service catalog.

**Previous review:** regression in the later provider-list optimization, not covered previously.

### B-N04 — Failed recording uploads poison every retry of that attachment

**Severity: medium · Effort: S**

**Evidence:** attachment upload tasks are stored at `app/Squircle/Sources/SquircleModel.swift:819`–`821`; `captureBlock` reuses the stored task (`835`) and awaits its value (`840`). Cleanup occurs only after the whole loop succeeds (`846`). A failed send restores the attachment (`889`–`893`).

**Impact:** a transient upload failure leaves a completed, throwing task in `captureUploads`. Pressing Send again awaits the same failed task and never attempts a new upload. The recording cannot recover without removing/re-attaching it.

**Fix direction:** remove the matching failed task on failure while retaining successful upload receipts. Give each upload a generation so cleanup cannot remove a newer replacement. Test failure then success for the same attachment ID.

**Previous review:** newly identified hole beside **N01's restored-attachment fix**.

### B-N05 — Retrying an ambiguously acknowledged message creates a new turn identity

**Severity: medium · Effort: M**

**Evidence:** each delivery generates a new message UUID inside the dispatch (`app/Squircle/Sources/SquircleModel.swift:949`–`953`). Any thrown result becomes `.failed`; the controller clears its pending echo and restores the text (`app/Squircle/Sources/UI/ThreadViewController.swift:1349`–`1352`). No stable message identity or accepted/unknown distinction survives for retry.

**Impact:** if T3 accepts the turn and the response is lost, retrying the restored text submits a different message. The user can trigger duplicate agent work even though the first message is already in T3. This also affects existing threads, independently of B-N01's draft ownership failure.

**Fix direction:** allocate message identity before the first attempt and retain it with pending content. Reconcile an unknown acknowledgement against T3 before retrying the same identity; distinguish rejection from transport ambiguity. Cover accept-then-disconnect with a fake gateway.

**Previous review:** not directly covered; the durable identity approach added for **A04** has not reached native message delivery.

## Repeated work and resource use

### B-E01 — The metadata timer reloads six collections even when their UI is hidden

**Severity: medium · Effort: M**

**Evidence:** `app/Squircle/Sources/SquircleModel.swift:1247`–`1265` repeats refresh four seconds after each pass. It fetches builds, apps and agents concurrently, then simulator sessions, selected-project tasks and selected-thread media. Task/media eligibility is based on retained selection, not the visible route (`1268`; `refreshOpenMedia`). `refreshServices` is another refresh entry point (`328`) without a common in-flight pass.

**Impact:** after visiting a conversation, Home can continue refreshing its task/history/media payloads. The overlay also owns this timer while its conversation is closed and the host is active. Unchanged replies still replace model collections and notify observers. Foreground/manual refresh can overlap the timer. This is recurring cellular/network and parsing work in addition to T3's live subscriptions.

**Fix direction:** share one coalesced refresh coordinator; derive required data from visible consumers and active operations. Separate slow-changing catalog/history from live build/simulator/task state, add versions/conditional reads, and refresh on events or bounded fallback schedules. Preserve live simulator ownership when the conversation itself is hidden.

**Previous review:** related to **N05/U01**, but broader service polling remained after those fixes. No numerical bandwidth or battery claim is made.

### B-E02 — Ordinary list/tick paths still rescan disk synchronously, including all task history

**Severity: medium · Effort: L**

**Evidence:** `/v1/builds` calls `list_jobs` under the shared store mutex (`src/server.rs:400`–`406`); it scans directories and parses every job JSON (`src/store.rs:83`–`103`). App listing uses the same mutex (`src/server.rs:821`). Task listing expands active **and all History** on every call (`src/server.rs:2281`–`2289`): each task reopens linked job records and lists media (`2245`, `2251`). Independently, the three-second task loop synchronously rereads linked build JSON (`338`, `2221`).

**Impact:** historical jobs/tasks grow the cost of an unchanged poll without a limit. The async HTTP/timer workers execute blocking filesystem work, and build/app listing keeps the global store lock while doing it. Removing the lock from download routes did not remove this control-path contention. The phone need not open History to pay for expanding it.

**Fix direction:** maintain bounded/versioned in-memory indexes updated by writes, hydrate them off the async executor, and fetch History lazily with pagination. Share build-state observations across tasks rather than reading a job once per link per tick. Keep mutations short and move remaining blocking operations to a dedicated blocking boundary.

**Previous review:** **H02 partially fixed**. Large artifact/diagnostic paths improved; ordinary list handlers still hold the lock over disk work. Tasks add a new unbounded scan path.

### B-E03 — Chat rendering still rebuilds the whole timeline on the main actor

**Severity: medium · Effort: M**

**Evidence:** `ThreadViewController` is main-actor isolated (`app/Squircle/Sources/UI/ThreadViewController.swift:76`). `renderItems` constructs and resolves all `ThreadItem.items` before comparing it with the previous result (`699`–`705`). Timeline construction walks all messages into turns (`app/Squircle/Sources/UI/ThreadTimeline.swift:126`–`139`) and re-parses link-bearing message Markdown (`245`–`247`). Model observation can call render for unrelated metadata changes as well as streamed content.

**Impact:** moving raw conversation reduction off the main actor did not move or cache this second full-history reduction. A long thread pays for old turns and Markdown repeatedly while typing/streaming or receiving unchanged catalog updates; the equality guard is too late to avoid that work.

**Fix direction:** keep immutable completed-turn rows/parsed media keyed by content revision, recompute only changed turns, and distinguish content from unrelated catalog changes before scheduling work. Perform pure parsing off the main actor and apply results only to the matching conversation generation.

**Previous review:** **N05 partially fixed**. Off-actor reduction and cache writing are useful, but the UI's downstream whole-history transformation remains.

## Media

### B-M01 — Videos are buffered as Data and written synchronously on the main actor

**Severity: medium · Effort: M**

**Evidence:** `loadVideo` fetches a full Data value then calls `data.write` in the main-actor model (`app/Squircle/Sources/SquircleModel.swift:1052`–`1068`). Task videos take the same path (`1291`–`1301`), retaining that Data in a nominally 16 MiB cache. `BoundedCache` intentionally keeps a single oversized entry (`app/Squircle/Sources/AgentStep.swift:207`). The service accepts individual media files up to 512 MiB (`src/media.rs:41`, `119`).

**Impact:** opening a valid large clip, or merely making its task thumbnail, can retain hundreds of MiB and synchronously write it while blocking the UI actor. Concurrent thumbnail/open requests are not coalesced before the file/cache exists, multiplying transfer/buffering work. The cache's configured budget is not an upper bound for a video.

**Fix direction:** download to a temporary file with bounded streaming, coalesce by immutable media identity, and atomically move it off the main actor. Cache small thumbnails separately from video files; do not retain movie Data in the image cache.

**Previous review:** newly exposed by task media and adjacent to **N05/N06**; byte-budgeted image caching does not bound this path.

### B-M02 — Downloaded-video eviction does not cover task files or previous launches

**Severity: medium · Effort: M**

**Evidence:** `StepVideos` tracks only 24 URLs in an in-memory cache (`app/Squircle/Sources/AgentStep.swift:233`); directory initialization merely creates the directory (`235`–`238`), and deletion only considers entries that leave that process's map (`244`–`248`). Task video files use a different `temporaryDirectory/task-<id>.mp4` path and bypass that map (`app/Squircle/Sources/SquircleModel.swift:1298`–`1302`).

**Impact:** after process termination, old downloaded files remain but the eviction index is gone; file-link downloads allocate fresh UUID filenames. Task videos are never counted or evicted by this cache at all. Repeated use can accumulate clips until the OS decides to purge temporary storage; Squircle's advertised bounded cache does not bound disk usage.

**Fix direction:** one file cache with a persisted/rebuilt index, byte and age limits, launch reconciliation and active-player leases. Route task and conversation downloads through it; preserve user-owned capture files separately. Validate ownership/eviction with temporary files, not UI goldens.

**Previous review:** **N06 partially fixed**. In-process eviction helps; lifetime and task-download coverage remain incomplete.

## Chat actions and simulator UI

### B-U01 — Multiple commands in one tool call all take the first result ID

**Severity: medium · Effort: M**

**Evidence:** `SquircleAction.parse` passes the same entire `result` to every parsed command (`app/Squircle/Sources/SquircleAction.swift:123`). Spawn/build identities use the first matching `id` in that text (`167`, `178`, `202`). The UI's resolution fallback only runs when the parsed thread ID is absent (`app/Squircle/Sources/UI/ThreadViewController.swift:758`).

**Reproduction/impact:** the Swift probe parsed two `squircle thread spawn` commands with different titles and two JSON replies containing different UUIDs. Both actions received the first UUID. Tapping the second “Started worker” line therefore opens the first worker; mixed spawn/build output can also associate the wrong kind of ID. Output-wide error detection can attribute one command's failure to another.

**Fix direction:** correlate structured command receipts to each action, preferably from service operation identities. For concatenated/filtered shell output whose correspondence cannot be established, leave the identity unknown rather than picking the first UUID. Add the two-command fixture to the parser tests.

**Previous review:** new chat-actions feature; not covered.

### B-U02 — Expanding an older simulator keeps the invisible newest feed running

**Severity: medium · Effort: S**

**Evidence:** attachment eligibility unconditionally includes deck `index == 0` (`app/Squircle/Sources/UI/SimulatorViews.swift:389`–`394`). Layout multiplies every nonexpanded picture's alpha by `1 - expansion` (`507`).

**Failure/impact:** fan out two simulators and expand the older one. At full expansion the newest deck picture is invisible, but it remains an attached feed consumer because it is index zero. Both H.264 streams/decoders continue although only one is visible.

**Fix direction:** derive attachment eligibility and rendered visibility from the same expansion/fan state. Retain both feeds only for the visible transition interval; detach the fully occluded deck target at its endpoint. Inspect this on rendered output with two simulators, without adding pixel tests.

**Previous review:** **U01 partially fixed**. Hidden Home/closed-overlay ownership improved; the newer multi-simulator deck creates another hidden consumer.

### B-U03 — Simulator input waits for the expansion spring to nearly finish

**Severity: medium · Effort: M**

**Evidence:** `app/Squircle/Sources/UI/SimulatorViews.swift:517` enables simulator input only when `isExpanded && e > 0.99`. Before that, the PiP's tap/pan recognizers remain active (`632`–`634`) and raw simulator touches are discarded (`692`–`695`).

**Impact:** tapping the simulator during expansion cannot act on the destination content; it is still treated as a PiP gesture or ignored. This directly conflicts with the required first-frame touch ownership and interruptible navigation rule. The source condition is verified; transition duration/appearance was not measured.

**Fix direction:** transfer input ownership when the route chooses the expanded target, and map touches through its current presentation geometry. Preserve the correct begin/move/end identity if expansion is interrupted. Verify rapid taps and interrupted expansion frame by frame, with `SQUIRCLE_STRESS=1` navigation reporting zero violations where applicable.

**Previous review:** newly identified stacking/expansion behavior; not fixed by U01's stream-lifetime work.

## Build helpers

### B-B01 — A bounded helper can time out while leaving descendants alive

**Severity: medium · Effort: M**

**Evidence:** `src/xcode.rs:421` drains both output pipes before awaiting the leader. On timeout/cancellation it checks the leader with `try_wait`; if that leader has exited, it disarms the process-group guard (`437`–`440`) without killing remaining group members.

**Reproduction/impact:** the probe ran a shell that started `sleep 10` with inherited output pipes and immediately exited. A 300 ms runner deadline returned TimedOut, but `kill(childPID, 0)` showed its owned child still alive. The probe killed it explicitly. Background compiler/script descendants can therefore outlive a cancelled/timed-out build helper and retain resources or keep writing artifacts.

**Fix direction:** treat leader exit and process-group completion as different states. Supervise/reap without abandoning an owned live group on the timeout/output-error path, while retaining the PID-reuse protection. Include a leader-exits-first fixture alongside existing helper cancellation checks. Review the analogous separate symbol-tool runner (`src/perf.rs:238`–`268`), whose unconditional pipe-reader join also lies outside its advertised deadline.

**Previous review:** **B02 partially fixed**. The shared bounded runner is a substantial improvement; this descendant case escapes it. B01's Mach-O checks and B03's toolchain-sensitive overlay key hold in the inspected code.

## Structure and remnants

### B-C01 — Core ownership boundaries still sit inside oversized multipurpose types

**Severity: low · Effort: L**

**Evidence:** at this snapshot `src/server.rs` has 2,411 lines, `src/agents.rs` 1,982, `src/main.rs` 1,211, `SquircleModel.swift` 1,439, `ThreadViewController.swift` 1,625, and `Overlay/SquircleOverlay.swift` 1,449. Concrete cross-concern coupling is visible in send ownership, metadata polling and task-video storage all living in `SquircleModel`; bootstrap/reset/wakes/git deletion all live in `Agents`. Dead entry points include phone `addTask` (`app/Squircle/Sources/SquircleModel.swift:1272`, `SquircleClient.swift:232`; no caller), and `PhonePose.interpolate`/`visible` (`app/Squircle/Sources/UI/DeviceStage.swift:21`, `24`; no live caller).

**Impact:** fixes to independent features repeatedly collide in the same files, and shared mutable selection/flags make the lifecycle bugs above easier to introduce. The unused task-creation API also preserves a phone capability removed from the product flow. Size alone is not the defect; unclear ownership and unused alternate paths are.

**Fix direction:** extract cohesive owners while fixing their real invariants: delivery operations, subscriptions, service refresh, media cache, task projection, coordinator operations and process supervision. Keep one route/state source of truth and reuse it in app/overlay. Delete the proven unused members; avoid a wholesale cosmetic rewrite. Split the overlay host/navigation/capture coordination only after its existing behavior is checked.

**Previous review:** **C02 remains partially deferred**, as the first report's status already admits. Existing `ConversationHost`, captured send contexts and cache helpers are useful improvements, not a completed decomposition.

## Check of the previous review's fixes

“Holds” below means the addressed code path was inspected and no counterexample to that specific fix was found; it is not a claim of phone/APNs/end-to-end validation. The Rust suite adds evidence where it has relevant fixtures. Partial/new gaps are counted only once above.

| Previous IDs | Result in this review |
| --- | --- |
| H01, H03, H04, H05 | Hold for auth-before-body, missing-preview recovery, separate transfer-start/completion evidence, and shared JSON rejection mapping. The delivered-body tracking still proves transfer handling, not installation or launch. |
| H02 | Partial: artifact paths improved; list/tick disk work remains (B-E02). |
| A01, A02, A03 | Hold for merge-aware cleanup checks, serialized durable app-agent creation, and explicit approval/runtime-mode propagation. Worker inheritance/override is now carried into bootstrap. Worker creation itself still lacks the reservation (B-A03). |
| A04, A06, A07 | Hold for serialized stable wake identities/reconciliation, pending-request identity, and deepest canonical project selection. This does not imply native sends or push have equivalent delivery guarantees. |
| A05 | Original lost-request problem fixed; retry can stop a later turn (B-A02). |
| A08 | Partial: needs-you/live-session cases escape stop confirmation (B-A01). |
| T01–T03 | UTF-8-safe clipping, supervised transport liveness and pending request/reader ownership hold in the inspected paths and tests. Coordinator backoff still never resets (B-A04). |
| R01–R04 | Recorder identity checks, startup rollback, explicit shutdown and pending close retry are present and covered by offline fake-host/process fixtures. Real simulator shutdown/recovery was not rerun. |
| N01 | Destination capture holds; created-thread/send-failure transition does not (B-N01). |
| N02, N04 | Thread-enrichment generation checks and the prior explicit close/teardown paths hold on inspection. This is not a blanket claim about every newly added Task. |
| N03 | Partial: setup-time subscription Exit is ignored (B-N02). |
| N05 | Partial: off-actor reduction/cache writer hold, main-actor timeline work remains (B-E03), and state/render cache revisions can disagree (B-S01); large-video writes also remain (B-M01). |
| N06 | Partial: bounded in-process caches exist; oversized video buffering and disk-cache lifetime/task coverage remain (B-M01/B-M02). |
| N07–N11 | Ordered cache writer, failed enrichment retry/idle-media refresh, update-before-add Keychain persistence, exact-origin asset validation and discovered CLI invocation hold on inspection. |
| U01 | Partial: visibility ownership is improved, but expanded simulator stacking keeps an occluded feed (B-U02). |
| U02, U03 | Non-starving observation/render scheduling and shared conversation-host interaction paths hold in the inspected fixes. |
| O01–O03 | Explicit capture stopping/cancellation, per-frame cadence/resumption accounting, and adaptive jelly cadence/Reduce Motion branches are present. No new source-confirmed regression retained. GPU cost, scene replacement and motion appearance still need the previously deferred phone check. |
| B01, B03 | Bounds-checked Mach-O planning and toolchain/settings-aware framework cache key hold; relevant Rust fixtures pass. |
| B02 | Partial: supervised helper paths exist, but leader-exit/descendant case escapes cleanup (B-B01). |
| D01–D03 | Full-content image identity, target-specific preview validation and UUID-checked symbol selection hold on inspection and relevant offline fixtures. No actual new capture/symbolication was performed. |
| C01, C03 | Explicit local-only media CLI/service contract and corrected active documentation hold for the addressed paths. |
| C02 | Still partial/deferred (B-C01). |

## Fix plan: exclusive file ownership

These are proposed implementation packages, **not changes made by this review**. Every existing file named below has one owner across the entire plan. A finding can need a contract change on both sides; its workers exchange the agreed shape instead of editing each other's files. New files stay within the named owner's concern. Inline Rust tests belong to their source owner. Do not add layout/text/golden tests or tests that call live T3, agents, builds or simulators.

Before parallel work, agree four small contracts: worker operation identity/reconciliation, task revision plus worker-turn signal, pending-send identity/outcome, and build notification app identity. Record those in the relevant docs through W9. Preserve subscription authentication, T3 ownership and read-only SQLite; no new agent harness.

| Package | Findings / outcome | Exclusive existing-file ownership | Validation / order |
| --- | --- | --- | --- |
| **W1 — Coordinator transactions** | B-A01–B-A04; agent/worker portions of B-S02/B-C01. Durable worker bootstrap, execution-aware stop/reset and healthy reconnect backoff. | `src/agents.rs`; `plugin/squircle/agents/app-agent.md`; `plugin/squircle/hooks/hooks.json`. The later main-branch guard is preserved; do not rewrite it for these fixes. | Start first. Fake-peer tests for pending-input stop, reset eligibility changing during wait/retry, and accepted-but-unacknowledged bootstrap. Keep Git fixture coverage. |
| **W2 — Task lifecycle** | B-T01–B-T03 and task portions of B-S02. Separate observations from explicit status holds, support History reactivation, reject stale tick results. | `src/tasks.rs`. | Start alongside W1. Three small state/revision fixtures based on the reproduced failures. Agree signal/revision shape with W3 before implementation. |
| **W3 — Service projections and contracts** | B-E02; service side of B-T01/B-T03 and B-P04; build/install/repository portions of B-S02. Versioned indexes, bounded History reads and authoritative build/app identity. | `src/server.rs`, `src/store.rs`, `src/apps.rs`, `src/media.rs`, `src/model.rs`, `src/main.rs`; `tests/http_contract.rs`, `tests/service_lifecycle.rs`, `tests/cli.rs`. | Start after contract agreement, alongside W1/W2. Integrate W2 before task acceptance checks. Preserve `--help`/JSON and private-store/auth semantics. Test stale revision and pagination/version contracts, not formatting. |
| **W4 — Push state machine** | B-P01–B-P04 and push/presence portions of B-S02. Acknowledged/retryable delivery, generation-checked enrichment and eligible-recipient gating. | `src/push.rs`; `app/Squircle/App/PushCenter.swift`; `app/Squircle/Shared/SquircleActivity.swift`; `app/Squircle/Widgets/SquircleWidgets.swift`; `app/Squircle/Sources/PushTarget.swift`. | Start independently after target contract agreement. Fake APNs transient failure/end-token recovery and delayed old-step completion. Integrate W3 target metadata and W5 query bounds. |
| **W5 — Helper supervision and enrichment I/O** | B-B01; query execution side of B-P03. Enforce process/output/deadline ownership through descendant completion. | `src/xcode.rs`, `src/overlay.rs`, `src/preview.rs`, `src/projects.rs`, `src/perf.rs`, `src/symbolicate.rs`, `src/t3steps.rs`. | Can start immediately. Short owned-child timeout/cancellation/output-limit fixtures; no actual build or SQLite query against the user's state. Preserve read-only enrichment. |
| **W6 — Native model, delivery and media** | B-N01–B-N05, B-S01, B-E01, B-M01/B-M02; native-model portions of B-S02/B-C01. Stable operations, attempt-scoped subscriptions, provider recovery, coalesced refresh and file downloads. | `app/Squircle/Sources/SquircleModel.swift`, `SquircleClient.swift`, `T3Gateway.swift`, `AgentStep.swift`, `T3ThreadState.swift`, `ClientModels.swift`, `AppProject.swift` (all under `Sources/`); `app/Squircle/Tests/T3Tests.swift`. | Start after send contract agreement; coordinate versions with W3. Fake protocol/upload tests for failure boundaries, temporary-file cache checks. Do not duplicate the other worker's connection-speed measurements. |
| **W7 — Chat presentation and routing** | B-U01, B-E03; controller side of B-N01/B-N05, B-P04, B-S01/B-S02 and B-C01. Identity-based rendering/actions and correct retry/navigation adoption. | `app/Squircle/Sources/SquircleAction.swift`; `app/Squircle/Sources/UI/ThreadViewController.swift`, `ThreadTimeline.swift`, `TasksViewController.swift`, `StudioViewController.swift`, `DeviceStage.swift`, `UpdateCurtain.swift` (all under `Sources/UI/`); `app/Squircle/Tests/SquircleActionTests.swift`. | Parser work can start immediately; send/render integration follows W6 and target integration W4. Use the two-command parser fixture; inspect long chat, delayed failed send and build-target routing in the app. Preserve main's newer portrait-recovery and Tasks swipe changes. |
| **W8 — Simulator ownership, visibility and input** | B-U02/B-U03 and simulator portions of B-S02. Typed service sessions/device leases; one visibility/interaction derivation for deck, fan and expansion. | `src/sims.rs`; `app/Squircle/Sources/UI/SimulatorViews.swift`; `app/Squircle/Sources/T3DeviceStream.swift`. | Independent of chat rendering after host-interface agreement with W7. Render two-simulator fan/expand/collapse, immediate input and mid-transition reversal. Verify hidden stream detachment and navigation stress without new pixel tests. |
| **W9 — Remaining structure, docs and integration record** | Overlay portions of B-S02, remaining B-C01, accurate completion/evidence. Small overlay-owner extraction if justified; remove no behavior merely to reduce line count. | `app/Squircle/Overlay/SquircleOverlay.swift`, `GlassJelly.swift`, `CaptureSession.swift`, `ScreenRecorder.swift`, `PerfRecorder.swift` (all under `Overlay/`); `app/Squircle/Tests/OverlayCaptureTests.swift`; `AGENTS.md`, `README.md`, `docs/`; app project configuration only if extraction requires adding files. | Last for structural edits. Record interface agreements first, then verified results/remaining limitations. Other packages fold local extraction/dead-member deletion into their own files; W9 must not re-edit those files. |

**Merge order:** W1 and W2 first; W5 can merge independently. Then W3 and W6, followed by W4 and W7 once their contracts are available. W8 can merge independently of those internals after agreeing its host interface. Finish W9 after the functional changes. Work within a wave can proceed in parallel; the file lists remain exclusive even when packages are sequenced.

**Acceptance:** run the existing fast offline Rust suite and concurrency check, plus only the focused invisible-logic fixtures above. Then perform one coordinated app/overlay inspection through Squircle-managed simulators: failed first-send recovery, subscription loss/provider recovery, foreground/background, History reopening, two-simulator expansion/input, and capture/Reduce Motion. Run the existing navigation stress audit after navigation changes and require `violations=0`. Device/APNs/background/battery claims require their own real evidence; do not relabel these source findings as measured performance or mark the prior deferred phone check complete. UI changes also require the actual simulator preview/catalog update specified in AGENTS.md.
