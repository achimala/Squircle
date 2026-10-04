# Remote iOS build, install and diagnostics

Status: agreed direction; end-to-end feasibility remains unproven. Sources checked 2026-10-04. Read this when implementing builds, distribution or device diagnostics.

## Accepted scope

The Mac builds apps. The iPhone must install over **cellular**, with Wi-Fi disabled. The user confirms installation and opens the app manually. Live application logs and actionable crash reports satisfy the debugging requirement. LLDB, remote launch and making the phone appear locally attached are outside this path.

Tailscale is installed and managed externally by users. The product consumes the resulting connectivity; it does not provision a VPN. Keep the Mac awake and reachable during builds/downloads.

## Proposed flow

1. Build and archive a chosen revision on the Mac; export a signed ad hoc IPA for the registered iPhone.
2. Preserve the archive, IPA, dSYMs, build logs and metadata: project, commit, bundle ID, version, build number and artifact checksums.
3. Serve an installation page, XML manifest and IPA from the Mac through trusted HTTPS, reachable over the user's Tailscale connection. The installation link uses `itms-services://?action=download-manifest&url=<encoded HTTPS manifest URL>`.
4. The user installs and launches. The app reports its build identifier to the hub. Until that acknowledgement, show “installation requested”, not “installed”.
5. App instrumentation sends logs while running, buffers during disconnection, and uploads persisted crash reports after relaunch. The Mac associates reports with the exact build and symbols.

**Critical proof:** Safari reaching the page does not prove the iOS installer can fetch the manifest and IPA over the VPN. Test system-installer routing, DNS, TLS trust and download authorization on the actual phone. Do not assume it forwards app bearer headers or browser cookies. Use installer-compatible authorization, such as scoped expiring download URLs within the tailnet; validate retries and expiry.

## Prerequisites and evidence

Require Apple Developer Program membership, registered device UDID, matching App ID/entitlements, distribution certificate/private key and valid provisioning profile. Signing must work noninteractively in the Mac's actual service context, including Keychain access. Record device settings and prompts required by the tested iOS version.

[Apple's ad hoc guide](https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile/) supports installation on registered devices without Xcode. [Apple's wireless installation guide](https://support.apple.com/en-euro/guide/deployment/depce7cefc4d/1/web/1.0) documents HTTPS, trusted certificates and manifest mechanics **in an enterprise context**; it is not evidence that this exact ad hoc/cellular/Tailscale combination works. TestFlight is the fallback, with Apple's upload/processing workflow replacing private OTA delivery.

## Reuse before custom code

- **Build/export candidate:** [fastlane `build_app`/gym](https://docs.fastlane.tools/actions/build_app/) wraps Xcode and produces signed IPA/dSYM artifacts; export options support a manifest. Adds Ruby tooling. Pin versions and verify export options against installed Xcode. Signing setup remains necessary; `match` is optional.
- **Agent development candidate:** [MobileBuildMCP](https://github.com/getsentry/MobileBuildMCP), formerly XcodeBuildMCP, supplies CLI/MCP simulator build/test/run tooling. Its device commands require reachable devices; they do not solve cellular OTA.
- **Integration still required:** artifact catalog, HTTPS/authentication, job status/cancellation, retries and diagnostic ingestion. Neither package supplies the complete remote product.

## Diagnostics: selection pending

Use app-owned structured logging with upload/buffering; OSLog alone does not expose a remote stream. [KSCrash](https://github.com/kstenerud/KSCrash) or [PLCrashReporter](https://github.com/microsoft/plcrashreporter) supplies crash capture but leaves ingestion and presentation work. [Sentry Cocoa](https://github.com/getsentry/sentry-cocoa) offers a broader stack, adding a hosted service or self-hosted operations. Select after a small prototype.

Retain symbols by binary UUID: [Apple requires matching dSYM and binary UUIDs](https://developer.apple.com/documentation/xcode/locating-a-missing-debug-symbol-file). Never promise immediate crash upload or uninterrupted background logging.

## Acceptance gate — all pending

- Build/export without interactive Mac prompts; preserve matching symbols.
- Install and update over cellular with Wi-Fi disabled; manually launch and verify build acknowledgement.
- Receive identifiable live logs; disconnect/reconnect and recover buffered events.
- Trigger a controlled test crash; relaunch, upload and symbolicate its stack.
- Report failed downloads/signing accurately and retry safely.

Complete this proof **before UI or finished CLI/adapter packaging**. The CLI-first architecture changes the integration boundary, not the device/signing proof. Record tested versions, commands and outcomes here.
