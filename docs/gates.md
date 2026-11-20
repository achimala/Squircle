# Visual gates (`squircle help gates`)

Every code change goes through two gates, the user's (2026-11-20):

    Plan ──▶ the user's Approve plan ──▶ Build (workers film each change)
         ──▶ Review (an independent reviewer) ──▶ the user's Approve merge ──▶ squircle merge

Questions and research are **No code** items (asked → answered → closed by
the user); a backlog is **Not planned yet**. File each work item with its
kind: `squircle task add --kind code|no-code|not-planned …`.

## 1. Plan (app agent)

Draw the pictures, write `docs/plans/<slug>/plan.md` in the app's folder,
hand it in. A plan can be one picture.

    squircle draw SPEC.json              # PNG beside it; `squircle draw --help` for the spec
    squircle plan ITEM --dir docs/plans/<slug>

`plan.md`:

    # Keep the deck on the phone

    One to three sentences: what is wrong and what changes.

    ![How it works now](pictures/now.png)
    ![The change, drawn on it](pictures/change.png)
    ![The problem](pictures/problem.png)

    ## Changes

    1. Keep the whole deck on the phone
       asks: item
    2. Server sends only changed cards
       asks: 3f2a9c1b

- Pictures: one idea each; **now** (how it works), **proposed** (the change
  drawn on it: added, moved, removed, anything odd in red), **problem**
  (you did / the app does / it should), or real screenshots.
- Changes: numbered 1, 2, 3…, one line each; this is your breakdown (no
  breakdown sub-tasks).
- `asks:` ties the user's words to the change that answers them: `item` for
  the item's own ask, or an ask's ID (its first 8 characters are enough;
  `squircle task show ITEM` lists them). **Every open ask must be tied**, or
  `plan` refuses ("what else got dropped?"). An ask the user replaced is
  retired with `task update ASK --replaced-by NEW`, not left out.
- The round then waits on the user's **Approve plan**, bound to that round
  and its digest. Words they add later (Change… or chat) aren't in it: the
  button greys out until you hand in the next round. No code before they
  approve; you get an `[approved]` message when they do.

## 2. Build (workers)

Brief workers with `thread spawn --task ITEM`: their brief carries the
approved plan's folder and changes. Each worker films each change it owns:

    squircle sim start --thread ID … (drive it) … squircle sim stop --thread ID
    squircle film ITEM --change 2 --side branch --thread ID      # its newest recording
    squircle film ITEM --change 2 --side main --file /abs/clip.mov

`film` keeps the clip in the item, takes before/after stills and measures
abrupt jumps (a frame changing over 3× its neighbours), and fails loudly if
the clip can't be read. Every change needs a film on the **branch** (a
picture is fine where nothing moves); `main` shows the before. Workers
never merge.

## 3. Review (app agent starts it, the reviewer submits)

    squircle review start ITEM --thread <app agent thread> [--branch B]

Starts the independent reviewer as a T3 worker (Codex `gpt-6-astra` unless
`.squircle/gates.toml` names another) in a fresh worktree at the branch's
head, with the plan, the diff, the films and the app's rules. It writes
`docs/plans/<slug>/review-N.md` and hands it in:

    squircle review submit ITEM --head <sha> --file /abs/review-N.md

`review-N.md`:

    # Review 2: PASS          (or REVISE, or BLOCKED)

    One or two sentences.

    ## Plan vs actual
    1. ✓ Keep the whole deck on the phone
    2. ✓ Server sends only changed cards
    3. ≠ A late grade is kept, not refused — why: both are kept, newest wins, because …
    4. ✗ Dropped the prefetch bar — why: …

    ## Findings
    ### Offline, the deck still says “Loading cards…”
    ![](frames/offline.png)
    - planned: opens from the phone
    - branch: waits on the server
    - fix: read Cards first

One line per planned change (✓ built, ≠ built differently with why, ✗
dropped with why), one picture per finding. `submit` refuses a review
missing a change's line, a why, a finding's picture, or a change's film.
PASS waits on the user's **Approve merge**, bound to that review round and
commit; REVISE or BLOCKED goes back to the workers, then `review start`
again. **A new commit on the branch voids the review and any approval of
it**: the item goes back to Build.

## 4. Merge (app agent)

    squircle merge ITEM

The only way onto the base branch: it merges exactly the approved commit,
with the plan folder (plan, pictures, every review, the films' stills) in
`docs/plans/<slug>/`, after running the app's merge checks. It refuses
without the user's approval, if the branch moved, if the review isn't PASS
for that commit, or if a change has no film. Your guard refuses `git
merge`, `git push`, `git commit` and other ref-writing git in your own
shell: there is no other way. A short reply ("ok", "looks good") is never an
approval; only the button is.

## The user's Change…

Their words go on the item as an ask (`[change]` message). At Plan, draw the
next round tying them to a change. At Review, the item is back at Build:
send the workers the whole current spec, then review again.

## Per app: `.squircle/gates.toml`

    squircle gates enable --thread ID [--base main] [--rule docs/engineering-preferences.md]… [--check "bun run typecheck"]…

Base branch, reviewer (`[reviewer] provider/model/effort`), the rule
documents the reviewer enforces, and commands `merge` runs on the merged
tree before it commits.

## Items from before gates

Open items were filed as code at Plan (a backlog as Not planned yet).
Import an existing plan as round 1 (`squircle plan`), refile questions with
`squircle task kind ITEM no-code`. Nothing is approved from history: the
user taps once.
