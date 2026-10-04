# Agent friendly CLI

Status: accepted CLI-first direction; the interface below is a proposal, not implemented commands. `iosdev` is a placeholder name. Language and packaging are undecided; Rust is optional.

## Purpose and boundary

Provide the same build, distribution, and diagnostics operations to Hermes, OpenClaw, coding agents, CI, and a human terminal. Callers need execution access to the Mac and the relevant permissions. The CLI supplies deterministic operations; the coordinator supplies planning, identity, and memory.

Reuse existing tools underneath. Begin by proving the real-device workflow, then package it. Do not build a generic agent framework or a new Xcode wrapper for its own sake.

## Progressive discovery

1. `iosdev --help`: concise purpose, command groups, and the next help command.
2. `iosdev build --help`: prerequisites, arguments, side effects, concrete examples, and how to inspect the result.
3. `iosdev help workflow`: one build → install → diagnostics example with links to deeper help.
4. `iosdev capabilities --json`: versioned supported operations and output-contract version. `doctor --json` checks configured prerequisites without changing them.

A small optional skill should point at this live help and describe when to use the tool. Do not duplicate the entire command reference in every agent's context. A full schema-discovery framework and MCP wrapper can wait for demonstrated demand.

## Proposed command shape

```sh
iosdev doctor --json
iosdev build start --project APP --request-id REQUEST_ID --json
iosdev build status BUILD_ID --json
iosdev build wait BUILD_ID --timeout 60 --json
iosdev build cancel BUILD_ID --json
iosdev install-link BUILD_ID --json
iosdev logs BUILD_ID --since CURSOR --json
iosdev crashes BUILD_ID --json
```

`install-link` prepares a link; it does not silently install or remotely launch an app. Keep “requested”, “downloaded” where observable, and “app launched and acknowledged build” distinct.

## Output and execution contract

- Human-readable defaults; explicit `--json` emits one structured result on stdout. Send progress to stderr. Reserve a separate documented JSONL/event mode for streaming.
- Stable IDs, documented exit codes, bounded output, cursors for logs, and artifact references instead of dumping entire build logs into context.
- Structured errors with a code, explanation, retryability, and suggested next step. Machine mode must not hang on hidden prompts; report required user action.
- `start` returns a durable job ID; successful submission is distinct from successful build completion. `wait` has a timeout, and `cancel` targets the specific job.
- Deduplicate submission retries using request IDs; retain records across agent sessions. Record source revision/dirty state, build identity, artifacts and symbol association.

An available HTTP service remains necessary for installation assets and incoming diagnostics. Async jobs need a supervisor independent of a transient agent shell. The same package can provide that service; startup/restart behavior must be explicit and tested. Offline crash/log buffering still belongs in the app instrumentation.

## Compatibility acceptance

Run the core commands directly without Hermes installed. Verify Hermes can discover and operate them, then verify the same workflow from OpenClaw when that environment is available. No OpenClaw installation is required merely to design the interface. Test JSON parsing, failure reporting, retries, cancellation, and disconnected-client behavior using the same core implementation.
