# Implementation plan

Status on 2026-10-04: the Squircle prototype is implemented. A signed probe archive/export, unsigned simulator build and local tests have passed. Cellular installation, physical-device feedback and real coordinator invocation remain pending. Exact evidence belongs in [validation](validation.md).

## Completed foundation

- Rust CLI with progressive help/JSON output and an Axum service for authenticated build control, expiring OTA links and diagnostic ingestion.
- SwiftUI Squircle Probe with Keychain credentials, persistent retries and PLCrashReporter integration; five unit tests passed on iPhone 18 Pro / iOS 27.0 simulator.
- Unsigned simulator build: `d5d1f0f7-8913-4085-85ce-ae44a9402927`.
- Signed archive and `release-testing` export: `61cf5aa9-770d-4ba2-a1cb-1a85f56eb78d`. Exported signature verification passed; binary/dSYM UUIDs match. Profile covers one registered device.
- Local HTTP contract tests cover token roles, artifact/manifest delivery, expired links and diagnostic replay/launch observation.

These results establish a working local foundation. They do not establish physical installation, cellular reachability or runtime crash capture.

## 1 Finish the cellular development proof

Next input: the user's HTTPS origin and working user-managed Tailscale connectivity. Tailscale was stopped at the latest check. Squircle's public-URL setting generates links; it does not provision HTTPS or configure the VPN.

1. Expose the existing service through trusted HTTPS. Verify control requests and installer-compatible capability URLs without adding bearer headers to installation downloads.
2. Generate a link for the signed probe. With Wi-Fi disabled, install over cellular and open manually. Record actual device/iOS version and required prompts/settings.
3. Configure the diagnostic token and exact build ID. Observe the launch event and a recognizable app log on the Mac.
4. Interrupt connectivity, enqueue a log, reconnect and verify recovery without duplicates.
5. Trigger a controlled probe crash with no debugger attached; relaunch, upload and symbolicate it using the retained dSYM.
6. Make a visible change, build/export a new version, install the update and correlate subsequent diagnostics with its build ID.

**Exit condition:** an observed edit → build → cellular install → feedback cycle. Add commands, timings, failures and evidence to [validation](validation.md). Follow [the remote workflow](remote-ios.md); private HTTPS installer reachability remains a hypothesis until tested.

## 2 Exercise the existing coordinator and coding CLIs

Have the independently installed Hermes perform a small coding task in a disposable project through each desired CLI, then discover and invoke Squircle through its live help. Check executable/login availability in Hermes' process context, working directories, approvals, completion/errors and cancellation. Test resume only where the workflow requires it.

Disconnect/reconnect during background work. Separately test gateway/service restart: do not blindly repeat completed side effects. Neither Hermes nor OpenClaw invocation has been validated yet.

**Exit condition:** a Hermes request delegates useful work, obtains an identifiable installable build and retrieves diagnostics through the same neutral CLI. Add a short skill if useful; add Paseo or an adapter only for an observed integration need. Keep OpenClaw compatibility marked pending until exercised.

## 3 Build the native controller

After the device proof, implement connect/authenticate → persistent conversation → task/progress/approval → build → install link. Squircle Probe is test instrumentation, not this controller. Then add project navigation, worker visibility, diagnostic views and reconnect behavior.

**Exit condition:** the validated loop works from the iPhone interface. Start with foreground streaming; choose background notifications deliberately rather than assuming a persistent iOS socket.

## 4 Harden and package

Exercise upgrades, Mac restarts, interrupted builds/uploads, credential expiry and signing failures beyond existing unit tests. Record compatible CLI/coordinator versions. Finish distribution and optional startup/launcher integration after the workflow is proven. Keep Tailscale user-managed and durable task state in the appropriate component; avoid creating another agent backend.
