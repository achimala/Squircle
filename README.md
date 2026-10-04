# Squircle

Build and iterate on iOS apps from your iPhone. **The native app talks to stock Hermes over Tailscale; the Mac runs Xcode and coding agents.** The Rust `squircle` tool supplies builds, installation links and diagnostics. Hermes owns identity, memory and conversations.

## Current state

The first [native app](app/Squircle/README.md) is installed and its Hermes chat works on the phone. It has persistent conversations, streamed responses/tool progress, approvals, stop, and installable builds. This personal build includes its Mac connection settings: **no token form, pairing flow or additional agent backend**.

The next interface uses **UIKit and Core Animation**, replacing the first SwiftUI presentation: app-centric project home → threads → installable builds, with an ivory canvas, floating device and flat rows. The redesign and frame-by-frame visual verification are in progress, not yet validated. [Design decisions](docs/product.md).

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
