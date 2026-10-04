# Agent entry point

Read [README.md](README.md), then only the linked detail relevant to the task. Do not load every document by default.

## Preserve these decisions

- Use an independently installed, unmodified Hermes as the persistent coordinator. Extend documented APIs, plugins, skills, and MCP; do not start by forking Hermes or creating another agent backend.
- Keep build/install/diagnostic logic in an agent-neutral CLI with discoverable help and structured output. OpenClaw compatibility is a goal; Hermes plugins and MCP are optional adapters, not core dependencies. See [CLI design](docs/cli.md) when implementing tooling.
- Build a native UIKit/Core Animation iPhone client. This supersedes the first SwiftUI UI. Organize apps/projects → threads → installable builds on a continuous ivory canvas: a floating dimensional device, expressive typography and flat rows. The user rejected rounded-card layouts; reserve glass for controls.
- Verify fluid transitions frame by frame on rendered output. Do not mark the redesign visually verified until that check is complete. The Mac hosts Xcode and the coding agents.
- Tailscale is user-managed. Do not bundle, install, or configure it as an implicit part of this product.
- Cellular operation is required. Signed installation, manual app launch, and app logs/crashes satisfy the requirement; LLDB and remote launch are outside the initial scope.
- Preserve the working phone installation, Hermes chat and automatic launch acknowledgement while refining the client. Real-phone crash recovery and Mac startup supervision remain separate checks.
- Existing Codex/Claude CLIs are the first delegation path. Paseo, separate memory services, and cloud distribution services are optional, not dependencies.

## Documentation discipline

User instructions take precedence. Label proposals and unknowns; do not turn a researched capability into a tested fact. Record evidence and versions when a milestone is actually validated. Update the relevant detail page when a decision changes; keep this entry point short.

These plans do not authorize unrelated setup changes or installations. Follow the active user request.
