# Validation evidence

Recorded 2026-10-04 on this Mac. This page records observed results, not claims
that the entire proposed product works. Local artifacts and credentials are
ignored by Git. Reproduce with the [walkthrough](verification.md).

## Environment

- Apple Silicon macOS; Xcode **27.1 (27A9269)**, Swift **6.4**.
- Rust **1.99.0**, repository-local under `.tools/`; no shell profile changes.
- Squircle **0.1.0**, Rust CLI/Axum service. Cargo dependencies locked.
- Optimized stripped arm64 executable: approximately **5 MB**.
  This measures the executable, not Xcode, dependencies or retained build data.
- Probe: SwiftUI, PLCrashReporter **1.12.2** pinned through Swift Package Manager.
- Approved signing team: **Dreamslate Inc. (`2F26US4NAU`)**.
- At the user's explicit request, the existing Tailscale connection was started
  and private HTTPS routes were configured: port 8443 for Squircle, 8444 for
  stock Hermes. The existing port-443 route was preserved. This is this Mac's
  setup, not bundled VPN management in the product.

## Automated checks

Rust tests cover private durable records/credentials, legacy record compatibility,
diagnostic deduplication/conflicts/quotas/cursors, argument safety, cancellation,
retry identity, shutdown admission, manifest construction, HTTP authorization,
ticket expiry, byte-identical IPA delivery, and CLI JSON/timeout behavior.
**45 Rust tests passed across the latest suites**: 34 library, 5 CLI process,
4 HTTP contract and 2 real service-lifecycle tests.
`cargo clippy --all-targets -- -D warnings`, formatting checks and the optimized
release build pass. Regression tests also cover import responsiveness and
absolute artifact paths across working-directory changes.

Probe: **9 XCTest tests passed** on isolated **iPhone 18 Pro / iOS 27.0** simulator
`389DF2C3-2656-40AD-830A-A8A90667D730`. Covers persistent queue replay/deduplication,
capacity retention, event limits, explicit server acknowledgement and HTTPS
validation, capture before connection setup and Swift UUID wire compatibility.
Evidence: `examples/SquircleProbe/.build/CanonicalTests.xcresult` (ignored).

Stock Hermes **v0.21.5+6977.gaf90026** invoked Squircle's capabilities and an
authenticated build-status query through its actual terminal tool; both exited
0. Session: `20261004_190013_61ebe2`. No plugin or fork was needed. OpenClaw is
not exercised. Stock Hermes's API is also reachable over private HTTPS with its
required authentication supplied automatically to the personal client build.

## Native client and Hermes API

The first native client used SwiftUI. **Seven client tests passed**. Its exact
Swift configuration and transport classes also passed live HTTPS session,
history, run-status and build-list checks; all **63** recorded SSE events
decoded. A separate harness compiled the unchanged configuration, client and
model classes, sent `Reply exactly SQUIRCLE_CLIENT_OK, do not use tools.`, observed
streaming and reconciled the final message in **7 seconds**, with `isRunning`
false and no error. Only that temporary test session was deleted afterward.

Stock Hermes API session `squircle-development-20261004` ran
`squircle capabilities --json` successfully as
`run_e2a8748966eb4ce2abee328753548e7f`. HTTPS retry with the same idempotency key
returned the same completed run. These are actual API/tool results, not mock
responses. The API runs in the independent Hermes installation using its existing
model configuration; no plugin or replacement coordinator was added.

Native client job `05d980f6-be8c-4e21-acb5-f82971f7db37` was signed, exported and
installed on the phone. Automatic launch event
`7763b0d0-0904-4691-a9c9-cb654c197d69` reached the Mac, and the user confirmed
that chat works in the installed app. The personal build embeds the existing
connection settings; it requires no manual token entry or pairing flow.

The subsequent **UIKit/Core Animation redesign** is an accepted direction.
Its project home, thread/build navigation and fluid transitions are not yet
claimed implemented or visually verified. Frame-by-frame acceptance is pending.

## Real Xcode jobs through Squircle

| Job | Result |
| --- | --- |
| `d5d1f0f7-8913-4085-85ce-ae44a9402927` | Unsigned Release simulator build succeeded |
| `61cf5aa9-770d-4ba2-a1cb-1a85f56eb78d` | Signed device archive and `release-testing` IPA export succeeded |
| `74efd708-a8a4-4cc9-abbc-924b53164569` | Updated simulator Probe; actual crash/recovery and symbolication succeeded |
| `7e9e1246-ee57-4dd9-8b6f-f070976283a3` | Updated signed Probe; installed/opened on the phone over cellular (user confirmation) |
| `05d980f6-be8c-4e21-acb5-f82971f7db37` | Signed native client installed; automatic phone launch event received and chat confirmed |

These jobs were submitted through the CLI to the real loopback service. Their records,
build logs, result bundles and outputs are retained under `.squircle/jobs/<ID>/`.
The device build explicitly enabled provisioning updates using the configured
Apple account. No account or device was registered by Squircle.

Device artifacts:

- IPA: `.squircle/jobs/61cf5aa9-770d-4ba2-a1cb-1a85f56eb78d/export/SquircleProbe.ipa`
- Archive: the same job's `App.xcarchive`
- dSYM: `App.xcarchive/dSYMs/SquircleProbe.app.dSYM`
- Bundle: `ai.dreamslate.SquircleProbe`, version **1.0**, build **1**
- Exported app passed `codesign --verify --deep --strict`.
- Binary and dSYM share arm64 UUID **0811D7A2-48A4-320E-812B-5E88E9C767B7**,
  checked using `xcrun dwarfdump --uuid`.
- Embedded ad-hoc profile belongs to team `2F26US4NAU`, includes **one device**,
  has `get-task-allow=false`, and expires **2027-07-25 01:00:17 UTC**.

The updated device build also passed exported-signature verification and has
matching binary/dSYM UUID **711FB97C-ABF1-3584-8AE4-06BA0DE7BEA4**. Its HTTPS
download matched the local IPA byte for byte (SHA-256
`a3fb8d1383228350e74bc2e3c41550cc30188501158561d12f6dd20fb719e4a7`).
The user confirmed installation and launch with Wi-Fi off and Tailscale connected.

## Diagnostics and remaining gates

A clearly labelled **host-only** log fixture was uploaded and read back through
the real CLI/service against the simulator job. It did not claim a phone launch;
`launch_observed` remained false. HTTP tests separately exercise launch reporting.

After replacing the debug service with the release executable, the signed build
record and host diagnostic fixture were read back successfully. The release
service runs on `127.0.0.1:8787`, with `.squircle` as its data directory and the
private HTTPS origin configured. Separate real-process tests verify unfinished
jobs become interrupted after restart and exclusive store ownership is enforced.

Actual simulator crash proof: launch without a debugger or connection settings,
signal only the Probe PID with SIGABRT, relaunch, recover a **182,734-byte**
PLCrashReporter report with the original build ID. Matching arm64 dSYM UUID:
**1673459F-0F2B-3870-81A7-53F15D66C77F**. Xcode symbolication resolves the app's
`main` frame and reporter exception thread; optimized Swift line is 0.
Artifacts: `.verification/probe-simulator-74efd708-*`.

With explicit user authorization, that actual report was forwarded from the Mac
through the private HTTPS endpoint and retrieved successfully. Event ID:
`b635c552-bab8-48c8-83f8-37c84a9db79e`. Its transport attribute explicitly says
`host-forwarded-simulator-report`; this is not a claimed phone-origin upload.
This exposed and fixed uppercase Swift UUID rejection at the server boundary.

Still unverified:

- Phone app-log collection, offline/reconnect recovery and actual phone crash upload/symbolication.
- Installing a visible update and distinguishing old/new build feedback.
- Coding-worker delegation and OpenClaw invocation in their actual environments.
- UIKit redesign and frame-by-frame transition verification.
- Packaged Mac startup supervision and suspended-client notifications.

Pairing, manual credential entry, coordinator adapters and additional backend
infrastructure are excluded from this personal build. No TestFlight or Firebase
service is required for the verified distribution path.
