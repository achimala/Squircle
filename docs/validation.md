# Validation evidence

Recorded 2026-10-04 on this Mac. This page records observed results, not claims
that the entire proposed product works. Local artifacts and credentials are
ignored by Git. Reproduce with the [walkthrough](verification.md).

## Native Hermes Desktop integration — version 7

The redesign was checkpointed first as `52b616d`. The chat integration now uses
stock Hermes `serve` v0.21.5+6977.gaf90026, through the approved existing HTTPS
8444 route. Hermes itself was not modified. Desktop's **Mac Hermes** connection
was selected in its actual UI; the native test chat and timed reply appeared in
its ordinary session list and transcript.

- **54 deterministic iOS tests pass.** The final regression also passed the live
  UI tool-detail/controls/relaunch test. Two opt-in network tests were skipped
  in that regression and exercised separately as described below.
- The native live transport test passed full `terminal` arguments/results,
  a real heartbeat reply, and a second client resuming the **same runtime ID**.
- A separate native live request test passed an actual `clarify` question,
  `request.answer`, continuation to a terminal call, and full stored tool-body
  retrieval through the existing Desktop REST transcript endpoint.
- The navigation UI test passed open/back, cancelled interactive back, thread
  and builds sheets. Expanded tool output is now in the accessibility tree;
  this was caught and corrected during the live UI test.
- Real simulator images were inspected. The native tool-result image was
  published to app `5f9b0650-b20b-4cd6-bcf2-a57574cab08c` as preview
  `e4dec16a-8a1d-4c20-8b41-ee8952f9a0fb`.

Evidence retained in `.verification/native-hermes/`: `regression.log`,
`live-heartbeat.log`, `live-clarification-and-ui.log`, `tool-result.png`, and
`restored-conversation.png`. Clean result bundles are in
`/tmp/squircle-hermes-release-check.xcresult`,
`/tmp/squircle-hermes-tests-v2.xcresult`, and
`/tmp/squircle-hermes-verified.xcresult`. Initial failing UI runs are superseded;
one Xcode diagnostic collector hung and was terminated after its tests finished.
The final runs used `-collect-test-diagnostics never` and completed cleanly.

The final signed archive/export is build `f86d83f5-f046-44bd-8ff4-0ef4018cc54a`,
from clean integration commit `e41b804`. `devicectl` installed it on the connected
iPhone and independently reported **0.1.0 (7)**. The phone's manual launch and
new automatic acknowledgement are still pending; installation is not recorded
as a new cellular or physical-device chat test.

A separate real simulator recording was inspected in consecutive rendered
frames over **3.2–4.6 s (opening)** and **5.7–7.1 s (closing)**. The phone, title,
and controls move continuously between gallery/workspace with no screen
crossfade. The actual published chat capture appears on the live 3D device.
Evidence: `motion.mp4`, `native-open-01…04.png`, `native-close-01…04.png` under
`.verification/native-hermes/`. This is visual continuity evidence on the
simulator, not a measured physical-device frame rate. The simulator recorder's
stale lock was cleared by restarting only the dedicated Squircle QA simulator.
Eleven test-only conversations were archived (recoverably) after verification;
the latest native example remains visible.

**Upstream limitation reproduced:** this Hermes version can consume the first
heartbeat tick in its slash-worker watchdog without running a reply; the second
tick delivered normally through the native owner process. No custom scheduler
was added. [Message coverage, Mac lifecycle and remaining limits](hermes-client.md).

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

The version 3 run completed **29 Swift unit tests and 1 navigation UI test cleanly**,
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

## Version 3 live 3D motion verification

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

## Version 5: users add Mac apps

Rust commit `01cd6c5` adds authenticated shallow directory browsing, real Xcode
scheme/settings inspection, and app import with a persistent archive recipe.
**71 Rust tests pass** (49 library, 9 CLI, 10 HTTP, 3 lifecycle); formatting and
strict Clippy pass. Tests cover import without any build history, preserved
identity/recipe across restart, package browsing, authentication, real Xcode JSON
shapes, missing-team handling, export options and bounded subprocess cleanup.

The iOS flow is **+ → browse the Mac or enter a path → choose scheme/name → Add**.
It imports through the same service and enables builds from the saved recipe.
Import does not start compilation. The real API inspected Squircle Probe and
identified its iOS app scheme, bundle, Dreamslate team and existing export plist.

`.verification/ImportV5.xcresult` passed **36 unit tests and 2 UI tests** covering
invalid-path recovery, actual import, stable app identity on duplicate import,
build availability, persistence after relaunch and existing spatial navigation.
`.verification/ImportV5Browser.xcresult` separately passed directory browsing,
tapping the real project package, and selecting the actual checked Xcode scheme.
The existing Probe was reimported; no fake app was added to the user's library.

Screenshots are retained under `.verification/import-v5-screens/`, with the first
UI run recorded in `import-v5-motion.mp4`. Inspection caught an oversized long
path control; the final browser check includes its width constraint fix.
Evidence also includes `import-v5-browse.json`, `import-v5-probe-inspection.json`,
`import-v5-probe-record.json` and `import-v5-squircle-record.json`. The latter
imports Squircle's own build recipe, used for the signed update below.

Job `6429fb55-c679-4ea3-8c10-538c33471830` archived/exported **0.1.0 (5)** from clean
revision `ea4ecd7`, then built, launched and captured its simulator counterpart.
Automatic preview publication succeeded; the actual verified Mac browser PNG
was subsequently selected as the featured app preview. The job retains its own
capture, whose source is `current_working_tree`.

Archive and IPA signatures verify under team `2F26US4NAU`; their arm64 binaries
and the dSYM share UUID `6DD13129-FD87-36FF-98EB-DA64AA4884B3`.
IPA SHA-256: `0e0f22fb7c2194e4fdf100ca5f2ece26548ed4fee75cbf859f0f999802ef15c3`.
Evidence: `.verification/squircle-v5-final-status.json`,
`squircle-v5-signing-proof.json` and `squircle-v5-featured-preview.json`.

CoreDevice installed the exported app on the connected iPhone 17 Pro Max and
activated it as PID **88082**. New launch event
`17999c21-bbf7-44cb-a1b2-ae6d0091dfa5` arrived at timestamp **1791144314**, distinct
from the simulator launch at 1791144254. Evidence:
`.verification/squircle-v5-phone-install.json`, `squircle-v5-phone-launch.json`,
`squircle-v5-before-phone-launch.json` and `squircle-v5-phone-launch-events.json`.
This verifies the connected-phone update, not a new cellular installation test
or physical-phone animation frame-rate measurement.

## Version 4 picker, motion and physical installation

Final source `07e725f` passed **29 unit tests and the navigation test** in
`.verification/PickerV4ReleaseCheck.xcresult`: picker swipes, app opening,
short-edge cancellation, full-edge back, reopening, existing thread/builds sheets
and normal back. Thread/chat content remains real; test history was not replaced
with design fixtures. Earlier checks in `PickerV4Final` and `PickerV4Accepted`
exposed hierarchy and visible-transition defects before the final run.

Sequential simulator frames were inspected for the live phone/title transport,
neighbor motion, cancellation and final handoff. Fixes preserve the presenting
window hierarchy, use a transparent transition container, avoid assigning frames
to transformed controls, and preserve a newer destination screenshot arriving
mid-transition. The empty-chat explanation was removed too.

Evidence: `.verification/picker-v4-release-motion.mp4`, `picker-v4-release-frames/`,
`picker-v4-release-screens/`, and the matching gesture/motion audit JSON files.
The recording has irregular and some non-monotonic timestamps, so it does not
establish rendered frame pacing. The apparent interactive-finalization gap spans
recording gaps longer than the measured **167.95 ms** settling interval; the
normal dismissal has continuous geometry and the same endpoint. Main-run-loop
cadence was mostly 16.67 ms, with some longer intervals; this is not a GPU or
physical-phone FPS measurement.

Job `204882db-9d4e-4fff-8411-f14aefbd42c3` archived/exported **0.1.0 (4)** from clean
revision `e96e80e`, then built, launched and captured its simulator counterpart.
Automatic preview publication succeeded; afterward the agent selected the actual
verified thread-list PNG as the featured app preview. Build capture remains
attached to the job. Preview source is `current_working_tree`.

Archive and exported IPA signatures verify. Distribution team: `2F26US4NAU`.
Archive, IPA and dSYM share arm64 UUID `F7BCE3FC-2636-3FDA-9B1E-05A8E8165A42`.
IPA SHA-256: `9aff08ce073cfc746f14584004c479502fce54632e5c61c20b2efef739705b1f`.
Evidence: `.verification/squircle-v4-final-status.json`, `squircle-v4-signing-proof.json`
and `squircle-v4-featured-preview.json`.

CoreDevice installed the exported app on the connected iPhone 17 Pro Max and
activated it as PID **87961**. New launch event
`b02f220d-289c-4a96-ab7b-1f62ebf9a68b` arrived at timestamp **1791143307**, distinct
from the simulator launch at 1791143175. Evidence:
`.verification/squircle-v4-phone-install.json`, `squircle-v4-phone-launch.json`,
`squircle-v4-phone-launch-events.json`. This verifies a connected-phone update,
not a new cellular test or a physical-device animation-performance measurement.

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
| `204882db-9d4e-4fff-8411-f14aefbd42c3` | Signed 0.1.0 (4), automatic preview, physical installation and launch succeeded; clean source `e96e80e` |
| `6429fb55-c679-4ea3-8c10-538c33471830` | Signed 0.1.0 (5), saved import recipe, automatic preview, physical installation and launch succeeded; clean source `ea4ecd7` |

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
- Feedback association beyond the verified per-build launch events.
- Coding-worker delegation and OpenClaw invocation in their actual environments.
- Packaged Mac startup supervision and suspended-client notifications.

Pairing, manual credential entry, coordinator adapters and additional backend
infrastructure are excluded from this personal build. No TestFlight or Firebase
service is required for the verified distribution path.
