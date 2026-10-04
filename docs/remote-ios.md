# Remote iOS build, install and diagnostics

Status on 2026-10-04: Squircle builds and exports the signed probe; the cellular installation and device feedback loop remains unproven. Read this for distribution and diagnostics. See [validation evidence](validation.md) for exact jobs, versions and artifacts.

## Accepted scope

The Mac builds apps. The iPhone must install over **cellular**, with Wi-Fi disabled. The user confirms installation and opens the app manually. Live application logs and actionable crash reports satisfy the debugging requirement. LLDB, remote launch and making the phone appear locally attached are outside this path.

Tailscale is installed and managed externally by users. The product consumes the resulting connectivity; it does not provision a VPN. Keep the Mac awake and reachable during builds/downloads.

## Implemented prototype

Squircle's Rust CLI and Axum service manage Xcode build jobs, retained artifacts/logs, expiring installation URLs and diagnostics. Control and diagnostic uploads use separate bearer tokens. The service generates the installation page, XML manifest and IPA download routes; **a configured public URL does not enable TLS**. Trusted HTTPS must be supplied separately through the user's network setup.

The intended device sequence is: open the expiring page → confirm installation → manually launch → report the build ID → send logs → crash → relaunch and upload the report. Install URLs use `itms-services` and scoped tickets, without requiring installer bearer headers or browser cookies. Creating a link or downloading an IPA does not confirm installation; `launch_observed` records an app-reported launch only.

HTTP contract tests cover token separation, imported IPA byte preservation, manifest metadata, expired/invalid tickets, diagnostic retries/conflicts and launch observation. These are local API tests, not a physical installation test. Imported IPAs are explicitly marked as having unverified signatures.

## Signing and build evidence

The probe's signed archive and `release-testing` export succeeded under Xcode 27.1. The exported app passed `codesign --verify --deep --strict`; its arm64 binary and dSYM UUIDs match. The profile belongs to Dreamslate Inc. (`2F26US4NAU`), includes one device, expires 2027-07-25 and has `get-task-allow=false`. This validates the generated artifacts, not installation on the user's phone. [Exact evidence](validation.md)

Other apps still need program membership, registered devices, matching identifiers/entitlements, certificates/private keys and profiles. Verify signing access in the actual service context. Provisioning changes require an explicit opt-in; successful setup for this probe is not universal signing readiness.

The prototype invokes `xcodebuild` directly. [fastlane](https://docs.fastlane.tools/actions/build_app/) and [MobileBuildMCP](https://github.com/getsentry/MobileBuildMCP) remain optional integrations, not dependencies or solutions to cellular reachability.

## Probe diagnostics

[Squircle Probe](../examples/SquircleProbe/README.md) uses PLCrashReporter 1.12.2, Keychain credentials and an atomic bounded upload queue. It emits launch and selected log events, recovers crash reports after relaunch, and retries manually or on foreground entry. Five simulator unit tests passed; actual crash capture/recovery and phone-to-Mac delivery are pending. This is app instrumentation, not remote OSLog access or uninterrupted background streaming.

Keep the original build attribution and [matching dSYM UUIDs](https://developer.apple.com/documentation/xcode/locating-a-missing-debug-symbol-file). Server ingestion is implemented; end-to-end symbolication remains a separate proof.

## Remaining acceptance gate

- Obtain the user-managed HTTPS origin; Tailscale was stopped at the latest check.
- Prove the system installer can fetch the manifest/IPA over cellular with Wi-Fi disabled. Safari access alone is insufficient evidence of installer VPN routing, DNS, TLS or download authorization.
- Install, manually launch and receive the correct build acknowledgement; repeat with a visible update.
- Receive logs, recover buffered events after reconnection, then crash/relaunch/upload and symbolicate the report.

[Apple documents registered-device distribution](https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile/) and [wireless manifest mechanics in an enterprise context](https://support.apple.com/en-euro/guide/deployment/depce7cefc4d/1/web/1.0); neither proves this exact cellular/Tailscale combination. TestFlight remains a fallback. Complete the device proof before polished UI or adapter packaging.
