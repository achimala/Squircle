# Native iPhone client on stock T3

Decision date: **2026-10-05**. The user approved abandoning the Hermes integration
and starting fresh on the already installed and running T3 server. This replaces
the earlier stock-mobile-client trial recommendation. The native replacement is now signed as 0.2.0 (13) and directly installed on the
paired iPhone. The user confirmed build 11 worked; its launch acknowledgement was
observed. The user reported unacceptable latency in build 12. Build 13 removes MJPEG entirely; its measured phone response latency remains pending.

## Boundary

- **T3:** provider processes and subscription logins, projects, threads, live
  activity, approvals/questions, cancellation, persistence and device management.
- **Squircle iPhone client:** UIKit presentation, native video playback/input,
  app-to-T3-project associations, local navigation and credential storage.
- **Existing Squircle CLI/service:** Xcode recipes/jobs, signed exports,
  installation URLs, app metadata/screenshots and diagnostics. Keep it independent
  of T3 and preserve its tested signing and HTTPS installer path.

Use the server bundled in the user's running T3 desktop app. Do not start another
server against its store, copy or directly mutate its database, reinstall provider
CLIs, change Tailscale, or replace existing network routes as an implicit step.
T3 desktop and our phone client should see the same server-owned threads.

Verified installed T3 version: **0.0.45**. Pin the first compatibility target to
that release. T3's [RPC contracts](https://github.com/pingdotgg/t3code/blob/v0.0.45/packages/contracts/src/rpc.ts)
and [shared client runtime](https://github.com/pingdotgg/t3code/blob/v0.0.45/packages/client-runtime/README.md)
are source references. The runtime package is private, not a published third-party
SDK. Keep protocol compatibility separate from presentation and negotiate
advertised capabilities. An upgrade needs a connection/stream regression check.

## Keep, replace, remove

| Existing part | Migration |
| --- | --- |
| Rust `src/`, CLI, archive/export/install and diagnostics | Keep. Teach both T3 providers to call the existing executable and progressive help. |
| `DeviceStage`, `StageLayout`, `SpringDriver`, `Theme`, screenshot decoding and motion tests | Reuse useful geometry, controls and interruptible navigation. Add streaming only after the flat player works. |
| Builds sheet, import flow, app catalog and signing configuration | Keep; associate apps with T3 environment/project identity and canonical checkout path. One checkout can have multiple schemes. |
| `HermesClient.swift` | Extract the independent Squircle API/build models and useful JSON utilities; discard Hermes REST/SSE behavior. The misleading filename currently includes reusable build logic. |
| `SquircleModel`, configuration, thread/activity presentation | Replace Hermes-owned conversation state with T3 snapshots/events and provider controls. Keep the UI's useful incremental rendering. |
| `HermesGateway`, `HermesConversation`, attachments/question adapters and delegated-log polling | Remove from the new runtime. No Hermes fallback is required. Preserve source in Git history, not a second active backend. |
| Hermes protocol/integration tests | Retire with the old implementation; retain motion, import, build and diagnostic coverage. Add actual T3 protocol/reconnect tests. |

Do not translate old Hermes conversation history into synthetic T3 threads.
Start with the user's actual T3 projects and existing threads. Do not uninstall
the separately installed Hermes app or daemon; that is outside this migration.

## Milestone 1: a small native connection and player

Before redesigning all screens, build a diagnostic native slice against the
existing T3 server:

1. Establish the stock authenticated environment connection. Obtain an explicitly
   scoped client session through the ordinary T3 pairing/bootstrap path; keep
   reusable credentials in Keychain and mint short-lived WebSocket tickets. Do
   not copy the desktop's internal token, weaken authentication, or print tokens.
2. Load server projects, open an existing thread and reconstruct it from a
   snapshot plus live events. Confirm parity with the desktop view and reconnect
   without duplicates. First implementation proposal: a small Swift transport
   and typed projection based on the pinned contracts, not another Mac bridge.
3. Open the same device through T3 and consume its authenticated `stream.avcc`
   feed. Parse the envelopes/codec configuration, decode H.264 natively, and
   present with a native video layer. Test decoder support for the actual profile.
4. Forward normalized touch/drag and hardware-button input on the existing
   authenticated device WebSocket. Derive coordinates from the actual frame and
   orientation. Match the host ID and simulator UDID used by the thread.
5. Measure input-to-visible response and frame freshness on the physical phone,
   over the existing private connection and cellular. Separate low FPS from a
   growing backlog; report capture/transport/decode limits as unknown unless
   measured. Proposed target: median response below 250 ms with no accumulating
   stale playback. The existing native client has not met this target yet.

The first deliverable is a phone build showing an existing T3 thread and a native
interactive stream. It must not need a T3 patch or a new agent runner.

The Cards-Verify input trial found Device Hub's
`com.apple.coredevice.dtuhidd.active = 1` shadowing legacy touch. The user-approved
upstream repair cleared the flag and restarted backboardd; the user confirmed
recovery. This can recur when Apple's Device Hub attaches. Avoid automatically
opening that window in the new workflow. Observe the conflict and offer the
explicit disruptive repair; never silently restart simulator apps.
See [trial evidence](direct-agents-plan.md#live-trial-simulator-input-2026-10-05).

## Milestone 2: complete provider interaction

Add new thread/provider/model selection, messages, real-time command/edit/output
details, approvals and questions, stop/continue, failures and disconnect recovery.
Use normalized T3 events; do not infer completion from a command receipt or poll
the worker's files for activity. Verify Codex and Claude separately in their real
server context. A manual simulator session must coordinate with active agent
work; do not claim an exclusive input lock unless the server enforces it.

Then connect the app picker to T3 project/thread identity and build recipes.
Keep app names and real thread content visible; builds remain secondary. Place
a compact live preview alongside chat, with a direct interactive expansion into
the full-screen player. Keep the stream mounted across that transition where
practical. Test video-layer/3D costs before putting moving video on the SceneKit
device; preserve a low-latency flat view. Idle treatment must follow known state,
not the mere absence of changing pixels.

## Milestone 3: one complete app delivery

Give the selected provider concise instructions to discover `squircle --help`,
`capabilities --json` and `help workflow`, then use `build start`, `build wait`,
`build log` and `install-link` against the existing service. Keep the executable
path and store selection explicit; no new MCP wrapper is required initially.

The phone's builds sheet reads the existing structured build records and presents
the installer page for the successful signed job. The user confirms installation
and manually launches the app. A posted URL or downloaded IPA is not proof of
installation. Verify the expected build/version, then logs and the existing
launch acknowledgement when supported by that app.

After the replacement passes these gates, remove old Hermes runtime/configuration
and tests from the active target and install the new Squircle phone build. Keep
the current signing identity and app catalog; retain old implementation in Git.

## Streaming replacement gate

The native client controls decoding, presentation and playback queues. It cannot
choose a new host encoder or transport just by consuming already encoded video.
T3 0.0.45's proxy [excludes WebRTC and exposes no iOS encoder-tuning write route](https://github.com/pingdotgg/t3code/blob/v0.0.45/apps/server/src/device/DeviceHubProxy.ts).

Put the player's video/input boundary behind a narrow interface now. If measured
latency remains in the host/network path, evaluate a separate streaming component
that reuses existing IOSurface capture/encoding code and reaches the same UDID.
It needs independent authenticated connectivity; never expose the raw helper or
decode/re-encode T3's feed. This would replace only streaming, while T3 keeps all
agent/session ownership. Do not add it before the native H.264 trial produces
evidence that the stock path is insufficient.

## Implementation evidence: 2026-10-05

- Installed stock T3 0.0.45, environment `517663a4-8e75-4992-84be-b33a1c4947c8`,
  existing desktop-owned server on port 3773 and existing HTTPS route on 443.
  Existing Squircle HTTPS route on 8443; no network setup changes. The build
  service was stopped and was restarted against its existing private store.
- Paired through the bundled official T3 CLI and OAuth bootstrap exchange;
  read/operate scope only. Private configuration/probes stay under ignored
  `.squircle/`, mode 0600. No T3 source or database mutation.
- `T3Gateway.swift`: verified Effect RPC Request/Chunk/Ack/Exit frames,
  correlated commands, cancellation/timeouts, subscriptions, heartbeat and
  reconnect. T3 owns persisted threads; snapshots recover connection state.
- `T3ThreadState.swift`: actual streaming messages append deltas; an empty final
  event seals the existing text instead of erasing it. Sequence replay is
  deduplicated. Command/edit output and requests come from T3 activities.
- `T3DeviceStream.swift`: AVCC framing/configuration, VideoToolbox decode,
  bounded decoded presentation, idle JPEG seed, native MJPEG fallback, authenticated
  input, touch/drag coordinates and Home. Native pinch is not implemented.
- **19 tests passed, one optional test skipped** in
  `Test-Squircle-2026.10.05_16-11-19-+0200.xcresult`: 4 active T3 app/recipe
  tests, 8 motion tests, 4 deterministic protocol/input tests and 3 live tests.
  Result is in `.squircle/t3-derived/Logs/Test/`. The unused legacy app catalog
  and its tests were replaced with T3 workspace ownership/recipe tests.
  Codex's real turn produced tool progress, a final marker and persisted history.
  The stream test proves **one native JPEG seed**, not continuous playback.
  A stronger three-frame test timed out while the Mac was locked, and the direct
  T3 feed probe also emitted only a seed with the debug motion loop running.
  `testContinuousNativeSimulatorFrames` requires an unlocked Mac, a changing
  simulator surface and `SQUIRCLE_VERIFY_STREAM_MOTION=1`; it is skipped by
  default. The normal native test command separately excludes signed-out Claude.
  The stream's idle request timeout was raised to avoid disconnecting a quiet
  simulator after 30 seconds. No continuous-video or latency milestone is claimed.
- Claude CLI reported `loggedIn: false`; T3's real Claude turn returned an
  authentication error despite its ready provider inventory. User was asked to
  restore login; success is not yet verified.
- The live AVCC packet probe received **one tag-4 JPEG seed, no H.264 packets**
  over its observation window. H.264 encode/decode throughput and transport
  latency need an active-screen test. Native fallback is implemented; do not
  claim the host latency issue fixed. Supported `device.list {retryHostId:local}`
  completed successfully but did not establish recovery.
- Signed Xcode archive/export succeeded: **0.2.0 (11)**, job
  `0e7c4157-3673-400e-9460-bbdc2c8d5f31`, bundle `ai.dreamslate.Squircle`;
  IPA and dSYM retained in the existing job store. HTTPS installer returns 200.
  The exported IPA signature verified; its manifest reports build 11 and its
  provisioning profile includes the paired iPhone. The exported app embeds the
  correct build job ID for its automatic manual-launch acknowledgement.
  Direct phone installation failed with CoreDevice error 4016 (required usage
  assertions/connectivity unavailable); a two-hour installation link was given.
- The actual native gallery capture was published to app
  `5f9b0650-b20b-4cd6-bcf2-a57574cab08c`, preview
  `adec430b-f263-4f4b-a58a-13ac3023e8f7`, alongside its updated summary.
  Final UI/touch/motion-frame verification remains pending. The Mac locked
  during checks; a signed build is not evidence that
  these interaction checks passed. Phone manual launch acknowledgement pending.

The active target removes Hermes transport, attachments, conversation reducers,
question adapters and delegated trace polling. Stock Hermes remains untouched.
Read historical `docs/validation.md` as earlier-build evidence only.


## Simulator lifecycle hardening: 2026-10-05, build 12

The user reported that the preview initially felt responsive, then disappeared
or stopped accepting touch. Three independent faults were found:

1. Client startup raced priming/video/input. A fresh helper could reject input,
   and the old input path did not retry as part of the video lifetime.
2. Presentation remembered the device separately from the stopped stream, so
   returning to the same target could suppress restart. Background/navigation
   also lacked complete resource recovery.
3. T3's host capture survived a generic simulator reboot and served stale seeds.
   Cards' actual screenshot showed its running app while the stream showed an
   Apple boot logo. T3's supported `device.shutdown` then `device.open` cleared
   that capture; both the stock viewer and native preview returned to live frames.
   This was a capture reset, not a backboardd/input-ownership repair.

Build 12 removes the AVCC/fallback race and uses one stock native MJPEG path.
The first video frame precedes the input config handshake; a single interactive
channel owns both resources and its ordered gestures. Enum cases carry the
resources permitted in each state. Either failure disables interaction, closes
both and retries. Generation checks suppress stale callbacks. Hide, pause and
restart are explicit presentation states. An explicit simulator restart delegates
to T3's capture-aware shutdown/open API. Idle feeds never trigger an app restart.

Evidence (local, Xcode 27.1 / iOS 27.0 / stock T3 0.0.45):

- Standard suite: **20 passed, one optional motion test skipped**, including a
  real Codex tool turn and persisted history. Log:
  `/tmp/squircle-preview-final-live-tests.log`.
- Motion/soak run: continuous native frame test **passed**, and the lifecycle
  test passed six forced input socket losses, duplicate starts, immediate startup
  cancellation/reopen and a **31-second quiet interval**. Total 38 seconds; log
  `/tmp/squircle-preview-stream-soak.log`. These runs verify 21 distinct tests;
  they are not a single all-tests run with no skips.
- Supported QA reset also restored live AVCC host packets: 171 tag-3 packets over
  eight seconds. H.264 client playback was removed for simpler lifecycle ownership;
  this packet probe is host evidence, not validation of the shipped decoder.
- Final deterministic suite: 16 passed in
  `Test-Squircle-2026.10.05_18-25-22-+0200.xcresult`. Final UIKit source compiled
  successfully in `/tmp/squircle-preview-final-build12.log`.
- Signed build **0.2.0 (12)**, job `a5d12767-36dd-4167-9a9f-c55c3a7445ec`;
  archive, IPA and dSYM exported. Code signature verified. `devicectl` reports
  successful installation on the paired iPhone. Manual launch of this build and
  the user's new interaction result remain pending.

MJPEG increases bandwidth relative to H.264. Measured phone/cellular latency,
long-duration sleep/wake, crash recovery, native pinch, Claude login and all
approval/question UX branches remain separate checks. Do not infer their success
from the reconnect soak or a signed archive.

The final build-12 source was also retested after signing: both initial native
frame/input and repeated lifecycle/recovery tests passed (39.5 seconds, zero
failures), `/tmp/squircle-preview-build12-recovery.log`. Its installer page
returns HTTP 200 and the manifest reports bundle-version 12.


Manual native simulator checks passed for live preview, Home, hide/reopen of the
same target, and tap-driven changes in Cards-Verify before/after reopening. CUA
operated the native client through the T3 desktop QA surface; actual `simctl`
PNG captures verified the rendered client independently of the desktop viewer's
lagging playback. Published capture `1370ef09-0972-4838-bd2d-05b0df7783c5` belongs
to Squircle app `5f9b0650-b20b-4cd6-bcf2-a57574cab08c`.

Final build-12 motion recording contains 302 actual rendered frames over about
7.4 seconds. All 222 captured frames numbered 80–301 were inspected in consecutive
contact sheets with no frame resampling: gallery → TidyKeys workspace → gallery.
The device moves continuously and the title stays attached to its app through
open/close; the prior stale title transform was removed. This verifies that
representative transition, not every gesture/landscape/provider flow or physical
phone frame cadence. Debug motion hooks are excluded from Release. Private local
evidence is retained under `.squircle/verification/build12/`.


## H.264-only correction: 2026-10-05, build 13

The user rejected build 12's MJPEG playback after testing high latency on the
same Wi-Fi. Choosing the simpler decoder without measuring latency was a
regression. Build 13 preserves the lifetime/input fixes and replaces JPEG playback
with the stock authenticated `stream.avcc` feed and native VideoToolbox decoding.
No MJPEG endpoint is requested, and tag-4 JPEG seeds are ignored. No fallback,
priming stream, new host component or T3 modification exists.

The framer handles arbitrary HTTP fragmentation and validates packet bounds.
Codec descriptions create a decoder waiting for an H.264 keyframe. Reference
frames are decoded serially off the main actor, with asynchronous/temporal flags
clear. Physical-phone decoder creation requires hardware acceleration. Only the
newest decoded image awaits UIKit, and the display drops decoded images when busy.
HTTPS video and WSS input remain on the existing user-managed Tailscale origin;
this change does not introduce WebRTC or direct LAN routing.

Verified on the final source:

- **Nine targeted tests passed**, zero skips/failures. Fragmented/coalesced AVCC
  and malformed lengths, existing target/coordinate/event/configuration coverage,
  actual initial decoding/input handshake, continuous motion and lifecycle recovery.
- Continuous QA motion: **180 decoded H.264 frames, 125 changed sampled pictures**
  in an 8.058-second test. Decode mean **3.23 ms**, maximum **7.37 ms** through
  frame 180 on the Mac's iOS simulator. These are decode times, not end-to-end
  latency or physical-phone hardware measurements.
- Six forced input disconnects restored fresh video/input pairs; duplicate starts,
  startup cancellation/reopen and a 31-second quiet interval passed again.
- A separately decoded first H.264 keyframe matched the native QA workspace and
  current clock. The existing desktop viewer was showing an older image; it was
  not used as frame-freshness ground truth.
- Actual build-13 native rendering showed SpringBoard. A touch through Squircle's
  preview opened Settings and the rendered H.264 preview changed accordingly.

- Signed **0.2.0 (13)**, job `073cf325-1bfa-4466-8de6-5f0531204934`, with IPA,
  archive and dSYM. CoreDevice installed it on the paired iPhone successfully; the manual-launch
  acknowledgement subsequently arrived.
- Catalog preview `9b1a96ca-6c3b-4493-bf45-d79b0e132552` contains the actual native
  H.264 preview after touch. Evidence retained under `.squircle/verification/build13/`.

The user subsequently confirmed build 13 works well and requested committing it
and stopping testing. This is a successful manual phone check; quantitative
phone input-to-visible latency and cellular bandwidth remain unmeasured.
No new navigation geometry was introduced; the earlier rendered motion evidence
is retained, without claiming another physical-phone visual audit.

## Provider-selection correction: 2026-10-05, build 14

Every thread subscription update copied the persisted model into the composer,
which reset a local Claude choice to the thread’s previous Codex selection. The
client now retains an explicit choice per thread until the server acknowledges
it. Live activity, reconnect snapshots and navigating away/back preserve that
choice; after acknowledgement, server changes become authoritative again.

Two targeted native tests passed, zero failures, in
`/tmp/squircle-provider-live-test.log`: selection regression across activity,
reconnect and thread navigation; real Claude tool execution/reply and persisted
history in thread `6157c318-6538-4ebb-b2bf-14330b211a71`.
An initial sandboxed `claude auth status` incorrectly suggested signed-out state.
Outside the sandbox, the installed CLI confirmed Claude Max subscription login,
and T3 successfully executed the real turn. No login or server changes were needed.

Signed 0.2.0 (14), job `99f5eb12-42fa-43a2-9edf-1f9558134da5`,
was installed successfully on the paired iPhone with CoreDevice. Manual launch
and the user’s phone check remain pending. No navigation geometry changed.

## 2026-10-05 redesign, 0.3.0 (15)

User request: a total rethink — gestures fought, motion was not fluid, the 3D
device had little presence, threads were basic, the simulator was ugly and hard
to reach.

**What changed**

- Removed the workspace screen, the full-screen zoom-presented thread (its
  system dismiss gestures competed with scrolling and simulator touches) and
  the flat `AVSampleBufferDisplayLayer` simulator panel.
- Home and its thread lists are native scroll views; the thread transition and
  the divider are each one interruptible spring. Back is a rightward pan
  anywhere in the thread; the conversation's scroll waits for it to fail, and
  it never begins on the live device or divider.
- The simulator picture is a Metal texture on the 3D display. The decoder now
  outputs 32BGRA instead of NV12. Input is unchanged (same T3 socket/protocol).
- Tool activities are merged per `toolCallId`; approval, context-window,
  runtime-warning and checkpoint bookkeeping no longer appear as rows.
  Reasoning summaries appear as collapsed thoughts.
- Threads are created on first send instead of on opening New Thread.

**Evidence (iOS 27.0 simulator, this source)**

- 22 unit tests passed (layout, springs, conversation grouping, ambient color,
  existing T3/AVCC/catalog tests).
- UI tests `testNavigationAndMotion` and `testRapidNavigationStaysConsistent`
  passed with real gestures.
- Held frames of the thread transition at 25/50/75 %, list expansion, all three
  detents, and dark mode were captured and inspected. Live video from a booted
  simulator rendered on the device with correct color; scene hit-testing
  returned top-left ≈ (0.07, 0.04), center ≈ (0.51, 0.50), bottom-right ≈
  (0.94, 0.96), nil outside the display.

**Not verified**

- Anything on the physical iPhone: frame rate, feel, tilt parallax, hardware
  BGRA decoding, latency, and a real finger driving the simulator through the
  3D device. Simulator touch delivery end to end was not exercised in this pass
  (only the coordinate mapping).
- Import, signed-build, reduced-motion, visual-tour and accessibility UI tests
  were rewritten for the new structure but not re-run. Live T3 round-trip tests
  were not re-run.

## 2026-10-05 approval controls, 0.3.0 (16)

User requested T3 approval options with Auto as the default. New drafts and
threads now use the stock `auto` runtime mode for creation and turn start;
existing threads retain their authoritative saved mode. The agent menu puts
Ask (`approval-required`), Auto edits (`auto-accept-edits`), Auto (`auto`) and
Full access (`full-access`) first, with the current mode checkmarked and shown
under the thread title. Changes use `thread.runtime-mode.set`; a local choice
survives stale snapshots and navigation until T3 acknowledges it. A rejected
change restores the previous choice and reports the error. Approval controls
remain available during execution; provider/model changes remain disabled then.

Approval prompts display T3's supplied option labels, decisions and warnings in
a vertical stack, including session/always acceptance when offered. User-input
questions still require answers. There is no client-side blanket acceptance or
server/provider configuration change. Contract reference:
[stock 0.0.45 orchestration](https://github.com/pingdotgg/t3code/blob/v0.0.45/packages/contracts/src/orchestration.ts).

Evidence: nine deterministic T3 tests and the actual draft menu interaction test
passed on final source (`/tmp/squircle-approval-release-check.log`). Both Codex
and Claude executed `pwd` and returned the requested marker in Auto, with no
pending requests; each verification thread persisted all four runtime mode
changes through T3's standard command API (`/tmp/squircle-approval-final-tests.log`).
Threads: Codex `dc054872-c5a1-4351-9be0-f6354d44a6b1`, Claude
`ef798f6c-cf3f-4315-ae5c-a8c0ed47b087`. This verifies that small read-only turn,
not provider behavior for every potentially sensitive command.

The rendered native menu was inspected and published to catalog app
`5f9b0650-b20b-4cd6-bcf2-a57574cab08c`, preview
`3aacecec-a290-4074-b110-9ba668b964bf`. No motion geometry changed.
Signed build 16 succeeded: job `93cbab47-9aee-425c-b460-40597f7a140f`.
Automatic approval review rejected installation-link creation because external
access to the private IPA was not explicitly authorized; no link was created.
The user then explicitly requested running the app on their phone. CoreDevice
installed build 16 on the connected physical iPhone 17 Pro Max and successfully
opened `ai.dreamslate.Squircle` with `device process launch`. No debugger was used.
The build service confirmed `launch_observed: true` for this job.
Physical-phone approval interaction and user experience remain unchecked.


## 2026-10-05 draft and model picker fixes, 0.3.0 (17)

New Thread previously adopted `selectedSessionID` during its initial render,
before its asynchronous draft reset. That also changed the ID read by the reset
task, causing it to reopen the existing thread. The controller now captures the
requested navigation target, waits for selection before rendering conversation
state, and adopts a created ID only after submission. Stale subscription handles
are discarded if selection changes during subscription startup.

Opening a simulator no longer creates a thread from a draft. `createSession` is
private to the send flow, empty submissions are ignored, and duplicate concurrent
submission is guarded. New drafts show flat model shortcuts for the saved preference
and ready providers' defaults, with an All models menu. Tapping the composer opens
the keyboard; opening the draft leaves the shortcuts visible. Preferences are
validated against the current T3 catalog. Existing threads expose only models
from their established provider instance; unknown/loading identity offers no model
changes. The same validation rejects invalid choices outside the UI. Approval
controls remain available.

Evidence: ten deterministic native T3 tests and UI tests
`testNewThreadAfterExistingThreadStaysAnEmptyDraft` and `testDraftApprovalOptions`
passed (`/tmp/squircle-draft-tests.log`, iOS 27.0). Native command capture checks
zero writes before nonempty submission and exactly thread.create followed by
thread.turn.start using the same new ID and selected model. UI verification visits
an existing thread, opens an empty draft, chooses a shortcut, abandons it, and
reopens another empty draft. The initial UI run caught keyboard occlusion; the
final run passed after removing automatic focus.

The actual rendered draft was inspected and published to catalog app
`5f9b0650-b20b-4cd6-bcf2-a57574cab08c`, preview
`499dd5eb-3ec5-4b51-9f5b-994ffe5aedfe`. This verifies the resting layout; transition
geometry was unchanged and no new frame-by-frame motion claim is made.
Signed build 17 succeeded, job `69a6b926-42e3-4cfe-b400-708476e27438`.
Phone installation/interaction and new live provider turns were not exercised
in this pass.

## 2026-10-05 in-app install and New Thread layout, 0.3.0 (18)

The user reported installs bouncing through Safari and needing a second tap.
The client opened the install-link reply's `page_url` (the Mac's HTTPS page);
it now opens the same reply's `install_url` (`itms-services`) directly, after
checking that its manifest URL is HTTPS on the configured Squircle host and port.
iOS then shows its own install confirmation over the app. That confirmation is
an OS requirement for ad-hoc installs and cannot be removed; installing a new
Squircle build still terminates the running copy. No server change.

New Thread: the device opens at the half detent with the app's real screen; the
mid-screen radio list, "Model" caption and repeated app name are gone. "What's
next?" and glass model chips (selected one prominent, then More for the full
menu) sit directly above the composer and wrap rather than scroll, so every
choice stays reachable.

Evidence: ten native T3 tests (plus stage-motion and live T3 tests) and UI tests
`testNewThreadAfterExistingThreadStaysAnEmptyDraft` and `testDraftApprovalOptions`
passed on iOS 27.0 simulator. A first run failed because More scrolled off-screen
in a single horizontal row; the wrapping layout fixed it. The rendered draft was
inspected and published to the catalog. Build 18's install link was checked to
carry an `itms-services` URL whose manifest is on the configured host and port.
Signed build 18 succeeded, job `d9f84f42-2113-441a-b9c0-9f41b9e68ca2`. Not yet
checked on the phone: the direct install prompt itself.

## 2026-10-05 thread redesign, 0.3.0 (19)

User request: comprehensible agent work, fluid motion, prominent glass and
shader effects; the agent should drive the simulator visibly, with inline
screenshots and recordings; no header; iMessage-like send; jump to bottom;
better agent questions. Decisions: handwritten Metal (SwiftUI never drives
layout), collapse finished turns but no single glass blob per turn, diffs one
tap away, effects bold for now.

**Data.** T3 0.0.45 projects every activity before sending it to clients
(`projectActivityPayload`): tool `input`, edit text and result images are
dropped, and snapshots keep only the latest 500 activities. The Squircle
service therefore adds `GET /v1/t3/threads/{id}/steps` (and
`…/steps/{call}/images/{n}`), reading `projection_thread_activities` from
`~/.t3/userdata/state.sqlite` with `/usr/bin/sqlite3 -readonly`; identifiers are
validated before interpolation. T3 itself is unmodified. During a running
command its description is not yet stored, so the live line shows the
humanised command until the step completes.

**Timeline.** Turns split at your messages. While running: the latest note,
the newest four steps on a rail (the running one is the live pill's headline),
earlier steps folded with their screenshots in a sideways gallery. Finished:
a glass "Worked for 6m 12s · 23 steps · 4 files changed" pill, screenshots kept,
then the answer. Rows enter with a spring; the summary ripples and a success
haptic plays when a turn ends. Galleries show newest first so a swipe right
still goes back.

**Simulator and media.** When T3 reports a device session for the thread, the
device rises to half and goes live; it settles when the agent closes it.
Squircle tells agents (once per thread, hidden in the conversation) which
simulator to open and how to record; `squircle media add` stores clips under
`.squircle/threads/<id>/media/` and `GET /v1/t3/threads/{id}/media[/{id}]`
serves them. Clips loop muted inline and play full screen on tap.

**Evidence (simulator, iOS 27.0).** 13 stage/timeline and 10 T3 unit tests
pass; 74 Rust tests pass. UI tests: both draft tests, navigation and motion,
and reduced-motion navigation pass. `testRapidNavigationStaysConsistent` fails,
and fails identically on the pre-redesign commit `043d5fc` (it opens the newest
thread, this very long live one). End-to-end on this thread: opening a
simulator from the agent made the device rise and stream live within a second;
a `device_screenshot` appeared inline; an agent-device recording published with
`squircle media add` played inline. The send flight was checked frame by frame
at 1/12 speed (one bubble, no duplicate text, conversation scrolls on the same
spring). The Metal glow was checked in captures. **Not visually verified:** the
completion ripple. Nothing was tested on the physical phone; frame rate and
Metal cost there are unmeasured.
Signed build 19 succeeded, job `9383b6be-0c88-476e-8cda-5c01bc176ccd`; its
thread capture is published to the catalog. Not installed on the phone.

## 2026-10-06 glass and flow, 0.3.0 (20)

User feedback on build 19, all addressed:

- **Builds in chat.** Any build job ID the agent ran or wrote in a turn that
  matches a Squircle build shows after the answer as a glass card with live
  status and Install (the direct `itms-services` prompt). Agents are told to
  put the build ID in their final reply.
- **History doesn't animate.** Galleries animate only shots added to the same
  gallery while visible; cached pictures never cross-fade.
- **Sticky turn header.** An expanded turn's summary pins to the top while
  you scroll inside it, pushed away by the turn's end; tap folds it.
- **Header-less.** Docked, the conversation runs to the top under the back
  button with the system scroll-edge blur; the device floats above the text
  as a PiP (a hole in the conversation's mask).
- **Back** is a left-edge swipe only.
- **Paragraph spacing** in agent answers.
- **Pickers.** Separate model and approval glass capsules above the field;
  menus build when opened, so live updates no longer reset them; short model
  names, sorted by version then size.
- **Glass, not rainbow.** The spectrum glow is removed. The live state is a
  glass loupe with a slow sheen; a Metal lens (`lensFragment`) hands each task
  over: the old line is compressed toward the glass edge, drawn in, split
  slightly by colour and faded as it rises out, while the next rises in. Text
  is crisp at rest (text actually behind the glass was blurred unreadable).
  The finished-turn ripple is white light.
- **Liquid send.** The message field's glass and the new message share a
  `UIGlassContainerEffect`: the message is born as a drop at the send button,
  swells while still joined to the field, and separates into a tinted glass
  bubble. User messages are tinted glass.
- **No jumps.** Structural changes during a turn animate; measured row
  heights are cached with per-type estimates.

Evidence (simulator, iOS 27.0): unit tests and the draft, approval and
navigation UI tests pass. Checked frame by frame with debug slow motion: the
lens hand-off (no size jump at its start, continuous overlap) and the liquid
send (drop fused to the field with smooth fillets, then separated). Sticky
summary pinning and tap-to-fold, the build card, the PiP hole, the scroll-edge
blur and pickers were checked in captures. Not checked on the physical phone.
Signed build 20 succeeded, job `28701013-3ca1-4c73-ae54-f173590384a2`; its
capture is published to the catalog. Not installed on the phone.

## 2026-10-06 diffs and a clean back swipe, 0.3.0 (21)

- **Correction after user feedback on build 20:** the send drop showed the
  message text spilling out of it (visible in the earlier slow-motion frames
  and wrongly accepted), and the glass message bubbles and the pill's sheen
  looked broken on the phone. The drop now carries no text and lands exactly
  on the bubble, which fades in; bubbles are solid tinted; the sheen is gone.
- **Diffs.** T3's thread snapshot carries a checkpoint per turn with changed
  files and line counts, so each finished turn shows a pill without a request.
  Tapping fetches `orchestration.getTurnDiff` (count − 1 → count). The viewer
  parses on a background thread into flat lines; a plain table shows one
  fixed-height, hand-laid-out row per line with sticky glass file headers
  (tap to fold); long lines scroll sideways together. No third-party package.
  Working-tree and last-commit diffs are not shown yet (T3's
  `review.getDiffPreview` needs a write-scoped token).
- **Jump to latest** is in the chip row's trailing end; the scroll is driven
  by a spring every frame and glides the last screen from any distance.
- **Back swipe.** Home passes the travelling device's frame to the thread,
  which cuts the conversation away around it, so text and screenshots never
  cover the device; the thread's floating controls fade as it leaves.

Evidence (simulator): unit tests and the draft, approval, navigation and
reduced-motion UI tests pass. The send was checked frame by frame at 1/14
speed. Back-swipe states were checked frozen at 35, 60 and 85 % for docked and
half detents. The diff viewer opened a real 8-file turn diff from T3, scrolled
and scrolled sideways with headers pinned. Not checked on the phone.
Signed build 21 succeeded, job `ea489ca3-23f5-4275-8c95-ff26ccebd611`. Not installed on the phone.

## 2026-10-06 phone on top, one-arc tap, Messages send, 0.3.0 (22)

- The 3D devices render in an overlay above the conversation, so the phone
  always sits on top; the conversation cut-out (which lagged the device
  during the edge swipe) is removed.
- Tapping the device moves it in one spring arc from its pose to the target
  detent's pose, lifting toward the viewer and turning to show its body,
  instead of sliding then growing.
- Send follows Messages: the bubble, with its text, rises from where the
  text was typed into place; the placeholder stays hidden until it lands.
  (Build 21's text-free drop was a misreading of the feedback.)
- 3D: jittered antialiasing at rest and native-scale rendering. Live-stream
  frames have no mipmaps, so tiny docked live pictures can still shimmer.

Evidence (simulator): tests as before pass; tap arc and send checked frame by
frame in slow motion; back swipe frozen at 25/55/85 % docked and half.
Signed build 22 succeeded, job `bba26565-54c6-403b-baf7-efaba4495f8b`. Not installed on the phone.

## 2026-10-06 polish, 0.3.0 (23)

- Your messages are tinted glass; glass rows rise on entrance instead of
  fading (faded glass renders wrongly).
- Finished-turn pulse: a soft Core Animation bloom around the summary pill
  (the Metal ring rendered low-rate and blurry). `Effects.metal`,
  `EffectView` and `LensView` are removed; no Metal shaders remain.
- Live pill: task text slides vertically and is clipped by the capsule.
- Pinned to the bottom, every change (your message, live pill, agent rows,
  streaming text) follows on one retargeting spring, including after the
  send flight and after animated row changes.
- Threads are cached in memory and in Caches/threads (state, step details,
  media); reopening shows the cached thread synchronously, laid out with
  per-thread cached row heights, at the bottom. A restored thread accepts the
  next live snapshot regardless of sequence.
- Home orders apps by last opened (UserDefaults), reordering only when a
  thread opens.

Evidence (simulator): unit tests and the draft, approval, navigation and
reduced-motion UI tests pass. Re-entry captured every 150 ms: the thread
appears at the bottom and does not move. Pill slide and pulse checked in slow
motion; send ends pinned with the live pill visible.
Signed build 23 succeeded, job `b98771f0-439e-4e8a-abc9-107ba1293aca`. Not installed on the phone.

## 2026-10-06 in-app debug overlay, 0.3.0 (24)

User request: iterate on an app from inside that app, with no developer effort and
nothing in App Store builds. **Decision (user, 2026-10-06):** inject instead of
asking projects to link a package, and share Squircle's paired connection through
the Keychain.

- **Framework.** `SquircleOverlay.framework` (target in `app/Squircle/project.yml`)
  compiles Squircle's own `Sources/` minus `SquircleApp.swift`, plus `Overlay/`.
  No code is duplicated. A C constructor starts it on load. It attaches a
  passthrough window holding a draggable glass bubble: a pulsing dot and the
  title of a working thread, orange when the agent needs you. Tapping springs
  open Squircle's Studio scoped to the host's bundle ID (threads, new thread,
  builds with Install, live simulator device); the top-right control closes it.
- **Injection.** After `archive` and before `exportArchive`, the CLI
  (`src/overlay.rs`) builds the framework once per source hash into
  `.squircle/overlay/<hash>/`, copies it into the app, adds a weak
  `LC_LOAD_WEAK_DYLIB` in the header padding, adds the
  `<team>.ai.dreamslate.squircle.shared` Keychain group to the app's entitlements
  (its own group stays first) and re-signs. The export then signs it like any
  embedded framework. Default on; `build start --no-overlay` (or
  `"no_overlay": true`) leaves it out.
- **Never in production.** Injection happens only for `development`, `debugging`,
  `ad-hoc` and `release-testing` exports, never for Squircle itself or simulator
  builds. At runtime the overlay requires an `embedded.mobileprovision`, which
  App Store builds lack.
- **Credential.** Squircle (which now has the shared group) writes its `client.json`
  to the Keychain item `ai.dreamslate.squircle.shared.client`
  (this-device-only). The overlay reads only that and stays off without it.
  Accepted risk: any code inside a test app, including third-party SDKs, could
  read the full T3 token on that phone.

Evidence (Xcode 27.1, iOS SDK 27.1): Squircle Probe build `6b8961c0-697a-4932-bfa5-8ac521bcea96`
exported with the overlay; `codesign --verify --deep --strict` passes; the
export re-signed the framework with Apple Distribution (2F26US4NAU); entitlements
list both Keychain groups. Overlay binary 1.4 MB; the IPA grew from 165 KB to 776 KB.
Squircle build `1bd05d40-3585-4341-ac0a-86572806af82` carries the shared group.
**Not yet validated:** overlay launch and use on the phone.
