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

**Fix, 0.3.0 (25):** several Xcode projects inside one T3 workspace (this repo
holds Squircle and Squircle Probe) made the app whose Mac record was updated last
take over the T3 project, and importing Probe failed. The owner is now chosen
independently of list order (the project nearest the workspace root, then the
one T3's title names), and importing an app whose surrounding T3 project
belongs to another app creates a T3 project for the app's own folder. Build
`03aca239-90fe-4593-a525-c2da742ddbb8`; catalog regression test passes.

**Fix, overlay never blank:** an app Squircle built but never added to T3 (Probe
shared the repo's T3 project) left the overlay with nothing to show. The overlay
now creates its own app's T3 project the way Add app does (matched by bundle ID
in the Mac catalog) and shows the error if that fails. Probe build
`87ca3c4e-caa7-48bc-abad-47d89eb7b217` carries it. Not yet validated on the phone.

**Redesign, compact glass overlay (user request, 2026-10-06):** the overlay had
opened all of Squircle. Now one spring moves a glass surface among three rests.
The **bubble** is the thread's live capsule: the turning mark and the step the
agent is on, sliding vertically; orange "Needs you"; a soft beat and "Done" when
a turn ends; a plain mark when idle. Drag it to either side. Tapping grows it
into a **card** (draggable by its top, paper under the glass so it reads over
any app): app name, Builds, full screen, minimize, the live capsule, compact
thread rows and a "New thread" field. A row or the live capsule grows into the
**full conversation**; back or the left-edge swipe shrinks it into the card,
following the finger. In the overlay the conversation opens docked and the
device appears only while the agent's simulator is live (you are already in
the app). `LiveCapsule` is shared with the thread's live row. Debug builds of
Squircle host the overlay for simulator checks with
`SQUIRCLE_OVERLAY_DEMO=<bundle id>`. Verified frame by frame in the simulator
(Squircle Debug, scoped to Squircle): all four transitions are continuous and
the opened thread is kept. Probe build `561aa697-61e7-4bef-8134-e23931e2d0eb`
carries it; not yet seen on the phone.

**Second redesign (user request, 2026-10-07):** no clipped morph; standard
Liquid Glass instead. The bubble and panel are glass in one
`UIGlassContainerEffect`: opening dematerializes the bubble's glass while the
panel's materializes at the same place, and the content scales out of the
bubble and fades in above the glass (it is a sibling of the container, so the
conversation's own glass controls are not merged into the panel). The bubble
and the panel share one anchor: the panel grows from the bubble's corner, and
moving either moves both. The panel shows the thread list or one thread, and
either can be mini (floating over the app while you use it) or full screen;
opening a thread keeps the size. Back is the thread's back button or a swipe
from the panel's left edge. The overlay hosts the conversation directly on its
own stage (transparent when mini, Squircle's backdrop when full); the device
appears only while the agent's simulator is live. A message in the list's field
starts a thread and opens it in place.

**Installing the running app (2026-10-07):** the Mac records when iOS first
fetches a link's IPA (`downloaded_at`, `GET /v1/install-links/{token}`), which
happens only after Install is tapped. A build of the running app (Squircle
itself, or an app with the overlay) then shows a glass notice that the app is
closing to update and goes to the Home Screen, where the icon shows progress;
it returns to normal if the update fails. iOS has no way to reopen an app after
replacing it. Squircle `151a7519-aa01-4af6-acaf-b758055dc285` (0.3.0 26) and
Probe `1abd89ec-8a3d-4403-909e-aa30debb25ff`; transitions verified frame by
frame in the simulator; not yet on the phone. *Superseded 2026-10-14
([review fixes](#2026-10-14-code-review-fixes-030-56)): `downloaded_at` was
set when the request arrived; it now means every byte was sent, and
`download_started_at` marks the IPA being opened. The curtain waits for
`downloaded_at`.*

**Correction, real glass morph (2026-10-07):** the previous build faked the
morph: two glass views crossfaded (materialize/dematerialize in a container)
while the content scaled and faded, which ghosted; and moving the content above
the glass broke panel dragging (only the glass moved). The system morph between
distinct shapes (`glassEffectID` in a `GlassEffectContainer`) exists only in
SwiftUI, which may not drive this layout. Now the bubble and panel are one
`UIGlassEffect` view whose frame and corners animate on a spring, so the glass
itself reshapes; the bubble's line fades as the shape leaves it, and the panel's
content (laid out at its final size, above the glass) fades in as the glass
arrives, so nothing is clipped. Dragging moves glass and content together by the
finger's offset and springs to the side with its speed; pans start from the
touch-down point. Verified frame by frame in the simulator (open, minimize,
panel drag, bubble drag). Probe `3218ba9c-7b9e-4fb2-8e2b-7d92547143af`.

**Morph, stretch and cross blur (user request, 2026-10-07):** one spring
(slightly underdamped) drives the morph. Every frame the single glass view takes
a shape between bubble and panel, past the panel while it overshoots; the panel's
content is stretched to that shape and un-blurs (Core Animation's Gaussian blur
filter, private API, only in the injected overlay and Debug builds) as it fades
in, while a plain copy of the bubble's line stretches and fades out. Found in
frame review: a blur filter renders transparent areas black, so only the
panel's content (on its paper) is blurred, and the live bubble line (masked
shimmer) is swapped for a plain copy during the morph. Probe
`1b6ebe57-95b3-4449-ba9c-babb90327c7c`.

**Agent overlay (user request, 2026-10-13):** "not updated at all for the new
unified single agent design … has a separate glass container that gets out of
sync with the rest of the ui". The installed Letters Abroad build
(`05e83365`, overlay cache `62fc26ae…`) already carried build-39 shared code;
the overlay's own controller had not changed since build 26. Now:

- Opening the overlay shows the app's agent conversation (the same
  `ThreadViewController` as the app, `agent: true`) with Threads and Builds
  beside a minimize button, and a full-screen toggle. Threads opens the
  threads sheet; a thread (or a worker update line) pushes in over the agent
  inside the panel; back or a left-edge swipe returns. The agent is mounted
  once and kept, so the panel opens already showing it. The bubble shows who
  needs you, else the agent's live step, else a working thread.
- One glass view holds everything: the bubble's line and the conversation are
  in its `contentView`, clipped by its corners. Its frame is one vector spring
  (`FrameSpring`: x, y, width, height in one display link, velocity kept when
  retargeted, held by a finger while dragged). Bubble ↔ mini ↔ full, side
  changes, keyboard and bubble width all retarget that spring; every frame
  derives the corner radius, the line's fade and the conversation's place
  from the presented frame. The conversation is laid out at least at mini
  size, pinned to the bubble's corner (the glass reveals it), and never
  larger than where the glass is headed (an overshoot shows paper, not a
  relayout). Removed: the separate content layer, stretch and Gaussian blur,
  and the `UIView.animate` resize, drag and keyboard animations.
- Opening first captures the host app into the message field (`hostWillBeCovered()`, `HostCapture`). *Superseded 2026-10-13: only a long press captures; see "Capture on long press" below.*
- DEBUG: `SQUIRCLE_OVERLAY_OPEN=mini|full`, `SQUIRCLE_OVERLAY_CYCLE=1`
  (with `SQUIRCLE_SLOW`) under `SQUIRCLE_OVERLAY_DEMO`.

Verified in the simulator (Squircle Debug scoped to Squircle, iPhone 17 Pro,
iOS 27.0) from a 4× slow recording at 4 fps: open, mini → full, thread push
and back, close and bubble width changes are one continuous shape with no
content outside it. Letters Abroad build with this overlay: job
`7cc921b4-50e4-49dc-ac12-9ba479bd03c9` (built from this branch's overlay sources,
key `ebaea9fe…`, then imported). Not yet on the phone.

**Stretch and cross blur, even padding (user request, 2026-10-13):** "animation
is ugly, dont want it clipping like this, just stretch and cross-blur the
content. need consistent padding around all sides". The glass is still one
`FrameSpring`, but nothing inside it is laid out from the moving frame any
more: the bubble's line is laid out at the bubble's size and the conversation
at the panel's resting size (mini or full, kept while it closes), and both are
scaled to fill the glass's presented frame every frame, so they stretch with
it (overshoot included) and are never cut by its edge. The outgoing one blurs
and fades as the incoming one sharpens (Core Animation's Gaussian blur, as on
2026-10-07). Mini ↔ full lays the conversation out at the new size and
cross-blurs it with a snapshot of the old layout, stretched the same way. Paper
is the blurred layer's own background (the filter turns clear areas black);
the system's scroll-edge blur can't draw inside a filtered layer or a
snapshot, so while the glass morphs it is hidden and the conversation fades
under the top controls with a mask. Padding: one 12 pt inset between the safe
area and the glass, and between the glass and the controls, composer, model
pickers and request card on every side; the mini panel's corner radius (34) is
concentric with the 44 pt buttons. The conversation gets the safe area it
will have at rest (`setOverlayLayout`), since UIKit's would change as the
glass stretches. Verified in the simulator (iPhone 17 Pro, iOS 27.0) from
4×/5×/12× slow screenshot sequences of the full `SQUIRCLE_OVERLAY_CYCLE`
(open, mini → full, thread push and back, full → mini, close, interrupted
open/close): continuous, no clipping, no black; insets measured 12 pt in mini
and full. Not re-checked: dragging the bubble or panel by finger (the gesture
code only changed coordinate space). Letters Abroad build with this overlay:
job `760e6572-a8b8-43ce-9899-3fcd25eb81e9` (overlay key `b82197f2…`, built from
main at `efa4bf6`); not yet on the phone.

**Lighter overlay, design A (user choice, 2026-10-13):** "generally heavy
feeling … huge glass blobs … all the extra buttons too especially in the little
docked one". Of three DEBUG alternatives the user picked A (Messages-like),
with changes. The overlay's conversations use `ChatStyle.light` (the app keeps
`standard`): "Worked for…", the changes pill and the live step are plain gray
text lines instead of glass; build cards are a plain fill with a solid Install
button; your messages keep their glass bubbles. Threads, Builds, full screen,
model and approvals are one ⋯ menu at the top right (the resize button and the
pickers' row are gone, so no empty band above the field). The field's + and
send are 30 pt, each centred on the one-line field 9 pt from its edge. A grab
handle at the top centre resizes the panel: its top edge follows the finger
and the conversation is laid out at the glass's own size every frame (text
reflows, nothing stretches) until the spring rests; above the docked panel it
widens toward full screen. Released within 20 pt of the top it goes full
screen, shorter than 180 pt it folds into the bubble (with the morph's
stretch), else it docks at that height, with the finger's speed (`FrameSpring`
now takes a size velocity). Tapping the handle toggles full screen. Measured in
the simulator (iPhone 17 Pro, iOS 27.0): the docked panel's content sits 12 pt
from all four of its edges, and the panel 12 pt from the screen's sides.
Handle drags (taller, full screen, back to docked, collapse to bubble) were
driven by a throwaway XCUITest and checked in screenshots, including frames
while the finger held mid-drag. Not checked: the ⋯ menu's items, a pushed
thread's back + ⋯. Letters Abroad build with this overlay: job
`5384b535-7a74-4387-8627-05f99a0d1e60` (overlay key `285a1fff…`, main at
`280b6a8`); not yet on the phone.

**Capture on long press (user request, 2026-10-13).** Tapping the bubble
opens the overlay without capturing. Long-pressing it (0.35 s; the tap waits
only for the finger to lift) captures the app beneath with a rigid haptic: the
screen flashes white, and the full-screen picture, lifted by a shadow and
rounding its corners, shrinks into its thumbnail slot in the message field
while the panel opens around it. One `SpringDriver` (response 0.35, damping
0.86) runs the flight from 0 to 1. Every frame the picture interpolates from
the screen to wherever the slot is now, so it follows the slot as the panel
stretches open; it flies into the bubble instead if the panel closes
mid-flight. The flash fades in the first third. The thumbnail stays hidden
(`Composer.held`) until the picture lands, then replaces it. The
tray now redraws a picture replaced under the same ID, so a second capture
shows. Fixed in the open morph: the bubble's line had a clear background, and
the blur turned it into a gray block while the panel opened; it now gets paper
while blurred. DEBUG: `SQUIRCLE_OVERLAY_OPEN=capture`. Verified in the
simulator (iPhone 17 Pro, iOS 27.0) at 20× slow (frame by frame) and in a
real-speed Squircle recording driven by a throwaway XCUITest: a tap opened
with an empty field, and a long press flashed and landed the capture. The
thumbnail with its remove button replaces the flying picture about 0.3 s after
the flash. Letters Abroad build: job `d69cbc9f-16b7-49c2-8777-e777af1ea6a6`
(overlay key `a67d4ccb…`, main at `c1da0e8`); not yet on the phone.

**Smoother handle, slower capture (user, 2026-10-13):** "a little jumpy
while resizing and the snapshot animation is way too fast". From a 30 fps
recording of a slow real drag: above the docked top the panel used to widen
toward full screen and its bottom slid toward the screen's, so the field moved
and every line re-wrapped each frame, and the conversation was pinned to the
panel's top. Now only the top edge follows the finger; the sides and bottom
stay where the drag began. The conversation keeps its newest message where it
was as its height changes (`ThreadViewController` moves the offset by the
change), so history appears and disappears at the top. A release that changes
the width (to full screen, or full to docked) cross-blurs with the glass
instead of re-wrapping live. Re-measured: while dragging, rows above the field
hold still (at most 2 pt, no re-wrap). The capture's flash now has its own
quick fade (`flashFade`, response 0.32), and the flight is softer (response
0.78, damping 0.92): about 0.7 s from flash to landing at real speed. Letters
Abroad build: job `51d4cf24-e7c0-4894-b03b-1de349076c5b` (overlay key
`7063e331…`, main at `dab5a20`); not yet on the phone.

**Handle path, top fade, springier capture (user, 2026-10-14):** the top
blur popped in after the panel settled; the capture was too linear and slow at
the end with too strong a flash; resizing taller still jittered; to and from
full screen popped; pulling down squashed the panel thin.

- The system scroll-edge blur can't draw inside the morph's blurred,
  stretched layers, so it appeared only at rest. The overlay now always uses
  the conversation's own fade under its top controls, there from the first
  frame.
- The handle moves the panel's top edge along one path. Docked, the
  conversation is laid out once (a little taller than the tallest docked
  panel) and pinned to the glass's bottom, which reveals it: nothing re-lays
  out per frame, and the handle and the top controls ride the visible edge
  (`setVisibleTop`). Above the tallest docked panel the glass widens toward
  full screen and a picture of the docked panel cross-blurs into the
  full-screen layout, following the finger both ways. Below `minimumHeight`
  the panel morphs toward the bubble (stretch and cross blur, as the spring
  does). Release carries on with the finger's speed (full screen, docked at
  that height, back, or into the bubble). The pan's recognition slop is
  subtracted so the edge doesn't skip at touch-down. When the height changes,
  a conversation scrolled to its end stays at its end.
- The picture is a snapshot of the glass as drawn on screen: inside the glass,
  gray labels and fills are vibrant, and a picture of the content alone
  (`snapshotView`, `drawHierarchy`, `render(in:)`) lost the build cards and
  the field's placeholder.
- Capture: flash 0.4 opacity fading on its own (response 0.2); flight
  response 0.5, damping 0.72, landing in about 0.4 s with a small overshoot.

Verified from real-touch recordings (throwaway XCUITest; 30 fps, frame by
frame): taller with no jitter, docked → full and full → docked continuous, a
pull-down cancelled back to docked and one completed into the bubble, opening
with the fade present throughout, the capture flight. Letters Abroad build:
job `9c690d0f-f240-4376-a154-d163edad6d97` (overlay key `5f304350…`, main at
`713918a`); not yet on the phone.

**Docked ↔ full screen without cross blur (user, 2026-10-14):** "feels like
the before and after states are ~ the same so why can't it transition
smoothly?" The conversation's column now keeps the docked panel's width in full
screen too (`setOverlayLayout(contentWidth:)`, the table centred), so both
states wrap every line alike. Between them, whether the finger or the spring
(handle tap, menu) moves the glass, the panel is laid out at the glass's frame
every frame with the part of the screen's safe area that frame covers
(`liveLayout`): the handle, ⋯, field and top fade slide to their full-screen
places as the glass widens, with no picture and no blur. Per frame only
constraint constants change. Cross blur remains for bubble ↔ panel and for the
panel's shortest layout morphing into the bubble. Verified from real-touch
recordings: drag up into full screen and back, handle tap to full and back,
continuous with nothing re-wrapping and nothing changing at rest. Letters
Abroad build: job `0a62e459-3211-4a01-bbe0-50bc96595e55` (overlay key
`bca1c588…`, main at `c29b0b4`); not yet on the phone.

**Fluid bubble, launch in place (user, 2026-10-14):** "as the agent changes
what it's doing the bubble resizes and text changes kinda abruptly and often
clips off … the squircle button flies into place from some random location".
Causes: the bubble's line was laid out at the glass's width every frame, so it
re-truncated as the width sprang, and the opening progress averaged width and
height, so a width change alone read as partly open (the line was squeezed to
the new width and stretched, and the panel's paper blurred in). At launch the
first `render()` animated the glass's spring from its zero frame before the
first layout. Now `LiveCapsule` lays each line out at its own text width
(within `widthLimit`, truncated there), moves lines only by transform, and
fades its trailing 9 pt, so the springing edge reveals or hides text softly;
the old task rises and fades out quickly as the new one rises in. A task shows
at least 1.1 s; changes within that collapse into the latest (tone changes,
such as Needs you, show at once). Opening progress is by height only. The
glass gets no frame until the first layout in a window, then grows in at its
resting place (`appear`, scale 0.5 → 1 with a little overshoot, fading in).
DEBUG: `SQUIRCLE_BUBBLE_DEMO=1` loops made-up statuses. Checked frame by
frame in a real-speed simulator recording (iPhone 17 Pro, iOS 27.0). Letters Abroad
build: job `cb942484-6b95-4ebe-9061-26b5d25bad8d` (overlay key `6650da73…`,
main at `b2e8e58`); not yet on the phone.

**Glass jelly overlay (prototype on branch `overlay-bubble`, 2026-10-14,
awaiting the user's reaction):** first the user picked the jelly character and
asked for "actual semitransparent frosted glass 3d jelly"; then, on that
prototype: "motion is kinda weird and unnatural, has some weird insets and
divots … want more, like, jiggle physics … let the jelly become the platter
rather than having this generic divorced glass platter … stand out a little …
feel separate from the rest of the app … make it feel more alive again" (eyes).

- `GlassJelly` is the overlay's glass: the bubble and, grown, the panel that
  holds the conversation (the Liquid Glass view is gone). Material: the app
  behind frosted by the system's live blur masked to the outline; a
  handwritten Metal shader (compiled from source at first use) lighting it as
  a cushion (tint deepening at the rim, a rim lit toward the light, a gloss
  streak, a glint, light gathered inside) and filling it with paper as it
  opens; a soft shadow in its colour. Terracotta while working, ochre for
  "needs you", olive when done; the rim and glow keep the panel visibly its
  own layer over the app.
- Motion is a small soft body: the controller only drives the frame spring;
  the jelly feels that frame's acceleration and resizing, and squash, shear
  and a lag offset (damped springs, about 3 Hz as a bubble, slower and calmer
  as a panel) ring down. The outline is the rest squircle under an affine
  squash and shear with its edges pillowed outward, so it bulges but never
  dents. A finger squashes it while held, a status change or finished task
  kicks it, "needs you" hops every few seconds; idle it barely breathes.
- Eyes: beside the bubble's line, and open, peeking just under the panel's
  top rim (where you grab it; the handle's pill is gone), drawn above the
  conversation on a soft patch of paper. They blink (sometimes twice),
  glance at any touch on the screen (the overlay window sees each touch
  first), read along while it works, look at the field while you type,
  squint when poked, smile when done and tilt worried when it needs you.
- Opening, the bubble's line leaves in the first fifth and the conversation
  fades in over the last 60% (no blur: the jelly is the paper, and a blur
  turns clear areas black). Main's live docked ↔ full layout and handle path
  are unchanged; full screen, the jelly's corners follow the display's.
- Cost: the shader redraws only while something changes; a settled panel
  draws nothing per frame. Not measured on a phone.

Verified in the simulator (iPhone 18 Pro, iOS 27.0) from real-touch
recordings driven by a throwaway XCUITest (tap in the app, fling, slow drag,
poke open, type, pull down by the face), light and dark, frame by frame at
12–20 fps: no dents, the panel settles in under a second, text legible on
paper in both appearances. Clips: `attachments/overlay-bubble/jelly2-*.mp4`.
Not on the phone.

Third round (user: "too jiggly and the eyes are twitchy … should probably be a
squircle … rounded 3d cubeoid … a little less creepy if the jelly dude were
detached … extends/pushes above … faintly blur"):

- The creature is its own body: a rounded cube of frosted jelly raymarched in
  perspective (top and side faces show; it leans into its motion and toward
  what it looks at), eyes on its front. It sits at the status pill's end,
  joined by a liquid neck (a smooth union of the two outlines that stretches
  as the creature follows a step behind). Open, it rises above the panel's top
  edge as a head on the same neck; the head is the handle (drag to resize,
  tap for full screen, pull down to close). The panel and full screen leave
  room above for it.
- Calmer: the blob's squash and lag are a third of before and well damped;
  only the frame's real motion moves it. The creature squashes when poked,
  gulps finished tasks, hops every few seconds when it needs you.
- Eyes: glances are held targets reached on a critically damped spring (reading
  along the line a word at a time while working); blinks are timed, 0.24 s.
- Both bodies blur the app behind them (live system blur masked to their
  outline); the panel's paper is a little translucent.

Verified the same way (real touches including head tap, full screen and pull
down; light and dark). Clips: `attachments/overlay-bubble/jelly3-*.mp4`.
Not on the phone.

Fourth round (user: "the outer glass casing and inner jelly thing is too
distracting. i just want one morphing jelly cube dude … a bit too much"): one
body, one material. A single Metal layer draws the pill or panel, the neck and
the cube with the same translucent tinted jelly (deeper toward its edges, one
soft rim, one soft highlight); the caustics, edge line, double highlights and
the cube's separate layer, shadow and blur box are gone. The pill's end runs
under the cube, so the cube reads as the head of one piece of jelly. The blur
is masked to the jelly's exact coverage (the same shader, drawn at 1×), and
nothing redraws while nothing moves. Clips: `jelly4-*.mp4`. Not on the phone.

Fifth round (user: "why is the liquid bridge stuff gone now"): the detached
cube is back on v4's single body. Docked, the cube sits beside the pill with a
gap; open, it rises above the panel's top edge as a head. Between them is an
explicit liquid neck (a capsule from the pill's end or the panel's top to the
cube, blended into both): finger-thick at rest, thinner as the cube trails a
drag or fling, pinched apart past twice its length. Still one material in one
pass, blur only under the jelly, no redraw when idle. Clips: `jelly5-*.mp4`.
Not on the phone.

Sixth round (user: "neck looks stupid it's clearly just bolted on … needs to
be more physically accurate"): the jelly is one 3D signed-distance field,
raymarched in one pass: the pill or panel (its outline extruded with fully
rounded edges), the bridge and the cube, joined by smooth unions so every join
is a concave meniscus, with normals and lighting from the combined field. The
bridge is a liquid bridge: a catenoid r(t) = w·cosh((t − L/2)/c) whose volume
is kept (each frame the waist w is solved for the current length), so
stretching lengthens and thins it and draws a little volume from the cube;
below a critical waist it pinches off and each half retracts into its body on
a damped spring, with a recoil wobble; when the bodies are close again they
merge. Squash keeps volume (blob: area; cube: wider and deeper as it
shortens). Fragments far from the jelly skip the march; nothing redraws while
nothing changes. Clips: `jelly6-*.mp4`, stills `jelly6-join-*.png`. Not on
the phone.

Seventh round (user: "bridge is too long and narrow … as the text is changing
the jelly position jitters"): the cube nearly touches the pill, joined by a
short, thick meniscus (waist 8 of end radius 11, ending inside the cube's near
side so the face stays flat); flings stretch it modestly and only a big pull
(waist under 4.9, about twice its length) pinches it. Jitter: the cube was on
its own spring and display link a frame out of step with the pill. Now it is
its anchor on the pill plus a lagging offset driven only by the anchor's own
acceleration (a pill resizing toward it moves nothing), it can't be pushed
into the pill, a side change carries it across instead of jumping, and the
jelly draws in the same transaction as the layout (`presentsWithTransaction`).
Measured on a 60 fps recording of rapid status changes: the cube's edge moves
only in smooth multi-frame eases (within one pixel otherwise). Clips:
`jelly7-*.mp4`, still `jelly7-rest.png`. Not on the phone.

**On the phone (2026-10-14, user on iPhone 17 Pro Max: "like 10fps … contents
disappear while resizing … dead frozen … keeps showing shimmer text
forever").** Causes found (the phone was not reachable from the Mac; fixes
checked in the simulator and by GPU timing on the Mac):
- The jelly set `presentsWithTransaction` but presented from the command
  buffer (a Metal thread, outside any flushed transaction). Drawables stayed
  held, so `nextDrawable` blocked the main thread up to a second per frame:
  the 10 fps, the frozen creature, and the jelly blanking while drawables
  were reallocated every frame of a resize. Now: commit, `waitUntilScheduled`,
  `present()` on the main thread inside the layout's transaction; the Metal
  layer grows and shrinks in 96-point steps instead of every frame.
- The body is no longer ray-marched: its extruded outline is solved directly;
  only fragments within 8 points of the cube or neck march. The blur's mask
  is a shape layer, not a second Metal pass. Same image (old vs new differ
  only along the one-pixel antialiased edge); Mac GPU time for a full-screen
  panel 0.43 → 0.10 ms, and the 1x mask pass is gone.
- The creature ticks on real time (springs stepped in ≤1/60 s pieces) on a
  120 Hz display link; injection now sets `CADisableMinimumFrameDurationOnPhone`
  in the app's Info.plist, without which iOS caps display links at 60 Hz.
  Layout and tick draw once per frame between them.
- The shimmer: the agent ended its turn after starting a worker, and the
  bubble showed any working thread's title, shimmering, ahead of "Done". Now
  only the agent's own work shimmers; when it finishes the bubble says Done,
  then "Worker · title" (or "2 workers") plainly while workers run.
  `SquircleModel.observe` is now a throttle, not a debounce, so constant
  model changes can never hold an update back.
Not yet verified on the phone.

**Review fixes (W7, 2026-10-14).** The jelly runs at 120 Hz only while
something moves; while it only breathes the link drops to 30 Hz, and while it
is still (the open panel, or Reduce Motion) it pauses until its next timed
blink or glance or a touch or layout. Reduce Motion: no breath, blinks, hops
or idle glances; it still looks at touches and the field. In the simulator,
idle alternated between the 30 Hz breath and short full-rate glances; with
`--reduce-motion` it slept between one-tick wakes. Captures own their
recorder (idle / recording / stopping); every stop finishes the recorder
first, a recording with no picture or a failed writer leaves no file, and a
replaced or disconnected scene cancels it. Performance captures judge each
frame against the period it ran at and skip gaps across inactive/background
(`periods`, `resumed`, and a per-hitch `period` in the JSON). In the overlay,
live simulator rows are previews, not buttons (`expandsSimulators = false`);
a closed panel or covered conversation releases its streams. Not yet checked
on the phone.

**How the overlay reaches apps.** It is compiled into each app when Squircle
signs it; an installed app keeps that overlay until the app is built and
installed again. The service compiles it from the checkout its binary was
built in (`CARGO_MANIFEST_DIR`) unless `SQUIRCLE_OVERLAY_PROJECT` is set, so a
service running from a worker's worktree injects that branch's overlay.
Proposed, not built: compile from the main checkout, and stamp the source key
into the framework so the overlay can show "Overlay outdated · Rebuild" when
the Mac's key differs.

## 2026-10-11 Home grid, 0.3.0 (28)

The user tried build 27 (first grid) and confirmed the grid is better than
the carousel, then reported: phones lagged and jiggled while scrolling, drew
over the toolbar buttons and ignored the scroll edge blur; taps did nothing;
the purple gradient backdrop read as AI slop; the latest thread title as a
subtitle was useless; the loading screen was ugly.

- Cause of lag/jiggle/overlap: one full-screen SceneKit view above all UIKit
  content re-rendered every device from scroll callbacks a frame late.
- Grid and app page now show still portraits (`DeviceStage.portrait`, an
  `SCNRenderer` snapshot of the same scene, lights and per-point scale) inside
  the scroll views. The stage draws only the moving or live device. Handoffs
  wait for the stage's first rendered frame (`afterNextRender`) before hiding
  a portrait, and clear the stage a turn after a portrait reappears.
- Off-center devices are turned to face the camera (`place`), so a pose
  looks the same anywhere on screen and in a centered portrait. Measured on
  the simulator: grid portrait vs. stage at the start of opening differ by
  0.64/255 mean over the screen, best alignment at (0, 0) px, equal shadow
  brightness; residual is edge anti-aliasing. Without the correction: 1.43.
- Taps: a plain `UIControl` never sends `.primaryActionTriggered`; cells use
  `.touchUpInside`.
- Removed: drum lean, scroll-velocity trailing, press tilt, CoreMotion tilt,
  ambient color glow. Backdrop is flat `Theme.paper`.
- Placeholder: an abstract, heavily blurred neutral screen (light and dark).
- Fixed the app name landing up to 70 pt high: it was framed while carrying
  its rise-in transform.
- `StageMotionTests` rewritten for grid/page/recede; 18 tests passed.
  Not yet measured on the physical phone.

**Build 29 (same day, user request): local caching.** Screenshots loaded from
the network on every launch and the grid waited for T3's shell snapshot.
`ScreenshotBinding` now keeps each app's last capture on disk (Caches/
Screenshots, key + bytes) and shows it immediately; it fetches only when the
source key differs, keeping the cached image until the newer one decodes.
`SquircleModel` caches the shell snapshot and app metadata
(`squircle-home.json`, written two seconds after changes) and restores them
at launch. Simulator: a cold relaunch showed the full grid with screenshots
1.2 s after launch.

**Build 30: thread transitions.** Reproduced from a simulator recording of
`SQUIRCLE_DEMO=1` at 30 fps. The list's 3D swing and the conversation's 3D
turn were sibling layers in one 3D rendering context, so Core Animation
intersected them: a moving vertical line sliced the conversation and the
faded list showed through it. Each now turns inside its own container
(`pageSwing`, `threadHost`, which passes touches through), and the
conversation is an opaque page with a soft edge shadow in the app (the
overlay keeps it transparent over glass). The bottom/top controls and the
app name were framed while carrying their rise-in transforms, so they rested
up to 40 pt off and jumped on the next layout; they are now placed by bounds
and center. Re-recorded open and close show neither defect.

**Build 31: responsive, flat thread push.** The user found every transition
blocking and the 3D swing into threads out of place. Touch was enabled only
when a spring settled (about a second with the 0.0005 rest threshold); now
the screen being arrived at is interactive from the first frame
(`towardGrid`/`towardPage`/`towardThread`), a tap on another app while one
returns lands the old one at once, a thread opened while another leaves
replaces it in place, and Back on the app page works while a thread is
still sliding away. Threads push flat: the conversation slides in from the
right over the list, which drifts left by a third. Verified frame by frame
in a simulator recording; touch-during-transition not yet exercised by a UI
test.

**Build 32: fast navigation.** The user found rapid in/out navigation
broken. A DEBUG stress mode (`SQUIRCLE_STRESS=1`, `SQUIRCLE_STRESS_SECONDS`)
now fires the controls' own entry points at random 30–500 ms intervals,
logs any phase moving with no spring driving it, and checks the resting
state. Fixed: stale handoff callbacks hid a portrait after it had taken the
device back (portrait visibility is now derived from `staged && stageDrawn`
and every handoff carries a generation); touches on a leaving conversation
fell through to hidden list rows and opened other threads (the leaving
conversation now swallows them); reversing kept opposing momentum and
overshot (`SpringDriver.redirect` drops it; presented progress is clamped);
removed thread controllers stayed subscribed and could move the stage
(`tearDown`); reopening the same thread mid-close now reverses it; the grid
reorders only while fully hidden; a new thread's first frame used unresolved
keyboard-guide frames and drew the device tiny. 40 s stress run: no stuck
states, correct rest; recordings checked frame by frame. Edge-swipe during
these races is not covered by the stress mode.

**Build 33: navigation as a route (user: make invalid states
unrepresentable; no Combine/Dispatch).** Build 32 still reached a blank
screen going in and out of threads. `StudioViewController` no longer has
phases or completion callbacks. The only navigation state is `Route`
(`grid`, `app(id)`, `thread(app, thread)`); user actions set it. Two springs
always head to targets derived from the route and what is mounted; the app
page's app and the thread controller change only while their spring is at 0
(off screen), so a different thread animates out, swaps, and animates in.
`sync()` is atomic and idempotent; `applyScene()` derives poses, visibility,
touch routing and portrait/stage ownership every frame. Portraits hide only
for devices the stage has actually rendered (`DeviceStage.drawn`, captured
by the render thread). The stage hands a device back one frame after its
portrait is on screen (`DisplayFrame.next()`). New async primitives:
`DisplayFrame.next()`, `ObservableObject.updates` (coalescing AsyncStream;
Combine's `.values` trapped under bursts). `scripts/check-swift-concurrency`
runs in every app build against `app/Squircle/concurrency-baseline.txt`
(50 legacy uses in 7 files; may only decrease). The DEBUG stress mode now
also drags the back edge with random releases and drafts, and audits every
frame; two 60 s runs: 0 violations, settled on the route.

**Build 34: tap flicker, type.** On the phone, tapping a device sometimes
flashed it at the top center for a frame: the app page mounts as the open
begins, and its hero portrait was allowed to draw the device until the stage
reported a render, which on hardware can lag a frame. A portrait now draws
the device only while progress is within 3% of where that portrait stands
(`atCell`, `atPage`); not reproduced in the simulator (2,883 frames
scanned), fixed from the code path; stress audit still 0 violations. The
user disliked the rounded app-name type: app names are now New York
(`Theme.appNameFont`, `appCaptionFont`); the rounded design is gone. The user then found serif out of place; build 35 uses plain SF (bold 34 title, semibold 15 caption).

## 2026-10-12 one agent per app, 0.3.0 (36–37)

User request: "a single agent I interact with per app and not all the
threads … dump issues into it … let it worry about organizing threads,
coordinating, testing, merging"; they can still open individual threads, but
the primary interface is chatting with each app's agent.

**Why this shape (researched and tested 2026-10-11/12):** only the real Claude
Code and Codex CLIs, which T3 runs, use the subscription's included usage;
per Hermes's own provider docs, a harness calling Anthropic directly bills
"extra usage" only. So the app agent is a T3 thread, not an outside harness
(Hermes, agent SDKs). Claude Code subagents show in T3 only as activity inside
their parent thread (read in T3 0.0.45's code), so workers are real T3
threads. Built-in T3 0.0.45 facts used: `thread.turn.start` with
`bootstrap.prepareWorktree` creates a thread and worktree from any client;
messages sent mid-turn fold into Claude's running turn; T3 launches Claude
with user/project/local setting sources, so plugins and hooks load; extra
provider instances with their own launch arguments are supported; custom
message context records survive.

- **Squircle agent instance.** `squircle agent setup` installs the plugin
  (`plugin/squircle`: agent definition `app-agent`, hooks) into the data
  directory and adds T3 instance `squircle` (driver claudeAgent, the default
  Claude binary and home) launched with `--plugin-dir … --agent
  squircle:app-agent`. The agent definition is the system prompt.
- **Staying on track:** a `UserPromptSubmit` hook (and `SessionStart` after
  compaction) adds the rules, the agent's thread ID and its live workers to
  every turn from `squircle agent context`; a `PreToolUse` hook refuses
  question dialogs, which stalled all coordination in the prototype; the
  service caps working workers at three. State lives in the service, not the
  conversation.
- **Service.** Paired with T3 by `squircle t3 connect` (its own session,
  orchestration read/operate, from a one-time pairing token). It keeps a live
  copy of T3's shell, `agents.json` (agent per project, worker ownership) and
  wakes the agent with a tagged `[worker update]` turn when a worker finishes,
  errors or needs input, once per turn outcome (`turn:state`), so restarts
  neither repeat nor miss one. (Superseded the same day: see the simplification below.)
- **CLI:** `t3 connect|status`, `agent setup|start|list|context`,
  `thread spawn|send|status|read|answer|archive`; HTTP `/v1/agents`,
  `/v1/agents/context`, `/v1/workers…`.
- **Phone (as of build 38):** tapping an app opens its agent's conversation;
  other threads push over it (see build 38 below). An app without an agent
  opens a draft; the first message asks the Mac to create the agent.
  Wake-ups render as one quiet line ("Add CHANGELOG.md finished"). The
  approvals picker is hidden for the agent. `SquircleModel` no longer uses
  Combine (`updates`/`observe` are AsyncStream); the Combine/Dispatch
  baseline went from 50 to 4.

**Verified:** live end to end on a scratch repo through the real service:
first message → one worker for three related CLI changes → service wake-up
→ agent reviewed, merged into `squircle/integration`, ran the 69 tests,
archived the worker; a second round showed the wake-up line on the
simulator. The prototype runs showed it holding its job and rules after a
forced compaction (39K→4K tokens) and refusing to commit to main on its own.
Rust tests and 11 app tests pass; `SQUIRCLE_STRESS=1` for 40 s: `settled=1
violations=0`. Grid → agent transition inspected frame by frame at 10× slow
motion: one layered push (threads rise beneath as the conversation slides
over them; the device travels without a gap). **Not yet checked:** the
physical phone, merge-conflict round trips, iOS builds from the integration
worktree, per-worker simulators, Codex as the app agent, weeks-long use.

**Same day, simplified (user: "just let me tell it what to do … are you
overengineering this").** Removed the integration branch and worktree (the
agent works in the project's folder), the per-turn rule list, the
question-dialog block, the three-worker cap and the prescribed workflow. The
plugin's agent definition now states only the agent's role, its tools and
the wake-ups; the hook supplies only its thread ID and live workers; workers
branch from the checkout's current branch. Verified live: "have a worker add a
'mod' command … when it's done, merge it into main" → worker, wake-up, the
agent merged into main itself (78 tests pass).

**Build 38 (user tried 37 on the phone: "can't talk to agent, just errors";
"you push me two levels deep … ugly").** (1) The first message to a new agent
failed: the service sent it before its live copy of T3 included the thread it
had just created; `send` now waits for it. Reproduced on the simulator before
the fix (message bounced back into the field) and passing after it, first and
follow-up messages, through the phone's own send path (`SQUIRCLE_SEND`).
(2) No list between Home and the agent: route `app` is the agent's
conversation (back returns to Home); `thread` pushes another thread over it,
from the agent's corner menu (threads, New Thread, Builds; replaced in 39) or by tapping a
worker update line. The model follows one conversation at a time, so the
covered agent ignores model changes and reselects its thread when the one
over it closes. The app page (`AppPage`) and its geometry are gone. Verified:
slow-motion frames of Home → agent (one push) and agent → thread → back;
returning restores the agent's own conversation; `SQUIRCLE_STRESS=1` 40 s:
`settled=1 violations=0`.

**Build 39 (user: "builds be one button and threads another that goes to a
proper view, not shove them all in a menu").** The agent's corner menu is
gone. Beside back sit two glass buttons: Threads opens a full-height sheet
listing the app's other threads (title, status, model, age) with a New Thread
button; picking one closes the sheet and pushes the thread over the agent.
Builds opens the builds sheet.
Verified in the simulator: docked, the three buttons sit clear of the PiP;
the sheet lists threads with status, opens a thread over the agent, and New
Thread opens an empty draft; Builds opens. Two fixes from looking: out of its
dock the device covered Threads and Builds (and full size overlapped back), so
the undocked device now starts below the button row (`undockedTop`); and the
explicit VoiceOver order omitted both buttons. `SQUIRCLE_STRESS=1` 30 s:
`settled=1 violations=0`.

## 2026-10-13 image attachments

User request: image uploads in Squircle generally, and opening the in-app
overlay pre-attaches a screenshot of the app that is easy to delete.

- **T3's own mechanism.** `thread.turn.start` takes
  `message.attachments: [{type:"image", name, mimeType, sizeBytes, dataUrl}]`
  (T3 0.0.45 limits: 10 MiB per image, 80 MiB per message). T3 writes each to
  `~/.t3/userdata/attachments/<thread>-<uuid>.jpg` and gives the provider its
  path. Sent images come back as `{type:"image", id, …}` on the message and are
  fetched through `assets.createUrl` (`resource: {_tag:"attachment", attachmentId}`),
  a short-lived signed URL. No separate upload server. T3's alternative
  `attachments.createUploadUrl` two-step upload is not used.
- **Composer.** A `+` menu (Photo Library; Camera where the app declares camera
  use) adds images as thumbnails above the text, each with a remove button.
  Pending images live on `SquircleModel.attachments`, so any composer bound to
  the model shows them; sending takes them and returns them if T3 refuses.
  Images resize to a 2000 px long side, JPEG. Sent images show under your
  bubble, right-aligned, and open full screen on tap.
- **Overlay.** Long-pressing the bubble (since 2026-10-13; a tap no longer captures) draws the scene's windows below the overlay
  (`drawHierarchy`, overlay window excluded) and attaches the picture under a
  fixed ID, so reopening replaces it instead of piling up (`Overlay/HostCapture.swift`).
- **New app agent with images:** the Mac creates the agent with no message and
  the phone sends the first message itself, so the images go through T3.
- Verified 2026-10-13 in the simulator (iOS 27.0, T3 0.0.45) on the Squircle
  Probe agent: two photos attached, one removed, sent with text; T3 stored a
  53 KB JPEG and the agent answered with the image's text; after a relaunch
  the image reloaded from T3. Overlay demo (`SQUIRCLE_OVERLAY_DEMO`) attached the
  app beneath on open, in both the list and a thread; remove worked. Not yet
  on the phone.

## 2026-10-13 simulator jank and agent PiP: findings and proposal

User report: opening or resizing the simulator tray (divider docked/half/full)
drops frames; simulator use feels janky; wanted: the simulator only as a PiP
while an agent (the app agent or its workers, possibly several) is using it,
otherwise no simulator UI, and the transcript showing where a simulator was
used, live while in use and the recording afterwards.

**Measured (simulator only, iOS 27.0 on the Mac, optimized DEBUG build, live
H.264 stream of Cards-Verify, two runs of eight dragless detent moves, four
of them tap-driven):** main-thread work
per divider frame mean 0.6–1.2 ms, worst 6.9 ms (`layoutStage`; `applyScene`
≤0.65 ms and runs twice per frame because the table's inset change re-enters
layout); SceneKit encode ≤0.65 ms. Dropped frames were rare (0–5 per 1.4 s
move). The CPU is therefore not the cause; the simulator draws on the Mac's
GPU and cannot show the phone's GPU/compositor cost. Not measured on the phone
(that requires replacing the installed build with an instrumented one).

**Why it is heavy on the phone (from the code, sizes for iPhone 17 Pro Max at
120 Hz):** the stage is one full-screen, non-opaque `SCNView` at native scale
(1320×2868) with 4× MSAA and jittering, physically based materials, IBL, a
directional light and three area lights, composited over all UIKit content.
While a stream is live it re-renders the whole scene for every decoded frame,
even at rest (measured: 85 renders in 1.4 s idle at half, i.e. every frame).
During a divider move, on top of that, the conversation's clip view is
resized under a `CAGradientLayer` mask (an offscreen pass over the
conversation every frame), the table's content inset changes and it
re-scrolls to the bottom with forced layout, and the glass buttons on the
divider move and rescale. The 3D tilt of a tap-driven move adds more screen
area. Opening also starts the stream and decoder in the same moment.

**Signals available today.** T3 0.0.45 `subscribeDeviceState` lists
`sessions: {threadId, hostId, deviceId, platform, openedAt}` for every thread
(Squircle currently reads only the selected thread's), plus `bootingDevices`.
A session lasts until `device_close`, so "in use" = an open session and that
thread's turn running. agent-device keeps per-session `events.ndjson` (every
command with timestamps) and `screen-recording.resource.json` under
`~/.t3/userdata/device/agent-device/sessions/`. T3 has no device recording
API; agent recordings exist only when the agent runs `agent-device record`
and `squircle media add` (Squircle's media endpoint then serves them).
`device_open`/`device_screenshot` tool calls are in `state.sqlite`, so the
steps endpoint can place a simulator span in its turn.

**Proposal** (approved the same day with changes; see the next section).

1. No simulator in a conversation at rest: no divider, docked device or
   simulator menu. Home keeps its still 3D portraits.
2. While any thread of the app has an open device session and a running turn,
   a flat PiP floats over the conversation: a rounded `AVSampleBufferDisplayLayer`
   fed by the existing H.264 stream (no SceneKit), draggable to any corner
   with velocity snapping like FaceTime. Several agents: one PiP per simulator,
   stacked, each captioned with its thread; tapping a worker's PiP opens that
   thread. Tap expands it large and interactive (touch input, Home); swipe
   down shrinks it back. Optional: system PiP (`AVPictureInPictureController`
   with the sample-buffer layer) so it keeps playing outside Squircle.
3. When the turn ends or the session closes, the PiP flies into its turn in
   the transcript and becomes the recording.
4. Transcript: a simulator block in the turn where use began: live while in
   use (the PiP docks into it when that row is on screen, so one decoder),
   then the recording, inline and muted, full screen on tap.
5. Recording: the Squircle service records each (thread, simulator) span
   itself with `simctl io recordVideo`, starting at the session/turn and
   stopping at turn end or `device_close`, and stores it as thread media
   tagged with the turn. Agent-published clips stay. Unknown: simctl
   recording alongside agent-device's own recording of the same simulator,
   and two threads sharing one simulator (one recording, shown in both).
6. The device no longer travels into the conversation: the push is flat and
   the tapped portrait goes with Home.

Unmeasured risks: several H.264 streams over cellular (T3 0.0.45 offers no
stream size control), and decoder cost of 2–3 streams on the phone.

## 2026-10-13 agent simulators, 0.3.0 (40)

The user approved the proposal with these changes: Squircle drives recording
(the agent starts a session through a discoverable CLI command and Squircle
records it and shows it), every active simulator must stay reachable
(including the user's own use), no system PiP for now, nothing installed on
the phone; optimize what the simulator can measure.

**Service and CLI.** `squircle sim start --thread ID [--device NAME|UDID]`,
`sim stop --thread ID`, `sim status [--thread ID]`, `sim devices` (HTTP
`POST /v1/sims`, `POST /v1/sims/stop`, `GET /v1/sims`, `GET /v1/sims/devices`;
`src/sims.rs`). Start opens the simulator for the thread with T3's own
`device.open` (so T3 and the phone stream it), waits for boot, and records
with `xcrun simctl io UDID recordVideo --codec=h264`. It returns the
agent-device command; the `--config`/`--session` values are derived exactly as
T3 0.0.45 does (sha256 prefixes of the host and of `[thread,host,device]`,
checked against a real `device_open` result). Stop, the thread's turn not
working for 8 s, a dead recorder or 30 minutes end the session: SIGINT to
simctl, `avconvert --preset Preset1280x720` (raw simctl output is about 6 Mbit/s,
17 MB for 23 s; after conversion, 9- and 12-minute sessions were 5.1 and
1.1 MB, still 1206×2622), then
the file joins the thread's media with a `simulator` record (session, device,
start, end) dated at its start, and T3's `device.close` ends the device
session. Sessions left recording by a previous service run are finished at
startup. The plugin's agent definition, worker prompts and the phone's
per-thread instructions tell agents to use `sim start/stop` and not
`device_open` or `agent-device record`: CoreSimulator allows one host
recording per simulator (`DEVICE_IN_USE`, observed).

**Phone.** No live SceneKit: `DeviceStage` only renders grid portraits. The
divider, detents, travelling device, simulator menu and manual simulator
choice are gone; conversations are full height and an app opening is a flat
push while Home falls back. `SimulatorFeeds` runs one T3 H.264 stream per
simulator while any screen shows it; `SimulatorScreen` draws decoded frames
through `AVSampleBufferDisplayLayer`. `SimulatorDock` floats over the app's
conversations: one PiP per active simulator (Squircle sessions of the app's
threads, and T3 device sessions of its working threads), stacked in a corner
the stack is dragged to (two springs, velocity-projected), captioned with the
thread when it is not the one on screen or there are several. Tap brings it
large over a dimmed conversation with Home, Open thread and Shrink; tap
outside or drag down shrinks it with the finger (one spring; what is
expanded changes only at rest). Touches on the large picture go to the
simulator. In the conversation, `ThreadItem.simulator` places each use in
the turn that began before it: live with a red dot while active (its PiP
steps aside while that block is on screen), then the recording, muted and
looping, full screen on tap. Simulator recordings no longer appear as
gallery clips.

**Measured (simulator, iOS 27.0, Debug builds, live H.264 stream of
Cards-Verify on screen in a thread, 10 s samples, two runs each):** app CPU
14.3% → 9.7–10.2%; the simulator's compositor (backboardd) 20.8% → 5.6–9.3%
(old: 3D device at half size; new: the turn's live block). The old build
re-rendered the whole full-screen scene for every decoded frame; the new one
only enqueues the frame. Physical-phone frame rate remains unmeasured (not
installed, by the user's choice).

**Verified by running it (simulator, against a second service on loopback
with a copy of the data directory; the loopback HTTP allowance was a local
patch, not committed):** `sim start` → PiP with the live picture over the
agent screen; two simulators stack; a real drag moved the stack and it
snapped to the bottom-left; tap expanded it large; the turn showed the live
block, then the recording after `sim stop`; an idle thread's session ended by
itself ("turn ended", recording filed). `SQUIRCLE_STRESS=1` for 40 s:
`settled=1 violations=0` (the audit now also fails if the PiPs show over
Home). Rust tests pass, including a check that the agent-device session name
matches T3's; app unit tests pass. **Not verified:** touches on the large
picture reached the stream (logged), but Cards-Verify did not react; the old
build's 3D device failed the same way in the same setup, so this is a
host-side input problem (the build-12 notes describe T3 capture needing a
`device.shutdown`/`device.open`), not fixed here. Also unverified: the
PiP-to-turn flight was not built (the PiP fades; the block becomes the
recording), cellular bandwidth of several streams, and the phone.

**Combined build 40** (this work merged with main's overlay agent, image
attachments and build detail, `8ba2655`): after the merge, `SQUIRCLE_STRESS=1`
40 s gave `settled=1 violations=0`; the overlay demo opened the app's agent
with the host screenshot attached and no device, and removing the attachment
worked. Service restarted on the new binary, `agent setup` rerun. Signed
build succeeded, job `32c34bb6-178a-479d-b558-8a23523c4fd7`. Not installed
on the phone.

## 2026-10-13 one look everywhere, 0.3.0 (41)

User: "have we updated its ui to use the new look? I hope it is all shared
code". Design A (see the overlay section) had been behind an overlay-only
style flag. It is now the only look, in the app and the overlay alike, with no
flag (`ChatStyle` and `PickerBar` are gone):

- "Worked for…" (`SummaryCell`), the changes line (`ChangesCell`) and the live
  step (`LiveCell`, a `LiveCapsule` with no surface of its own) are plain text
  lines. A finished turn's pulse blooms around the line.
- A build in the conversation (`BuildCell`) is a plain filled card with a solid
  Install button.
- Your messages keep their tinted glass bubbles and the send flight.
- The field (`Composer`) is the one glass surface at the bottom; its + and send
  are 30 pt without glass, centred on a one-line field 9 pt from its edges.
- Model and approvals are in a ⋯ glass button at the top right, which is in
  every conversation. Jump-to-latest floats above the field's trailing end.
- Navigation differs, not the look: the app's agent keeps back, Threads and
  Builds (user, 2026-10-13) beside ⋯; a thread has back and ⋯; the overlay's
  agent sets `compactControls` and shows only ⋯ (its handle closes it; Threads,
  Builds and full screen go in the menu).

Checked in the simulator (iPhone 17 Pro, iOS 27.0): the Squircle agent, a
thread over it, and the overlay docked (unchanged from the overlay's design A);
`SQUIRCLE_STRESS=1` for 30 s ended with `violations=0`. Squircle build
`a7292357-04cf-4aa5-8a8f-d192f615a730` (0.3.0 41, main at `8174ff2`); not yet on
the phone.


## 2026-10-13 inline media in agent text, 0.3.0 (42)

User: "Inline photos and stuff seem broken." Agents write Markdown with
absolute Mac paths (`![after](/Users/…/cmp-after.png)`,
`[clip](/Users/…/capture.mp4)`); the phone showed only the alt text.

- `Markdown.segments` cuts an answer or note at local pictures (`![alt](path)`
  or a link straight to an image file) and clips (`.mp4`, `.mov`, `.m4v`);
  alt text is dropped as a caption, web URLs and code fences stay text.
- Consecutive media form one `.figure` row (`FigureCell`): an album layout at
  the text's width and each file's own proportions, rows no taller than 440 pt
  and no shorter than 190 pt, so phone screenshots pair up and a wide composite
  keeps its own row. Clips play inline, muted and looping; a tap opens a picture
  full screen (zoomable) or a clip with sound.
- Files load through T3's own signed asset URLs (`assets.createUrl` with a
  `media-file` resource for the thread and path), as T3's web client does; T3
  serves only previewable media types. Its `imageDimensions` reserve each
  picture's box before the bytes arrive. No Squircle service change.

Checked in the simulator on the Squircle agent thread and a worker thread over
it: before, "before", "after" and "drag" showed as words; after, the composites,
screenshots and the clip show in place, the clip plays, and both tap through to
full screen. Images you send were unaffected (none in that thread).
Squircle build `713e2489-65e3-44f6-b026-bf992445fa0c` (0.3.0 42, main at
`d0c8ba1`); not yet on the phone.

## 2026-10-14 surviving background and network changes

User: "Frequently get t3 connection errors on background and foreground the
app." What was wrong: iOS suspends the app a few seconds after it leaves the
screen, which kills T3's socket without telling it. On return Squircle still
thought it was connected, so the first requests failed and showed "Couldn't
reach T3", the thread showed "Reconnecting…", and the reconnect waited a
second before its first try. The heartbeat only wrote pings and never noticed
a silent (half-open) socket, e.g. after a Wi-Fi/cellular handover. The
injected overlay had the same model and the same faults.

Now (`SquircleModel` connection section, `T3Gateway`): Squircle holds a
background task, so the socket survives the ~30 s iOS allows; when that runs
out it closes the socket cleanly. On return it reconnects at once (or, if the
socket is still up, checks it answers a ping within 4 s). One connector
retries immediately, then 0.5 s doubling to 15 s; a network change
(`NWPathMonitor`) retries now or re-checks the socket. A socket with no frame
for 40 s (T3 answers every Ping) is dropped. Requests made mid-reconnect wait
for the new socket instead of failing. Reconnecting resubscribes the shell,
devices and the open thread; the transcript stays on screen and T3's snapshot
brings it up to date. Nothing is shown unless T3 stays unreachable for 8 s.

Verified in the simulator (DEBUG `SQUIRCLE_DROP_T3_EVERY=10` fails the socket
every 10 s): four 4 s app switches kept the same socket; a 75 s background
closed it at the ~30 s limit and reconnected on return; forced drops
reconnected in ~0.2 s, with the thread's transcript and live simulator PiPs
intact and no notice. Not tested: toggling the simulator's network (needs root
on the Mac) and a T3 that stays down. Not yet on the phone.

## 2026-10-14 Clay palette

User: "The purple theme in the app is a bit sloppy btw can we come up with a
nicer design." Three alternatives (Graphite: ink on neutral paper; Harbor:
deep teal; Clay: terracotta on warm cream) were captured in the simulator in
both appearances (Home, the agent conversation, Builds); the user picked
**Clay**. It is now the only palette, in the app and the injected overlay
(both use `Theme`):

- accent terracotta (light 0.71/0.33/0.20, dark 0.94/0.56/0.41);
  `Theme.onAccent` (white / deep brown) for text on accent fills;
- paper warm cream 0.972/0.957/0.933, dark warm charcoal 0.078/0.070/0.064;
- your bubbles a sand tint of the accent;
- status olive (success), ochre (warning) and crimson (failure) instead of
  system green/orange/red, so they stay apart from the accent.

The purple palette and the unused studio backdrop colours were removed. DEBUG
capture hooks kept for stills: `SQUIRCLE_BUILDS=1` (the app's builds),
`SQUIRCLE_NO_DOCK=1` (hide simulator PiPs) and `SQUIRCLE_DEMO_SEND` on the
agent (the send animation, never sent to T3). Checked in the simulator: Home,
agent conversation, Builds and the overlay (full) in light and dark.
Squircle build `715bcac7-ecac-4db7-ae31-a7c97b272ee4` (0.3.0 44, main at
`dcda2df`); not yet on the phone.

## 2026-10-14 the agent's role every turn

User: the app agent "forgets its role and starts just doing everything
manually". Evidence: the role was already the system prompt (`--agent
squircle:app-agent` on every launch and `--resume`; a scratch `claude -p`
quoted it). Neither long agent transcript (LanguageApp 12 MB, RemoteAppDev)
had compacted, yet the LanguageApp agent spent 128 tool calls profiling,
editing and committing itself and never spawned a worker. The prompt invited
that ("besides doing work yourself, you can run worker threads"), and the
per-turn note carried only the thread ID and workers.

- **System prompt** (`plugin/squircle/agents/app-agent.md`): the agent
  coordinates and workers implement, unless the user says otherwise; how to
  reply for a phone: short, pictures `![..](/abs/path)` and clips
  `[..](/abs/path)` copied out of /tmp into `~/.t3/userdata/attachments`
  (T3 signs any absolute media path), builds as the Install card, no bare
  paths, IDs, branches, hashes or Squircle internals unless asked.
- **Per-turn note** (`squircle agent context`, `UserPromptSubmit` and
  `SessionStart:compact`): the same role and reply style in three
  sentences, with the CLI, the thread ID and the workers.
- **Workers:** the footer of their first prompt carries the reply style
  (their threads are opened on the phone too).
- **Phone:** a build of any app mentioned in a turn renders as an Install
  card under its app's name (it used to need the thread's own app, so the
  agent's test builds of other apps showed as a UUID).

Verified: a scratch session with the new plugin, `/compact` forced, still
answered that it coordinates and would `thread spawn` a worker, and saw the
note re-injected after compaction.

Squircle build `5f52e109-f73e-42c1-8946-ae7ca8675cf2` (0.3.0 45, main at
`076d35e`); the Install card for another app's build is not yet checked on screen.

## 2026-10-14 restart and start fresh (0.3.0 46)

User: running agents keep an old system prompt, and the LanguageApp agent
had a long history of doing all the work itself; they wanted a way to fix
that from the phone or by telling the agent.

- **Finding:** Claude Code stores a `prompt_snapshot` of the system prompt
  in the session and restores it on `--resume`. A session relaunched with an
  updated `app-agent.md` still answered from the old prompt (scratch
  `claude -p --resume` with an old and a new plugin copy). So relaunching
  alone does not update instructions; the earlier note that the role is the
  system prompt "on every launch and `--resume`" only holds for the first
  launch.
- **`squircle agent restart`** sends T3 `thread.session.stop` (history and
  resume cursor kept; plugin and hooks reload on the next launch) and marks
  the agent so its next turn note carries the current `app-agent.md` body
  once, as replacing any earlier version.
- **`squircle agent fresh`** creates a new agent thread on the same model,
  renames the old one "<app> agent (until <date>)" (not archived, so it
  stays in the phone's Threads), stops its session, moves its workers to the
  new coordinator and starts the new thread with a `[handoff]` turn (context
  record `squircle-handoff`): app, last 8 commits, workers, the user's last 8
  messages, the old agent's last reply and the agent's `--handoff` note. No
  model runs in the service.
- **Mid-turn:** both are stored as `pending` in `agents.json` and run when
  the agent's turn ends, so an agent can run them on itself. The plugin has
  one line telling it how.
- **Phone:** the agent's ⋯ menu has Restart Agent and Start Fresh (a
  destructive confirm item). The agent view follows the Mac's agent for the
  app, so a new thread replaces the old one in place within one refresh
  (≤4 s); the handoff renders as a quiet "Started fresh" line.

Verified on the scratch project: restart kept a codeword and the agent then
described the new fresh-start rule it had denied before; telling the agent
"start fresh" ran after its turn, the new agent's first reply was two short
sentences; Start Fresh from the ⋯ menu in the simulator switched the open
conversation in place. LanguageApp's agent was started fresh from the ⋯
menu (deferred through a running turn); its first reply was three short
sentences naming the open item. Not yet checked on the physical phone.

Squircle build `e76693ea-4f76-47c2-a735-b327e0ff49c5` (0.3.0 46, main at `adec020`) succeeded; not yet installed on the phone.

## 2026-10-14 notifications and the Live Activity (0.3.0 51)

User decision: notifications and a Live Activity sent straight from the Mac
service to Apple with the user's own APNs auth key, no relay for now. A later
App Store build may need a small relay, so sending sits behind one interface.

- **Service (`src/push.rs`).** `Push` decides what to say; a `Transport`
  delivers it. `Apns` is HTTP/2 to `api.sandbox.push.apple.com` or
  `api.push.apple.com` (by the token's environment, which the phone reports),
  with an ES256 provider token (JWT, `ring`) reused for 40 minutes and
  refreshed on `ExpiredProviderToken`. A relay would be another `Transport`;
  the phone's contract stays: `POST /v1/push/devices` (device token,
  push-to-start token, bundle ID, environment), `/v1/push/activities`
  (an activity's update token, or none when it ended), `/v1/push/presence`
  (foreground and the conversation on screen), the alert's `squircle` key
  (`project`, `thread`, `build`, `bundle`) and the activity's content state.
  Tokens Apple reports gone (410, `BadDeviceToken`) are forgotten.
- **Key.** `squircle push setup --key-file … --key-id … --team-id …` checks
  the key and stores it in `<data>/push/apns.json` (0600); output and logs
  never show it. The service reloads it when the file changes, no restart.
  `push status` lists registered phones without tokens; `push test
  [--live-activity]` sends one now.
- **What notifies.** From T3's shell: the app agent replied (its reply's
  first line), asks a question (the question) or stopped with an error; a
  worker finished, needs you or errored; a device build succeeded or failed.
  Title is the app's name, body one line. Notes within 3 s for one app are
  one notification (up to four lines). Nothing for the thread the phone
  reports showing (presence expires after 5 minutes), and the phone hides a
  banner for the conversation on screen too.
- **Live Activity.** One per app with an agent: the agent's current step
  (from T3's state database, read-only, every 8 s while working), workers
  running, and "Needs you". Started by push-to-start when work begins and the
  phone isn't in the foreground, or by the app when it leaves with work in
  progress; updated by `liveactivity` pushes (state changes at priority 10,
  step text at most every 10 s at priority 5); ended 20 s after everything is
  idle, dismissed 2 minutes later; stale after 15 minutes without word. The
  widget extension (`SquircleWidgets`, the one place SwiftUI is used, as
  ActivityKit requires) draws a small jelly cube in Clay terracotta, ochre
  for needs-you and olive when done. Tapping it opens the app.
- **Phone.** `PushCenter` (app target only, never the overlay) asks for
  permission, registers tokens with the Mac on every return to the
  foreground, reports presence, and opens a tapped notification's app,
  thread or build. `aps-environment` (`development`; the ad hoc
  `release-testing` export signs it as `production`, which the app reads
  from its embedded provisioning profile) is in `SquirclePush.entitlements`,
  not yet the target's: Xcode on this Mac has no Apple account, so automatic
  signing uses the wildcard team profile, which cannot carry Push (build
  `e86ee230` failed: "doesn't include the Push Notifications capability").
  For the same reason the widget extension has no profile ("No profiles for
  'ai.dreamslate.Squircle.Widgets'", build `358efb85`), so it is not yet
  embedded. Without both the app gets no tokens, shows no Live Activity and
  the Mac has no one to send to; the rest of the app is unchanged.

Tested without a key: JWT signature and claims verified against the key's
public key, alert and activity payloads, burst coalescing, viewed-thread
suppression, and the service path over HTTP/2 against a local fake APNs that
answers 200 and 410. In the simulator the app got a device token and its
Live Activity started and rendered (system log); a render of the views:
working, needs you, done. Not yet checked with a real key or on the phone.

### Creating the APNs key

0. Xcode → Settings → Accounts: sign in with the Apple ID of team
   `2F26US4NAU`, so signing can give Squircle's App ID the Push capability.
   Then in `project.yml` point `CODE_SIGN_ENTITLEMENTS` at
   `Resources/SquirclePush.entitlements`, add the `SquircleWidgets`
   dependency (commented there) and build.
1. developer.apple.com/account → Certificates, IDs & Profiles → Keys → +.
2. Name it (e.g. "Squircle push"), tick **Apple Push Notifications service
   (APNs)**, Configure: environment **Sandbox & Production**, key
   restriction **Team Scoped (All Topics)**. Save, Continue, Register.
3. Download `AuthKey_XXXXXXXXXX.p8` (only possible once). Note the **Key
   ID**; the **Team ID** is under Membership details (`2F26US4NAU`).
4. On the Mac: `squircle push setup --key-file ~/Downloads/AuthKey_XXXXXXXXXX.p8
   --key-id XXXXXXXXXX --team-id 2F26US4NAU`, then delete the download.
5. Install the new Squircle build, open it, Allow notifications, then
   `squircle push test --live-activity`.
## 2026-10-14 simulator deck

User, after trying several simulators on the phone: "we need to stack em
somehow and let them fan out when tapped … it's so in the way". With two or
more, `SimulatorDock` now shows one deck in the corner, 80 pt wide (was 96, or
78 each when 3+ sat in a column): the most recently started simulator on top,
up to two more peeking below it, darker, and a count badge. Tapping the deck
fans the pictures out from the corner into a row with each thread's name
beneath (a `fan` spring, interruptible like the others); tapping one brings it
large as before, and shrinking it returns it to the deck. A tap or drag outside
the row gathers it. One simulator stays a single small picture. Pictures that
can't be seen (behind the deck's top, or docked in the conversation) detach
from their feed and keep their last frame; a feed whose screens are all gone
stops streaming, so hidden simulators don't decode.

**Verified (simulator, iOS 27.0, Debug, four live sessions: this worker's, two
scratch worker threads' and another worker's):** deck with badge "4"; the
DEBUG `SQUIRCLE_SIM_FAN=1` sequence (same paths as taps) fanned the row,
expanded the second picture, shrank it into the deck, fanned and gathered;
screenshots at ~2.5 per second showed each step moving continuously, no
jumps. Not verified: real finger taps (T3's agent-device daemon was not
running), the phone.

## 2026-10-14 Squircle actions in the conversation (0.3.0 52)

User: what the agent does through Squircle (starting workers, messages
between threads, builds, simulators) showed only sometimes; messages agents
send each other looked like the user's own.

- **Why steps went missing:** T3 0.0.45 sends a client only a thread's newest
  500 activities (`THREAD_DETAIL_ACTIVITY_LIMIT`), and in an app agent's
  thread about a third of those are `context-window.updated`, so whole turns
  lost all their steps. The service's step details
  (`/v1/t3/threads/ID/steps`) now also carry each tool call's start time,
  turn, finished/failed and, for Squircle commands, their output; the app
  rebuilds every tool call T3 no longer sends. They also list every worker
  Squircle started (archived too) for names.
- **Lines:** the app reads Squircle commands from the Bash command line
  (quotes, heredocs, `S()` wrappers and `$S` variables; `SquircleAction`)
  and their output. Started worker (its live state: working, done, needs
  you, error), Sent to / Answered (tap for the whole message), Read, Archived,
  Cleaned up, Started build (with its build card), Started/Stopped simulator,
  Restarted, Started fresh, and Squircle's wake-ups as one "From <worker>"
  line per worker each stay in view when the turn folds. Lookups (status,
  help, build status) and commands Squircle refused fold with the other steps.
  Tapping a worker's line opens its thread (not once it is archived).
- **Who wrote a message:** the service marks what it sends for an agent with
  a context record: `squircle-task` (a worker's prompt), `squircle-agent-message`
  (`thread send`), both with `payload.from` the sending agent's thread, next to
  the existing `squircle-worker-update` and `squircle-handoff`. Only unmarked
  user messages get the user's bubble. A worker's task shows at the top as
  "Task from <agent>" over a thin rule, Markdown, without the instructions
  Squircle appends (cut at the `---` line starting "You are a worker for this
  app's agent", which also identifies tasks sent before the marks); messages
  read "From <agent>". Messages sent before the marks still look like yours.

Verified in the simulator against the coordinator thread with a scratch copy
of the service: turns that showed nothing now show their steps and lines, and
a worker's thread opens with its task. Not yet on the phone; the service must
be restarted for the step history and the marks.

## 2026-10-14 code review fixes (0.3.0 56)

The [October code review](code-review-2026-10.md) found 46 defects (10 high).
Fix waves W1–W9 are merged into main; source version 0.3.0 (56). The
resulting contracts are in
[architecture](architecture.md#boundaries-after-the-october-2026-review) and
[CLI design](cli.md); the review's status section lists each finding as fixed
or deferred. Product decisions in AGENTS.md are unchanged.

- **Service:** authentication before any body is read; one JSON error shape
  for every route with an explicit `retryable`; capture uploads streamed to
  disk one at a time; a missing preview no longer breaks the catalog; install
  tickets separate `download_started_at` from `downloaded_at` (every byte
  sent); shutdown stops simulator recordings and closes T3 device sessions.
- **App agents:** one agent per app under concurrent first sends; the chosen
  approval mode (`runtime_mode`, `agent start --runtime-mode`) applies at
  creation and survives a fresh start; cleanup never deletes a branch with
  merge commits the base doesn't contain; wake-ups and resets are saved and
  retried; discard stops a working worker before removing its files.
- **Phone:** sends land in the conversation that sent them; T3 ending a
  subscription reconnects; bounded caches and one ordered disk writer; the
  update curtain waits for every byte; the overlay shares the app's
  conversation through `ConversationHost` and shows live simulators there as
  previews; capture always stops its recorder; the jelly stays still under
  Reduce Motion.
- **Tests:** 122 Rust tests pass (100 unit, 6 CLI, 13 HTTP contract, 3
  service lifecycle). The CLI deadline tests failed about one run in three:
  macOS hands accepted sockets the listener's non-blocking mode, so the fake
  server sometimes answered before reading the request, and the 3-second
  bounds timed first-use credential fsync. The fake server now uses blocking
  sockets and an ordered stop, and the bound only separates the CLI's deadline
  from reqwest's 60-second fallback; 25 consecutive runs passed.

Not yet verified: the coordinated phone/simulator check in step 4 of the
review's fix plan (rapid navigation during a delayed send,
background/foreground, Home with live simulators, scene replacement during
capture, Reduce Motion, app/overlay parity).

## 2026-10-14 T3's 1 MB config

Build 55 stopped holding the connection on `server.getConfig` because its
reply had reached about 1 MB and outlasted the 40 s liveness deadline on
cellular. Measured against T3 0.0.45 on the Mac (read-only probe): 949 KB, of
which 830 KB is `providers[].workspaceSnapshots`. For each provider instance
T3 keeps, in memory, the skill and slash-command catalog of the last 16
folders it started a turn in (`upsertProviderWorkspaceSnapshot`, `.slice(-16)`;
32 for Antigravity), about 34 KB each for Claude with the installed plugins
(80 commands, 12 skills) and 20 KB for Codex. Every worker worktree adds one;
removing the worktree, archiving the thread or `server.refreshProviders`
doesn't drop it. It is not persisted, so restarting T3 clears it. At the time:
claudeAgent 16 folders (13 already deleted), squircle 6, codex 3. So it is
bounded, at roughly 16 × 35 KB per used instance (about 1.5 MB with claude,
squircle and codex full), and grows with the size of the skill catalog.
`subscribeServerConfig` sends the same list; no narrower T3 RPC exists. T3
does accept `permessage-deflate`, but the 34 KB blocks exceed deflate's
window (gzip only gets 949 → 219 KB).

Now the phone asks the Squircle service (`GET /v1/t3/providers`), which reads
T3's config locally and drops `workspaceSnapshots`, `skills` and
`slashCommands`: 24 KB (2 KB gzipped). The socket's large-reply allowance is
gone. T3's shell snapshot is separate: 92 KB for 62 unarchived threads (about
1.4 KB each), growing until workers are archived.
