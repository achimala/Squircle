# Product decisions

Status: accepted direction from the conversation, recorded 2026-10-04. Implementation choices remain provisional where marked.

## Intended experience

The user talks to one persistent agent through a beautiful native iPhone app. That agent knows the user and ongoing projects, delegates coding work, builds on the Mac, presents an installable build, and investigates feedback from the phone. Projects and worker conversations should be discoverable without requiring the user to coordinate every CLI manually.

The Mac is both the agent host and the Xcode build environment. Remote use must work on cellular, not just another Wi-Fi network.

## Accepted decisions

| Area | Decision |
| --- | --- |
| Coordinator | Use off-the-shelf Hermes as the primary runtime, independently installed and maintained. |
| Product shape | An agent-neutral iOS development CLI plus a native SwiftUI client. Hermes integration is a thin, optional adapter. Avoid owning a second orchestration backend. |
| Name and implementation | Squircle for the CLI and future client. Rust is preferred for tooling; SwiftUI for iOS. |
| Portability | The same development tools should be usable by OpenClaw, Hermes, and other agents with appropriate access to the Mac. |
| Persistent identity | Let Hermes own persona, memory, conversations, and coordination. Start with native memory. |
| Coding workers | Reuse the user's Codex and Claude CLIs. No custom worker abstraction is planned initially. |
| Connectivity | User-managed Tailscale is acceptable. Do not bundle it. |
| Device feedback | Installing builds, opening them manually, and returning live app logs/crashes are sufficient. |
| Maintenance | Prefer maintained components, native Mac execution, and minimal services/setup. |
| Interface | Our own polished iOS app is a core goal; existing interfaces may help validate the workflow first. |

## Scope boundaries

Initial work does not require making Xcode believe a cellular phone is locally connected, interactive LLDB, remote launch, a VPN implementation, an OpenClaw deployment, or a separate memory service. Build on the Mac and distribute a correctly signed installable package.

The CLI-first decision refines the earlier Hermes-plugin proposal: keep domain logic independent of the chosen agent. OpenClaw compatibility does not change Hermes as the user's first coordinator. Full OpenClaw chat support in the native client is a separate scope decision.

Avoid requiring Firebase or another hosted distribution account when the Mac can serve the artifacts. The proposed install route still needs device testing and Apple's signing prerequisites.

## Still open

- Cellular HTTPS delivery and real-device diagnostic recovery. The user confirmed signing/device readiness and selected Dreamslate Inc. (`2F26US4NAU`); signed export now passes. See [evidence](validation.md).
- Whether the selected diagnostics components pass the complete real-device proof.
- How much independent worker-session control the client needs; this determines whether Paseo adds value.
- Notification delivery while the iOS client is suspended, onboarding polish, and future support for other users/multiple hosts.

The user is setting up Hermes and authorized implementing this prototype, initializing Git, and making small commits. That does not authorize unrelated setup changes or configuring Tailscale. See [the implementation plan](plan.md) for the remaining work.
