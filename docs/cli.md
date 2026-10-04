# Agent-friendly CLI

Status: implemented Rust prototype, 2026-10-04. Executable name: `squircle`.
See [workflow](verification.md) for runnable examples and [evidence](validation.md)
for the distinction between implemented and physically verified behavior.

## Boundary and discovery

The same deterministic build/install/diagnostic operations serve Hermes, OpenClaw,
coding agents, CI, and a human terminal. Callers need access to this Mac and its
signing environment. The coordinator supplies planning, identity, and memory.

1. `squircle --help`: purpose, command groups, next help command.
2. `squircle build start --help`: arguments and side effects.
3. `squircle help workflow`: build → installation → diagnostics walkthrough.
4. `squircle capabilities --json`: implemented operations and limits.
5. `squircle doctor --json`: read-only Xcode and signing inventory.

A future short skill can point agents at this live help. MCP and coordinator
plugins are optional adapters; neither belongs in the core dependency graph.

## Implemented commands

| Command | Result |
| --- | --- |
| `init`, `serve` | Private state/credentials; foreground HTTP service |
| `auth show --scope diagnostics` | Explicitly reveal the phone upload credential |
| `build start` | Durable job ID; archive/export or unsigned simulator mode |
| `build list`, `build status ID` | Persisted job records and launch acknowledgement |
| `build wait ID --timeout 60` | Completion or bounded timeout; no implicit cancellation |
| `build cancel ID` | Cancel that queued/running job |
| `build log ID --offset N --limit N` | Bounded compiler log, byte cursor |
| `build import --ipa PATH` | Private copy of an existing IPA; no signature certification |
| `install-link ID --ttl-seconds 3600` | Expiring HTML page, manifest and IPA URLs |
| `logs ID --since N --limit N` | Persisted diagnostic events, record cursor |
| `crashes ID --since N --limit N` | Crash events only, same record cursor |
| `symbolicate --report PATH --dsym PATH` | Local Xcode symbolication attempt for Apple-text reports |
| `diagnostics send --file PATH` | Upload one diagnostic JSON fixture |

`install-link` does not install or remotely launch an app. A `launch_observed`
flag reflects an authenticated diagnostic event, not independent OS attestation.
The service does not currently track installation/download completion.

## Output and persistence contract

- `--json` emits one versioned result on stdout: `schema_version: 1`, `ok`, and
  `data` or `error`. Default output is pretty JSON. Help is human-readable text.
- Exit 0 means command success; exit 2 means invalid input, failed operation, or
  unsuccessful/timed-out wait. Successful submission is not build completion.
- Errors contain `code`, `message`, `retryable`, and `next_step`. Build logs live
  in files rather than expanding tool-result context.
- Stable request IDs deduplicate identical build submissions; changed arguments
  with an existing ID are rejected. Records and artifacts survive agent sessions.
- Git revision/dirty state are best-effort submission-time observations. The
  working tree is not snapshotted; queued builds may see later edits.
- Jobs retain app identity, archive/IPA/app paths and associated dSYMs. The service
  reports unfinished jobs as interrupted after restart; it does not resume Xcode.
- Log/diagnostic reads are bounded and paginated. `build list` currently returns
  all records. There is no streaming CLI mode, retention deletion or log rotation.

`SQUIRCLE_DATA_DIR`/`--data-dir` select the private store. `SQUIRCLE_SERVER`/
`--server` select the API address. Credentials come from the local store; they are
not placed in command-line arguments. Control requests use a different token from
phone uploads. The service defaults to loopback and requires user-provided HTTPS
for phone access. See [lifecycle limits](verification.md#limits-and-lifecycle).

## Compatibility acceptance

Automated CLI tests run with an empty `PATH`, without an agent executable or
running service for discovery. HTTP tests exercise the same core implementation
used by the phone. Actual invocation from Hermes and OpenClaw remains pending;
no installation of either is required to use Squircle directly.
