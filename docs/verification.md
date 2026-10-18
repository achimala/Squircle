# Verify Squircle

Squircle is a Rust CLI and local service. The commands below run on your Mac and
exercise the build, install and diagnostics path with the bundled sample app.
Keep the service running in a separate terminal. Squircle does not install
itself as a login service and does not configure Tailscale or HTTPS.

For the iPhone app's own setup see the [app guide](../app/Squircle/README.md).

## Build and inspect

```sh
./scripts/cargo-local build
export SQUIRCLE_DATA_DIR="$PWD/.squircle"
./target/debug/squircle doctor --json
./target/debug/squircle init --json
./target/debug/squircle serve
```

Use another terminal with the same `SQUIRCLE_DATA_DIR` (or `--data-dir`). The default
service address is `http://127.0.0.1:8787`.

## Verify the build runner without signing

```sh
./target/debug/squircle build start \
  --project examples/SquircleProbe/SquircleProbe.xcodeproj \
  --scheme SquircleProbe --mode simulator --request-id probe-simulator-1 --json
./target/debug/squircle build wait BUILD_ID --timeout 120 --json
./target/debug/squircle build log BUILD_ID --json
```

The service assigns BUILD_ID. Reusing the request ID with the same arguments
returns the same job. A wait timeout leaves it running. `build cancel BUILD_ID`
requests cancellation. Simulator builds cannot produce an OTA install link.

## Archive and export for a registered iPhone

The sample's project and `ExportOptions.plist` name a signing team; set them to
your own team first. Signing certificates, profiles and device registration
must be available to the user the service runs as.

```sh
./target/debug/squircle build start \
  --project examples/SquircleProbe/SquircleProbe.xcodeproj \
  --scheme SquircleProbe \
  --export-options examples/SquircleProbe/ExportOptions.plist \
  --request-id probe-device-1 --json
./target/debug/squircle build wait BUILD_ID --timeout 300 --json
```

If Xcode needs to create/update signing assets, explicitly add
`--allow-provisioning-updates` and a new request ID. The flag uses your existing
Xcode account and may contact Apple's developer services. Squircle does not add
accounts or register devices. An existing signed IPA can instead be copied into
the store with `build import --ipa /absolute/path/App.ipa`.

## Publish the installation link

Configure trusted HTTPS routing to this local service using your own Tailscale
setup. Squircle does not do that for you. Restart `serve` with:

```sh
./target/debug/squircle serve --public-url https://YOUR-MAC-HOSTNAME
./target/debug/squircle install-link BUILD_ID --json
```

Open `page_url` on the phone with Wi-Fi disabled and Tailscale connected. Confirm
installation, then open Squircle Probe manually. Treat the expiring link as a
credential. The installer must reach the manifest and IPA independently of the
browser. A fetched page or link is not proof of installation.

## Probe diagnostic test setup

Configure Squircle Probe with the same HTTPS origin and the diagnostic upload
token, revealed deliberately with:

```sh
./target/debug/squircle auth show --scope diagnostics --json
```

Use the upload token for the diagnostic-only Probe. Squircle-built Probe apps embed their build
ID. Send a log, test offline buffering/retry, then deliberately crash and relaunch.

```sh
./target/debug/squircle logs BUILD_ID --json
./target/debug/squircle crashes BUILD_ID --json
./target/debug/squircle build status BUILD_ID --json
```

Crash capture/upload is distinct from symbolication. Save an event's `message`
as an Apple-text `.crash` file and use the retained dSYM:

```sh
./target/debug/squircle symbolicate --report report.crash \
  --dsym /path/from/build/status/SquircleProbe.app.dSYM --json
```

This invokes the selected Xcode's `symbolicatecrash`. Inspect the resulting app
frames; command completion alone does not prove symbol resolution. JSON `.ips`
is unsupported. See [Probe instructions](../examples/SquircleProbe/README.md)
for its test crash workflow.

## Limits and lifecycle

JSON output is versioned. Exit code 0 means the command succeeded; code 2 means
invalid input, failed operation or a wait that did not reach success. `build start`
success means accepted, not built. Errors name their code and next step.

One build runs at a time, with up to 16 queued/running and a 30-minute runner
deadline. Control and diagnostic bearer tokens are separate. Install links last
one hour by default, up to one day, and permit retries until expiry. Diagnostic
uploads are limited to 1 MiB each and 64 MiB per build; the CLI reads bounded pages.
There is no automatic retention deletion or log rotation yet: monitor disk space.

Disconnecting the CLI/phone does not cancel a service-owned job. A graceful service
shutdown cancels active jobs. After a crash/restart, unfinished records become
interrupted; inspect any remaining processes/artifacts before explicitly retrying.
No claim is made that active Xcode processes resume after a service restart.

Build records capture the Git revision and dirty state at submission when
available. Builds use the working tree, which can change while queued; this is
provenance metadata, not a source snapshot or reproducibility guarantee.
