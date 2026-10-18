# Security

Squircle is early-alpha software for one person's own Mac and iPhone. It has
had internal code reviews but no independent security audit.

## Reporting a vulnerability

Please report privately through GitHub's **Report a vulnerability** button on
the repository's Security tab, not in a public issue. Include what you found,
how to reproduce it and what an attacker gains. Expect a reply within a week or
so; this is a one-person project and there is no bounty.

If you find a real credential in this repository or its history, report it the
same way and don't use it.

## Trust boundaries

**The Mac is trusted.** The Squircle service, T3, Xcode and the coding agents
all run as your user and can read what you can. Squircle adds no sandbox
around agents; T3's approval modes are what limit them.

**T3 Code.** Squircle trusts your T3 server and uses its normal APIs with its
own paired session (scoped to orchestration read/operate). It reads T3's
`state.sqlite` read-only for tool details T3 doesn't stream, and never writes
to it.

**The network.** The service listens on loopback (`127.0.0.1:8787`) by
default. The CLI and T3 pairing send credentials over plain HTTP only to
loopback or Tailscale addresses (whose traffic Tailscale encrypts) and
require HTTPS everywhere else; redirects are never followed. The phone talks
to T3 and the service over HTTPS. Reaching them from the phone (for example
with Tailscale Serve) is your setup: Squircle never installs or configures
Tailscale, TLS or a VPN, and `--public-url` does not turn on TLS by itself.

**Credentials.** `squircle init` creates separate control and diagnostics
tokens in the private data directory (files are created owner-only).
Diagnostic tokens can only upload logs and crashes. Install links are
expiring tickets (an hour by default); treat a link as a credential until it
expires.

**Your personal app build.** The build copies the phone's connection file
(T3 session and Squircle tokens) into the app so it can start without a
pairing screen, and the app then keeps them in the iPhone Keychain. Anyone
with that IPA has those credentials: never share or publish it. Re-pair and
rebuild if it leaks.

**The debug overlay.** Device builds that Squircle signs for other apps get an
injected `SquircleOverlay.framework`, and are re-signed with a Keychain group
shared with Squircle so the overlay can use Squircle's paired connection. Any
code in such an app (including its third-party dependencies) can therefore
read that connection. This was accepted on purpose for the maintainer's own
apps; don't build untrusted projects with the overlay (`--no-overlay` opts
out). The overlay is never added to App Store exports or simulator builds.

**The history subagent's guard.** The app agent's `squircle:history` subagent
is limited by a Claude Code hook (`squircle agent guard`) to a fixed list of
read-only Squircle lookups in Bash. This is workflow enforcement inside Claude
Code, not an operating-system sandbox: its Read, Grep and Glob tools can still
read any file the agent's process can.

**Notifications.** Your APNs key stays in the data directory on the Mac;
notifications go straight from the Mac to Apple.

## Supported versions

Only the latest commit on `main`. There are no releases yet.
