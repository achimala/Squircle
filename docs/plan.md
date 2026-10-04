# Implementation plan

Status on 2026-10-04: the Mac build service, stock Hermes API and first native
client work together. The user installed the client and confirmed phone chat;
its launch acknowledgement reached the Mac. Exact evidence is in
[validation](validation.md).

## Completed foundation

- Rust CLI/service for Xcode jobs, signed artifacts, installation links and
  diagnostic collection; 61 Rust tests passed.
- Signed cellular installs of Probe and the native client, with automatic launch
  acknowledgement from client job `05d980f6-be8c-4e21-acb5-f82971f7db37`.
- Stock Hermes CLI/API invocation, persistent sessions, streamed runs and
  idempotent run retries over the existing Tailscale HTTPS connection.
- UIKit client with project-scoped threads, chat, tool progress, approvals,
  stop and builds. Twenty model/network tests and three live UI tests passed,
  including chat after relaunch and a real signed archive. See validation for
  the Xcode result-finalization limitation.
- Probe instrumentation with nine tests, real simulator crash recovery,
  matching symbols and successful symbolication. Physical-phone crash recovery
  remains unverified.
- Real simulator capture, private HTTPS PNG retrieval and CLI publication of
  Squircle screenshots. The client displayed them on its 3D device and replaced
  the texture with a second publication while remaining open. The latest run
  completed 29 unit tests and one navigation UI test cleanly.
- Consecutive simulator frames of the live 3D opening/closing transition were
  inspected: continuous phone, changing perspective, no blank or duplicate
  handoff. Timing evidence and simulator limits are in validation.

## 1 Complete real app previews and device acceptance

The UIKit/Core Animation app is implemented: project home, threads and
installable builds on a continuous ivory canvas, with a floating dimensional
device and flat rows. Glass is reserved for controls. The phone is a live 3D mesh
displaying a real app screenshot. App names, summaries and immutable captures
persist in the Mac catalog and can be updated by agents independently of builds.
The user stopped the image-judge workflow; no further score-driven iterations.

**Verified:** actual screenshot publication and visible texture replacement
without relaunch, CLI metadata editing with separate persisted API readback,
clean tests and frame-by-frame live 3D transition inspection.

**Remaining acceptance:** install the exported **0.1.0 (3)** update on the
physical phone and confirm its launch acknowledgement. Archive/export, automatic
simulator capture/catalog update and byte-identical private HTTPS delivery passed. Preserve sending, streaming, reconnecting and installation
access. No generated artwork may stand in for a missing capture.

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
