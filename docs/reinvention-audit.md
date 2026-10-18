# Reinvention audit (2026-10-18)

**Status: proposal; the service and app items are done.** Items 2, 3, 4, 5, 11, 12
and the `gzip;q=0` bug were fixed on 2026-10-18 (branch
`service-reinvention-fixes`): `time` for dates, `src/git.rs` on
`run_bounded`, `run_bounded_with_input` for perf, std `File::try_lock`,
`store::write_private`/`publish_private`, and `Snapshot::wait_for`. The app and
overlay items 1, 6–10, 14–16, 18 and 20 (and the `BoundedCache` copy and
fallback-UUID side notes) were done on 2026-10-18 (branch
`app-reinvention-fixes`): the diff parser follows each hunk's line counts,
both line diffs use `difference(from:)`, T3 payloads are `JSONValue`
literals encoded once (`JSONValue.from`/`.foundation` are gone), one reply
`Envelope` in `SquircleClient`, `ISODate.format`, `Elapsed` on
`Duration.formatted`, ImageIO `Downsample` for thumbnails, shared helpers,
and the dead code here and in [oss-review](oss-review.md) D1–D6 deleted.
Unit tests pass; the diff viewer and a picture send were checked in the
simulator. Items 22–25 stay optional. Item 21 still waits on the user. The rest of this page is the audit as written. It covers the
Rust service/CLI (`src/`), the iPhone app, overlay and widgets
(`app/Squircle`), and `scripts/`, looking for hand-written code that redoes
what the platform or a maintained package already does well. Markdown parsing
is excluded because another worker is moving it to Foundation's parser.

Toolchain at audit time: rustc 1.99, deployment target iOS 18.0, Xcode 27.1.
Line counts come from reading the code. "Free" crates are ones Cargo.lock
already compiles in as transitive dependencies.

**Overall:** the codebase mostly uses the platform already. On the app side
that means diffable data sources, `UIKeyboardLayoutGuide`, sheet detents,
`UIMenu`, `PHPicker`, `RelativeDateTimeFormatter`, URLComponents,
URLSessionWebSocketTask, VideoToolbox, AVAssetWriter and CryptoKit. On the
service side it means clap, plist, url, reqwest, tokio-tungstenite and the
JSON flags of simctl and xcodebuild. There is no large rewrite to do. The
payoff is a handful of real bugs that hand code hides, two duplicated process
runners, an unmaintained dependency and some dead code. Realistically about
250–350 lines go, and no new crate needs downloading.

## Ranked findings

| # | Where | What it reimplements | Replacement | Lines | Risk | Verdict |
|---|---|---|---|---|---|---|
| 1 | `app/Squircle/Sources/UI/DiffViewer.swift:45-47` | **Bug.** The skip for unified-diff header prefixes (`+++`, `---`, `index `, …) also runs inside hunks. A removed line `-- comment` (SQL, Lua, a Markdown `---` rule) or an added line `++i` is dropped, and the line numbers and +/− counts drift after it. | Keep the 45-line parser (no package beats it). Add an `inHunk` flag: set at `@@`, cleared at `diff --git`, and test header prefixes only outside a hunk. | +3 | low | **Fix** |
| 2 | `src/simpool.rs:539-554` (string→secs) and `src/t3.rs:90-104` (secs→string) | Two hand-written ISO-8601 conversions using Hinnant's civil-date algorithm. They share the name `iso_seconds` but convert in opposite directions. The parser accepts invalid dates without complaint: `history --since 2026-02-30` becomes 2 March, and month 13 gives a wrong date with no error. It also handles no offset except `Z`. | The `time` crate 0.3, which is already compiled with `parsing`+`formatting` because plist 1.10 needs them (MIT/Apache-2.0, actively maintained). `OffsetDateTime::parse(s, &Rfc3339)`, plus a `format_description!` for T3's `.mmmZ` output. | −22 | low | **Worth it** |
| 3 | `src/server.rs:1225-1270` `git_output`; `src/agents.rs:963-969`; `src/history.rs:385-395` | Three git runners, each hardened differently. Only `server.rs` has a deadline and an output cap. Only `server.rs` and `history.rs` scrub `GIT_*`. `agents.rs` has no deadline and no `core.fsmonitor=false`. | One hardened `git()` built on the existing `xcode::run_bounded` (`src/xcode.rs:539`), which already has deadline, capture cap, kill-on-drop and process-group handling. | ~−40 | low | **Worth it** (fixes uneven hardening) |
| 4 | `src/perf.rs:238-276` `run` | A second, blocking copy of `run_bounded`: process group, deadline, cap, then kill the group before reaping. It busy-polls every 10 ms and starts 2 OS threads per call (atos, dwarfdump, mdfind, swift-demangle). | Make `perf show` async (its caller, the CLI `main`, is already async) and give `run_bounded` an optional stdin (~8 lines). | ~−30 | low (CLI path only) | **Worth it** |
| 5 | `src/server.rs:359`, `src/service.rs:38`, `src/overlay.rs:15,229-231` | The `fs2` crate for `flock`. 0.4.3 has had no release since 2018. | std `File::try_lock` (stable since 1.89, `flock` on macOS), matching `TryLockError::WouldBlock`. Drops a dependency. Consider adding blocking `File::lock` to `clippy.toml` `disallowed-methods`. | ~−2, −1 dependency | low | **Worth it** (trivial) |
| 6 | `app/Squircle/Sources/T3Gateway.swift:5-9, 434-439` (`JSONValue.from(Any)`, `.foundation`), 21 call sites (RPC envelope on every request/Ping/Ack, `Reduction.stamp`, `Delivery`, `SquircleModel`, `T3ThreadState.messages`, each `T3DeviceStream` touch move) | Builds JSON values by round-tripping `[String: Any]` → JSONSerialization → bytes → JSONDecoder. A message with a multi-MB base64 picture goes through about 6 serialize/decode passes on the main actor. A value JSON can't hold quietly becomes `null` and is sent that way. | Make `JSONValue` `ExpressibleBy…Literal` (dictionary, array, string, bool, int, float, nil; ~12 lines of plain Swift) and build commands as `JSONValue` directly. | ≈0 net (call sites get slightly wordier) | low (the compiler finds every site) | **Worth it** for speed and correctness, not line count |
| 7 | `app/Squircle/Sources/UI/ThreadDetail.swift:82-98` `lineDiff` | A hand-written LCS line diff with an (n+1)×(m+1) Int table. Above 400k cells it falls back to "all removed + all added". It also lists additions before removals. | `b.difference(from: a)` (`CollectionDifference`, Myers, Swift stdlib), then walk the removal and insertion offsets. | −6 | low | **Worth it** (no memory blow-up or bad fallback on big edits) |
| 8 | `app/Squircle/Sources/AgentStep.swift:173-181` `lineDelta` | Counts +/− lines as a multiset rather than a diff, so a moved line counts as unchanged. | `let d = b.difference(from: a); return (d.insertions.count, d.removals.count)` | −5 | low | **Worth it** (matches git) |
| 9 | `app/Squircle/Sources/UI/Theme.swift:20-48` `glow(for:dark:)`, `characteristicColor(of:)` | Dead code from the rejected coloured glow; nothing references it. | Delete. | −29 | none | **Worth it** |
| 10 | `app/Squircle/Sources/SquircleClient.swift`: 24 local `struct Reply { ok; data }`, 23 `guard reply.ok`, and the same catch mapping at :294, :322, :338, :414 | Repeated reply-envelope boilerplate. This is a cleanup, not an SDK swap. | One generic `Envelope<T: Decodable>`, a `perform` that returns `data`, one error mapping. | ~−35 | low | **Worth it** |
| 11 | Private-file create (0600, `O_NOFOLLOW`, create_new): `src/store.rs:665-674`, `src/apps.rs:332-338`, `src/media.rs:66-75`, `src/projects.rs:453-458`. Temp-then-rename done 3 ways: `store.rs:716-752` (fsync + directory sync), `media.rs:126-141,162-164` (no fsync), `perf.rs:49` | Atomic writes copied by hand, with inconsistent durability (media records are renamed without fsync). | One internal helper modelled on `store.rs`. Optionally promote `tempfile` (already a dev-dependency; MIT/Apache, maintained) and use `NamedTempFile::new_in(parent)` + `persist`. | ~−20 | low | **Worth it** as an internal merge; `tempfile` itself is marginal |
| 12 | `src/agents.rs:1304-1313` `ready` (50×100 ms), `:2350-2358` `wait_thread`, `:2576-2584` `wait_stopped` | Sleep-polling a value that `actor::Snapshot` already publishes through a `tokio::sync::watch`. | Add `Snapshot::wait_for(pred)` over `watch::Receiver::wait_for`, wrapped in `timeout_at`. Each CLI call through `ready()` stops paying up to 100 ms. | ~−15 | low–moderate (every change the predicates read must `publish()`) | **Worth it** |
| 13 | `src/symbolicate.rs:1-190` | Wraps the deprecated `symbolicatecrash` and rejects JSON `.ips` (line 115), the format iOS 15+ writes. | Xcode's `CrashSymbolicator.py` (present in CoreSymbolicationDT.framework), or parse `.ips` with serde and reuse perf.rs's dSYM-UUID matching and `atos`. **Untested.** | ≈0 | medium | **Worth it if crash symbolication is used.** It closes a capability gap rather than saving lines |
| 14 | `app/Squircle/Sources/UI/TasksViewController.swift:125,127,436` | Task thumbnails (54–96×72 pt) are decoded at full resolution with `UIImage(data:)` on the main thread. | `byPreparingThumbnail(ofSize:)` (iOS 15), as `GalleryCell`/`FigureCell` already do. | ±0 | low | **Worth it** (smoother Tasks scrolling) |
| 15 | `Reduction.swift:47-49` (a formatter per `CommandIdentity.fresh()`), `SquircleModel.swift:1427-1428`, `ThreadViewController.swift:863`, `T3Gateway.swift:72` (`nonisolated(unsafe)` shared formatter) | `ISO8601DateFormatter` allocated per call or shared unsafely. | One `static let` `Date.ISO8601FormatStyle(includingFractionalSeconds: true)` (iOS 15, Sendable), or `Date.now.ISO8601Format()`. | ~−4 | very low | **Worth it** (small) |
| 16 | Duplicated helpers across app and overlay: `Overlay/PerfRecorder.swift:209-214` `Ticker` duplicates `DisplayLinkProxy` (`UI/SpringDriver.swift:146-150`); provisioning-profile plist extraction (`AppConfiguration.swift:39-47`, `App/PushCenter.swift:248-259`); hex (`PushCenter.swift:267-269`, `AgentStep.swift:322`); `file(_:)` (`AgentStep.swift:153-155`, `CommandLabel.swift:217-219`, which could be `lastPathComponent`); `CGRect.lerp` (`SquircleOverlay.swift:1886-1891`, `SimulatorViews.swift:972`); "+n −m" attributed string ×3 and the build-status symbol switch ×2 in UI | Copy-paste. | Share one copy each. | ~−40 | none | Housekeeping; do it when touching these files |
| 17 | `src/xcode.rs:334-369` vs `src/projects.rs:388-418` (ExportOptions checks); `preview.rs:219-233` vs `apps.rs:445-455` (PNG header); `simpool.rs:568-584` vs `preview.rs:46-67` (simctl JSON walk); 4× `now()`; 2× `TargetSettings` | Internal duplication in the service. | Merge. | ~−40 | low | Housekeeping |
| 18 | `ThreadTimeline.swift:24-29` `TurnSummary.format`, `ThreadCells.swift:1260-1261` live timer, `Overlay/CaptureSession.swift:132-135` clock | Hand-built `"%d:%02d"` durations; the live timer shows "75:03" past an hour. | `Duration.formatted(.units(…, width: .narrow, maximumUnitCount: 2))` and `.time(pattern: .minuteSecond / .hourMinuteSecond)` (iOS 16). "1m 0s" becomes "1m". | ~−6 | low | Worth it, small |
| 19 | `src/t3.rs:496-502` `clip` | A loop to find a char boundary. | `str::floor_char_boundary` (stable 1.91). | −6 | none | Worth it, trivial |
| 20 | `T3DeviceStream.swift:548-549` | Aspect-fit maths. | `AVMakeRect(aspectRatio:insideRect:)` | −1 | none | Trivial |
| 21 | `src/t3steps.rs:45-72` (+15 call sites in `t3steps.rs`, `history.rs`, `agents.rs:1998`) | Reads T3's `state.sqlite` by spawning `/usr/bin/sqlite3 -readonly -json` per query, with SQL built by `format!`. The only guards are `valid()` (`t3steps.rs:22-28`) and hand-written LIKE escaping (`history.rs:254-258`). Screenshots come back as base64 in JSON text up to 64 MB. | `rusqlite` (MIT, actively maintained), `SQLITE_OPEN_READ_ONLY`, bound parameters. Costs: a C dependency (`libsqlite3-sys`, bundled or system), `spawn_blocking`, and `InterruptHandle` in place of kill-on-drop for deadlines. | ≈0 net | medium | **The user's call.** The payoff is safety (no injection surface) and no process per Live Activity read, not lines. The system `sqlite3` is a documented choice |
| 22 | `ThreadsViewController.swift:92-121`, `BuildsViewController.swift:116-142` (rows `ThreadViews.swift:322-434`, `BuildsViewController.swift:201-320`) | A stack view of every row inside a scroll view, with hand diffing (`rowViews`, `renderedOrder`, manual separators). No reuse and no cap. | `UICollectionView` list layout + diffable data source (iOS 14); optionally `UIListContentConfiguration` cells. | −46 to ~−150 | medium (restyle; Tasks embeds `threads.scrollView`) | **Only if the lists get long**; correct today |
| 23 | `AppImportViewController.swift:80-96,145-150` | Hand-made loading, empty and error backdrop. | `contentUnavailableConfiguration` (iOS 17) | ~−10 | low | Optional |
| 24 | `ThreadDetail.swift:101-143` `ImageViewController` | Pinch-zoom viewer with no centring when zoomed and no double-tap. | `QLPreviewController` (needs a temp file), or centring in `scrollViewDidZoom`. | ~−40 | low–medium | Optional |
| 25 | `Overlay/FrameSpring.swift` (87 lines) | Copies SpringDriver's display link, timestep and rest check for 4 channels. | A 4-channel (SIMD4) SpringDriver. Per-frame stepping stays (a recorded rule). | ~−40 | medium | Optional |
| 26 | `src/buildlog.rs:112-146` | Heuristic compile-error parsing, while `xcode.rs:283-297` already writes an `.xcresult` that nothing reads. | `xcrun xcresulttool get build-results`. The text parser must stay for export, overlay and `-showBuildSettings`, which produce no xcresult. **Output format unchecked.** | ~−35 | medium | Not now (two paths for one job); revisit if compile errors get missed |

## Keep: hand code that is deliberate, simpler or better

- **Shell parsing.** This covers `src/guard.rs` (`plain_words`, `simple_commands`, `substitutions`), `src/simpool.rs:94-163` and the app's `SquircleAction.swift:328-514` / `CommandLabel`. `shlex` only splits words: it can't report the first character that makes the shell do more, and can't split on `; | &` or `$(…)`. Full shell parsers are unmaintained (conch-parser) or heavy. The guard is security allowlist code and should stay hand-written. `agents.rs:946-953` `quote` emits exactly the `'\''` form the guard parses.
- **APNs ES256 JWT** (`src/push.rs:85-121`, ~35 lines over `ring`). `jsonwebtoken` 10 means picking a crypto backend and more dependencies.
- **`compact_json`** ETag/304 + gzip (`server.rs:228-270`). tower-http's compression would pull in `async-compression`, and ETag would still be hand-written. *One-line bug:* `gzip;q=0` (lines 231-235) is treated as accepting gzip.
- **Constant-time token compare** (`server.rs:170-172`). It hashes both values and XOR-folds them, which is correct; `subtle` adds nothing.
- **No HTTP Range** on media and IPA responses. The app fetches whole files. tower-http `ServeFile` would lose the `O_NOFOLLOW` and install-evidence streaming.
- **`history.rs` BM25 ranking, snippets and section splitting.** The recorded "no copy or index" decision rules out FTS5 or tantivy. pulldown-cmark or humantime for a few lines isn't worth a dependency.
- **`serving.rs`'s own hyper-util accept loop.** Deliberate: axum's graceful shutdown waits on stalled peers.
- **The `xcode.rs` process group trick** (`OwnedGroup`, leader held unreaped with WNOWAIT so the pgid can't be reused). process-wrap doesn't guarantee that.
- **Mach-O weak-dylib insertion** (`overlay.rs:483-640`). goblin and object only read Mach-O, `install_name_tool` can't add load commands, and insert_dylib/optool are unmaintained.
- **macOS tools:** `sips`, `avconvert`, `atos` and `swift-demangle` (they demangle Swift better than addr2line/symbolic), `ps`, `proc_pidinfo` and `KERN_PROCARGS2` via libc (`sysinfo` is far heavier), and `localtime_r` in `upkeep.rs` (`time` refuses local offsets in multithreaded processes). Tool output already uses JSON or XML flags wherever one exists.
- **`actor.rs`, `fsm/**`, `SpringDriver`, the custom push and edge-swipe navigation, PiP corner throw, conversation bottom-pinning and the sticky "Worked for…" header.** These are recorded architecture. `UIViewPropertyAnimator` can't retarget while keeping velocity, nor give a per-frame value. Interruptible system navigation transitions need iOS 26, and the target is 18. UIKit has no anchor-to-bottom scrolling.
- **App media and streaming:** the `avcC` parse (`T3DeviceStream.swift:159-185`, bounded; CoreMedia still needs dimensions from the SPS), the T3 framer, `SimulatorPacer` (a jitter buffer for a feed without timestamps), and ScreenRecorder's Metal + AVAssetWriter (ReplayKit prompts and would record the overlay). PerfRecorder's mach sampler stays too: MetricKit is delayed and aggregated, and OSLogStore was measured and rejected.
- **`BoundedCache` / `RecentCache`** rather than NSCache. They cache value types with deterministic, tested eviction. Small fix: `AgentStep.swift:217` copies the whole dictionary on each eviction; a lazy filter or `min(by:)` avoids that.
- **The hand ISO date parser** (`T3Gateway.swift:13-70`). It is measured and pinned by a test against Foundation, and accepts variants a single FormatStyle doesn't. Benchmark `Date.ISO8601FormatStyle.parse` on iOS 18 before touching it.
- **`T3Gateway` RPC framing and heartbeat.** This is T3's protocol on top of URLSessionWebSocketTask.
- **Small cases kept on purpose:** ETag revalidation without URLCache (caching is off on purpose for credentialed responses), explicit snake_case CodingKeys (`convertFromSnakeCase` would give `t3Url`), plural ternaries (the app isn't localised), `FigureCell` justified rows, `ShimmerLabel`, the composer's `sizeThatFits` growth, the `uuids(in:)` byte scan, and the 1-line backoffs. Also hex via `format!`, `escape_html` and `model::token`.
- **`dirs`**: low payoff to drop.

## Side notes found along the way (not reinvention)

- `UpdateCurtain.swift:82` calls the private `suspend` selector. That's fine for Squircle-signed builds, but App Store review would reject it.
- `T3ThreadState.swift:99/142` falls back to `UUID().uuidString` inside the computed `messages`, so a step without an ID gets a new identity on every pass.
- `ClientModels.swift:346-353` `JSONValue.init(from:)` tries String, Bool and Double with `try?` before object. That's worth checking against `ConnectionTrace` decode times on large frames.
- `ThreadViewController.swift:997` `stickyTapped` animates `contentOffset` with `UIView.animate`. Rows won't lay out mid-flight, so it should use `scrollSpring`.
- `ThreadCells.swift:518, 737` still override `traitCollectionDidChange` (deprecated since iOS 17).
- `actor.rs` `Lanes` never removes per-key entries.
- In `main.rs`, `env::args().any(== "--json")` panics on non-UTF-8 arguments; use `args_os`.
- SceneKit (`DeviceStage`) is deprecated as of the iOS 26 SDK.

## Suggested order

1. Bugs first (items 1, 2, and the `gzip;q=0` one-liner).
2. Then the duplicated service process runners (3, 4) and `fs2` (5).
3. Then the app's JSON round-trip (6) and the diff fixes (7, 8).
4. Then dead code and boilerplate (9, 10).

Everything from item 16 down is housekeeping to fold into other work in those files. Item 21 needs a decision from the user.
