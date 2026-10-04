# Implementation plan

Status on 2026-10-04: documentation only. The user is installing Hermes. Every validation step below is pending.

## 1 Verify existing agent delegation

Have Hermes perform one small coding task in a disposable project through each CLI the user wants to use. Confirm the executable and login are available to the gateway process, the correct working directory is used, required approvals work, and completion/errors return to Hermes. Check resume only if the intended workflow needs it.

Also disconnect/reconnect during a background task and exercise cancellation. Record Hermes/CLI versions and API capabilities. Client disconnection and gateway restart are different cases; neither should cause a completed side effect to be blindly retried.

**Exit condition:** useful delegated work reaches a clear result without building a custom coding-agent integration. Add Paseo only if an observed session-management requirement warrants it.

## 2 Prove the cellular development loop

Use a minimal iOS test app and existing command-line tools. Do not wait for the SwiftUI controller or a finished Hermes plugin.

1. Establish signing prerequisites and produce a device-specific, correctly signed exported IPA.
2. Serve the manifest and IPA from the Mac over trusted HTTPS reachable through the user's Tailscale connection.
3. With the phone on cellular and Wi-Fi disabled, initiate installation, install, and open the app manually.
4. Produce an app log and a test crash. Deliver logs to the Mac; after relaunch, deliver and symbolicate the crash using the matching dSYM.
5. Make a visible code change, build a new version, install the update, and correlate subsequent diagnostics with that build.

**Exit condition:** an observed edit → build → cellular install → feedback cycle. Record signing/export settings, tool/device versions, URL behavior, timings, failures, and retained evidence in [the workflow document](remote-ios.md). Private HTTPS installer reachability is a hypothesis until this succeeds.

## 3 Package the proven workflow as a neutral CLI

Expose the working operations through an agent-neutral CLI and reuse existing tools. Add the small local service needed for asynchronous jobs, artifacts, and diagnostic ingestion. Define progressive help, structured output, durable build metadata and bounded logs as described in [CLI design](cli.md). Teach Hermes the workflow with a short skill; add a plugin only for a concrete integration need.

**Exit condition:** direct CLI use and a Hermes request both produce identifiable installable builds, and returned diagnostics can support a fix. Verify CLI independence from Hermes and record OpenClaw compatibility as pending until exercised. Report interruption/failure honestly; avoid duplicating agent state.

## 4 Build the native client

First build a thin vertical slice: connect/authenticate, open a persistent conversation, send a task, show progress, handle approvals, display a build, and open its install link. Then add polished project navigation, worker visibility, diagnostic views, and reconnect behavior.

**Exit condition:** the complete validated loop works from the iPhone interface. Handle foreground streaming first; choose background notifications deliberately rather than assuming a persistent iOS socket.

## 5 Harden and simplify setup

Test upgrades, Mac restarts, interrupted builds/uploads, expired installation links, and signing failures. Record compatible CLI, coordinator, and optional adapter versions. Add a small Mac setup/launcher helper only if useful. Keep Tailscale user-managed.

## Current evidence

Earlier read-only checks found an Apple Silicon Mac with Xcode 27.1 and Codex/Claude executables. They did not establish device connectivity, signing readiness, gateway CLI access, or successful remote installation. Recheck relevant facts when implementation begins.
