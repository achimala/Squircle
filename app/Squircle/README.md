# Native Squircle iPhone client

UIKit/Core Animation client for the user's existing stock **T3 Code 0.0.45**
server. T3 owns agent processes, projects, threads, live activity and persistence.
Squircle's Rust service owns builds, installation links, app metadata and launch
diagnostics. The Hermes integration has been removed from the active target.

## Signing and namespace

`Config/Signing.xcconfig` is the one place for the Apple team, the bundle ID
prefix (the app, widgets, overlay, tests and the Probe example are
`<prefix>.Squircle`, `<prefix>.Squircle.Widgets`, `<prefix>.SquircleOverlay`,
…) and the Keychain group the app shares with the debug overlay
(`<prefix>.squircle.shared`). Put your own values in the git-ignored
`Config/Local.xcconfig` (copy `Local.example.xcconfig`); then run XcodeGen.
With no local file the project builds unsigned or for the simulator as
`com.example`. The entitlements, Info.plist and Swift read these settings,
and the overlay framework's Info.plist carries them to the Rust injector, so
changing the prefix changes everything together.

The CLI builds the overlay framework from the `app/Squircle/Squircle.xcodeproj`
of the checkout it was compiled in. A `squircle` binary copied elsewhere needs
`SQUIRCLE_OVERLAY_PROJECT` pointing at a checkout's project, or
`build start --no-overlay`.

## Personal connection

A private connection JSON (normally the ignored `.squircle/client-t3.json`)
supplies these keys:

```json
{
  "t3_url": "https://your-existing-t3-origin",
  "t3_token": "YOUR_PAIRED_T3_SESSION",
  "squircle_url": "https://your-existing-build-origin",
  "squircle_token": "YOUR_BUILD_SERVICE_CREDENTIAL",
  "diagnostic_token": "YOUR_UPLOAD_CREDENTIAL"
}
```

Issue the session with T3's own CLI, scoped to `orchestration:read
orchestration:operate filesystem:read` (T3 0.1.0 signs URLs for Mac files the
agent's Markdown shows only for `filesystem:read`; without it those pictures
fail to load):

```sh
ELECTRON_RUN_AS_NODE=1 "/Applications/T3 Code (Beta).app/Contents/MacOS/T3 Code (Beta)" \
  "/Applications/T3 Code (Beta).app/Contents/Resources/app.asar/apps/server/dist/bin.mjs" \
  auth session issue --scope orchestration:read --scope orchestration:operate \
  --scope filesystem:read --ttl 30d --label "Squircle native client" --json
```

Put its `token` in `t3_token`. Do not borrow the desktop's session or mutate
T3's SQLite store. When the session expires, issue a new one and rebuild the
personal client (`t3 auth session revoke ID` retires the old one once the new
build is installed). Self-service pairing/refresh UI is not implemented yet.

The app embeds it as `client.json` only when `Config/Local.xcconfig` sets
`SQUIRCLE_EMBED_CONNECTION` to its path; the build fails if that file is
missing and warns that it carries credentials. Such a build is for your own
phone and simulator: never distribute its IPA. Leave the setting empty for
CI, unsigned checks and anything you publish.

The paired session is stored in the iPhone Keychain. HTTPS requests reject
redirects. The RPC WebSocket sends the session's bearer; the device input socket uses
a short-lived ticket.
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

`StudioViewController` owns one `Route` (Home grid, an app's agent, a thread
over it) and derives everything on screen from it: Home's grid of still device
portraits (`DeviceStage` renders them once with SceneKit; nothing draws
continuously), the app's conversations (`ThreadViewController`, full height)
and `SimulatorDock`, the PiP/deck of simulators the app's agents are using.
`ThreadViewController` is also the overlay's conversation; each host states
what it can do through `ConversationHost` (the overlay shows live simulators
as previews). `SimulatorFeeds` shares one T3 H.264 stream per simulator while
a live cell is visible; `SimulatorScreen` shows decoded frames through
`AVSampleBufferDisplayLayer` and maps touches by aspect fit.
`ThreadCells.swift` holds the conversation rows, `ThreadViews.swift` the
composer and thread rows, `Markdown.swift` agent text. DEBUG-only `SQUIRCLE_APP`,
`SQUIRCLE_SCRUB`, `SQUIRCLE_THREAD` and `SQUIRCLE_SIM_EXPAND` hold real
states still for captures.

`SquircleModel` owns the T3 connection, conversations and caches. Each
conversation has a `ConversationID`; a send is a `PendingSend` with stable
message and command IDs, asked again on the next connection when T3's answer
is lost; connection callbacks carry their attempt;
tasks and media refresh only under a screen's `RefreshLease`; clips live in
the `squircle-media` file cache; disk writes go through the `DiskCache`
actor; `close()` tears the model down. See
[architecture](../../docs/architecture.md#state-ownership-contracts-review-b-2026-10-15).

`T3Gateway` implements Effect RPC; `T3ThreadState` reduces snapshots/events.
`T3DeviceStream` owns one native H.264 connection and an input socket as a pair.
Video starts before the input handshake; only interactive state enables touch.
Decode, pacing and presentation are serial and off the main actor: each picture
goes straight to the visible screens' video renderers at a paced host time
(`SimulatorPacer`); the main actor only gets the newest for sizing. A stopped stream
cannot retain a live channel, and a channel owns its gesture queue. A stream runs
only while a live cell or PiP shows it; background and navigation release it.
Simulators appear only while an agent's session uses one; the service, not the
phone, opens and closes T3's device session. See
[architecture](../../docs/architecture.md) for lifecycle states and boundaries.

Video is AVCC H.264 over T3's authenticated HTTPS feed; touch uses WSS. There
are no MJPEG playback, priming or fallback requests. VideoToolbox decodes one
frame at a time off the main actor; only the newest decoded picture waits for
presentation. Physical-phone decoder creation requires hardware acceleration.
Native pinch, exclusive input ownership and measured cellular latency/bandwidth
remain unverified/unimplemented.

## History

The notes below record builds 13–19 as they were validated then; they are
not the current source (build 56 at the time of writing; see the
[implementation record](../../docs/t3-native-migration.md) for later builds).

Build 19, thread redesign: header-less thread, readable
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
