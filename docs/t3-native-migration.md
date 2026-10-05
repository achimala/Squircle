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
