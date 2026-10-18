# Squircle Probe

Minimal SwiftUI proof app for cellular installation, launch acknowledgement, logs and crash recovery. This is not the polished Squircle client.

## Build

Requires Xcode and XcodeGen. PLCrashReporter is pinned to **1.12.2** through Swift Package Manager; the first build downloads its source. No hosted crash service is used.

```sh
cd examples/SquircleProbe
xcodegen generate
xcodebuild -project SquircleProbe.xcodeproj -scheme SquircleProbe \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

The team and bundle ID prefix come from `app/Squircle/Config/Signing.xcconfig` and your git-ignored `Local.xcconfig` beside it (copy `Local.example.xcconfig`); the bundle ID is `<prefix>.SquircleProbe`. `ExportOptions.plist` selects Xcode's `release-testing` export method for registered devices. Device signing/export requires valid certificates and profiles; this scaffold does not create or update them. Do not add `-allowProvisioningUpdates` without coordinating that setup.

Pass `SQUIRCLE_BUILD_ID=<id>` when archiving to embed the server build ID; otherwise enter and save the ID in the app. Capture starts as soon as that identity is known, independently of the server URL, token or Keychain availability. Preserve the archive/dSYMs for that exact binary. Run queue and transport tests against an available simulator:

```sh
xcodebuild -project SquircleProbe.xcodeproj -scheme SquircleProbe \
  -destination 'platform=iOS Simulator,id=<simulator UUID>' \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO test
```

## Exercise the loop

1. Install the exported build on the phone through Squircle's OTA page, with Wi-Fi disabled. Open it manually.
2. Confirm the embedded build ID, or enter and save the ID returned by Squircle. A launch event is queued even while offline. Enter the HTTPS **origin** and **diagnostic** bearer token (never an agent/admin key); save the connection to upload queued events.
3. Send a recognizable log. With networking unavailable, enqueue another; reconnect and tap Retry or foreground the app.
4. With no debugger attached, confirm **Crash this probe**. Relaunch manually. PLCrashReporter recovers its actual crash report; the app queues it with its original build ID and uploads it. Symbolicate using the matching dSYM UUIDs on the Mac.

Tokens live in the device Keychain. Nonsecret origin/build settings use UserDefaults. No credentials are committed. HTTPS uses system trust; redirects are rejected rather than forwarding credentials. A browser session is not required.

## Contract and durability

`POST /v1/diagnostics` sends bearer authorization and JSON: `event_id`, `build_id`, `kind` (`launch`, `log`, `crash`), `message`, integer Unix `timestamp`, and string-valued `attributes`. Only HTTP 2xx with `{"ok":true}` acknowledges an event. The server should deduplicate `event_id` because a lost response causes a retry.

The atomic Application Support queue is limited to 128 events / 8 MiB; messages are at most 512 KiB and individual encoded events under 1 MiB. A full queue rejects new events visibly, preserving old evidence. Crash originals are purged only after durable enqueue. The app retries manually and when active; it does not promise background delivery. Reports that cannot be decoded or exceed limits remain on device, and another deliberate crash is disabled until recovery succeeds.

Integration into another app: reuse the event schema, queue, transport and Keychain storage; initialize PLCrashReporter early, persist build attribution in its custom data, and enqueue selected app logs. Do not install a second crash handler beside an existing crash SDK. [PLCrashReporter's documented integration](https://github.com/microsoft/plcrashreporter#example) provides the capture APIs used here.

## Validation status

Validated 2026-10-04 with Xcode **27.1 (27A9269)**: unsigned simulator build succeeded; **9 unit tests passed** on an isolated iPhone 18 Pro / iOS 27.0 simulator. They cover durable replay and deduplication, capacity retention, event limits, canonical UUID wire encoding, explicit acknowledgement, HTTPS endpoint validation, capture without connection credentials, Keychain failure, and recovery failure. Test results: `.build/CanonicalTests.xcresult` (local, ignored).

An actual simulator process was launched without a debugger, sent SIGABRT at its verified PID, and relaunched. PLCrashReporter recovered one report into the durable queue without a configured URL/token, preserving build ID `74efd708-a8a4-4cc9-abbc-924b53164569`. The app/report arm64 UUID matches `1673459F-0F2B-3870-81A7-53F15D66C77F`. Squircle symbolication and an independent `atos` check resolve the app's `main` frame and the reporter's exception thread. The optimized Swift entry point reports line 0; this is not proof of arbitrary app source-line resolution. Reports and symbolication output are under the repository's ignored `.verification/probe-simulator-74efd708-*` paths.

Signed archive/export also succeeds for Dreamslate; see [validation evidence](../../docs/archive/validation.md). **Physical cellular installation and app-originated launch/log/crash uploads remain pending.** The simulator recovery above does not prove the phone's network or installation path.
