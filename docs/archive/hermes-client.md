# Native Hermes client protocol

> **Archived.** Superseded: the Hermes client was removed in the T3 migration (2026-10-05). Kept as a record; nothing here runs today.

## Decision

The phone uses the WebSocket JSON-RPC protocol served by **unmodified `hermes
serve`**, the same backend used by Hermes Desktop. The previous Sessions/Runs
HTTP API was real Hermes, but was the wrong surface for an interactive companion:
it exposes shortened tool previews and does not supply Desktop's native request,
background-event and session-control behavior. There is no new coordinator,
timer service or coding-agent execution adapter. Version 8 reads referenced
Claude event logs for presentation; see [coding visibility](coding-visibility.md).

The installed protocol source is `tui_gateway/contracts/` and
`apps/shared/src/gateway-contract.generated.ts` in the independent Hermes
installation. This integration was checked against **v0.21.5+6977.gaf90026**.
Do not infer compatibility with every future Hermes release.

## Client behavior

| Hermes messages | Phone behavior |
| --- | --- |
| `message.start/delta/interim/complete`, errors | Streaming text and separate commentary segments; authoritative history reconciliation after completion |
| `tool.start/complete/generating`, terminal output | Concise action rows; full-height command, file, change and result views; errors and duration; output chunks accumulated |
| `reasoning.*`, `thinking.delta` | Collapsible detail supplied by Hermes |
| `subagent.*` | Hermes-provided child identities, progress and result details; open the native child conversation when an ID is supplied |
| `status.update`, notices, background/btw/review | Progress or conversation notices; replies remain subscribed after the initiating turn finishes |
| `session.control.update` | Goal, loop and heartbeat state, with native pause/resume/clear controls and slash-command entry |
| `approval`, `clarify`, `sudo`, `secret`, vault requests | Native response panels using the server's choices, request IDs, cancellation and replay state; masked credential input |
| `connection.request/update` | Native connector/catalog approval, required credentials, authorization links, skip and continue; server-owned settlement |
| Images and local-file links | Attachment buttons; authenticated stock file download and native Quick Look; remote URLs open normally |
| `todo.updated`, preview links, voice transcript | Visible todo state, tappable links and transcript text |
| Unknown session events | Readable labeled fields in detail, never silently discarded |

The compact WebSocket history omits most tool result bodies. The client uses
the stock Desktop `GET /api/sessions/{id}/messages` transcript, paging through
500-row pages and joining tool calls by their original IDs, to retain full saved
results. This is the existing Desktop server API, not a new endpoint.

`session.list/create/resume/history`, `session.events.since`, `prompt.submit`,
`prompt.interrupt`, `slash.exec`, `request.answer`, and `session.control` remain
stock operations. Sessions are created as `source=desktop`, with the selected
app's real directory. Desktop lists them in its ordinary session area; old
`api_server` chats remain accessible without rewriting their provenance.

The socket stays attached while the app is active. Reconnection reattaches live
sessions, replays missing events, restores open requests and uses a fresh snapshot
when the replay window or backend epoch changes. The client never resubmits an
unacknowledged prompt automatically. Mid-turn messages use Hermes's steering
behavior. Server history remains authoritative; local state holds app/session
associations and navigation only.

## Explicit boundaries

- Desktop GUI bridge requests (`preview.read/act`, `terminal.read`, `window.read`,
  `tour`) need an actual Desktop window. The phone declines with Hermes's
  non-owner response, so an attached Desktop renderer can handle them. It does
  not pretend to own the Mac browser or terminal. Desktop layout/pet/display
  operations remain Desktop features; unfamiliar notifications are inspectable.
- Hermes events alone do not include all nested CLI internals. Version 8 can
  read a referenced Claude `stream-json` log through the existing authenticated
  file API; it does not intercept execution, and Codex logs are not parsed.
- iOS can suspend its socket in the background. Hermes continues on the Mac;
  reopening catches up. Push notifications and iOS background execution are not
  supplied by this protocol migration.
- The installed Hermes has a **first-heartbeat-tick race**: its slash-worker
  watchdog can consume the first due tick into an undrained queue. Three live
  checks observed the missing first reply; longer checks delivered the second
  tick through the stock session-owner poller. No Hermes code was patched and
  no phone scheduler hides this behavior. Heartbeats also require the owning
  Hermes process; durable scheduling remains Hermes cron.
- Attachment preview and the published simulator capture are implemented; composer file/photo picking and the full
  Desktop settings, editor, browser, voice-call and operating-system UI are not
  part of this chat-message integration.

## This Mac

With the user's explicit approval, the existing Tailscale HTTPS **8444** route
now targets `127.0.0.1:9119` (`hermes serve`). Squircle remains on 8787 via 8443;
the existing 443 route is unchanged. No Tailscale management is embedded.
Hermes Desktop's **Mac Hermes** connection uses that same 8444 server and default
profile. The previous local connection is retained.

Stock basic/native authentication protects the server. Private configuration is
in ignored `.squircle/hermes-desktop.env` and `.squircle/client.json`; no credentials
are committed. The personal signed build adds `hermes_desktop_url`,
`hermes_desktop_token`, `hermes_desktop_refresh_token`, and `hermes_profile`.
The phone refreshes through stock `/auth/native/refresh` and stores renewed
credentials in its Keychain. Desktop's saved credential is Electron safeStorage
encrypted. TLS validation is unchanged.

The server is currently a detached stock process. Automatic Mac startup and
crash supervision remain unimplemented, as for the earlier server. To restart
manually from this repository with the private environment already configured:

```sh
set -a
source .squircle/hermes-desktop.env
set +a
hermes serve --host 127.0.0.1 --port 9119
```

The old HTTP server on 8642 is retained for rollback and any existing work; the
new personal client uses the native transport. Builds without the new desktop
configuration retain the legacy adapter for compatibility, but it does not offer
native message parity.
