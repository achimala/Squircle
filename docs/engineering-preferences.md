# Engineering preferences

The owner's standing preferences for all code in this repo: the Rust service and CLI (`src/`), the iPhone client (`app/`) and the plugin (`plugin/squircle`). Every code review (per-merge Astra reviews, audits, workers reviewing their own diff) checks against this page. [AGENTS.md](../AGENTS.md) carries the product decisions and these rules in more detail; where they differ, the newer owner instruction wins.

## Simple as possible
- Write the plainest code that does the job. No pointless wrappers, layers or conversions; add a type or helper only when it removes real complexity or duplication today.
- No speculative code: no options, flags, hooks, caches or config for needs that don't exist yet.
- Target only the latest T3 (orchestration protocol 2). No compatibility shims for older versions or old data shapes.

## No duplication
- One concept, one place. Find the existing owner of that logic and extend it.
- Delete dead code, legacy branches and old/new dual paths when you touch them. Old designs live in Git history, not behind flags.

## Root causes, not band-aids
- Fix the cause. No fallback timeouts, retry layers, second paths or defaults that hide a bug.
- No waits, sleeps or timers to paper over ordering, in code or tests. Wait for the real event: an owner's message, a channel closing, a process exiting or file changing (`src/kq.rs`), a T3 event.
- Durations the owner chose as product rules run off the policy clock (`src/clock.rs`); each use is listed in `build.rs`'s `POLICY_CLOCKS`. Rules take the time as an argument; tests use tokio's paused clock (`clock::elapse`) and never sleep.

## Service: single owners, no locks
- State lives in single owners (`src/actor.rs`): letters are synchronous and never `.await`, readers use published snapshots, async work that must not overlap runs in ranked lanes, and `Drop` only tells an owner. See [owners](fsm-architecture.md#owners-and-who-may-wait-for-whom-implemented-2026-10-17).
- No mutex, read-write lock, semaphore, file lock or blocking wait; `clippy.toml` and `build.rs` fail the build on them.
- Read T3's state database read-only, never write it. The service runs no model.

## Client: invalid states unrepresentable
- A small source of truth (an enum route, a value) plus values that move continuously toward it. Derive every frame, visibility, interactivity and ownership from that state in `sync()` each time; never toggle them from callbacks or completion handlers. Mount and unmount only off screen.
- If a sequence of taps could leave the screen wrong, the design is wrong, not the timing. `StudioViewController` is the reference; DEBUG `SQUIRCLE_STRESS=1` must report `violations=0` after navigation changes.
- Swift concurrency only (async/await, `Task`, `AsyncStream`, `@MainActor`, `DisplayFrame.next()`). No Combine or Dispatch; the concurrency baseline only goes down.

## Motion follows the finger
- Native scroll physics or one interruptible spring drives every move. The destination takes touches from the first frame; a tap mid-transition takes over.
- No crossfades, no system zoom/sheet gestures over the conversation or simulator.
- Verify transitions frame by frame on rendered output before calling them verified.

## Hot paths on the phone
- Per-frame code doesn't allocate, rebuild layers or redo work whose inputs didn't change.
- Measure on the phone before and after; never claim a frame rate that wasn't measured. Recordings never trade frame rate.

## Tests: very high bar
- Test only logic that is easy to get wrong and invisible on screen: parsers, protocol and stream decoding, security checks, state that must survive reconnects.
- No tests that restate the code (layout numbers, view text, a filter filters), and none that call live T3, agents, builds or simulators. The suite stays a few seconds.
- Delete a test when the design it pins changes; don't rewrite it.
- Check UI by running the app and looking at it, with real data at real scale.

## Docs
- Label proposals and unknowns; don't turn a researched capability into a tested fact. Record evidence and versions when something is actually validated.
- Update the relevant detail page when a decision changes; keep AGENTS.md short.
