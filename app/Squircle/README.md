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
marker, without editing files. Run the Claude test separately after subscription
login is restored. The separate continuous-frame test requires a changing simulator surface and
`SQUIRCLE_VERIFY_STREAM_MOTION=1`; it skips by default. Run tests in a separate
simulator from the streamed target: Xcode can reboot its runner, while T3 retains
capture until its own `device.shutdown` is called. The isolated runner created
for this check is `35024ED8-E5BF-4DD7-9F25-DDEE9771EC44` (SquircleTransportTests).
The stream soak verifies paired input/video recovery, duplicate start, cancelled
startup and a quiet 31-second interval. Deterministic tests cover target validation,
live delta replay, touch coordinates and preserved app/motion logic.

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

Current signed build: **0.2.0 (13)**, job
`073cf325-1bfa-4466-8de6-5f0531204934`. CoreDevice directly installed it on the
paired iPhone, and its manual-launch acknowledgement arrived. Nine targeted tests passed on the final source, with actual native
H.264 rendering/touch checked separately. The user confirmed the phone experience works well; quantitative response latency
remains unmeasured. See [migration evidence](../../docs/t3-native-migration.md).
