# Contributing

Squircle is an early-alpha personal project. Issues and small, focused pull
requests are welcome; for anything larger, open an issue first so we can agree
on the direction. [AGENTS.md](AGENTS.md) lists decisions the maintainer has
made on purpose (one agent per app, T3 owns agents and threads, the Clay look,
no live 3D, and so on). Changes that reverse one of them need a conversation
first, not a pull request.

## Setup

Follow the [README](README.md#quick-start): macOS with Xcode, XcodeGen and a
Rust toolchain, plus T3 Code if you want to run the whole thing. Keep your
private state (credentials, the phone's connection file, build products) in
the ignored `.squircle/` directory or another `SQUIRCLE_DATA_DIR`; never
commit it. `scripts/cargo-local` uses a toolchain in the ignored `.tools/`
directory if one exists and otherwise your own `cargo`.

To use simulators while developing, start them through Squircle
(`squircle sim start --thread ID`), not with `simctl` or `xcodebuild`, so the
service can lease, record and shut them down.

## Checks

Run these before sending a change:

```sh
cargo test --locked                    # Rust tests; a few seconds after compiling
cargo clippy --locked --all-targets    # includes the no-locks rule (clippy.toml)
scripts/check-swift-concurrency        # no new Combine or Dispatch in the app
xcodegen generate --spec app/Squircle/project.yml
xcodebuild -project app/Squircle/Squircle.xcodeproj -scheme Squircle \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO SQUIRCLE_CLIENT_CONFIG=/dev/null build
```

The app's unit tests run on a simulator you started through Squircle
(`xcodebuild ... -scheme Squircle -destination 'platform=iOS Simulator,id=UDID' test`).
There is no CI yet, and `cargo fmt --check` doesn't pass on the whole tree
yet; format the files you touch.

For UI changes, run the app and look at it: describe or attach what you saw.
Motion counts as checked only when you've looked at it frame by frame in
rendered output. Compiling is not visual verification.

## Rules the code follows

**Service (Rust): no locks.** Every piece of shared state has a single owner
(`src/actor.rs`). Others send it messages, read its published snapshots, or
run async work that must not overlap in a ranked lane. `Drop` only tells an
owner. Clippy and `tests/ownership.rs` fail on any mutex, read-write lock or
blocking wait. See [owners](docs/fsm-architecture.md#owners-and-who-may-wait-for-whom-implemented-2026-10-17).

**App (Swift): concurrency only through Swift concurrency.** Use
async/await, `Task`, `AsyncStream`, `@MainActor` and `DisplayFrame.next()`.
Don't add Combine or Dispatch (`DispatchQueue`, `.sink`, `@Published`,
`ObservableObject`, …). `scripts/check-swift-concurrency` runs in every app
build against `app/Squircle/concurrency-baseline.txt`; that baseline only goes
down. Remove old uses when you touch them.

**App: make invalid states unrepresentable.** Screens derive their frames,
visibility and interactivity from one small source of truth (an enum route,
a value) every time, rather than toggling them from callbacks.
`StudioViewController` (route + `sync()` + `applyScene()`) is the model; its
DEBUG `SQUIRCLE_STRESS=1` mode must report `violations=0` after navigation
changes. Native scroll physics or one interruptible spring drive every move;
nothing waits for an animation to finish before taking touches.

**Fix root causes.** No extra timeouts, retry layers or fallbacks to hide a bug.

**Tests only where looking can't catch it.** Test tricky logic that's
invisible on screen: parsers, protocol and stream decoding, security checks,
state that must survive reconnects. Don't write tests that restate the code
(layout numbers, view text) and don't call live T3, agents, builds or
simulators from tests. Delete a test when the design it pins changes. The
suite must stay a few seconds.

**T3 stays unmodified.** Squircle talks to T3 through its normal APIs and
reads T3's `state.sqlite` read-only; never write to it, fork T3 or add
another agent backend.

## Documentation

Keep docs short and current. Label proposals and unknowns as such; don't
describe something researched as tested. Record versions and evidence when
you validate a milestone. When a decision changes, update its detail page
and keep [AGENTS.md](AGENTS.md) short.

## Commits

Small commits that each build and pass the checks. The subject is a short
plain sentence, optionally with an area prefix: `Diffs: keep -- and ++ lines
inside hunks`, `SquircleClient: one reply envelope`. Explain why in the body
when it isn't obvious. Don't mix a mechanical change (formatting, a move)
with a behavior change.

By contributing you agree your work is released under the [MIT license](LICENSE).
