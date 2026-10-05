# Native Squircle iPhone client

UIKit/Core Animation client for the user's existing stock **T3 Code 0.0.45**
server. T3 owns agent processes, projects, threads, live activity and persistence.
Squircle's Rust service owns builds, installation links, app metadata and launch
diagnostics. The Hermes integration has been removed from the active target.

## Personal connection

The ignored `.squircle/client-t3.json` supplies these keys:

```json
{
  "t3_url": "https://your-existing-t3-origin",
  "t3_token": "YOUR_PAIRED_T3_SESSION",
  "squircle_url": "https://your-existing-build-origin",
  "squircle_token": "YOUR_BUILD_SERVICE_CREDENTIAL",
  "diagnostic_token": "YOUR_UPLOAD_CREDENTIAL"
}
```

Use T3's ordinary pairing CLI/token exchange, scoped to `orchestration:read
orchestration:operate`. Do not borrow the desktop's session or mutate T3's
SQLite store. The current paired session expires after 30 days; when it expires,
create a new standard pairing and rebuild the personal client. Self-service
pairing/refresh UI is not implemented yet. This personal build embeds private
connection credentials; do not distribute its IPA to others.

The paired session is stored in the iPhone Keychain. HTTPS requests reject
redirects. RPC and input WebSockets use freshly minted short-lived tickets.
Tailscale is external and user-managed; the app does not install or configure it.

## Build and validate

```sh
xcodegen generate --spec app/Squircle/project.yml
xcodebuild -project app/Squircle/Squircle.xcodeproj -scheme Squircle \
  -destination 'platform=iOS Simulator,id=YOUR_SEPARATE_TEST_RUNNER' \
  -only-testing:SquircleTests -skip-testing:SquircleTests/T3LiveTests/testClaudeRoundTrip test
./target/release/squircle --data-dir .squircle build start \
  --project app/Squircle/Squircle.xcodeproj --scheme Squircle \
  --export-options app/Squircle/ExportOptions.plist --allow-provisioning-updates --json
```

Live tests intentionally create clearly labelled verification threads in this
repository's T3 project. They ask the selected provider to run `pwd` and return a
marker, without editing files. Claude subscription login and its real round trip were verified outside the
agent sandbox on 2026-10-05. The separate continuous-frame test requires a changing simulator surface and
`SQUIRCLE_VERIFY_STREAM_MOTION=1`; it skips by default. Run tests in a separate
simulator from the streamed target: Xcode can reboot its runner, while T3 retains
capture until its own `device.shutdown` is called. The isolated runner created
for this check is `35024ED8-E5BF-4DD7-9F25-DDEE9771EC44` (SquircleTransportTests).
The stream soak verifies paired input/video recovery, duplicate start, cancelled
startup and a quiet 31-second interval. Deterministic tests cover target validation,
live delta replay, touch coordinates and preserved app/motion logic.

## Interface (0.3.0)

`StudioViewController` owns one `DeviceStage` (SceneKit) and Home: a paging
carousel of `AppPage` lists. `StageLayout` is the single source of geometry: the
device fills the space above the content, on Home (above the app name, shrinking
as the list scrolls) and in a thread (above the divider). `ThreadViewController`
is a child on the same stage with three divider detents; `ThreadViews.swift`
holds conversation rows, composer and the device touch surface; `Markdown.swift`
renders agent text. Decoded simulator pictures are BGRA pixel buffers wrapped as
Metal textures on the device's display material; touches are mapped by
hit-testing the scene, so any pose is exact. DEBUG-only `SQUIRCLE_APP`,
`SQUIRCLE_EXPAND`, `SQUIRCLE_SCRUB`, `SQUIRCLE_DETENT`, `SQUIRCLE_THREAD` hold
real states still for captures.

`T3Gateway` implements Effect RPC; `T3ThreadState` reduces snapshots/events.
`T3DeviceStream` owns one native H.264 connection and an input socket as a pair.
Video starts before the input handshake; only interactive state enables touch.
Decode is serial/off the UI thread with one newest frame waiting. A stopped stream
cannot retain a live channel, and a channel owns its gesture queue. Background and
navigation release the pair; returning reconnects the saved target. Hide remains
hidden until explicitly chosen again. The simulator menu includes T3's supported
restart for stale host captures; restarting closes its running apps. See
[architecture](../../docs/architecture.md) for lifecycle states and boundaries.

Video is AVCC H.264 over T3's authenticated HTTPS feed; touch uses WSS. There
are no MJPEG playback, priming or fallback requests. VideoToolbox decodes one
frame at a time off the main actor; only the newest decoded picture waits for
presentation. Physical-phone decoder creation requires hardware acceleration.
Native pinch, exclusive input ownership and measured cellular latency/bandwidth
remain unverified/unimplemented.

Current source: **0.3.0 (15)**, the interface redesign; signed job
`0dbb4c79-6a83-4dad-a070-bef12b1d1d87`. Previous signed build: 0.2.0 (14), job
`99f5eb12-42fa-43a2-9edf-1f9558134da5`.
Build 14 fixes provider selection being overwritten by live thread updates.
Its selection regression and live Claude tool/reply tests passed; direct phone
installation succeeded. Manual launch of build 14 remains pending.

Build 13, job `073cf325-1bfa-4466-8de6-5f0531204934`:
 CoreDevice directly installed it on the
paired iPhone, and its manual-launch acknowledgement arrived. Nine targeted tests passed on the final source, with actual native
H.264 rendering/touch checked separately. The user confirmed the phone experience works well; quantitative response latency
remains unmeasured. See [migration evidence](../../docs/t3-native-migration.md).
