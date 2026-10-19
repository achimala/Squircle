# Squircle

Build and iterate on iOS apps from your iPhone. Squircle is a native UIKit
iPhone client for your own, unmodified [T3 Code](https://github.com/pingdotgg/t3code)
server, plus a small Rust service on the Mac. T3 owns the coding agents,
projects and threads; the Mac runs Xcode. You talk to one agent per app from
the phone, watch it work (including the simulator it uses), and install the
signed builds it makes, over cellular if your Mac is reachable.

> **Status: very early alpha.** Squircle is a personal project that changes
> daily. Expect breaking changes, rough edges and missing setup steps. It comes
> with no guarantees or support; see [LICENSE](LICENSE) (MIT). If you're
> thinking about using it at a company, I'd love to hear from you, but you
> don't need to ask.

## What works today

- **Home:** a grid of your apps as device portraits made from real simulator
  screenshots. Tapping one opens that app's agent.
- **One agent per app:** a T3 thread on a Claude instance with Squircle's
  plugin. It answers you, runs ordinary T3 worker threads in their own
  worktrees, and is woken when they finish. You tell it how to work.
- **Tasks:** the agent keeps a list of what you asked for and where each stands.
- **Simulators:** while an agent uses one, it floats over the conversation as
  a live, touchable picture; the recording lands in the agent's turn.
- **Builds:** signed device builds you install from the phone; builds of
  other apps can carry a small debug overlay that opens Squircle inside them.
- **Notifications and a Live Activity**, sent from the Mac with your own APNs key.

Not done: a pairing screen on the phone (credentials are built into your
personal build), LLDB or remote launch. `squircle service install` runs the
service as a launchd user agent so it survives reboots.
The full dated record is in [history](docs/history.md).

## Requirements

- A Mac with Xcode (tested with 27.1), [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  and a Rust toolchain (tested with 1.99; install with [rustup](https://rustup.rs)).
- [T3 Code](https://github.com/pingdotgg/t3code) installed and running (tested
  with 0.0.45), with Claude Code signed in. Codex is optional, for workers.
- An iPhone on iOS 18 or later, and an Apple Developer team that can sign
  for it. The app compiles unsigned without one.
- For use away from home: HTTPS routes from the phone to T3 and to the
  Squircle service. [Tailscale](https://tailscale.com) Serve works well;
  you set it up yourself, Squircle never installs or configures it.

Squircle is macOS only.

## Quick start

```sh
# 1. Build the CLI and service.
cargo build --release            # or ./scripts/cargo-local build --release
export PATH="$PWD/target/release:$PATH"
export SQUIRCLE_DATA_DIR="$PWD/.squircle"   # private, ignored by Git

# 2. Create local state and credentials, check Xcode, start the service.
squircle init
squircle doctor
squircle serve --public-url https://YOUR-MAC-HTTPS-ORIGIN   # keep running

# 3. In another terminal (same SQUIRCLE_DATA_DIR): give the service its own
#    T3 session. Create a pairing token in T3 (pair a new client), then:
pbpaste | squircle t3 connect --url http://127.0.0.1:3773
#    restart `squircle serve`, then install the app-agent plugin into T3:
squircle agent setup

# 4. Generate the Xcode project and check it compiles.
xcodegen generate --spec app/Squircle/project.yml
```

To put the app on your phone, write the phone's connection file
(`.squircle/client-t3.json`, described in the [app guide](app/Squircle/README.md)),
copy `app/Squircle/Config/Local.example.xcconfig` to `Local.xcconfig` with
your signing team, bundle ID prefix and that file as
`SQUIRCLE_EMBED_CONNECTION`, and start a signed build with
`squircle build start`. Install it from the link the service gives you, then
open it. `squircle help workflow` walks through builds, install links and
diagnostics; `squircle capabilities --json` lists every command.

A build that embeds that connection file is for your own devices: **never
share its IPA**. Leave `SQUIRCLE_EMBED_CONNECTION` empty for anything else.

## How it fits together

```text
iPhone app ──HTTPS/WebSocket──> T3 Code (agents, threads, simulators)
     └──────HTTPS────────────> Squircle service on the Mac ──> Xcode, T3
```

| Piece | Where | What it does |
| --- | --- | --- |
| Service and CLI | `src/` (Rust) | One `squircle` binary: builds, install links, app catalog, tasks, simulator leases, notifications, agent wake-ups. `squircle serve` is the service; every other command is a client usable by any agent. See [CLI](docs/cli.md). |
| iPhone app | `app/Squircle` (UIKit) | Talks to T3 directly for conversations and to the service for everything else. See the [app guide](app/Squircle/README.md). |
| Overlay | `app/Squircle/Overlay` | Squircle's own conversation view as a framework injected into device builds of other apps. Never in App Store exports. |
| Plugin | `plugin/squircle` | The app agent's instructions, its read-only history subagent and hooks, installed into T3 by `squircle agent setup`. |
| Probe | `examples/SquircleProbe` | A sample app with crash and log reporting, used to test the build and diagnostics path. |

The service never runs a model and never writes to T3's database; it reads
T3's `state.sqlite` read-only for details T3 doesn't stream.

## Read more

| Question | Document |
| --- | --- |
| Contributing, checks and rules | [CONTRIBUTING](CONTRIBUTING.md) |
| Reporting a security issue, trust boundaries | [SECURITY](SECURITY.md) |
| Decisions that must be kept | [AGENTS.md](AGENTS.md) |
| What owns each part? | [Architecture](docs/architecture.md), [owners and state machines](docs/fsm-architecture.md) |
| How do agents build and deliver apps? | [CLI](docs/cli.md), [workflow](docs/verification.md) |
| How does cellular installation work? | [Remote iOS](docs/remote-ios.md) |
| How do tasks work? | [Tasks](docs/task-tracking.md) |
| How does the phone record performance? | [Performance capture](docs/perf-capture.md) |
| Why each design, with evidence | [Migration record](docs/t3-native-migration.md), [history](docs/history.md) |
| The jelly characters (direction B is built; the rest is a proposal) | [Jelly design](docs/design-jelly-language.md) |
| Reviews and audits | [Open-source review](docs/oss-review.md), [code review](docs/code-review-2026-10.md), [second review](docs/code-review-2026-10-b.md), [reinvention audit](docs/reinvention-audit.md) |
| Publishing this repository | [Publishing](docs/publishing.md) |
| Superseded designs (Hermes, live 3D) | [Archive](docs/archive/) |
