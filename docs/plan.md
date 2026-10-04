# Implementation plan

Status on 2026-10-04: the Mac build service, stock Hermes API and native client
work together. Version 3 is installed on the phone. Version 4's picker/thread
redesign has passed 29 unit tests and navigation checks. The final committed
layout, rendered motion and device update remain under verification. Exact
evidence is in [validation](validation.md).

## Completed foundation

- Rust CLI/service for Xcode jobs, signed artifacts, installation links and
  diagnostic collection; 61 Rust tests passed.
- Signed cellular installs of Probe and the native client, with automatic launch
  acknowledgement from client job `05d980f6-be8c-4e21-acb5-f82971f7db37`.
- Stock Hermes CLI/API invocation, persistent sessions, streamed runs and
  idempotent run retries over the existing Tailscale HTTPS connection.
- UIKit client with project-scoped threads, chat, tool progress, approvals,
  stop and builds. Earlier live UI tests exercised Hermes chat after relaunch
  and a real signed build.
- Probe instrumentation with nine tests, real simulator crash recovery,
  matching symbols and successful symbolication. Physical-phone crash recovery
  remains unverified.
- Real simulator capture, private HTTPS PNG retrieval and CLI publication of
  Squircle screenshots. The client displayed them on its 3D device and replaced
  the texture with a second publication while remaining open. Version 3's tests,
  live 3D transition inspection, automatic capture and connected-phone
  install/launch passed. This was not a new cellular installation test.

## 1 Verify the version 4 interaction and device update

Version 4 implements a horizontal live 3D app picker → minimal flat threads,
with builds in a secondary sheet. Actual phone/title/control views move spatially
with interactive back navigation. There are no fades, explanatory panels or
placeholder prose. Metadata remains available to agents; the device displays
only real screenshots.

**Passed:** picker swipes, opening an app, interactive back cancellation and
completion, reopening, existing thread/builds sheets and normal back navigation.

**Pending:** finish the rerun after the last layout changes, inspect rendered
motion frame by frame, then sign, install and confirm version 4's launch
acknowledgement. Preserve the working chat/build/install flows. Passing
interaction assertions alone does not establish visual continuity. Continue
functional verification without image judges.

## 2 Complete phone feedback and worker verification

Exercise phone logs, offline queue recovery, controlled crash/relaunch/upload
and matching-dSYM symbolication. Install a visible update and distinguish its
feedback from the previous build. The private HTTPS installer path is already
proven for this phone; no new distribution backend is needed.

Have stock Hermes delegate a small coding task through the desired Codex/Claude
CLIs, obtain an identifiable build and retrieve diagnostics through Squircle.
Check working directory, login, approvals, completion and cancellation in the
actual process. Resume/restart behavior and OpenClaw invocation remain separate
tests; add Paseo or a skill only for an observed need.

## 3 Harden the working flow

Exercise service/gateway restarts, interrupted uploads/builds, signing failures
and upgrades. Package Mac startup supervision and notification delivery only
when their intended behavior is clear. Foreground SSE does not provide suspended
iOS background notifications. Keep Tailscale external and avoid a second agent
backend.
