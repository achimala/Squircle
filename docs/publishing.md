# Publishing the repository

**Status: proposal; nothing here has been run.** The current tree has been
cleaned of personal material (2026-10-18), but Git history still holds it.
This page lists what history contains and two ways to publish, so the
maintainer can choose. Either way is a separate, deliberate release operation:
rewriting or exposing history can't be undone once someone has cloned it.

## What history contains

Surveyed on 2026-10-18 over `main` (435 commits). Counts are commits whose
diffs add or remove the item.

| Item | Where | Notes |
| --- | --- | --- |
| Maintainer's home paths | 9 commits: the checkout path under `~/Documents/…/RemoteAppDev` and the user's `~/.local/bin/codex` | Names the account and machine layout. Also in deleted UI tests and early client code. |
| Apple team ID | 14 commits: `project.yml`, `ExportOptions.plist`, docs | Not a secret, but identifies the maintainer's team. Still in the current app/probe configuration until the signing namespace is made configurable (cleanup step 4). |
| Account and cost investigation | `docs/coding-visibility.md` and `docs/validation.md` (removed 2026-10-18) | A Claude session ID, the subscription tier, a reported API cost and local backup filenames. |
| Bundle and Keychain namespace | Everywhere (`ai.dreamslate.*`) | Public identifiers, intended to stay unless renamed. |
| Author identity | Every commit | One author/committer name and email on `main`; other refs may carry a second email. Keep, or rewrite with a mailmap. |
| Private Hermes-era setup | Old docs | Local ports and route layout, no hostnames or credentials. |
| Hostnames | Tests and examples | Only synthetic `*.ts.net` names were found (`mac.tail.ts.net`, `your-mac.your-tailnet.ts.net`, …). |
| Local refs | `refs/t3/checkpoints/*` (669), `refs/codex/turn-diffs/*` (10), worker branches | T3/Codex checkpoint snapshots of working trees. **Never push these.** |

The open-source review's scan (P2 in [oss-review](oss-review.md)) found no
credential, signing key, profile, IPA or database in reachable history. That
scan was pattern-based, not a dedicated scanner; run one (below) on exactly
what you will publish.

## Option A (recommended): a fresh public repository

Publish the cleaned tree as one new root commit in a new, empty repository.
History stays private in the existing repository.

```sh
git clone --single-branch --branch main /path/to/private-checkout squircle-public-src
mkdir squircle-public && cd squircle-public && git init -b main
git -C ../squircle-public-src archive main | tar -x
gitleaks dir --config .gitleaks.toml -v .           # must be clean
git add -A && git commit -m "Squircle: initial public release"
git remote add origin git@github.com:OWNER/squircle.git   # new, empty repo
git push -u origin main
```

Pros: nothing from history can leak, no rewritten SHAs in the private repo,
T3 checkpoints and worktrees keep working. Cons: public history starts at
release; the dated reasoning lives on in `docs/` (history, migration record)
rather than in commits. Later development can continue in the public
repository, or in the private one with periodic squashed exports.

## Option B: rewrite history with git-filter-repo

Keeps the commit history but with new SHAs. Work only in a fresh clone of
`main`, never in the development repository (its worktrees, T3 checkpoint
refs and open branches all point at the old SHAs).

1. Clone only `main`, without tags or other refs:

   ```sh
   git clone --single-branch --branch main --no-tags /path/to/private-checkout squircle-rewrite
   cd squircle-rewrite
   ```

2. Write `../replacements.txt` (one rule per line, `old==>new`; `regex:`
   prefixes a regular expression). Fill in the real values locally; don't
   commit this file:

   ```text
   regex:/Users/[a-z]+/Documents/[^/]+/RemoteAppDev==>/path/to/Squircle
   regex:/Users/[a-z]+/\.local/bin/codex==>codex
   regex:/Users/[a-z]+/==>~/
   TEAM_ID_VALUE==>TEAMID
   SESSION_ID_VALUE==>SESSION_ID
   regex:\$11\.7[0-9]*==>(cost removed)
   regex:subscriptionType=[a-z]+==>subscriptionType=…
   ```

3. Rewrite. The mailmap is optional, to change the public author email
   (`Name <public@email> <old@email>`):

   ```sh
   git filter-repo --replace-text ../replacements.txt \
     --replace-message ../replacements.txt \
     --mailmap ../mailmap.txt
   ```

   To drop the Hermes-era coding-visibility page from every commit instead of
   redacting it, run a second pass:
   `git filter-repo --invert-paths --path docs/coding-visibility.md --path docs/archive/coding-visibility.md`.

4. Verify before pushing anywhere:

   ```sh
   gitleaks git --config .gitleaks.toml -v           # whole rewritten history
   git log -p --all | grep -nE '/Users/[a-z]+/|TEAM_ID_VALUE|SESSION_ID_VALUE'   # expect nothing
   git for-each-ref                                   # only refs/heads/main
   ```

   Also read the result by eye: a scanner won't flag personal notes written in
   prose.

5. Push to a **new** empty repository (`git push origin main`). Don't
   force-push the rewrite over the existing private remote: that strands every
   clone, worktree and T3 checkpoint that references the old SHAs.

Pros: history and authorship are kept. Cons: a rewrite is easy to get subtly
wrong (a missed pattern stays public forever), and every later fix to the
private repository needs re-exporting.

## Either way

- Publish only `main`. Never mirror the development repository
  (`git push --mirror` would publish T3 checkpoints and worker branches).
- Don't attach IPAs built from a personal checkout: they embed the phone's
  connection credentials ([SECURITY](../SECURITY.md)).
- If the final scan finds a real credential, rotate it; redacting history
  doesn't make an exposed secret safe again.
- Decide the copyright line in [LICENSE](../LICENSE) and the author email you
  want public before the first push.
