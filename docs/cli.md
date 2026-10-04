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
| `app browse --path PATH` | Browse one Mac directory; omit the path to start at the service user's home |
| `app inspect --project PATH --scheme SCHEME` | Discover schemes and inspect iOS application/signing settings without building |
| `app import --project PATH --scheme SCHEME --name NAME` | Persist app identity and its archive recipe without starting a build |
| `app list`, `app show ID`, `app register` | Persistent app catalog; `register` adds metadata only, without a build recipe |
| `app update ID --name NAME --summary TEXT` | Edit app metadata without replacing its identity or preview |
| `app preview ID --file PATH` | Publish a real PNG as the app's latest immutable preview artifact |
| `preview capture BUILD_ID --simulator UUID` | Build-associated capture on an explicitly selected simulator |
| `install-link ID --ttl-seconds 3600` | Expiring HTML page, manifest and IPA URLs |
| `logs ID --since N --limit N` | Persisted diagnostic events, record cursor |
| `crashes ID --since N --limit N` | Crash events only, same record cursor |
| `symbolicate --report PATH --dsym PATH` | Local Xcode symbolication attempt for Apple-text reports |
| `diagnostics send --file PATH` | Upload one diagnostic JSON fixture |

`install-link` does not install or remotely launch an app. A `launch_observed`
flag reflects an authenticated diagnostic event, not independent OS attestation.
The service does not currently track installation/download completion.

## Import an existing app

The native **+ → Mac browser or pasted path → scheme/name → Add** flow uses the
same service operations available to any agent:

```sh
squircle app browse --path ~/Projects --json
squircle app inspect --project /path/Atlas.xcworkspace --json
squircle app import --project /path/Atlas.xcworkspace --scheme Atlas --name Atlas --json
```

Inspection accepts optional `--scheme` and `--configuration`; import defaults to
`Release` and also accepts `--configuration`. Paths refer to the service's Mac.
The authenticated APIs are `GET /v1/projects?path=…`,
`GET /v1/projects/inspect?project=…&scheme=…&configuration=…` and
`POST /v1/apps/import` with `project`, `scheme`, `name` and optional
`configuration`. Responses use the ordinary `ok`/`data` envelope.

Import inspects the project and persists a `build_request` in its app record.
The client prefers that recipe over historical jobs, enabling the first build
without an earlier CLI build. Reimporting the same canonical project/scheme
keeps its app identity. Import does not start Xcode compilation or publish a
preview. A missing signing team can return `can_import: true` with an `issue`
warning; unsupported/non-iOS schemes cannot be imported. Device signing is
proven only by an actual successful build with Xcode configured.

Real CLI/API inspection and native import, browsing and relaunch checks pass.
Saved archive recipes allow Xcode provisioning updates when a later build is
requested; import itself does not change signing or register a device.
Existing `app register` remains a metadata-only operation.

## App metadata and previews

The Mac catalog is the source of truth for app names, summaries and screenshots.
Discover an app with `app list`. Use `app import` to save a build recipe, or
`app register --project PATH --scheme SCHEME --name NAME` for metadata alone.
Re-registration is idempotent and preserves edited text. Use
`app update ID --summary TEXT` after meaningful changes; `--name` is optional.

After UI work, capture the running app's actual simulator screen, inspect it,
then publish `app preview ID --file PATH --caption TEXT`. This publication needs
no new build. The ID is the persistent **app ID**, not a build or preview ID.
Optional `--build BUILD_ID` and `--source-revision REV` provenance must describe
the supplied pixels accurately. A source label is recorded provenance, not independent proof
of what the screenshot contains. Read each command's `--help` for current flags.

Each publication validates a regular PNG file (signature, bounded chunks and
nonzero dimensions; maximum 20 MiB), makes a private copy and assigns a new preview
UUID. Existing image files are immutable. The app record points to the latest
preview and retains timestamp, caption and optional build/revision association.
`captured_at` is simulator capture-completion time for built-in captures; for
agent-supplied files it is server publication time, not an inferred file-creation
time. `updated_at` records app metadata changes. Published files use source
`agent`; built-in captures use `simulator`. Supplying a build ID checks the app
association but does not establish that the pixels came from that exact binary.
The client fetches the image through authenticated HTTP. It displays an empty or
unavailable state when there is no capture; it must not substitute generated UI.

Build capture is optional (`build start --preview`), runs in the same worker lane
as Xcode, and requires a dedicated simulator configured by UUID. Capture failure
preserves the IPA and any previous image. Simulator builds reuse their product;
archive previews rebuild the current working tree, so they must not claim to be
pixels from a frozen archived revision. App synchronization accepts only newer
captures and does not overwrite edited names/summaries. End-to-end validation of
the new catalog/client flow is tracked in [validation evidence](validation.md).

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
used by the phone. Actual stock Hermes CLI and API runs have invoked Squircle
successfully; OpenClaw invocation remains pending. No agent installation is
required to use Squircle directly. See [validation](validation.md).
