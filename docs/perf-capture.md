# Performance capture from the phone

**Status 2026-10-14: built (overlay), verified in the simulator; not yet tried
on the phone or over cellular.** The user asked for a way to start and stop a
performance trace inside an app, on the phone, often on cellular, and hand it
to the agent; then (approving the build) for screenshots and screen recordings
in the same place.

## As built

- The message field's + menu in the overlay: Photo Library, Camera, then App
  Screenshot, Record Screen, Record Performance. Long-pressing the bubble
  still takes a screenshot.
- Recording docks the overlay into the bubble in a recording state
  (`CaptureSession.Recording`, rendered by `LiveCapsule` tone `.recording`:
  crimson tint, pulsing dot, "Recording screen/performance", elapsed time).
  The app stays usable; tapping the bubble stops; 60 s limit stops it too.
  The panel opens with the recording flying into the field (a screen
  recording from the screen, a performance one from the bubble).
- Screen recording (`ScreenRecorder`): the app's own windows below the overlay
  at 30 fps, finger dots, H.264 1.8 Mbit/s, long side 1280 px: no overlay, no
  system prompt. Simulator check: 11 s → 435 KB, 588×1280, overlay absent.
  **2026-10-18 (user: the app drops frames while recording):** frames used to
  come from `drawHierarchy` on the main thread, measured at 55 ms a frame in
  the simulator (3× screen), the app falling from 60 to 15 fps.
  The render-server snapshot under it was ~8 ms; the rest was CoreGraphics
  converting the full-size snapshot (8-bit extended-range sRGB, which no
  8-bit context matches) pixel by pixel and resampling it. Now each window is
  rendered by QuartzCore's private `CARenderServerSnapshot` (layer mode, the
  call UIKit makes, keys from QuartzCore's own `kCASnapshot*` constants)
  straight into the encoder's IOSurface-backed buffer at recording scale, in
  an actor off the main thread; windows above the bottom one go to a scratch
  surface and are blended with vImage (each render clears its destination).
  Measured: main thread 0.04 ms a frame, 60 fps, no late frames while
  recording; 7–9 ms a frame off the main thread for two windows; 30 fps
  output, overlay absent. If the private call is missing the recorder does
  not start. Not yet measured on the phone.
- Performance (`PerfRecorder`, `MainThreadSampler`): display-link frame times
  (hitch = frame more than 1.5 periods apart), main-thread stack every ~1 ms
  (suspend, `thread_get_state`, frame-pointer walk bounded to the main
  thread's stack, resume; nothing allocates or locks while suspended),
  CPU/memory/thermal every 250 ms, touches, screen name at each hitch,
  loaded images with UUIDs; `dladdr` names on the phone. No app log since
  2026-10-15: `OSLogStore` reads the process's whole log to find the
  recording's window, which was 2.1 s of a 2.4 s stop in the simulator and
  far longer on the phone (the user saw stop "hang"). Without it the main
  thread's part of a stop measured 2 ms and the rest (stacks, `dladdr`, JSON)
  0.3 s off the main thread; the bubble reads "Finishing recording" meanwhile.
- Upload: `POST /v1/captures?kind=video|performance` (control token, 300 MB
  route limit) into `<data>/captures/`, started as soon as the recording is
  attached; uploads don't wait for each other. Until the message is sent its
  pending bubble already shows the recording (the line, or the clip from the
  phone's copy); a failed upload puts it back in the field with the error.
  The message gets a "Recorded in the app:" block of links (hidden
  in the transcript): the video plays in your message's gallery; a
  performance recording shows as one line ("Performance recording · 0:08 · 11
  hitches"); the link tells the agent to run `squircle perf show PATH`.
- `squircle perf show PATH|ID [--dsym]` (text; `--json` structured), `perf
  list`. App frames: a given dSYM, a Squircle build's dSYMs by UUID,
  Spotlight, or the binary on this Mac (simulator). System frames: Xcode's
  device symbols for the phone's OS build, the file on this Mac, or the
  phone's `dladdr` guess (marked approx), demangled.
- Simulator check (Squircle Debug, `SQUIRCLE_OVERLAY_DEMO` + `SQUIRCLE_JANK=1`,
  250 ms main-thread busy loop every 1.5 s): 8 s capture, every hitch's
  stack named `StudioScene.deliberateJank() SquircleApp.swift:62`; the
  Squircle Probe agent received the capture and ran `perf show` on it.

## Original proposal

## Recommendation

Record in the app's own process, upload over the existing paired connection,
symbolicate on the Mac, and give the agent a short text summary plus the raw
file. Instruments stays a Mac/simulator tool the agent drives itself.

What the user does: in the overlay's ⋯ menu (and Squircle's own, in DEBUG
builds) tap **Record performance**. A small red dot shows while recording. Use
the app; tap the dot to stop (or it stops after 60 s). The capture goes into the
message field like the screenshot does; the user adds a sentence ("scrolling the
feed stutters") and sends.

What the agent receives: one line in the message pointing at the capture, and
`squircle perf show ID --json` returning:

- the worst hitches (start, duration, what was on screen), each with its
  symbolicated main-thread stack, heaviest frames first;
- a timeline: frames, hitches, app log lines, CPU %, memory footprint, thermal
  state, foreground/background changes;
- a path to the raw capture and the build it came from.

## What works in-process (no Mac, works on cellular)

| Signal | How | Notes |
| --- | --- | --- |
| Frame hitches | `CADisplayLink` timestamps vs `targetTimestamp` | Catches main-thread/commit hitches. Render-server-only hitches are invisible in-process. |
| Main-thread stacks | Background thread suspends the main thread ~1 kHz while recording (`thread_suspend`, `thread_get_state`, frame-pointer walk) | **Prototyped** (macOS arm64, same Mach calls as iOS): 752 samples in a 956 ms busy loop, app frames symbolicated offline from the dSYM with `atos -l <load address>`. Same technique Sentry and ETTrace ship on iOS. Keep only samples overlapping hitches to stay small. |
| CPU, memory, thermal | `task_info`/`thread_basic_info`, `phys_footprint`, `ProcessInfo.thermalState`, every 250 ms | Cheap. |
| Energy | None public per app | Not possible in-process. |
| App log lines | `OSLogStore(scope: .currentProcessIdentifier)` | Dropped 2026-10-15: reading it made every stop take seconds. |
| `os_signpost` intervals | Not reliably readable in-process | Signposts are generally kept only while a tool records. Unverified on iOS 27; don't depend on it. |
| MetricKit hangs/CPU exceptions | `MXMetricManager` subscriber in the overlay, forwarded as diagnostics | Delivered after the fact (next launch / daily), never on demand. Useful passively, not for "record now". |

Each sample stores raw addresses plus image load addresses and UUIDs. System
frames are named on the phone with `dladdr`; app frames on the Mac.

## What needs the Mac

- **Instruments against the phone over cellular: not possible in practice.**
  CoreDevice finds network-paired phones by Bonjour on the local network; there
  is no supported path over Tailscale/cellular (consistent with the product
  scope: no making Xcode think a cellular phone is local). The phone was
  USB-wired during this check (`transportType: wired`), so the cellular case was
  not tested directly. When the phone is wired or on the Mac's Wi-Fi, `xctrace
  record --device <phone>` works and could be offered as a "full trace" option.
- **Instruments on a simulator: works headless today.** Checked with Xcode 27.1:
  `xctrace record --template 'Time Profiler' --device <sim> --all-processes
  --time-limit 3s` then `xctrace export --toc` exposes `time-profile`,
  `potential-hangs`, `hang-risks`, `os-signpost`, `os-log` and thermal tables as
  XML. The agent can already do this itself; a `squircle perf sim` wrapper
  would just summarise the XML the same way.
- **Symbolication.** Each build job keeps its dSYM; match the capture's image
  UUID to the job and run `atos`. System frames for the phone's OS can also be
  named from Xcode's iOS DeviceSupport cache (present for the current iOS 27.0).

## Delivery

- Upload: `POST /v1/perf` on the Squircle service over the paired connection the
  overlay already reads (which token it holds was not checked). Gzip JSON;
  ~1–3 MB for a 60 s capture with hitch-only stacks.
- Into the conversation: the composer gets a "Performance · 12 s · 4 hitches"
  attachment chip; on send, the message text carries a one-line reference the
  agent passes to `squircle perf show`. T3 attachments are images only, so the
  file itself never goes through T3.
- CLI (agent-neutral, `--help`, JSON): `squircle perf list`, `perf show ID`
  (summary), `perf raw ID` (path), `perf sim --thread ID` (simulator Instruments).

## Cost and risks

- Size: roughly 2–4 days. Recorder in the overlay sources (shared with
  Squircle DEBUG), upload endpoint and store, symbolication + summary in Rust,
  composer chip.
- The sampler suspends the main thread; if it ever paused while holding a lock
  the sampler needs (malloc), the app could deadlock. Mitigation: preallocate
  buffers, no allocation or Swift runtime calls between suspend and resume.
- Observer effect: ~1 kHz sampling costs a few % CPU; the summary should say so.
- Frame-pointer walks miss frames in leaf functions and some system code; deep
  inlining in Release builds collapses frames (`atos -i` recovers some).
- Overlay-only: never in App Store exports, consistent with the overlay rule.
