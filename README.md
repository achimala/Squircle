# Squircle

Build and iterate on iOS apps from an iPhone, using a Mac as the build machine and agent host. The chosen direction is **a standard Hermes installation, an agent-neutral iOS development CLI, and a native SwiftUI client**. Hermes is the first coordinator; the development tooling should also work from OpenClaw and other agents with Mac shell access.

## Current state

As of 2026-10-04, a Rust CLI and local service implement asynchronous Xcode builds, expiring installation links, and authenticated diagnostic collection. A minimal SwiftUI **Squircle Probe** exercises app logs, offline buffering, and crash capture using PLCrashReporter.

**Verified:** real simulator build, signed Dreamslate device archive/export, valid exported signature and matching dSYM; Rust contract tests and Probe simulator tests. **Pending:** physical cellular installation and phone-to-Mac feedback, actual Hermes/OpenClaw invocation, and the polished client. See [validation evidence](docs/validation.md).

## Run the prototype

Requires macOS, Xcode, and Rust. The helper uses the repository-local Rust toolchain if present, otherwise your installed Cargo. It does not install dependencies.

```sh
./scripts/cargo-local build --release
export SQUIRCLE_DATA_DIR="$PWD/.squircle"
./target/release/squircle --help
./target/release/squircle capabilities --json
./target/release/squircle help workflow
```

Follow the [verification walkthrough](docs/verification.md) to start the service, build, and connect the phone. Tailscale and HTTPS remain user-managed. The service runs in the foreground; no login daemon is installed.

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

Agents should start with [AGENTS.md](AGENTS.md). These documents distinguish accepted decisions, proposed implementation, and unverified assumptions. They are not a claim that the proposed stack already works together.
