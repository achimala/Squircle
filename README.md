# Squircle

Build and iterate on iOS apps from your iPhone. **The native app talks to stock Hermes over Tailscale; the Mac runs Xcode and coding agents.** The Rust `squircle` tool supplies builds, installation links and diagnostics. Hermes owns identity, memory and conversations.

## Current state

Version 9 adds live activity for both Claude Code and Codex delegated by Hermes,
full-height command/change/output views, and actual simulator captures. It uses
the CLIs’ standard structured events through stock Hermes, with no additional
agent runner or change to Hermes’s model. Real delegated sessions verified Claude
Max and Codex ChatGPT login and displayed actions before completion. [Coding visibility and authentication](docs/coding-visibility.md).

Version 7 switched chat to stock Hermes Desktop’s native protocol, with
full tool arguments/results, requests, shared Desktop sessions and native
background replies. [Message support and upstream limits](docs/hermes-client.md).

The [native app](app/Squircle/README.md) has persistent conversations, streamed responses/tool progress, approvals, stop, and installable builds. Version **0.1.0 (9)** is signed and installed on the phone, verified by `devicectl`. Its manual-launch acknowledgement remains pending; version 7’s acknowledgement was verified. This personal build includes its Mac connection settings: **no token form, pairing flow or additional agent backend**.

The interface uses a horizontal live 3D app picker, a minimal flat thread list and a secondary builds sheet. UIKit moves the actual phone, app title and controls through spatial transitions with interactive back navigation; there are no screen fades or explanatory panels. Real screenshots and agent-editable app metadata persist on the Mac. **Live simulator tests for both delegated coding agents pass, alongside 62 deterministic protocol/presentation tests and earlier native chat/navigation checks.** [Design decisions](docs/product.md), [test evidence and limits](docs/validation.md).

**Add an app from the phone:** **+ → browse the Mac or paste a project path → choose scheme/name → Add**. Import saves the app's build settings on the Mac, so its first build can start from the phone. Import itself does not build or create a screenshot. This flow is verified and included in installed version 5. [Import details](docs/cli.md#import-an-existing-app).

**Verified on 2026-10-04:** cellular installation, automatic native-app launch acknowledgement on the Mac, live Hermes API interaction, signed builds and matching symbols, and real simulator crash recovery/symbolication. [Evidence and remaining checks](docs/validation.md). The Probe remains a diagnostic test fixture, separate from the app.

## For development

Requires macOS, Xcode, and Rust. The helper uses the repository-local Rust toolchain if present, otherwise your installed Cargo. It does not install dependencies.

```sh
./scripts/cargo-local build --release
export SQUIRCLE_DATA_DIR="$PWD/.squircle"
./target/release/squircle --help
./target/release/squircle capabilities --json
./target/release/squircle help workflow
```

See the [app guide](app/Squircle/README.md) to rebuild the client and the [CLI walkthrough](docs/verification.md) for build/diagnostic commands. Tailscale remains an external dependency; setup on this Mac was performed at the user's explicit request. Mac startup supervision is not packaged yet.

After changing an app's UI, capture its actual simulator screen, find its ID with `squircle app list`, update its summary, and publish the PNG with `squircle app preview ID --file PATH`. See [app metadata and previews](docs/cli.md#app-metadata-and-previews) for the contract.

## Read only what you need

| Question | Document |
| --- | --- |
| What are we building and what has been decided? | [Product decisions](docs/product.md) |
| What belongs to Hermes versus our code? | [Architecture](docs/architecture.md) |
| How should any agent discover and use the tools? | [CLI design](docs/cli.md) |
| How will cellular installation and diagnostics work? | [Remote iOS workflow](docs/remote-ios.md) |
| How do I run it, and what has been proven? | [Walkthrough](docs/verification.md), [validation evidence](docs/validation.md) |
| What should happen next and what proves success? | [Implementation plan](docs/plan.md) |
| Why were other products and approaches deferred? | [Alternatives](docs/alternatives.md) |

Agents should start with [AGENTS.md](AGENTS.md). The linked evidence separates the working path from remaining checks.
