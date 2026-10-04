# Squircle iPhone app

A native SwiftUI client for the user's independently installed Hermes. Open the
app, talk to the agent, and install ready apps from Builds. Hermes retains the
conversation history; the client stores only selected-session/active-run pointers
for reconnecting. No coordinator, memory service or pairing backend is embedded.

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
- `Sources/Views/`: chat, conversations, approvals and build installation UI.
- `Tests/`: seven protocol/request tests; live HTTPS and full-model tests also
  passed against this Mac. See [validation](../../docs/validation.md).

The current build was signed, exported and installed; its automatic launch
event reached the Mac. Keep the Mac and external Tailscale connection available.
