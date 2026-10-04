# Squircle iPhone app

A UIKit/Core Animation client for the user's independently installed Hermes:
project home → threads → installable builds, on a continuous ivory canvas with
a live floating 3D device, flat rows and glass controls. The device displays
actual app screenshots; app metadata and previews persist on the Mac. Publishing
a new screenshot through the CLI has updated the visible texture without
relaunching the client. Opening and closing transitions were inspected frame by
frame on the simulator, with continuous perspective changes and no blank or
duplicated phone. Signed **0.1.0 (3)** is exported and ready to install. Its build also captured
the simulator screen and updated the Mac catalog automatically.
The first client build is already installed and phone chat works.

Hermes retains conversation history; the Mac app catalog owns app names,
summaries and preview artifacts. Local client state holds navigation, thread
associations and active-run pointers for reconnecting. No coordinator,
memory service or pairing backend is embedded.

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
- `Sources/UI/`: UIKit screens and Core Animation transitions, with no SwiftUI.
  SceneKit displays a live procedural phone textured with a real screenshot.
  Transition progress rotates its mesh and moves its camera. The live viewport
  is reparented during the transition; idle continuous rendering is disabled.
  Missing screenshots remain empty, with no generated identity artwork.
- `Tests/` and `UITests/`: **29 unit tests and one navigation UI test completed
  cleanly**, with `.verification/RealPreviewFinal.xcresult` and a successful exit.
  Earlier UI tests exercised real Hermes chat/relaunch and build submission. See
  [validation](../../docs/validation.md) for the evidence and remaining checks.

The installed baseline was signed, exported and installed; its automatic launch
event reached the Mac. Live model send/stream/history reconciliation also passed
in seven seconds. Keep the Mac and external Tailscale connection available.

After changing an app's UI, capture and inspect its actual simulator screenshot.
Use `squircle app list` to find the persistent app ID, `app update ID --summary
TEXT` to record its current state, and `app preview ID --file PATH --caption
TEXT` to publish the PNG independently of a build. See the [CLI contract](../../docs/cli.md#app-metadata-and-previews)
for provenance and timestamp semantics. The user stopped the image-judge loop;
verify the working capture, metadata and live-motion path instead.
