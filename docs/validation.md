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
**61 Rust tests passed across the latest suites**, including app metadata and
preview coverage. `cargo clippy --all-targets -- -D warnings` passes. Formatting
checks and the optimized release build also passed. Regression tests cover import responsiveness and
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

The **UIKit/Core Animation app is implemented**, with project-scoped threads,
build lists and installation actions. Earlier versions used a cached SceneKit
phone image with generated identity artwork. That implementation has been
replaced: the live SceneKit view accepts only supplied screenshots, and transition
progress rotates the actual mesh. Without a capture, its screen remains empty.
Actual screenshot texture rendering and replacement without client relaunch
have now been observed, as recorded below. Live opening and closing transitions
also passed frame-by-frame inspection on the simulator.

An earlier full run logged **20 model/network tests and all 3 live UI tests
passing**: navigation, an exact `SQUIRCLE_DESIGN_OK` Hermes reply retained after
app relaunch, and a real signed build started from the app. Evidence:
`.verification/uikit-tests-final.log`. Xcode then hung finalizing its result
bundle and the process was interrupted, so this is test-log evidence, not a clean
completed `.xcresult`. An earlier UIKit run completed cleanly with 17 unit tests
and 2 UI tests. The build-action test produced signed job
`f3b5440a-81f7-4511-9b5b-c795265420f7` from clean source revision `70e53d0`.

The latest run completed **29 Swift unit tests and 1 navigation UI test cleanly**,
with exit 0 and `.verification/RealPreviewFinal.xcresult`. Log:
`.verification/real-preview-final-tests.log`. The earlier 28-unit clean run and
navigation-only run with a packaging hang are superseded by this completed run.
Navigation assertions and the visual motion inspection are separate evidence.

The user explicitly stopped the image-judge workflow. Its screenshot scores are
not acceptance evidence for the new functional preview path.

**Implemented and locally tested:** a private JSON app
catalog stores names/summaries and immutable PNG publications independently of
builds. Registration deduplicates canonical project+scheme; build synchronization
preserves edited text and newer screenshots. Six focused catalog tests passed
(`cargo test apps::tests --lib`), covering persistence, copy/provenance, invalid
input, app/build association and private paths. No Xcode or live service was
involved in those tests.

## Real simulator preview and HTTPS retrieval

After restarting the updated service with the dedicated simulator configured,
`preview capture 74efd708-a8a4-4cc9-abbc-924b53164569` installed and launched the
Probe's built simulator product and captured a **229,826-byte PNG**. Capture
source was `built_simulator_product`, at Unix time **1791140527**. It automatically
created app record `4e49ae98-345e-4218-a831-00c4f3a33677` and preview
`9b4ae41d-4f38-4267-a266-1de41f5b34b7`.

The authenticated app-preview request over private HTTPS port 8443, using that
preview version, returned bytes identical to the original simulator capture.
SHA-256: `293f52e73e2c29fa9d8eb3769bd5fd48530af14a9e334d497c9e8f7cb403bb7d`.
Evidence: `.verification/https-preview-proof.json`. This proves actual capture,
automatic catalog association and HTTPS image delivery on this Mac.

The main client is registered separately as app
`5f9b0650-b20b-4cd6-bcf2-a57574cab08c`. Through `app preview`, the CLI published
actual Squircle UI-test screenshot **03 (thread)**; the running client displayed
those pixels on its 3D phone. Screenshot **04 (builds)** was then published while
the client remained open, and replaced the displayed texture **without relaunch**.
Evidence: `.verification/published-thread-on-phone.png` and
`.verification/published-builds-without-relaunch.png`. The thread screenshot was
restored through the CLI afterward. These are actual app screenshots, separate
from the Probe capture and from a new physical-device installation.

`app update` changed the summary to “Apps, threads and installable builds.
Previews update from real simulator captures.” A separate `app show` confirmed
the persisted value through the API. Evidence:
`.verification/squircle-metadata-edit.json` and
`.verification/squircle-metadata-readback.json`. Restart persistence is covered
by the focused catalog tests.

## Live 3D motion verification

Every consecutive frame **238–321 (opening)** and **441–524 (closing)** from
`.verification/live-3d-navigation.mp4` was inspected. The phone stayed continuous,
its perspective changed in 3D, and neither handoff showed a blank or duplicated
device. Contact sheets: `.verification/live-3d-open-{0..3}.jpg` and
`.verification/live-3d-close-{0..3}.jpg`.

The last four samples in `.verification/live-3d-motion-audit.json` measured:

| Transition | Intervals | Median ms | Maximum ms | Above 33.5 ms |
| --- | ---: | ---: | ---: | ---: |
| Workspace open, live 3D | 64 | 16.67 | 34.79 | 1 |
| Workspace close, live 3D | 68 | 16.67 | 16.67 | 0 |
| Thread open | 63 | 16.67 | 55.71 | 1 |
| Thread close | 67 | 16.67 | 16.67 | 0 |

These are **simulator main-run-loop intervals**, not GPU timings or proof of
120 Hz rendering on a physical phone. The opening outliers are retained rather
than summarized away.

**Device acceptance:** the updated build was subsequently installed and launched
on the connected physical phone; see the version 3 evidence below.
no successful export or new phone installation is claimed yet.

## Signed version 0.1.0 (3)

Job `a8cc8e8e-ece9-4d8a-9a8a-1af3a3082a5e` archived and exported the client
from clean revision `95ab906`. The same job built its simulator counterpart,
installed/launched it, captured the actual screen, and published preview
`bd74d46b-21ef-4b80-8a40-c1569a470162` to the existing app record. The agent-edited
summary was preserved. Capture source is `current_working_tree`, not a claim
that the archived binary itself ran in the simulator. The job's observed launch
was from the **simulator**, not proof of installation on the physical phone.

The private HTTPS install page returned 200; its manifest identified
`ai.dreamslate.Squircle`. The downloaded **347,184-byte IPA** matched the exported
file: SHA-256 `110a3548f5a5ded61eb76aed4221d942738210b1301ccdda2a29a1b6c260b74e`.
Both archive and exported app passed `codesign --verify --deep --strict`; the
IPA uses Apple Distribution for Dreamslate team `2F26US4NAU`. Archive, exported
binary and dSYM share arm64 UUID `13CE61CD-7CCD-370E-ABED-BE26F8EE40C1`.
Signing evidence: `.verification/squircle-v3-signing-proof.json`.
Evidence: `.verification/squircle-v3-final-status.json`, `squircle-v3-catalog.json`
and `squircle-v3-https-proof.json`. After checking automatic publication, the
agent selected the previously captured real thread screen as the app's featured
preview; the build's own capture remains attached to the build.

On the user's request, CoreDevice found the physical iPhone 17 Pro Max connected.
The exported version 3 app was installed successfully and activated in the
foreground as PID **87823**. A new launch event
`aa0ab753-d6dc-4074-a417-1b80a6bf7e68` arrived at timestamp **1791141439**,
separate from the simulator event at 1791141210. Evidence:
`.verification/squircle-v3-phone-install.json`, `squircle-v3-phone-launch.json`
and `squircle-v3-phone-launch-events.json`. This proves a connected-device update
and launch, not a new cellular installation test or physical-device frame-rate test.

## Real Xcode jobs through Squircle

| Job | Result |
| --- | --- |
| `d5d1f0f7-8913-4085-85ce-ae44a9402927` | Unsigned Release simulator build succeeded |
| `61cf5aa9-770d-4ba2-a1cb-1a85f56eb78d` | Signed device archive and `release-testing` IPA export succeeded |
| `74efd708-a8a4-4cc9-abbc-924b53164569` | Updated simulator Probe; actual crash/recovery and symbolication succeeded |
| `7e9e1246-ee57-4dd9-8b6f-f070976283a3` | Updated signed Probe; installed/opened on the phone over cellular (user confirmation) |
| `05d980f6-be8c-4e21-acb5-f82971f7db37` | Signed native client installed; automatic phone launch event received and chat confirmed |
| `f3b5440a-81f7-4511-9b5b-c795265420f7` | UIKit build-button test submitted a real signed archive/export; clean source `70e53d0` |
| `a8cc8e8e-ece9-4d8a-9a8a-1af3a3082a5e` | Signed 0.1.0 (3), exported IPA and automatic simulator preview/catalog update succeeded; clean source `95ab906` |

These jobs were submitted through the CLI or native app to the real service. Their records,
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
- Packaged Mac startup supervision and suspended-client notifications.

Pairing, manual credential entry, coordinator adapters and additional backend
infrastructure are excluded from this personal build. No TestFlight or Firebase
service is required for the verified distribution path.
