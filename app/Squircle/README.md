# Squircle iPhone app

A UIKit/Core Animation client for the user's independently installed Hermes.
Version 5 opens with a horizontal live 3D app picker, then a minimal flat thread
list. Builds live in a secondary sheet. App names and actual thread content carry
the interface; glass is reserved for controls. The actual phone, title and
controls move between screens, with interactive back navigation and no fades.

Signed **0.1.0 (5)** is installed and launched on the physical iPhone. The code
passed 36 unit tests and import/navigation checks, including interactive back
cancellation and completion. Simulator transition frames were inspected; real
screenshot publication and the phone's automatic launch report are verified.
See [validation](../../docs/validation.md) for evidence and recording limits.

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
own configuration. Hermes's normal required API authentication stays intact.

## Implementation

- `Sources/HermesClient.swift`: stock Sessions/Runs REST and SSE, Squircle app/build APIs.
- `Sources/SquircleModel.swift`: current screen state, reconnect and launch report.
- `Sources/UI/`: horizontal picker, flat threads and a builds sheet. SceneKit
  textures the live phone with a real screenshot; transition progress moves its
  mesh, camera and surrounding UIKit views. Idle continuous rendering is off.
  Missing screenshots leave the display blank, without placeholder prose or
  invented artwork. There is no SwiftUI.
- `Tests/` and `UITests/`: 36 unit tests and version 5 import/navigation checks pass,
  covering Mac browsing, scheme selection, import persistence, picker swipes,
  back cancellation/completion, thread and builds sheets.
  Earlier live tests cover Hermes chat/relaunch. The final signed archive,
  export, simulator capture and physical installation/launch also succeeded.

Keep the Mac and external Tailscale connection available.

After changing an app's UI, capture and inspect its actual simulator screenshot.
Use `squircle app list` to find the persistent app ID, `app update ID --summary
TEXT` to record its current state, and `app preview ID --file PATH --caption
TEXT` to publish the PNG independently of a build. See the [CLI contract](../../docs/cli.md#app-metadata-and-previews)
for provenance and timestamp semantics. The user stopped the image-judge loop;
verify the working capture, metadata and live-motion path instead.
