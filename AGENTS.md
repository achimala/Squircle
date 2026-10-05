# Agent entry point

Read [README.md](README.md), then only the linked detail relevant to the task. Do not load every document by default.

## Preserve these decisions

- **2026-10-05:** replace the Hermes client integration with a fresh native client for the user's already running, unmodified T3 Code server. T3 owns agents, threads and execution. Do not fork T3 or create another agent backend. See [native migration](docs/t3-native-migration.md).
- Keep build/install/diagnostic logic in an agent-neutral CLI with discoverable help and structured output. OpenClaw compatibility is a goal; Hermes plugins and MCP are optional adapters, not core dependencies. See [CLI design](docs/cli.md) when implementing tooling.
- Build a native UIKit/Core Animation iPhone client. This supersedes the first SwiftUI UI. Use a minimal horizontal 3D app picker → flat thread list. Show app names and actual thread content; omit UI explanations, metadata summaries, capture captions and build banners. Keep builds in a secondary sheet. No cards; reserve glass for controls.
- Use direct spatial transitions and interactive back gestures, not screen crossfades. Verify fluid transitions frame by frame on rendered output. Do not mark the redesign visually verified until that check is complete. The Mac hosts Xcode and the coding agents.
- App previews must use actual simulator screenshots on the live 3D device. After UI changes, discover the app ID with `squircle app list`, update its name/summary with `squircle app update`, and publish the capture with `squircle app preview ID --file PATH`. The Mac app catalog is authoritative; do not create screen artwork from an app name or another agent backend. The user stopped the image-judge workflow.
- Tailscale is user-managed. Do not bundle, install, or configure it as an implicit part of this product.
- Cellular operation is required. Signed installation, manual app launch, and app logs/crashes satisfy the requirement; LLDB and remote launch are outside the initial scope.
- Reuse signed installation, app metadata, build tooling, diagnostics and the useful UIKit motion code. Hermes compatibility is no longer required; preserve old implementation in Git history. Do not uninstall the user's independent Hermes or change its services as part of this client migration. Real-phone crash recovery and Mac startup supervision remain separate checks.
- Select existing Claude Code or Codex providers through T3 with subscription authentication. Use T3's normalized live state/events instead of polling delegated agent logs. On this Mac use `/Users/anshu/.local/bin/codex`; the Homebrew binary is stale.
- Start simulator playback with T3's authenticated H.264 feed, native iOS decoding and its existing input protocol. No MJPEG playback, priming request or fallback. Measure latency before adding a separately authenticated streaming component; never expose the raw device hub. T3's iOS tuning and WebRTC endpoints are not exposed by the installed 0.0.45 proxy.

## Documentation discipline

User instructions take precedence. Label proposals and unknowns; do not turn a researched capability into a tested fact. Record evidence and versions when a milestone is actually validated. Update the relevant detail page when a decision changes; keep this entry point short.

These plans do not authorize unrelated setup changes or installations. Follow the active user request.
