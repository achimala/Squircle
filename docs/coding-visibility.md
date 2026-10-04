# Coding activity and subscription authentication

The phone is a client of stock Hermes. It does not launch an alternative coding
backend. The client presents **Claude Code's standard `stream-json` and Codex's `exec --json` events**:
commands, read/write/edit actions, text, failures and results are displayed as a
native timeline. JSON envelopes, hooks, signatures and thinking blocks are not
conversation content. Details show the command, file contents, before/after edit
and output in a separate full-height view. Hermes tool results receive the same
readable projection.

## Claude execution convention

Use the existing Claude CLI and Hermes's orchestration support. Before coding,
run `claude auth status` from the actual execution environment. This user's
expected result is `authMethod=claude.ai`, `subscriptionType=max`, with no API-key
source. Do not silently fall back to API billing.

For a headless coding task, use Claude's supported
`--output-format stream-json --verbose` options and retain stdout in a dedicated
absolute `claude-<task>.jsonl` file. Keep normal permission controls. Include that
absolute log path in Hermes's visible conversation/tool result, including when a
Hermes child owns execution, so the phone can discover it. Use a path without
spaces for this initial discovery implementation. This is an output convention,
not a wrapper around Claude or another execution service. The phone reads only
referenced files through Hermes's authenticated `/api/fs/download` endpoint.

The reader requests one-megabyte byte ranges, appends new bytes while open (five
seconds between refreshes), tolerates an incomplete final JSON line, and parses
off the UI thread. Initial files are capped at 32 MiB. It does not discover every
Claude process on the Mac, reconstruct absent logs, or provide native nested CLI
approvals. Runs without a referenced standard log retain ordinary Hermes tool
visibility. Codex uses its documented `thread`, `turn`, and `item` event records;
item updates replace existing actions by ID. This is a presentation adapter, not
terminal-text scraping or another execution backend. Commands, file changes,
agent text, MCP calls, searches, plans and failures are projected into the same UI.
Incremental reads refresh every five seconds while the activity view is open;
this is live polling, not a native nested-agent push stream.

## Codex execution convention

Hermes remains the general assistant with its existing model and runtime. Use
its bundled `codex` or `claude-code` skills and terminal/background-process tools
to delegate. Do not switch Hermes providers or runtime to expose coding activity.
The separately tested Codex-runtime profile was removed; no model picker was added.

Before launching Codex, run `/Users/anshu/.local/bin/codex login status` in Hermes's execution environment
and require `Logged in using ChatGPT`. Do not fall back to an API key. Use
`env -u OPENAI_API_KEY -u CODEX_API_KEY /Users/anshu/.local/bin/codex exec --json --sandbox workspace-write`
with the task and explicit working directory, retaining stdout in an absolute
`codex-<task>.jsonl` path. Reference the path immediately in the parent Hermes
conversation/tool arguments so activity can be opened before completion. Keep
normal sandbox and permission controls; inspect failures rather than retrying
with bypass flags. Codex's JSON output does not attest billing itself; the UI
must not infer subscription billing merely from its presence.

[Codex's supported structured event stream](https://developers.openai.com/codex/noninteractive/)
is the source contract. Stock Hermes currently exposes the terminal invocation,
not these nested CLI items, so a small native presentation adapter is necessary
for this delegation path. No Hermes fork, new agent server, or custom process
runner is involved.

## Authentication finding on this Mac

On 2026-10-05, the actual redesign log
`~/.hermes/cache/scratch/squircle-redesign/claude-implementation.jsonl` identified
Claude Code 2.1.289, session `cf8e1749-c37e-483c-85a3-2da2ff0f0bd9`,
`apiKeySource=ANTHROPIC_API_KEY`; its result reported $11.7172548. This is the CLI's
reported API cost, not an independently audited invoice. The parent Hermes
session used `openai-codex` with `subscription_included`.

The shell exported `ANTHROPIC_API_KEY`, overriding an existing valid Max login.
Claude's supported user settings now set `env.ANTHROPIC_API_KEY` to an empty
string. Other settings and shell API access are preserved; the prior settings
were backed up in `~/.claude/settings.before-squircle-subscription.json`.
A fresh real Claude request succeeded with startup `apiKeySource=none`; separately,
`claude auth status` executed by the running stock Hermes returned `claude.ai`
and `max`. This applies to new Claude processes. The old run's API label remains
historically accurate; changing settings cannot undo its cost.

Primary reference: [Anthropic's API-key precedence guidance](https://support.claude.com/en/articles/12304248-manage-api-key-environment-variables-in-claude-code).

## App visibility

The thread's iPhone button opens the Mac catalog's actual published simulator
capture and displays its timestamp. After UI work, agents must capture and
publish current pixels using the existing `squircle app preview` workflow.
This is a capture, not a live video feed or remote simulator control. Existing
builds and diagnostics remain in their secondary sheet.

On this Mac, use `/Users/anshu/.local/bin/codex` (0.159.0). Hermes’s login shell
resolves an older Homebrew installation first; that binary rejects the current
Codex configuration. The explicit current executable preserves user settings
and subscription login without altering global shell configuration.

The installed **user copies** of Hermes's `claude-code` and `codex` skills now
contain these conventions; each previous file is retained alongside it as
`SKILL.before-squircle-visibility.md`. Hermes's installed source is unmodified.
No experimental Claude provider was installed. Default Hermes remains
`gpt-6.1-sol` / `openai-codex` with its general-assistant tool loop.
