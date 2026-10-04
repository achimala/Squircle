# Agent entry point

Read [README.md](README.md), then only the linked detail relevant to the task. Do not load every document by default.

## Preserve these decisions

- Use an independently installed, unmodified Hermes as the persistent coordinator. Extend documented APIs, plugins, skills, and MCP; do not start by forking Hermes or creating another agent backend.
- Keep build/install/diagnostic logic in an agent-neutral CLI with discoverable help and structured output. OpenClaw compatibility is a goal; Hermes plugins and MCP are optional adapters, not core dependencies. See [CLI design](docs/cli.md) when implementing tooling.
- Build a native UIKit/Core Animation iPhone client. This supersedes the first SwiftUI UI. Use a minimal horizontal 3D app picker → flat thread list. Show app names and actual thread content; omit UI explanations, metadata summaries, capture captions and build banners. Keep builds in a secondary sheet. No cards; reserve glass for controls.
- Use direct spatial transitions and interactive back gestures, not screen crossfades. Verify fluid transitions frame by frame on rendered output. Do not mark the redesign visually verified until that check is complete. The Mac hosts Xcode and the coding agents.
- App previews must use actual simulator screenshots on the live 3D device. After UI changes, discover the app ID with `squircle app list`, update its name/summary with `squircle app update`, and publish the capture with `squircle app preview ID --file PATH`. The Mac app catalog is authoritative; do not create screen artwork from an app name or another agent backend. The user stopped the image-judge workflow.
- Tailscale is user-managed. Do not bundle, install, or configure it as an implicit part of this product.
- Cellular operation is required. Signed installation, manual app launch, and app logs/crashes satisfy the requirement; LLDB and remote launch are outside the initial scope.
- Preserve the working phone installation, Hermes chat and automatic launch acknowledgement while refining the client. Real-phone crash recovery and Mac startup supervision remain separate checks.
- Hermes remains the general assistant with its existing model. Delegate coding to the existing Claude Code or Codex CLI using subscription authentication; retain and reference their standard structured event logs as described in [coding visibility](docs/coding-visibility.md). Never switch Hermes runtime/provider merely to expose coding-agent progress. On this Mac use `/Users/anshu/.local/bin/codex`; the Homebrew binary is stale.
- Existing Codex/Claude CLIs are the first delegation path. Paseo, separate memory services, and cloud distribution services are optional, not dependencies.

## Documentation discipline

User instructions take precedence. Label proposals and unknowns; do not turn a researched capability into a tested fact. Record evidence and versions when a milestone is actually validated. Update the relevant detail page when a decision changes; keep this entry point short.

These plans do not authorize unrelated setup changes or installations. Follow the active user request.
