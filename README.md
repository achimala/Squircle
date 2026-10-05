# Squircle

Build and iterate on iOS apps from your iPhone. Squircle is a native UIKit client
for your existing **unmodified T3 Code server**. T3 owns coding agents, projects,
threads and execution; the Mac runs Xcode. The independent Rust `squircle` CLI
supplies signed builds, installation links, app screenshots and diagnostics.

## Current state

**2026-10-05: native T3 replacement implemented, version 0.2.0 (13).**
The active iPhone target no longer contains Hermes transport or worker-log polling.
The independently installed Hermes and T3 were not changed.

- Existing T3 projects/threads, live message and tool events, provider/model
  choice, new threads, stop and approval/question responses.
- Preserved 3D app picker, spatial navigation, actual screenshots and secondary
  signed-builds sheet.
- One native H.264 preview and paired input connection. Input enables only after
  video and the HID handshake succeed. Failures reconnect both resources;
  hiding, leaving the thread and backgrounding release them. Returning restores
  the selected target. An explicit restart uses T3's own capture-aware API.

**Verified for build 13:** nine targeted native tests passed, including 180 decoded
H.264 frames with 125 changing pictures, six forced input disconnects, startup
cancellation, duplicate starts and a 31-second idle connection. Actual native
rendering and touch were checked; signed build 13 was directly installed on the
paired iPhone; its manual-launch acknowledgement arrived, and the user confirmed
it works well. Earlier Codex execution and spatial-transition evidence remains
recorded in [implementation evidence](docs/t3-native-migration.md).

Build 12's MJPEG playback caused unacceptable phone latency, reported by the user.
It is removed. There is no MJPEG priming request or fallback. AVCC decoding uses
VideoToolbox, requires hardware decoding on the phone, and bounds decoded
presentation to the newest picture. Video still uses T3's authenticated HTTPS
feed, with WSS input over the existing user-managed Tailscale route. Measured
physical-phone response latency remains outstanding.

T3's host can retain a stale capture after a simulator reboot. Its supported
shutdown/open API restored live capture; transport reconnection alone cannot
identify a stale image on an otherwise valid idle connection. Do not auto-reboot
an agent's simulator. Claude subscription login and complete physical-phone/crash
recovery checks remain outstanding.

## For development

Requires macOS, Xcode, XcodeGen and the existing T3 installation. No new agent
backend, T3 fork, provider install or Tailscale configuration is needed.

```sh
./scripts/cargo-local build --release
export SQUIRCLE_DATA_DIR="$PWD/.squircle"
./target/release/squircle --help
./target/release/squircle capabilities --json
./target/release/squircle help workflow
xcodegen generate --spec app/Squircle/project.yml
```

The personal build uses ignored `.squircle/client-t3.json`: HTTPS T3 origin,
normal paired session scoped to orchestration read/operate, and existing Squircle
build/diagnostic credentials. It contains no Hermes credentials. Never commit
this file or private runtime probes. The native client stores the paired session
in the device Keychain; it does not copy T3's database. See the
[app guide](app/Squircle/README.md) for setup and build commands.

The existing build service is running on its original loopback address and
user-managed Tailscale HTTPS route. Startup supervision is not packaged yet.
After UI changes, find the app ID with `squircle app list`, update its summary,
and publish an actual simulator PNG with `squircle app preview ID --file PATH`.
Actual native simulator captures are published through that catalog.
See the evidence page for the scope of rendered transition checks.

## Read only what you need

| Question | Document |
| --- | --- |
| What is implemented and what remains unverified? | [Native T3 implementation](docs/t3-native-migration.md) |
| How does T3 streaming/input work? | [T3 research and simulator trial](docs/direct-agents-plan.md) |
| What owns each part? | [Architecture](docs/architecture.md) |
| How do agents build and deliver apps? | [CLI design](docs/cli.md) |
| How does cellular installation work? | [Remote iOS workflow](docs/remote-ios.md) |
| What was verified before the T3 replacement? | [Historical validation](docs/validation.md) |

Start with [AGENTS.md](AGENTS.md). Historical Hermes validation describes earlier
builds and is not evidence that this replacement passed those checks.
