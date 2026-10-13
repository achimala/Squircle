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
  -destination 'platform=iOS Simulator,id=YOUR_SEPARATE_TEST_RUNNER' test
./target/release/squircle --data-dir .squircle build start \
  --project app/Squircle/Squircle.xcodeproj --scheme Squircle \
  --export-options app/Squircle/ExportOptions.plist --allow-provisioning-updates --json
```

The unit tests run in seconds and never touch T3, agents or a simulator stream.
Check live behavior by running the app and looking at it.

## Interface (0.3.0)

`StudioViewController` owns Home's grid of still device portraits
(`DeviceStage` renders them once with SceneKit; nothing draws continuously),
the app's conversations (`ThreadViewController`, full height) and
`SimulatorDock`, the PiPs of simulators the app's agents are using.
`SimulatorFeeds` shares one T3 H.264 stream per simulator; `SimulatorScreen`
shows decoded frames through `AVSampleBufferDisplayLayer` and maps touches
by aspect fit. `ThreadViews.swift` holds conversation rows and the composer;
`Markdown.swift` renders agent text. DEBUG-only `SQUIRCLE_APP`,
`SQUIRCLE_SCRUB`, `SQUIRCLE_THREAD` and `SQUIRCLE_SIM_EXPAND` hold real
states still for captures.

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

Current source: **0.3.0 (19)**, thread redesign: header-less thread, readable
agent steps with inline screenshots and recordings, Metal glow, iMessage-style
send, inline question card, simulator that follows the agent. See
[thread redesign](../../docs/t3-native-migration.md#2026-10-05-thread-redesign-030-19).
Build 18: Install opens the build's `itms-services` link
directly (no Safari page); New Thread shows the device at half size with wrapping
model chips above the composer. Signed job `d9f84f42-2113-441a-b9c0-9f41b9e68ca2`
succeeded; not installed on the phone. Build 17 added local drafts and valid
model picker fixes.
New Thread keeps the keyboard closed until the composer is tapped, presents
preferred/default model shortcuts, and creates its T3 thread only on first send.
Existing conversations restrict model changes to their established provider.
Ten native tests and two UI regressions passed; the draft capture is published in
the Mac catalog. See [draft evidence](../../docs/t3-native-migration.md#2026-10-05-draft-and-model-picker-fixes-030-17).

Previous source: **0.3.0 (16)**, approval controls; signed job
`93cbab47-9aee-425c-b460-40597f7a140f`, installed and opened on the paired iPhone
with CoreDevice at the user's explicit request. New threads default
to Auto; the agent menu offers Ask, Auto edits, Auto and Full access. Existing
threads retain their saved mode until changed. Native regression/menu tests and
real Auto turns through both providers passed; see
[approval evidence](../../docs/t3-native-migration.md#2026-10-05-approval-controls-030-16).
Previous interface redesign: build 15, job `0dbb4c79-6a83-4dad-a070-bef12b1d1d87`.
Previous signed build: 0.2.0 (14), job
`99f5eb12-42fa-43a2-9edf-1f9558134da5`.
Build 14 fixes provider selection being overwritten by live thread updates.
Its selection regression and live Claude tool/reply tests passed; direct phone
installation succeeded. Manual launch of build 14 remains pending.

Build 13, job `073cf325-1bfa-4466-8de6-5f0531204934`:
 CoreDevice directly installed it on the
paired iPhone, and its manual-launch acknowledgement arrived. Nine targeted tests passed on the final source, with actual native
H.264 rendering/touch checked separately. The user confirmed the phone experience works well; quantitative response latency
remains unmeasured. See [migration evidence](../../docs/t3-native-migration.md).
