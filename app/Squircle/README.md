# Squircle iPhone app

A native client for the user's independently installed Hermes. The first SwiftUI
build is installed and phone chat works. The selected redesign uses UIKit and
Core Animation: project home → threads → installable builds, on a continuous
ivory canvas with a floating device, flat rows and glass controls. Rounded-card
layouts were rejected. Visual and transition acceptance is still pending.

Hermes retains conversation history; local client state holds navigation,
project associations and active-run pointers for reconnecting. No coordinator,
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

- `Sources/HermesClient.swift`: stock Sessions/Runs REST and SSE, Squircle builds.
- `Sources/SquircleModel.swift`: current screen state, reconnect and launch report.
- Presentation: the initial SwiftUI screens are being replaced with UIKit/Core
  Animation. Verify rendered screens and transitions frame by frame before
  claiming the redesign complete.
- `Tests/`: seven protocol/request tests; live HTTPS and full-model tests also
  passed against this Mac. See [validation](../../docs/validation.md).

The installed baseline was signed, exported and installed; its automatic launch
event reached the Mac. Live model send/stream/history reconciliation also passed
in seven seconds. Keep the Mac and external Tailscale connection available.
