# Implementation status and next checks

**2026-10-05:** native frontend for stock T3, signed **0.2.0 (13)** and directly
installed on the paired iPhone. Existing agent-neutral build/install service remains
intact. See [migration evidence](t3-native-migration.md).

## Completed

- Direct paired T3 projects/threads/providers, live text/tool events, model controls,
  creation, stop, approvals/questions and snapshot recovery.
- One native H.264/input lifetime, ordered touch, Home, preview expansion,
  hide/show and background/navigation recovery; explicit capture-aware restart.
- Preserved app picker/spatial navigation, actual screenshots, build recipes,
  signed artifacts, installer links and launch diagnostics.
- Removed active Hermes adapters and delegated-log polling.
- 21 distinct native tests verified across standard and motion runs, including
  real Codex execution and six forced input disconnect/reconnect cycles.
- User confirmed build 11 working; its automatic launch acknowledgement arrived.
  Build 12 had unacceptable phone latency; its MJPEG playback is removed.
  CoreDevice successfully installed H.264-only build 13; its manual launch
  acknowledgement arrived. The user confirmed build 13 works well.
- Nine targeted build-13 tests passed, including 180 decoded H.264 frames,
  125 changing pictures and six repeated reconnects. Native rendering/touch checked.

## Remaining verification

1. Build-13 phone response latency.
2. Broader physical-phone visual/gesture checks. Native tap/Home/hide/reopen
   and a representative rendered open/close transition passed; catalog updated.
3. Claude subscription login and its separate round trip; provider inventory is
   not authentication evidence.
4. Measured cellular latency/bandwidth and long-duration Mac sleep/wake, physical
   phone crash recovery, live approval/question/cancellation UX branches.

## Later capabilities

Self-service pairing renewal, Mac startup supervision, native pinch/landscape,
large-history paging and multi-scheme picker association remain subsequent work.
No additional orchestration service is planned. Never infer stalled capture from
unchanging pixels or automatically restart an agent's simulator.
