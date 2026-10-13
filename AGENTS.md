# Agent entry point

Read [README.md](README.md), then only the linked detail relevant to the task. Do not load every document by default.

## Preserve these decisions

- **2026-10-05:** replace the Hermes client integration with a fresh native client for the user's already running, unmodified T3 Code server. T3 owns agents, threads and execution. Do not fork T3 or create another agent backend. See [native migration](docs/t3-native-migration.md).
- Keep build/install/diagnostic logic in an agent-neutral CLI with discoverable help and structured output. OpenClaw compatibility is a goal; Hermes plugins and MCP are optional adapters, not core dependencies. See [CLI design](docs/cli.md) when implementing tooling.
- Build a native UIKit/Core Animation iPhone client. **2026-10-05 redesign (user-requested total rethink), superseding the picker → workspace → modal thread flow:** one continuous 3D stage. **2026-10-11 (user-confirmed):** Home is a grid of devices with only each app's name (no thread title subtitle); tapping one opens the app page, whose thread list scrolls up beneath the device as it shrinks. Devices are still portraits rendered once and placed in the scroll views (they scroll natively, pass under toolbar buttons and their edge blur); since 2026-10-13 no live 3D scene draws at all. Flat page backdrop, no colored gradient glow (user: "AI slop"); a screen without a capture shows an abstract blurred placeholder. See [grid](docs/t3-native-migration.md#2026-10-11-home-grid-0300-28). See [redesign](docs/t3-native-migration.md#2026-10-05-redesign-030-15). Show app names and actual thread content; omit UI explanations, metadata summaries, capture captions and build banners. Keep the build list in a secondary sheet; builds the agent mentions also appear in the conversation as an installable glass card. No cards otherwise; reserve glass for controls. **2026-10-05 thread (user-requested):** no title bar; agent work reads as plain step sentences that fold into a tappable "Worked for…" glass pill per finished turn (the one allowed summary); screenshots and recordings show inline; agent questions are an inline glass card; handwritten Metal effects (SwiftUI never drives layout). **Later the same day:** no rainbow glow (user: harsh, too Apple-like); the live state is a glass capsule whose task text slides vertically, clipped by the capsule (user rejected the Metal lens warp, 2026-10-06); your messages are tinted glass bubbles that rise with their text out of the field, as in Messages; finished turns pulse softly (Core Animation, not a Metal ring); threads are cached and reopen at the bottom; Home orders apps by most recent use; the conversation is full height; model and approval pickers sit above the field. See [thread redesign](docs/t3-native-migration.md#2026-10-05-thread-redesign-030-19).
- **2026-10-12 (user-requested): one agent per app.** Tapping an app pushes in the conversation with its app agent (one level; back returns to Home); the app's other threads push over the agent from a Threads button (a full-height list sheet) or by tapping a worker's update line; Builds is its own button beside it (user rejected a threads list in between, 2026-10-12, and the combined corner menu, 2026-10-13). The agent is a T3 thread on T3's "squircle" Claude instance (plugin `plugin/squircle`, installed by `squircle agent setup`) in the project's folder; it can run ordinary T3 worker threads in their own worktrees, and the service wakes it when one finishes. The user tells it how to work: no built-in workflow, branches, rules or caps (user: "just let me tell it what to do"). The service runs no model. Never an outside agent harness: only T3's provider CLIs use the subscription's included usage. See [one agent per app](docs/t3-native-migration.md#2026-10-12-one-agent-per-app-030-3637).
- **2026-10-13 (user-approved): simulators only while an agent uses them, superseding the travelling device, the divider and the live 3D device.** Agents start a simulator through Squircle (`squircle sim start --thread ID`; the plugin, worker prompts and per-thread instructions say so): the service opens it for the thread through T3, records it, and on `sim stop` or the turn ending files the recording in that turn and closes T3's device session. While any of the app's threads uses a simulator (a Squircle session, or a T3 device session of a working thread, including the user's own), a flat PiP floats over the app's conversations, one per simulator, stacked in a corner you drag it to; tapping it brings it large and touchable (Home, open its thread). The turn shows the same simulator live, then its recording. Simulators are drawn flat by the system video layer, never in SceneKit. No system PiP for now. See [agent simulators](docs/t3-native-migration.md#2026-10-13-agent-simulators-030-40).
- Motion follows the finger: native scroll physics or one interruptible spring drive every move. The destination screen takes touches from the first frame of a transition; nothing waits for a spring to settle, and a tap mid-transition takes over (user, 2026-10-11). Entering a thread is a flat push with no 3D tilt (user: out of place). Back from a thread is a swipe from the left edge (user changed this from swipe-anywhere on 2026-10-06). No screen crossfades, and no system zoom/sheet gestures over the conversation or simulator. Verify transitions frame by frame on rendered output before calling them visually verified. The Mac hosts Xcode and the coding agents.
- App previews must use actual simulator screenshots. After UI changes, discover the app ID with `squircle app list`, update its name/summary with `squircle app update`, and publish the capture with `squircle app preview ID --file PATH`. The Mac app catalog is authoritative; do not create screen artwork from an app name or another agent backend. The user stopped the image-judge workflow.
- Tailscale is user-managed. Do not bundle, install, or configure it as an implicit part of this product.
- Cellular operation is required. Signed installation, manual app launch, and app logs/crashes satisfy the requirement; LLDB and remote launch are outside the initial scope.
- Reuse signed installation, app metadata, build tooling, diagnostics and the useful UIKit motion code. Hermes compatibility is no longer required; preserve old implementation in Git history. Do not uninstall the user's independent Hermes or change its services as part of this client migration. Real-phone crash recovery and Mac startup supervision remain separate checks.
- Select existing Claude Code or Codex providers through T3 with subscription authentication. Use T3's normalized live state/events instead of polling delegated agent logs. T3 strips tool inputs and result images from client streams, so the Squircle service reads T3's `state.sqlite` read-only for those details only; never write to it. On this Mac use `/Users/anshu/.local/bin/codex`; the Homebrew binary is stale.
- Start simulator playback with T3's authenticated H.264 feed, native iOS decoding and its existing input protocol; decoded pictures are drawn flat (`AVSampleBufferDisplayLayer`). No MJPEG playback, priming request or fallback. Measure latency before adding a separately authenticated streaming component; never expose the raw device hub. T3's iOS tuning and WebRTC endpoints are not exposed by the installed 0.0.45 proxy.

- **2026-10-06 (user decision):** device builds Squircle signs for other apps get an injected debug overlay (Squircle's own sources as `SquircleOverlay.framework`, added between archive and export). The overlay reads Squircle's paired connection from a team-shared Keychain group; the user accepted that risk. It is never in App Store exports or simulator builds. No fallback credentials. See [debug overlay](docs/t3-native-migration.md#2026-10-06-in-app-debug-overlay-030-24).

## Engineering rules (iPhone client)

- **Make invalid states unrepresentable.** Model navigation and UI as a small
  source of truth (an enum route, a value) plus values that move continuously
  toward what it implies. Derive every frame, visibility, interactivity and
  ownership from that state each time; never toggle them from callbacks or
  completion handlers. Change what is mounted only where it is off screen.
  If a sequence of taps could leave the screen wrong, the design is wrong, not
  the timing. `StudioViewController` (route + `sync()` + `applyScene()`) is the
  reference; its DEBUG `SQUIRCLE_STRESS=1` mode audits every frame and must
  report `violations=0` after navigation changes.
- **Swift concurrency only.** Use async/await, `Task`, `AsyncStream`,
  `@MainActor` and `DisplayFrame.next()` (wait for the next frame). Do not add
  Combine or Dispatch (`DispatchQueue`, `.sink`, `@Published`,
  `ObservableObject`, …). `scripts/check-swift-concurrency` runs in every app
  build and fails on any increase over `app/Squircle/concurrency-baseline.txt`;
  the baseline only goes down (`--update` refuses increases). Remove existing
  uses when you touch them.

- **Tests only where looking can't catch it** (user, 2026-10-11). Do not
  write tests that restate the code (layout numbers, view text, a filter
  filters) or exist to show diligence. Test only logic that is easy to get
  wrong and invisible on screen: parsers, protocol and stream decoding,
  security checks, state that must survive reconnects. No tests that call
  live T3, agents, builds or the simulator. Check UI changes by running the
  app and looking at it. Delete a test when the design it pins changes;
  don't rewrite it. The suite must stay a few seconds.

## Documentation discipline

User instructions take precedence. Label proposals and unknowns; do not turn a researched capability into a tested fact. Record evidence and versions when a milestone is actually validated. Update the relevant detail page when a decision changes; keep this entry point short.

These plans do not authorize unrelated setup changes or installations. Follow the active user request.
