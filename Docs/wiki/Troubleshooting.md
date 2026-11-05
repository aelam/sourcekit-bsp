# Troubleshooting

Server logs: `/tmp/sourcekit-bsp/<PID>.log`. Each process keeps up to three files,
rotating at 5 MiB. Older files use `<PID>.1.log` and `<PID>.2.log`.
The previous shared `/tmp/sourcekit-bsp.log` is no longer written by new servers.

Normal logs include startup summaries, requests that take at least one second,
warnings, and errors. Add `--debug` to the server's `.bsp/*.json` arguments or set
`BSP_DEBUG=1` in its environment to enable request summaries. `BSP_DEBUG=0` disables
the environment flag; `--debug` takes precedence. Internal messages are limited
to 4096 characters. Build progress, diagnostics, and raw build logs are unchanged.

To inspect the connection:

```sh
python3 Scripts/bsp_client.py --server /absolute/path/to/sourcekit-bsp \
  --project /absolute/path/to/HelloProject --method workspace/buildTargets --verbose
```

Use `--developer-dir /Applications/Xcode.app/Contents/Developer` to select Xcode.
Use target IDs returned by `workspace/buildTargets` in protocol requests.

## The server appears idle

The server waits for `build/initialize` with `rootUri` over stdin/stdout.
Use a BSP client; raw JSON lacks the required message framing.

## Server changes have no effect

Rebuild the executable selected in `.bsp/sourcekit-bsp.json` and restart the
client connection. `swift build` does not update an Xcode-built executable.
Use that same executable with the probe's `--server` option.

For application project changes, the client must send file notifications or
`workspace/reload` with a request ID.

Schemes named `sourcekit-bsp-*.xcscheme` under an Xcode project's
`xcshareddata/xcschemes/` directory are generated build helpers. Their file
events do not reload the workspace. Changes to user schemes and project
configuration still trigger reloads.

## Definition lookup or references fail

1. Check that the Swift extension and SourceKit-LSP are running.
2. Check project discovery with `workspace/buildTargets` and `buildTarget/sources`.
3. Check per-file compiler arguments with `textDocument/sourceKitOptions`.
4. Enable background indexing or run a full indexing pass with the same Xcode toolchain:

```sh
xcrun sourcekit-lsp debug index --project /absolute/path/to/HelloProject
```

## "Cannot call write after a stream was destroyed"

The server connection closed. Check earlier SourceKit-LSP output and the server
log for the cause, then verify the executable and toolchain with the probe above.

## "Unable to find a destination"

Replace the stored device ID with an available destination:

```sh
xcrun simctl list devices available
xcodebuild -project /path/to/Hello.xcodeproj -scheme Hello -showdestinations
```

Use `-workspace` for a workspace. Generic destinations support compilation;
run/test/debug need a runnable device. Tests select an available simulator if
no destination is supplied.

## Compile succeeds but run fails

Compile and run with the same configuration, destination, and DerivedData path.
Check `statusCode` for failure. `buildTarget/outputPaths` reports the default
product root, not per-request overrides.

## Tests fail during launch

Use a target with `canTest: true` and a concrete destination. The test request
builds its dependencies. Inspect Xcode logs and the result bundle path reported
there. End any paused debug session for the same app, or use another simulator.

For project discovery errors, inspect the resolved project:

```sh
swift run sourcekit-bsp xcode-project resolve-project --workspace-folder /absolute/path/to/HelloProject
```

## Concurrent index preparation

Concurrent preparations of the same target share work while their build graph
and input versions match. Watched file events, graph reloads, and build completion
advance these versions. Clients must report saved input changes through
`workspace/didChangeWatchedFiles`, including content edits that do not change target
membership. Completed preparations are not cached. Cancelling one request leaves
the shared build running for other requests.
