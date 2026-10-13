# Squircle

Build and iterate on iOS apps from your iPhone. Squircle is a native UIKit client
for your existing **unmodified T3 Code server**. T3 owns coding agents, projects,
threads and execution; the Mac runs Xcode. The independent Rust `squircle` CLI
supplies signed builds, installation links, app screenshots and diagnostics.

## Current state

**2026-10-13: one look everywhere, version 0.3.0 (41).** Conversations read
like plain chat in the app and the overlay alike: status lines are plain text,
your messages keep glass bubbles, and model and approvals sit in a ⋯ menu. See
[one look](docs/t3-native-migration.md#2026-10-13-one-look-everywhere-030-41).

**2026-10-13: agent simulators, version 0.3.0 (40).** A simulator shows only
while an agent uses it: agents run `squircle sim start`, Squircle records the
simulator, and the phone shows it as a draggable PiP over the app's
conversations (several at once, tap for large and touchable) and live in the
turn, then the recording there. The divider and the live 3D device are gone;
on the simulator the compositor's CPU with a live stream on screen fell from
21% to 6–9%. Not yet on the phone. See
[agent simulators](docs/t3-native-migration.md#2026-10-13-agent-simulators-030-40).

**2026-10-12: one agent per app, version 0.3.0 (37).** Tapping an app opens
its agent, which you tell what to do; it can run worker threads and is woken
when they finish. Other threads open over it from its Threads list; Builds has its own button. The agent is a T3
thread on a "Squircle agent" Claude instance with Squircle's plugin; the
service wakes it when workers finish. Verified end to end on a scratch repo
and in the simulator; not yet on the phone. See
[one agent per app](docs/t3-native-migration.md#2026-10-12-one-agent-per-app-030-3637).

**2026-10-06: in-app debug overlay, version 0.3.0 (24).** Device builds Squircle
signs for other apps now carry a small injected overlay: a glass bubble showing
that app's agent work that opens Squircle's own view of the app (threads, new
thread, builds, live simulator). No project changes; never in App Store
exports; `--no-overlay` opts out. Not yet validated on the phone. See
[debug overlay](docs/t3-native-migration.md#2026-10-06-in-app-debug-overlay-030-24).

**2026-10-06: diffs, version 0.3.0 (21).** Each finished turn that changed
files shows a small pill ("8 files +81 −30") from T3's checkpoint; tapping it
opens that turn's diff (`orchestration.getTurnDiff`) in a fast native viewer.
Jump-to-latest sits at the right of the chip row and glides down. The back
swipe keeps the travelling device clear of the conversation. The send drop
carries no text, and message bubbles are solid again. See
[diffs](docs/t3-native-migration.md#2026-10-06-diffs-and-a-clean-back-swipe-030-21).

**2026-10-06: glass and flow, version 0.3.0 (20).** The conversation runs
full height with the docked device floating as a PiP. The live state is a
glass loupe: a handwritten Metal lens bends each finished task out through the
glass edge as the next rises in. Your message pinches off the field as liquid
glass into a glass bubble. Model and approval pickers sit above the field;
builds the agent mentions appear inline with Install; an expanded turn's
summary pins while you read inside it. Back is a left-edge swipe. See
[glass and flow](docs/t3-native-migration.md#2026-10-06-glass-and-flow-030-20).

**2026-10-05: thread redesign, version 0.3.0 (19).** No title bar: the
conversation starts under a floating back button and the docked device. Agent
work reads as sentences (a command's own description, "Edited Theme.swift
+12 −3") on a shimmering rail, the running step is a live glass pill, and a
finished turn folds into a "Worked for…" pill. Screenshots the agent takes and
clips it records appear inline; diffs and output are one tap away. Handwritten
Metal draws a flowing spectrum around the live pill and message field.
Sending lifts your words into their bubble; a glass button jumps to the latest
message; agent questions are an inline card. When the agent opens a simulator
through T3 the device rises and goes live by itself. Signed build 19 is ready,
not installed. See [thread redesign](docs/t3-native-migration.md#2026-10-05-thread-redesign-030-19).

**2026-10-05: in-app install and New Thread layout, version 0.3.0 (18).**
Install in Builds now opens the build's `itms-services` link directly, so iOS's
own install prompt appears over Squircle; Safari and the Mac's install page are
no longer in the path. iOS still requires that one system confirmation. New
Thread opens with the device at half size showing the app, and the prompt and
wrapping model chips sit directly above the composer. Ten native tests and the
two draft UI tests passed; signed build 18 is ready, not installed on the phone.
See [build 18 evidence](docs/t3-native-migration.md#2026-10-05-in-app-install-and-new-thread-layout-030-18).

**2026-10-05: draft and model picker fixes, version 0.3.0 (17).** New Thread
opens a local empty draft after visiting another conversation; T3 creation happens
only on the first nonempty submission. Model shortcuts remember your preference,
and existing threads offer only models from their established provider. Ten
native tests and two UI regressions passed; the rendered draft capture is published
in the Mac app catalog. Signed build 17 is ready, not installed on the phone.
See [draft evidence](docs/t3-native-migration.md#2026-10-05-draft-and-model-picker-fixes-030-17).

**2026-10-05: approval controls, version 0.3.0 (16).** New threads default to
Auto. The agent menu exposes all four T3 approval modes; provider-supplied
approval choices and warnings are displayed inline. Native tests, menu interaction,
and real Codex/Claude Auto turns passed. Signed build 16 was installed and opened
on the paired iPhone at the user's request. See [approval evidence](docs/t3-native-migration.md#2026-10-05-approval-controls-030-16).

**2026-10-05: ground-up interface redesign, version 0.3.0 (15).** The T3
transport, build service and credentials are unchanged from build 14.

- **Home:** a carousel of large 3D devices showing each app's real screenshot,
  lit by that screenshot's own color. The app's threads start beneath its name;
  scrolling them up shrinks the device, tapping the device toggles it back.
  New Thread and Builds stay at the bottom. Threads show live Working / Needs
  you state from T3.
- **Thread:** slides in while the same device travels to it. A divider moves
  the device among docked (beside the title), half and full; it always fills
  the space above the conversation. Swipe right anywhere to go back.
- **Simulator:** the thread's live H.264 picture is drawn on the 3D device
  itself and touches on its display go to the simulator. No separate panel.
- **Conversation:** Markdown answers, the agent's thoughts, tool calls merged
  into one line each and grouped, inline approvals, a growing glass composer,
  agent/model menu under the title. A new thread is created by its first message.

Verified in the simulator for this source: 22 deterministic tests, and real
gesture UI tests for carousel, list pull, device tap, divider drags, cancelled
and completed back swipes and rapid interruptions. Live simulator video on the
3D device and its touch mapping were checked there too. **Not yet checked on
the physical phone:** feel and frame rate, tilt parallax (needs a gyroscope),
hardware BGRA decode, and touch on the live device. See
[the redesign record](docs/t3-native-migration.md#2026-10-05-redesign-030-15).

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
an agent's simulator. Claude subscription login and a real T3 reply are verified in build 14’s source.
Complete physical-phone/crash recovery checks remain outstanding.

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

**Build 14 provider correction:** local provider choices survive live events,
reconnects and thread navigation until T3 acknowledges the choice. The targeted
regression and live Claude tool/reply tests passed; signed build 14 was installed
on the paired iPhone. Manual launch of build 14 remains pending.
