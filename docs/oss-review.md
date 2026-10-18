# Squircle open-source readiness review

Reviewed 2026-10-18 on `oss-review`, source commit `9c63bec7baf55f1e92a78fc3dcd39b738a7729ab`.

## Summary

**Not ready to open source yet.** The core architecture is sound, and 209 Rust tests plus unsigned app/overlay Release builds pass. Before publishing: add licensing, sanitize personal data and history, document portable setup/signing, fix remote-HTTP credential handling and the history guard, and establish CI. Dead code is limited; the larger maintenance costs are oversized modules, repeated plumbing, and stale docs. Only this review was changed.

This is a **publish-after-targeted-cleanup** verdict, not a recommendation to rewrite the product. T3 ownership, the agent-neutral CLI, UIKit layout, the Clay design, still device portraits, shared conversations, simulator leases, team-shared overlay credentials, and single-owner Rust state are intentional decisions to preserve.

## Scope, method, and verification

Read `AGENTS.md` and `README.md` first. Inventoried all 184 tracked files: 47 Rust files, 71 Swift files, the C overlay loader, project/build configuration, plugin templates, scripts, examples, and documentation. The Rust/Swift/C files total 53,731 lines, including tests. Reviewed subsystem boundaries and representative execution paths, searched the complete tracked tree for references/configuration/secrets, traced superseded implementations through Git, and ran the checks below. This is not a claim that every branch or runtime combination was exercised.

The worktree started clean. Native builds used a temporary archive of the reviewed commit, so other workers' overlay edits were neither modified nor incorporated. No live T3 connection, provider invocation, real simulator session, APNs delivery, signed build, installation, or UI inspection was performed. Temporary build products and isolated probes were removed after recording their results here.

| Check | Result and boundary |
| --- | --- |
| README's `./scripts/cargo-local --version` in this worktree | **Failed:** `cargo: not found`. The wrapper checks this checkout's ignored `.tools` and then PATH. An existing toolchain in the main checkout was usable when explicitly selected; nothing was installed. |
| Rust `cargo test --locked --offline` | **209 passed:** 185 library, 6 CLI, 14 HTTP contract, 1 ownership, 3 service lifecycle. The test groups took about 7.4 seconds combined after compilation. |
| Initial sandboxed Rust run | 180 library tests passed and 5 failed. Loopback socket binding/process inspection were restricted. The complete rerun with those restrictions lifted passed; these are not reported as product defects. Tests used temporary stores, fake hosts, and local helper processes. |
| Rust Clippy, `--locked --offline --all-targets` | **Passed with warnings**, including complexity, collapsible branches, and items after a test module. This was not `-D warnings`. |
| Rustfmt, `fmt --all -- --check` | **Failed:** formatting differences in 40 files. No formatting changes made. |
| `scripts/check-swift-concurrency` | **Passed**, with the coverage limitations in Q1 below. |
| XcodeGen regeneration | **Passed:** generated `project.pbxproj` exactly matched the tracked one. Generated into the temporary snapshot, not the worktree. |
| Squircle, Release, generic iOS, unsigned | **Build succeeded**, with private configuration disabled. No launch or signing proof. |
| SquircleOverlay, Release, generic iOS, unsigned | **Build succeeded** using its scheme and an explicit temporary DerivedData directory. Earlier target-only attempts failed on sandbox access to Xcode's default cache; no source compile error was established by those failures. |
| Native warnings | Shared client captures mutable `data` in a concurrently executing closure (`app/Squircle/Sources/SquircleClient.swift:397-403`); compiler says this becomes an error in Swift 6 language mode. Also deprecated trait callbacks and an unused binding. This is a compiler finding, not proof of an observed race. |
| Local Markdown file links | No missing local file destinations found by a simple link scan; anchors and external links were not validated. |
| Offline guard probe | **Failed the claimed read-only restriction:** accepted a history tool command whose Git external helper wrote a marker in a temporary directory. Details in P3b. |
| Credentials/history | Pattern scan of tracked text and 1,707 unique blobs, about 60 MB, reachable from available refs at scan time. No confirmed live secret found. Limitations and personal-data findings in P2. |

Tool versions: Rust/Cargo **1.99.0**, Xcode **27.1 (27A9269)**, XcodeGen **2.45.4**. The project selects Swift **5.0 language mode** (`app/Squircle/project.yml:9`), not Swift 6 language mode. These are the versions used, not a demonstrated minimum support matrix.

Native build commands, with `SNAPSHOT` and `SCRATCH` denoting temporary directories:

```sh
xcodegen generate --spec "$SNAPSHOT/app/Squircle/project.yml"
xcodebuild -project "$SNAPSHOT/app/Squircle/Squircle.xcodeproj" \
  -scheme Squircle -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$SCRATCH/DerivedData" CODE_SIGNING_ALLOWED=NO \
  SQUIRCLE_CLIENT_CONFIG=/dev/null build
xcodebuild -project "$SNAPSHOT/app/Squircle/Squircle.xcodeproj" \
  -scheme SquircleOverlay -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$SCRATCH/DerivedData" CODE_SIGNING_ALLOWED=NO build
```

Not run: native XCTest, Widgets build, Probe build/tests, release-mode Rust compilation, fresh-machine installation, dependency vulnerability/license audit, graphical asset inspection, or end-to-end compatibility with the running T3. Existing historical evidence is not substituted for those checks.

## Scorecard

Scores are a qualitative contributor-readiness assessment: 1 = poor, 5 = strong. They are not a security certification or an average that overrides a publishing blocker.

| Area | Score | Assessment |
| --- | --- | --- |
| Architecture clarity | 3/5 | Strong ownership decisions and increasingly explicit reducers; discovery is hindered by large adapters and history-heavy documentation. |
| Dead code | 4/5 | The large Hermes implementation was actually removed. Confirmed leftovers are small; no abandoned alternative app backend found. |
| Duplication | 3/5 | Conversations and shader foundations already shared; HTTP wrappers, caches, subprocess wrappers, and CLI metadata still repeat. |
| Consistency | 2/5 | Formatting gate fails, lint warnings remain, and advertised guard coverage is incomplete. |
| Docs/onboarding | 1/5 | Knowledgeable maintainer notes, but no complete independent contributor path, CONTRIBUTING, or SECURITY document. |
| Tests | 4/5 | Fast, meaningful Rust tests for persistence, protocol, permissions, and lifecycle. Native suite exists but was not executed here; no CI evidence. |
| Build/setup reproducibility | 2/5 | Current sources compile and project generation is deterministic here. Toolchain discovery, signing identity, bootstrap, and binary resource location depend on local setup. |
| Security/privacy/release hygiene | 2/5 | Useful authentication, private storage, and origin controls; two concrete trust-boundary gaps, personal material in history, and credential-bearing personal build packaging. |

## Publishing gates

“Before publishing” below means before presenting this as a reusable, supported open-source project. Large structural refactors are not prerequisites. Binary distribution has additional requirements explicitly distinguished below.

### P1 — No license or published ownership/attribution policy

**Must fix.** `git ls-files` contains no LICENSE/COPYING, NOTICE, CONTRIBUTING, SECURITY, or CI workflow. `Cargo.toml:1-5` has no license/license-file, repository, homepage, or Rust minimum-version metadata. These are verified absences, so there is no nonexistent file to cite.

Choose and include the intended license, identify the copyright holder, and record the provenance of bundled artwork and any copied code. Inventory dependency licenses and any required notices before distributing artifacts; that compatibility review was not performed here. The Probe explicitly uses PLCrashReporter (`examples/SquircleProbe/project.yml:6-9`), and Rust has a committed dependency lockfile. This is a release ownership gap, not a finding that a particular dependency violates a license.

Add concise contribution and vulnerability-reporting instructions. A code of conduct, issue templates, and a governance document are useful follow-ups; they need not delay a small initial release once responsibility and reporting are clear.

### P2 — Decide and sanitize the publication set, including history and binaries

**Must fix the publication process; no confirmed credential leak was found.** Do not confuse a clean HEAD or ignored data folder with approval to publish every historical object or locally built IPA.

| Material | Evidence | Classification and action |
| --- | --- | --- |
| Personal absolute paths | `AGENTS.md:20`, `docs/coding-visibility.md:46-48`, `docs/direct-agents-plan.md:57`, `docs/validation.md:460` | Real maintainer-machine information. Generalize public instructions while keeping the local executable choice in private setup. Do not change the user's actual tools or services. |
| Personal account/session history | `docs/coding-visibility.md:62-78` | Includes an account/subscription investigation, session identity, local backup location, and reported cost. Not a credential, but not necessary contributor documentation. Remove or deliberately approve a sanitized historical record. |
| Signing team | `app/Squircle/project.yml:8`, `app/Squircle/ExportOptions.plist:6`, `examples/SquircleProbe/project.yml:12`, `examples/SquircleProbe/ExportOptions.plist:6` | Identifies the maintainer's Apple team and breaks independent signing. A team ID is not a signing secret. Replace hardcoded ownership with local configuration; address generated project copies too. |
| Bundle/keychain namespace | `app/Squircle/project.yml:32`, `app/Squircle/Resources/Squircle.entitlements:7-8`, `app/Squircle/Sources/AppConfiguration.swift:37-51`, `src/overlay.rs:24-26`, `app/Squircle/Overlay/OverlayHost.swift:10` | Public identifiers, not tokens. They are nevertheless a cross-language configuration contract; a contributor cannot safely change just the app bundle ID. See P4. |
| Credentials in native artifacts | `app/Squircle/project.yml:48-59`, `app/Squircle/Sources/AppConfiguration.swift:24-30` | The build copies the entire private connection JSON into `client.json` whenever present, without a Release/public-artifact distinction. Keychain storage does not remove that bundle copy. Preserve personal builds, but make credential embedding explicit and prevent publication of such artifacts. |
| Ignored private state | `.gitignore:1-5`, `README.md:204-209` | Good existing controls for `.squircle`, local tools and verification output. They do not protect arbitrary credential filenames elsewhere or old commits. Add targeted secret detection and release-archive checks. |
| Secret-shaped scan hits | `src/push.rs:1335-1342`, `src/push.rs:1361`; historical configuration models and README examples | The PEM hits generate a fresh throwaway test key or use invalid `AAAA`; other candidates were placeholders or JSON coding-key names. Do not label these as leaked APNs keys. |
| Private-looking hostnames | `src/artifact.rs:83`, `app/Squircle/Tests/T3Tests.swift:420-427`, `examples/SquircleProbe/Sources/DiagnosticsTransport.swift:18` | The observed `.ts.net` hits are synthetic example/test names. No actual private tailnet hostname confirmed by the scan. Prefer reserved example names in public examples to make this obvious. |

History checks covered `HEAD`'s 389 commits and available reachable refs, including T3 checkpoint refs. `git log -S` and historical blobs show personal paths in deleted UI tests and earlier client code as well as today's docs. Git metadata also contains two distinct author/committer email values; values are deliberately not reproduced here. Attribution may be intentional—decide what to expose rather than silently rewriting it.

No tracked `.p8`, `.p12`, `.pem`, `.mobileprovision`, `.ipa`, SQLite database, or private connection JSON was found in the filename inventory of scanned reachable history. The scan searched common provider-token, JWT, PEM, long literal secret-assignment, personal-path, and hostname patterns. It was not an entropy scanner, binary forensic review, or validation against providers. Dedicated secret-scanner tools were unavailable. Reflogs, unreachable objects, remote-only refs, release attachments, hosted CI artifacts, and Git LFS storage were not covered. Other workers can add refs after the scan.

Before changing repository visibility, inspect the exact refs/archive to publish with a dedicated scanner and a human privacy review. Choose sanitized history or a clean public export in a separate release operation. Do not mirror the development repository's refs indiscriminately. Rotate credentials if that release audit finds an actual secret; there is no evidence here justifying a claim that a particular key is compromised. Nothing in this review rewrites history or revokes credentials.

### P3 — Fix two credential/read-only contract gaps

#### P3a — Non-loopback HTTP accepts sensitive credentials

**High priority, source-proven.** `src/main.rs:783-801` accepts either `http` or `https` for any host and then attaches the control/diagnostic bearer. `local_server` already recognizes loopback (`src/main.rs:693-701`) but this request path does not apply it. `src/t3.rs:50-68` similarly accepts a non-loopback HTTP origin and sends the one-time pairing token to it.

A contributor setting `--server http://remote-mac:8787` or pairing against an HTTP LAN endpoint can send credentials without transport encryption. The default loopback URL is appropriate; the problem is accepting remote plaintext without a boundary. This is a configuration-triggered exposure, not a demonstrated unauthenticated server compromise. No credentials were sent to a remote endpoint during review.

**Fix:** one parsed origin policy for both Rust entry points: HTTPS for remote hosts; HTTP permitted only for explicit loopback hosts; reject userinfo, query, fragment and unexpected paths consistently. Keep redirects disabled. Use small offline URL-policy tests, including IPv4/IPv6 loopback and hostile origins. The native configuration already requires HTTPS (`app/Squircle/Sources/AppConfiguration.swift:92-96`). This does not entail provisioning Tailscale or changing the user's network.

#### P3b — The history “read-only” guard can execute a writing helper

**High priority, reproduced locally.** `src/guard.rs:61-65` skips leading environment assignments. Its Git allowlist permits `diff`, while filtering only selected arguments (`src/guard.rs:92-105`). The installed hook is explicitly presented as restricting the history agent to reading (`src/guard.rs:38-41`, `plugin/squircle/agents/history.md:4-7`).

Offline reproduction: submitted a synthetic history-agent Bash event to the compiled `squircle agent guard`, with this command shape:

```text
GIT_EXTERNAL_DIFF=<temporary-helper> git diff --no-index <temporary-a> <temporary-b>
```

The guard returned exit 0 with no refusal. Executing that command against two scratch files invoked a harmless helper which wrote a scratch marker. No repository configuration, T3 session, model, or user file was modified. The probe and marker were removed.

**Fix:** use a constrained history command surface backed by Squircle's own bounded read-only operations, or validate the executable, environment, Git options, and external-driver behavior together. Invoke any permitted Git reads with external diff/text conversion disabled and a controlled environment. Add a regression for this specific invisible security boundary. Retain the existing single history subagent and T3 worker ownership; a new agent backend is not needed. Until fixed, describe this hook as workflow enforcement, not an OS sandbox or a guaranteed read-only execution boundary.

### P4 — A new contributor cannot follow one independent setup path

**Must fix docs/configuration before advertising a working quick start.** `README.md:190-215` assumes an existing T3 install, existing HTTPS routes, local credentials, and an already-running build service. The app guide gives a JSON shape but says to use the ordinary pairing exchange without a complete fresh setup sequence (`app/Squircle/README.md:8-27`). The main README omits Rust from its explicit requirements (`README.md:192-202`); `scripts/cargo-local:5-11` installs nothing and uses a per-checkout ignored toolchain or PATH. The documented command failed in this otherwise equipped worktree until the existing Rust toolchain was explicitly selected.

Provide one tested guide for a separate Mac/account or clean environment:

1. Required macOS/Xcode SDK, Rust and XcodeGen versions; a supported T3 version/protocol contract; which features require an Apple account and which can compile unsigned.
2. Build the CLI; initialize a new private data directory; start the foreground service; explain loopback versus externally supplied HTTPS and `--public-url`.
3. Pair a separate service T3 session, install the Squircle plugin through `agent setup`, and create the phone's own connection configuration. Explain expiry/re-pairing and credential rotation without publishing real values.
4. Configure the contributor's signing identity, app/extension IDs and shared Keychain group consistently across Swift, entitlements, XcodeGen and the Rust injector. Keep the accepted shared-group behavior; do not replace it with fallback credentials.
5. Generate the project, compile unsigned first, then document the explicit signed install/manual-launch path. Document simulator work through Squircle leases; do not encourage unmanaged simulator booting.
6. State optional feature status: push entitlements and embedding the Widgets target are deliberately disabled pending signing setup (`app/Squircle/project.yml:25-42`). These are not dead features or a ready-by-default Live Activity distribution.

**Binary-package caveat:** the Rust overlay builder defaults to `env!("CARGO_MANIFEST_DIR")/app/Squircle/Squircle.xcodeproj` (`src/overlay.rs:41-46`) and requires that project to exist (`src/overlay.rs:258-262`). Copying the CLI binary to another Mac does not carry its overlay sources; a binary built in a disposable checkout retains that path. For a source-only release, document the source-tree dependency and `SQUIRCLE_OVERLAY_PROJECT`. Before advertising standalone binaries, package/discover those resources explicitly and test after moving the installation. No such moved-installation test was performed here.

### P5 — Establish repeatable contribution gates

**Must establish a baseline before accepting public contributions.** There is no tracked CI configuration or contributor check command. `clippy.toml` is useful and `src/lib.rs:1-3` denies its banned-type/method lints, but no public automation runs it. Rustfmt currently fails in 40 files; pick a documented formatting baseline in an isolated mechanical commit, without mixing it with behavior changes.

Use a macOS job for the actual supported platform: locked Rust tests, Clippy with an explicit warning policy, formatting check, Swift concurrency check, XcodeGen drift check, and unsigned app/overlay compilation with no credentials. Run the existing native logic suite in an appropriate controlled runner; it was not run here. Keep tests limited to contracts, parsing, persistence, lifecycle and security as required by `AGENTS.md`; do not add live T3/provider tests or tests that pin layout text/numbers.

Record tested tool versions and a supported Rust minimum or pinned contributor toolchain. Do not promise Linux support from the presence of Rust: process inspection, build/signing and simulator adapters intentionally use macOS facilities (`src/service.rs:12-18`, `src/projects.rs:15-19`). A source release does not require a packaged login service, self-service phone pairing UI, or LLDB support; those remain explicit limitations, not new requirements.

## Confirmed dead code and superseded material

Method: full-tree symbol searches include app, overlay, widgets, tests, C entry points, and project source lists; historical searches establish removed callers where available. “No callers” below means no caller in this repository at the reviewed commit, not a formal whole-program proof. Swift delegate methods, C-exported functions and app/widget entry points were excluded from simplistic one-occurrence results.

| ID | Evidence | Confirmation and proposed disposition |
| --- | --- | --- |
| D1 | `app/Squircle/Sources/ClientModels.swift:335-341`, `AgentApproval` | Only its declaration remains. `git log -S AgentApproval` and the `da3d0d0` migration show the old model usage removed with Hermes. Internal Swift value type, not a decoded/registered runtime class. Delete it. |
| D2 | `app/Squircle/Sources/UI/Theme.swift:20-48`, `glow` and `characteristicColor` | No `Theme.glow` or `characteristicColor` callers in any target. History `0c28fa4` removes the color-analysis caller during the still-portrait migration. These are leftovers from screenshot-colored studio lighting, superseded by the intentional flat/Clay design. Delete the helpers, not the still portrait renderer. |
| D3 | `app/Squircle/Sources/UI/Theme.swift:138-155`, `glassEffect` and `setGlassCorner` | Each function has only its declaration. `glassSurface` remains used and implements its own material/corner setup (`app/Squircle/Sources/UI/Theme.swift:120-135`). Remove the unused helpers; do not eliminate glass controls. |
| D4 | `app/Squircle/Sources/UI/ThreadViewController.swift:237`, `focusComposer` | Only declaration found; no selector/export annotation or caller in app/overlay/tests. Remove the obsolete controller entry point. |
| D5 | `app/Squircle/Sources/T3DeviceStream.swift:537-542`, `disconnectInputForTesting` | Only declaration remains. `a6d033c` removed its live test caller under the user's “no live or UI tests” decision. Remove the orphan DEBUG hook; do not restore those tests to justify keeping it. |
| D6 | `app/Squircle/Sources/UI/StageLayout.swift:8-9`, `titleHeight` | Set by `StudioViewController.makeLayout` (`app/Squircle/Sources/UI/StudioViewController.swift:430-432`) but never read by layout. Synthesized equality still includes it, so it is an unused input rather than an unused type. Remove field and argument together after verifying no visual change. |
| D7 | `src/fsm/coordinator/mod.rs:69-78`, `Dispatched::into_result` | No repository caller or test uses it. It collapses distinct dispatch outcomes that current durable callers preserve. Remove or narrow visibility if the crate is internal; because it is `pub`, external use is unknown and removal should follow the public-API policy. |

No whole active source file was established as removable. No stale Cargo feature flag was found: `Cargo.toml` defines no project feature table. `SQUIRCLE_OVERLAY`, DEBUG hooks, device/simulator compilation differences and upkeep thresholds have current roles; do not bulk-delete them. `debugLens` is a stale name but still invoked by the DEBUG capture flow and now configures the plain live line (`app/Squircle/Sources/UI/ThreadViewController.swift:1748-1752`); rename it when touching the tooling, rather than calling it dead.

Only two files live in `scripts/`: both remain used. `cargo-local` is referenced by the README; `check-swift-concurrency` is wired into the app build (`app/Squircle/project.yml:43-47`). `app/Squircle/Resources/generate-icon.swift:3` declares itself the manual icon source; no in-repo invocation was found. Document its regeneration procedure and ownership instead of deleting it merely because it is outside the build.

History confirms substantial cleanup already happened:

- `da3d0d0` deleted the active Hermes client/gateway/conversation adapters and delegated coding-log presentation. The remaining Hermes reference in active CLI help is stale prose (`src/main.rs:661`), not a running Hermes backend.
- `23d5876` removed much of the travelling/live 3D device path. `DeviceStage` still uses SceneKit to generate cached portraits (`app/Squircle/Sources/UI/DeviceStage.swift:38-57`, `app/Squircle/Sources/UI/DeviceStage.swift:111-128`); this is required current behavior, not dead SceneKit code.
- `8174ff2` selected one conversation appearance and removed the style flag; `f5ead7a` made Clay the sole palette. There is no evidence to justify restoring style flags or alternate routes.
- Home receding geometry is still called (`app/Squircle/Sources/UI/StudioViewController.swift:880-888`), and the overlay's C constructor calls its Swift entry point (`app/Squircle/Overlay/OverlayLoader.c:1-3`, `app/Squircle/Overlay/OverlayHost.swift:7-13`). Neither is dead despite misleading naive symbol counts.
- Probe is an explicit instrumentation example, not the retired app (`examples/SquircleProbe/README.md:3`). Its SwiftUI UI is not a violation of the native client's UIKit requirement.

The safe dead-code cleanup is small. Removing whole renderer, overlay, widget, compatibility-decoder or example directories would exceed the evidence.

## Duplication worth consolidating

### U1 — Service JSON envelopes are reimplemented per native endpoint

`app/Squircle/Sources/SquircleClient.swift:85-95`, `app/Squircle/Sources/SquircleClient.swift:108-145`, and `app/Squircle/Sources/SquircleClient.swift:360-366` repeat request construction, HTTP method, body encoding, reply envelopes and `ok` checks. A partial `send` helper already exists at `app/Squircle/Sources/SquircleClient.swift:266-273`; `perform` at line 390 centralizes transport but leaves each endpoint to reconstruct the contract.

**Proposal:** one typed `APIEnvelope<T>` and generic `get/mutate` path with per-endpoint payload/response types and explicit timeout/error policy. Consolidate error/schema validation there. Preserve separate T3 and Squircle credentials, long-lived WebSocket behavior, upload handling, and origin checks; a universal transport that blurs those boundaries would be worse. Scope: roughly one file plus small contract fixtures, low/medium risk.

### U2 — Two bounded in-memory cache implementations

`BoundedCache` in `app/Squircle/Sources/AgentStep.swift:184-224` tracks cost and recency; `RecentCache` in `app/Squircle/Sources/UI/ThreadViewController.swift:23-69` separately implements count-based recency and memory-warning eviction. The generic cache is also hidden in an agent-step file, making discovery poor.

**Proposal:** move the value cache into a neutral support file and let the main-actor, memory-pressure-aware wrapper hold it with unit cost. Keep memory notifications in the wrapper, disk caching separate, and explicitly preserve/change the oversized-single-entry policy (`BoundedCache` retains the newest entry even above budget). This is duplication of eviction bookkeeping, not proof the two caches currently have identical semantics. Low/medium risk; target eviction/ownership behavior only if tests are needed.

### U3 — Git/process wrappers bypass the shared bounded runner

`src/agents.rs:963-968` runs Git with `.output()`; `src/history.rs:381-385` repeats Git setup/error decoding and adds `kill_on_drop`. The bounded process-group runner already exists in `src/xcode.rs` (output types at `src/xcode.rs:478-506`, group ownership at `src/xcode.rs:436-475`) and is used even by SQLite reads (`src/t3steps.rs:45-61`).

**Proposal:** extract process supervision into `process.rs`, then introduce one Git adapter with explicit output/deadline/cancellation and safe read-versus-mutating policies. Migrate one caller at a time. This fixes the leaky dependency of database readers on an Xcode-named module and avoids yet another timeout implementation. Preserve each command's output semantics: the agent helper trims text, the history helper does not. Medium risk, especially for archive/cleanup operations; retain stop receipts and expected Git tips.

### U4 — CLI declarations, capability metadata and polling logic drift independently

`src/main.rs:41-691` declares commands, `src/main.rs:838-1368` dispatches them, and `src/main.rs:859` manually enumerates capabilities. The compiled binary reports 57 operation entries but **none for `history.*`, `notes.*`, or `agent.compact`**, although those commands exist (`src/main.rs:424-475`, `src/main.rs:1217-1218`). This is a reproduced discoverability inconsistency, not merely a style preference.

Build waiting (`src/main.rs:962-1002`) and preview waiting (`src/main.rs:1056-1101`) also repeat deadline-bounded fetch/sleep/error handling with different terminal predicates.

**Proposal:** split command groups into modules, centralize operation descriptors used by capabilities/help, and share only the polling/deadline mechanism with distinct typed completion policies. Do not make preview submission retry automatically, or reinterpret timeout as cancellation. Existing CLI deadline tests provide useful protection (`tests/cli.rs:237-298`). Small/medium, moderate contract risk.

### U5 — Jelly rendering has shared foundations but repeated policy/encoding

The shader, pipeline and uniforms are already shared in `app/Squircle/Sources/UI/JellyShader.swift`; the overlay uses `JellyRenderer` too (`app/Squircle/Overlay/GlassJelly.swift:1128`). Remaining duplication includes mood-to-color logic (`app/Squircle/Sources/UI/Jelly.swift:182-197`, `app/Squircle/Overlay/GlassJelly.swift:756-771`) and render-pass/encoder construction (`app/Squircle/Sources/UI/Jelly.swift:707-724`, `app/Squircle/Overlay/GlassJelly.swift:1123-1153`).

**Proposal:** share the semantic agent palette and a narrow draw-encoding helper. Keep overlay recording state, neck/body interaction, live hero scheduling and cached sprout loops explicit. **Do not unify presentation timing blindly:** the hero presents through its command buffer, while the overlay deliberately waits until scheduled and presents within its Core Animation transaction. Preserve that distinction and verify rendered frames after any change. This is optional, higher-risk cleanup; coordinate after the active overlay workers finish.

### U6 — T3 protocol concepts are implemented in two languages without a common compatibility fixture set

Rust `src/t3.rs:1-4` explicitly implements the same RPC protocol as Swift `T3Gateway`. Framing/dispatch handling lives at `src/t3.rs:259` and `app/Squircle/Sources/T3Gateway.swift:220-325`; raw T3 projection knowledge also appears in `src/history.rs:269-293` and `src/t3steps.rs:30-34`.

**Proposal:** retain the two native transports and their separate credentials. Share a sanitized, version-labelled set of protocol JSON fixtures and a short compatibility contract, exercised independently by Rust and Swift. Move SQLite schema knowledge behind a clearly named read-only adapter; keep `history` as a consumer. Do not create a shared transcript database, proxy agent backend, or cross-language networking framework. Medium effort, low runtime risk if initially limited to fixtures/docs.

**What is already consolidated:** the overlay constructs the same `ThreadViewController` for agent and worker conversations (`app/Squircle/Overlay/SquircleOverlay.swift:1088-1101`) and implements `ConversationHost` (`app/Squircle/Overlay/SquircleOverlay.swift:1798`). The framework compiles the app sources except its app entry point (`app/Squircle/project.yml:102-124`). `FrameSpring` already delegates numerical integration to `SpringDriver.step` (`app/Squircle/Overlay/FrameSpring.swift:73-75`). Separate host navigation, rectangle/scalar spring wrappers and native/Rust protocol implementations should not be counted as wholesale duplicate products.

## Architecture: understandable ideas, expensive navigation

The best parts are substantive:

- `Owner`, published snapshots and ranked lanes establish a clear service-state policy (`src/actor.rs:1-25`, `src/actor.rs:46-77`, `src/actor.rs:181-221`). Preserve it. The deliberate mutex encapsulated inside a ranked lane is not a request to reverse the no-shared-lock decision.
- The commit gate separates proposed and committed state and releases effects only after saving (`src/fsm/core/commit.rs:14-37`, `src/fsm/core/commit.rs:81-106`). Tasks use that machinery through one owner (`src/tasks.rs:78-87`).
- Dispatch distinguishes accepted/refused/not-sent/unknown (`src/fsm/coordinator/mod.rs:52-66`), and the phone preserves conversation identity (`app/Squircle/Sources/SquircleModel.swift:6-27`). These are good foundations for reconnect correctness.
- The HTTP router separates control, diagnostic and ticket-authorized access, applying authentication before extraction (`src/server.rs:271-347`). Private media creation uses exclusive creation and no-follow flags (`src/media.rs:54-74`); SQLite is opened read-only (`src/t3steps.rs:45-52`). These controls deserve preservation and regression coverage.

The current source layout still makes a newcomer learn too many unrelated responsibilities at once. Counts below are physical lines, including any embedded tests/debug code—not a claim that every line is production complexity.

| Module | Lines | Responsibilities that should be easier to find |
| --- | ---: | --- |
| `src/agents.rs` | 3,520 | Wire/storage adapters, shell observations, coordinator lifecycle, workers, Git cleanup, notifications, prompt text, history context, plugin installation and tests. Examples: Git at line 963, lifecycle at 1634, worker spawn at 2239, plugin setup at 3486. |
| `src/server.rs` | 2,645 | Runtime wiring, all endpoint families, build supervision, media/import/installer logic, error envelopes and tests. `AppState` starts at line 33; build workflow at 526; later simulator routes resume after the test module at 1999. |
| `src/sims.rs` | 1,860 | T3/recorder host adapter, persisted session recovery, admission/session effects, cleanup and tests. The reducers already provide a sensible seam; do not replace their ownership with another session registry. |
| `src/push.rs` | 1,591 | APNs signing/HTTP, device registration persistence, desired-state calculation, activity delivery and tests. Extract adapters around the existing owner rather than splitting that owner's data across services. |
| `src/main.rs` | 1,401 | Command definitions, local operations, HTTP transport, status polling, capabilities/help and rendering. |
| `app/Squircle/Sources/SquircleModel.swift` | 2,081 | Connection integration, delivery/command reducers, project/catalog state, preferences, caches, media, task actions, install state and disk persistence. The extracted `ClientState/` machines help, but their runtime integration still accumulates here. |
| `app/Squircle/Sources/UI/ThreadViewController.swift` | 1,768 | Timeline/table behavior, scroll following, sizing/cache, composer/send animation, media, builds, approvals/questions and debug harness. |
| `app/Squircle/Overlay/SquircleOverlay.swift` | 1,812 | Overlay routes/mounts, geometry/gestures, conversation hosting, capture UI and debug probes. Review reflects this commit only; do not overlap current overlay edits. |

Further layering issues:

1. The generic subprocess runner is under `xcode`; read-only history/SQLite functionality depends on build-tool infrastructure by name. Extract the runner without changing its lifecycle guarantees (U3).
2. Domain decisions and API presentation are interleaved in HTTP handlers. For example, `server::start` validates build recipes before coordinating work (`src/server.rs:526-565`); much of this belongs in a build application service callable from a thin route. CLI-specific printing belongs in CLI modules, never those domain services.
3. Useful neutral types are hidden in feature files: `JSONValue` under `ClientModels` (`app/Squircle/Sources/ClientModels.swift:343-365`), `BoundedCache` under `AgentStep`, `RecentCache` inside the conversation controller, and `DiskCache` at the end of `SquircleModel` (`app/Squircle/Sources/SquircleModel.swift:2008-2025`). Move these first; no runtime behavior needs to change.
4. Rust exports virtually the entire implementation through `pub mod` (`src/lib.rs:5-32`). Define whether the supported product is the CLI/HTTP protocol or also a Rust library API. Prefer `pub(crate)` for internal modules where feasible; otherwise contributors cannot tell which refactors are externally breaking.
5. The T3 version and database assumptions need a named compatibility boundary. `app/Squircle/README.md:3` names 0.0.45; SQL consumers depend directly on projection tables. This is intentional read-only enrichment, but a protocol/database mismatch should have an explicit supported-version diagnostic instead of relying on maintainer memory.

### Proposed target structure

Keep one Rust crate initially, the same service owners, the same persisted/wire identities and the same Xcode targets. Directory moves are a discovery aid, not a state migration.

```text
src/
  main.rs                     small entry point
  cli/                        args, command groups, HTTP client, output
  api/                        router, auth/errors, handlers by feature
  runtime/                    service wiring, shutdown/handover
  coordinator/                owner, T3 shell, lifecycle, workers, outbox driver
  builds/                     application service, Xcode, overlay, artifacts
  simulators/                 host adapter, session runtime, pool runtime
  push/                       owner, APNs adapter, projections
  t3/                         RPC, read-only database adapter, compatibility
  process.rs                  bounded process-group runner
  fsm/                        existing pure machines and commit contract
  tasks/, storage/, catalog/  existing ownership boundaries, made discoverable

app/Squircle/
  App/                        app entry/lifecycle and push wiring
  Sources/Transport/          T3 and Squircle clients, origin policies
  Sources/State/              existing reducers, runtime adapters, model facade
  Sources/Support/            caches, JSON value, display-frame/spring helpers
  Sources/UI/Conversation/    one controller family for both hosts
  Sources/UI/Home/            route, portraits and simulator dock
  Sources/UI/Jelly/           shared renderer and semantic look
  Overlay/                    host scene, panel interaction and capture
  Shared/, Widgets/, Tests/   explicit target membership retained
```

The first restructuring commits should be moves/extractions with unchanged APIs. Do not convert `SquircleModel` into many independently mutating mirrors, share UI navigation state across hosts, introduce an FSM framework, split into microservices, or change the rendering design to make refactoring easier.

## Contributor docs: concrete contradictions and gaps

| ID | Evidence | Correction |
| --- | --- | --- |
| Q1 | `scripts/check-swift-concurrency:14-15` scans Sources/Overlay/Tests/UITests; `app/Squircle/project.yml:19-23` also builds App/Shared, and Widgets is another target. `tests/ownership.rs:28-35` truncates at the first test module, while production server code continues at `src/server.rs:1999`. | Expand Swift target coverage and remove stale UITests assumptions. Make the Rust scan exclude test modules without dropping later production code, or organize files so tests are last and enforce it. Clippy still covers the Rust library, so this is a gap in the standalone test's advertised coverage, not evidence of current forbidden locks. Wire checks for every relevant build target. |
| Q2 | `README.md:8-188` labels a long chronological log “Current state”; it includes the superseded rainbow/Metal lens, carousel and travelling device at `README.md:100-167`. | Put a short current capability/limitation summary and quick start first; move chronological evidence to a clearly labelled archive. Preserve the decisions and dated evidence without presenting mutually exclusive designs as current. |
| Q3 | `docs/product.md:9-10` says the replacement is unimplemented, and `docs/product.md:22-34` still lists Hermes and live 3D as accepted behavior. `docs/hermes-client.md:3-16` and `docs/coding-visibility.md:3-25` read as active instructions. | Archive/label these as superseded by the T3 migration and link the current guide. These are stale documentation files, not proof of dormant active Hermes integration. |
| Q4 | `src/main.rs:661`; reproduced `squircle app show --help` says Hermes owns conversations. | Correct user-facing help to T3; no backend change required. |
| Q5 | `src/main.rs:859` omits implemented history/notes/compact operations; reproduced through the compiled CLI. | Make capability inventory agree with the public command surface (U4). Agent-neutral tooling depends on reliable discovery. |
| Q6 | `plugin/squircle/agents/app-agent.md:16` tells the agent the user may add tasks on the phone. `AGENTS.md:11` says no task + button; `TasksViewController` has no task-creation path. | Remove the claim about creating tasks on the phone; preserve status/reordering controls and the agent's task ownership. |
| Q7 | `docs/architecture.md:76-79` still says workers run full-access. `docs/cli.md:83` and `plugin/squircle/agents/app-agent.md:13` say they inherit the coordinator mode unless overridden; `src/agents.rs:396` implements the provider-aware choice. | Update the architecture paragraph to the current inheritance rule. Do not alter the approval policy. |
| Q8 | `README.md:231` calls the jelly proposal “not built”, despite the implemented crew entry in `AGENTS.md:13` and `app/Squircle/Sources/UI/Jelly.swift:5-9`. | Distinguish implemented direction B from still-proposed extensions. |
| Q9 | `docs/verification.md:7-10` assumes this Mac's credential-bearing client and points to historical validation as “current evidence”; this file is embedded by CLI help (`src/main.rs:887`). | Rewrite the actual CLI help workflow for an independent user, and keep dated verification in history. Do not let an embedded help document silently teach the old setup. |

`docs/fsm-architecture.md:3-13` appropriately distinguishes proposal baseline from later implementation, but its 1,594 lines are not an entry-level architecture guide. Keep it as a design record and add a short current module/owner map. Likewise, the 2,459-line migration record is valuable evidence, not onboarding. Current native version is 0.3.0/build 75 (`app/Squircle/project.yml:10-11`), while CLI/plugin metadata uses Cargo 0.1.0 (`Cargo.toml:3`, `src/agents.rs:3505`); document whether these intentionally version independently.

Missing contributor guidance should cover: clean setup and teardown, authoritative generated-project inputs, exact local checks, where protocol fixtures belong, data-directory layout/backup/recovery, supported T3 versions, credential renewal, who reviews changes to persistence/security/overlay injection, and what “verified” means. Distinguish compile/test evidence from signed export, install, manual launch, phone crash recovery and rendered motion verification. An OS support matrix should state that iOS 18 is the configured deployment target (`app/Squircle/project.yml:4-5`), while this pass only compiled against the installed iOS 27.1 SDK.

## Ordered cleanup plan

Estimates are rough focused engineering effort, not calendar promises. Each numbered item is a separately reviewable change; larger items should be split by feature. “Small” is generally tens to a few hundred changed lines; “medium” is several hundred; directory extraction can move many lines while changing little logic.

| Order | Deliverable | Size / risk | Acceptance evidence |
| --- | --- | --- | --- |
| 1 | Choose license, provenance/notice policy, public/private publication set; sanitize docs and plan any history export (P1/P2). | Small docs work, about 0.5–1 day; history publication itself has high irreversible risk and is a separate operation. | Reviewed license/provenance inventory; dedicated scan of exact public refs/artifacts; no real credentials or unapproved personal logs. |
| 2 | Fix remote-origin transport policy (P3a). | Small, about 0.5 day; low/medium risk. | Offline URL-policy cases pass; loopback setup remains valid; remote HTTP rejected before credentials leave. |
| 3 | Close the history guard's external-helper escape (P3b). | Small/medium, about 0.5–1.5 days; medium compatibility risk. | Harmless marker reproducer refused; allowed history operations still work without external command execution. |
| 4 | One configurable signing/namespace contract and explicit personal-credential embedding; source-resource distribution policy (P2/P4). | Medium, about 1–2 days; high signing/keychain compatibility risk. Coordinate with overlay owner. | Different test namespace generates and compiles; existing personal identity remains usable; public artifacts contain no connection JSON; moved CLI behavior is explicit. |
| 5 | Rewrite current README/setup and active CLI help, archive superseded docs, fix capability inventory (P4, Q2–Q9). | Small/medium, about 1 day; low runtime risk. | Another account/environment follows it; required tools and optional features are explicit; capabilities reflect commands. |
| 6 | Isolated formatting baseline, fix/baseline lint warnings, complete guard coverage, add macOS CI (P5/Q1). | Mechanical medium, about 1–2 days; low logic risk but merge-conflict risk. Schedule after concurrent changes. | Locked tests, chosen lint policy, format, concurrency checks, project drift and unsigned app/overlay builds are green without secrets. |
| 7 | Delete D1–D6 and decide D7's public visibility; move neutral native helpers. | Small, about 0.5 day; low risk. | Both native targets compile, relevant existing tests pass; no design or runtime behavior change. |
| 8 | Consolidate native REST envelopes and cache bookkeeping (U1/U2). | Medium, about 1–2 days, separate commits; medium decoding/eviction risk. | Contract/error fixtures and existing cache/send/media tests; preserve credentials and cache semantics. |
| 9 | Extract process/Git adapter and CLI groups/polling (U3/U4). | Medium, about 1–2 days per slice; medium lifecycle/CLI risk. | Existing subprocess, worker cleanup and CLI deadline tests; no change to stop receipts, retries or exit statuses. |
| 10 | Split HTTP handlers/application services, then `agents.rs`, `sims.rs`, `push.rs` around existing owners. | Several small extraction PRs, about 2–4 days overall; medium risk if mechanical, high if mixed with state changes. | Same persisted fixtures and wire envelopes; existing race/restart/idempotency tests. Owners and lane ordering remain single sources of truth. |
| 11 | Thin native model/controller adapters around existing reducers; add versioned cross-language protocol fixtures (U6). | Medium per feature, about 2–4 days; medium/high UI lifecycle risk. | Existing native logic tests; explicit rendered navigation checks through Squircle's simulator workflow for UI-affecting changes. No inferred visual verification from compilation. |
| 12 | Optional jelly encoding/palette cleanup after overlay workers finish (U5). | Small/medium, about 1–2 days; high visual/timing risk relative to payoff. | Frame-by-frame rendered comparison and existing stress diagnostics; retain presentation timing, motion and cache-loop behavior. |

Steps 1–6 are the publishing work. Steps 7–12 improve maintainability and can follow an honestly labelled early source release. Complete any signing/binary-distribution validation only for the artifacts actually promised; a source-only release can explicitly retain those limitations. No product redesign, replacement backend, live-test expansion, or wholesale state migration is needed to make this repository welcoming and reviewable.
