# Product decisions

Status: accepted direction from the conversation, recorded 2026-10-04. Implementation choices remain provisional where marked.

## Intended experience

The user talks to one persistent agent through a beautiful native iPhone app. That agent knows the user and ongoing projects, delegates coding work, builds on the Mac, presents an installable build, and investigates feedback from the phone. The home screen centers on apps/projects, leading into their threads and installable builds.

The Mac is both the agent host and the Xcode build environment. Remote use must work on cellular, not just another Wi-Fi network.

## Accepted decisions

| Area | Decision |
| --- | --- |
| Coordinator | Use off-the-shelf Hermes as the primary runtime, independently installed and maintained. |
| Product shape | An agent-neutral iOS development CLI plus a native client using stock Hermes APIs. Avoid owning a second orchestration backend. |
| Name and implementation | Squircle for the CLI and client. Rust tooling; UIKit and Core Animation for the iOS presentation, superseding the initial SwiftUI UI. |
| Portability | The same development tools should be usable by OpenClaw, Hermes, and other agents with appropriate access to the Mac. |
| Persistent identity | Let Hermes own persona, memory, conversations, and coordination. Start with native memory. |
| Coding workers | Reuse the user's Codex and Claude CLIs. No custom worker abstraction is planned initially. |
| Connectivity | User-managed Tailscale is acceptable. Do not bundle it. |
| Device feedback | Installing builds, opening them manually, and returning live app logs/crashes are sufficient. |
| Maintenance | Prefer maintained components, native Mac execution, and minimal services/setup. |
| Interface | Horizontal 3D app picker → flat thread list, with builds in a secondary sheet. App names and actual thread content only: no explanatory summaries, capture captions, build banners or redundant headings. Reserve glass for controls; no cards. Spatial, interruptible transitions and interactive back gestures replace screen crossfades. Verify motion frame by frame. |
| App identity and previews | Persist names, summaries, project/scheme identity and latest screenshots on the Mac. Agents can update metadata and publish real simulator captures independently of a build. Display those pixels on a live 3D mesh; no generated logo, monogram or other pretend app screen. |
| Setup for the personal build | Bundle the existing Mac connection settings into the signed client. No manual token entry or pairing flow. Hermes remains stock and enforces its normal API authentication internally. |

## Scope boundaries

Initial work does not require making Xcode believe a cellular phone is locally connected, interactive LLDB, remote launch, a VPN implementation, an OpenClaw deployment, or a separate memory service. Build on the Mac and distribute a correctly signed installable package.

The CLI-first decision refines the earlier Hermes-plugin proposal: keep domain logic independent of the chosen agent. OpenClaw compatibility does not change Hermes as the user's first coordinator. Full OpenClaw chat support in the native client is a separate scope decision.

The Mac-hosted install route has worked on the user's phone. Firebase is unnecessary for this flow; other apps still need Apple's signing prerequisites.

The user stopped the image-judge iteration workflow and requested a working preview. Functional verification now centers on real screenshot capture/publication, metadata persistence and a continuous live 3D transition. A missing screenshot leaves the modeled display blank. The subsequent version 4 redesign also removes visible preview-status copy; metadata stays available to agents.

## Still open

- Version 4's 29 unit tests, navigation checks, archive/export, real preview publication and physical installation/launch pass. Simulator transition frames were inspected; physical-device frame-rate profiling remains unmeasured. See [evidence](validation.md).
- Real-phone offline diagnostic recovery and actual phone crash upload/symbolication; the simulator crash path is verified.
- How much independent worker-session control the client needs; this determines whether Paseo adds value.
- Notification delivery while the iOS client is suspended, onboarding polish, and future support for other users/multiple hosts.

Hermes is installed and its API is running. The user explicitly authorized this Mac's Tailscale/HTTPS setup, app implementation and small commits; Tailscale remains an external dependency. See [the implementation plan](plan.md) for the remaining work.
