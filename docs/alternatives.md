# Alternatives and why they are deferred

Research snapshot: **2026-10-04**. These are architectural judgments from primary documentation and source, not performance benchmarks or validation of an end-to-end Mac/iPhone setup.

## Accepted direction

Use **stock Hermes, an agent-neutral iOS development CLI, and our own native client**. UIKit/Core Animation supersedes the first SwiftUI presentation. Hermes supplies identity, native memory, sessions and orchestration. The user refined the earlier plugin-first design to make the development tooling reusable by other agents. Hermes plugins are optional adapters. [CLI design](cli.md), [Hermes client API](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server).

## Other agent hosts

- **OpenClaw:** not the user's first coordinator because of perceived weight; this was not a measured comparison. The user subsequently requested compatibility, so the development CLI must remain usable from OpenClaw. This does not require switching the initial coordinator. Rust is not a requirement. [OpenClaw shell tools](https://docs.openclaw.ai/tools/exec).
- **Paseo:** a credible optional worker layer if we need structured provider sessions, approval handling or detailed coding-agent timelines. Start with Hermes's existing coding-agent integrations; add Paseo only if a smoke test reveals a concrete gap. Another daemon is not justified merely because it exists. [Paseo SDK](https://paseo.sh/docs/sdk).
- **T3 Code:** relevant as a coding interface and increasingly as an orchestrator. Earlier research found substantial orchestration work in its V2 nightly, with a different stable-release surface. Our T3/Paseo comparison was preliminary; it does not establish a lasting capability or maintenance winner. Neither is required beneath the selected Hermes architecture. [T3 releases](https://github.com/pingdotgg/t3code/releases).

## Additional memory systems

Start with Hermes's identity files, curated memory, searchable session history and learned skills. Evaluate retrieval and continuity on real projects before adding infrastructure. [Native memory](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory).

**Basic Memory, Mem0, Hindsight, Letta and Honcho are deferred, not rejected.** They address different needs. Basic Memory was a legitimate candidate for inspectable, provider-neutral Markdown knowledge; it was not demonstrated to be the best memory system. Letta also changes the agent-harness choice, rather than simply adding storage. Revisit a provider when a specific requirement—such as semantic recall, automatic extraction or shared memory—outgrows the native approach. [Hermes memory providers](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory-providers).

## Distribution and diagnostics

**Firebase is unnecessary** for the verified Mac-hosted artifact flow over user-managed Tailscale. Other apps still need valid signing and provisioning; transferring an IPA into our app does not itself install it.

**TestFlight remains an alternative** when its distribution convenience outweighs App Store Connect setup and processing delay. Direct remote device debugging is a separate capability from distributing a build.

Probe uses PLCrashReporter and a bounded upload queue; the simulator crash path is verified. [Pulse](https://github.com/kean/Pulse), [SwiftLoggerServer](https://github.com/krugazor/SwiftLoggerServer) and [GlitchTip](https://glitchtip.com/documentation/install/) remain optional alternatives for broader inspection or diagnostics. None is an additional dependency. Remaining phone checks are in [the remote workflow](remote-ios.md).
