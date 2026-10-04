# Implementation plan

Status on 2026-10-04: the Mac build service, stock Hermes API and first native
client work together. The user installed the client and confirmed phone chat;
its launch acknowledgement reached the Mac. Exact evidence is in
[validation](validation.md).

## Completed foundation

- Rust CLI/service for Xcode jobs, signed artifacts, installation links and
  diagnostic collection; 45 Rust tests passed.
- Signed cellular installs of Probe and the native client, with automatic launch
  acknowledgement from client job `05d980f6-be8c-4e21-acb5-f82971f7db37`.
- Stock Hermes CLI/API invocation, persistent sessions, streamed runs and
  idempotent run retries over the existing Tailscale HTTPS connection.
- First SwiftUI client with chat, tool progress, approvals, stop and builds;
  seven client tests plus live Swift transport/model checks passed.
- Probe instrumentation with nine tests, real simulator crash recovery,
  matching symbols and successful symbolication. Physical-phone crash recovery
  remains unverified.

## 1 Refine the native app

Replace the initial SwiftUI presentation with UIKit and Core Animation. Start
from an app-centric project home, then threads and installable builds. Use a
continuous ivory canvas, floating dimensional device, typography and flat rows;
reserve glass for controls. The user rejected the initial rounded-card target.
Keep fluid transitions and direct access to the working Hermes conversation.

**Acceptance:** inspect rendered screens and transitions frame by frame, fix
visible discontinuities, and preserve sending, streaming, reconnecting and
installation access. This redesign and visual acceptance are currently pending;
the working first client is the baseline, not proof of the redesign.

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
