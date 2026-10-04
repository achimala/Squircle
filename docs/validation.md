# Validation evidence

Recorded 2026-10-04 on this Mac. This page records observed results, not claims
that the entire proposed product works. Local artifacts and credentials are
ignored by Git. Reproduce with the [walkthrough](verification.md).

## Environment

- Apple Silicon macOS; Xcode **27.1 (27A9269)**, Swift **6.4**.
- Rust **1.99.0**, repository-local under `.tools/`; no shell profile changes.
- Squircle **0.1.0**, Rust CLI/Axum service. Cargo dependencies locked.
- Optimized stripped arm64 executable: **4,927,504 bytes** (about 4.7 MiB).
  This measures the executable, not Xcode, dependencies or retained build data.
- Probe: SwiftUI, PLCrashReporter **1.12.2** pinned through Swift Package Manager.
- Approved signing team: **Dreamslate Inc. (`2F26US4NAU`)**.
- Tailscale was present but reported **Stopped**, without a usable host address.
  Squircle did not install, configure, or start it.

## Automated checks

Rust tests cover private durable records/credentials, legacy record compatibility,
diagnostic deduplication/conflicts/quotas/cursors, argument safety, cancellation,
retry identity, shutdown admission, manifest construction, HTTP authorization,
ticket expiry, byte-identical IPA delivery, and CLI JSON/timeout behavior.
**40 Rust tests passed**: 31 library, 5 CLI process, 4 HTTP contract tests.
`cargo clippy --all-targets -- -D warnings`, formatting checks and the optimized
release build pass. Regression tests also cover import responsiveness and
absolute artifact paths across working-directory changes.

Probe: **5 XCTest tests passed** on isolated **iPhone 18 Pro / iOS 27.0** simulator
`389DF2C3-2656-40AD-830A-A8A90667D730`. Covers persistent queue replay/deduplication,
capacity retention, event limits, explicit server acknowledgement and HTTPS
validation. Evidence: `examples/SquircleProbe/.build/Tests.xcresult` (ignored).

CLI discovery was exercised without agents on `PATH` and without a running
service. This is dependency independence, not an actual Hermes/OpenClaw invocation.

## Real Xcode jobs through Squircle

| Job | Result |
| --- | --- |
| `d5d1f0f7-8913-4085-85ce-ae44a9402927` | Unsigned Release simulator build succeeded |
| `61cf5aa9-770d-4ba2-a1cb-1a85f56eb78d` | Signed device archive and `release-testing` IPA export succeeded |

Both were submitted through the CLI to the real loopback service. Their records,
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

The registered device's identity has not been compared with the intended phone.
Valid signing/export does not prove that phone installation will succeed.

## Diagnostics and remaining gates

A clearly labelled **host-only** log fixture was uploaded and read back through
the real CLI/service against the simulator job. It did not claim a phone launch;
`launch_observed` remained false. HTTP tests separately exercise launch reporting.

After replacing the debug service with the release executable, the signed build
record and host diagnostic fixture were read back successfully. The release
service is running on `127.0.0.1:8787`, with `.squircle` as its data directory and
no public URL configured. This verifies retained completed work, not recovery of
an actively running Xcode process.

Still unverified:

- System-installer access to private HTTPS manifest/IPA URLs over cellular.
- Physical installation, manual launch and correct build acknowledgement.
- Phone log delivery, offline/reconnect recovery and actual crash upload.
- Real crash capture/relaunch and application-frame symbolication.
- Installing a visible update and distinguishing old/new build feedback.
- Hermes and OpenClaw discovery/delegation in their actual process environments.

The polished controller, coordinator adapters, startup supervision and installer
packaging are future work. No TestFlight, Firebase or other cloud distribution
service is required by this prototype.
