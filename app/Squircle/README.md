# Squircle iPhone app

A UIKit/Core Animation client for the user's independently installed Hermes.
**Version 0.1.0 (7) source** is a first-principles redesign: one lit 3D stage
shows every app on a real device with its actual published screenshot. Opening
an app moves that same device to the top of its workspace (a flat list of real
Hermes threads); a single interruptible spring drives SceneKit and UIKit, and
the left-edge back gesture can grab, reverse or finish it at any frame. Builds
and Add App are native sheets; close, back, Builds, New Thread, compose/send,
approvals and the connection pill use Liquid Glass (iOS 26 APIs with material
fallbacks). Light and dark appearance, Dynamic Type, Reduce Motion (no turning,
receding or lift; short direct moves) and VoiceOver labels are supported. Apps
without a capture show an honest dark "No screenshot yet" display.

Installed on the physical iPhone: **version 5** (the previous design). Build 6
has passed simulator tests only; see [validation](../../docs/validation.md) and
the redesign handoff for exact results. Physical-device motion is unmeasured.

Hermes retains conversation history; the Mac app catalog owns app names,
summaries and preview artifacts. Local client state holds navigation, thread
associations and active-run pointers for reconnecting. No coordinator,
memory service or pairing backend is embedded.

## Add an existing app

Tap **+**, browse the Mac or paste an `.xcodeproj`/`.xcworkspace` path, choose
the scheme and app name, then tap **Add**. The Mac saves the app identity and
build recipe; no first CLI build is required. Import opens the app without
building it. Use its builds sheet when ready; a real screenshot appears after
capture or agent publication.

This flow passed real Mac import, folder/scheme selection, error recovery and
relaunch checks and is included in installed version 5. A missing signing team can appear as a warning
without blocking import, but a successful device build still requires Xcode's
signing setup. See the [CLI/API contract](../../docs/cli.md#import-an-existing-app).

## Build

The XcodeGen project uses Dreamslate team `2F26US4NAU` and bundle ID
`ai.dreamslate.Squircle`. Generate with `xcodegen generate` in this directory.
From the repository root, use the running Squircle service:

```sh
./target/release/squircle --data-dir "$PWD/.squircle" build start \
  --project app/Squircle/Squircle.xcodeproj --scheme Squircle \
  --export-options app/Squircle/ExportOptions.plist --json
```

The personal build reads `.squircle/client.json` during its build phase. That
ignored file supplies `hermes_url`, `hermes_token`, `squircle_url`,
`squircle_token`, `diagnostic_token`, and optional `agent_instructions`. It is
already configured on this Mac. Values are copied into the signed app; they are
not entered by the phone user or committed to Git. A different host needs its
own configuration. The personal build also supplies the native Desktop URL, access/refresh credential
and profile. Stock authentication and TLS stay enabled; renewed credentials go
to the iOS Keychain. See [connection details](../../docs/hermes-client.md).

## Implementation

- `HermesGateway.swift`, `HermesConversation.swift`, `HermesQuestionPanel.swift`:
  stock Desktop WebSocket protocol, full tool details, requests, native controls,
  replay and shared Desktop sessions. [Supported messages and limits](../../docs/hermes-client.md).
- `HermesClient.swift`, `SquircleModel.swift`, `AppProject.swift`: Squircle
  app/build/import APIs and a legacy chat adapter for older configurations.
- `Sources/UI/DeviceStage.swift`: one `SCNView` for all devices; hardware geometry is
  built once and flattened, each device only owns its display material. Renders on
  change or while a gesture/transition is live; never idles continuously.
- `StageLayout.swift` (pure gallery/workspace/transition poses), `SpringDriver.swift`
  (retargetable spring, finger takeover), `ScreenshotBinding.swift` (PNG decode and
  downsample off the main thread), `StudioViewController.swift` (gallery + navigation),
  `WorkspaceViewController.swift`, `ThreadViewController.swift`, `BuildsViewController.swift`,
  `AppImportViewController.swift`, `Theme.swift`. DEBUG-only `MotionAudit` and
  `SQUIRCLE_SCRUB`/`SQUIRCLE_DEMO` hooks support frame capture; absent from Release.
- `Tests/` and `UITests/`: 54 deterministic unit tests, two opt-in native Hermes
  integration tests, navigation, rapid
  interruption, Reduce Motion, import, Hermes round-trip, build, visual tour,
  accessibility audit and comparable performance probes.

Keep the Mac and external Tailscale connection available.

After changing an app's UI, capture and inspect its actual simulator screenshot.
Use `squircle app list` to find the persistent app ID, `app update ID --summary
TEXT` to record its current state, and `app preview ID --file PATH --caption
TEXT` to publish the PNG independently of a build. See the [CLI contract](../../docs/cli.md#app-metadata-and-previews)
for provenance and timestamp semantics. The user stopped the image-judge loop;
verify the working capture, metadata and live-motion path instead.
