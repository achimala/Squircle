# Remote App Development

Build and iterate on iOS apps from an iPhone, using a Mac as the build machine and agent host. The chosen direction is **a standard Hermes installation, an agent-neutral iOS development CLI, and a native SwiftUI client**. Hermes is the first coordinator; the development tooling should also work from OpenClaw and other agents with Mac shell access.

## Current state

As of 2026-10-04, the user is setting up Hermes. This repository contains planning documentation; no integration has been implemented or tested end to end.

**Next milestone:** prove a signed build can travel from the Mac to the phone over cellular, then return useful diagnostics. First do a small check that Hermes can invoke the existing coding CLIs. Build the polished client after that development loop works.

## Read only what you need

| Question | Document |
| --- | --- |
| What are we building and what has been decided? | [Product decisions](docs/product.md) |
| What belongs to Hermes versus our code? | [Architecture](docs/architecture.md) |
| How should any agent discover and use the tools? | [CLI design](docs/cli.md) |
| How will cellular installation and diagnostics work? | [Remote iOS workflow](docs/remote-ios.md) |
| What should happen next and what proves success? | [Implementation plan](docs/plan.md) |
| Why were other products and approaches deferred? | [Alternatives](docs/alternatives.md) |

Agents should start with [AGENTS.md](AGENTS.md). These documents distinguish accepted decisions, proposed implementation, and unverified assumptions. They are not a claim that the proposed stack already works together.
