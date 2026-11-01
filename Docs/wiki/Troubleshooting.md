# Troubleshooting

Server logs: `/tmp/sourcekit-bsp.log`. To inspect the connection:

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
swift run XcodeProjectCLI resolveProject --workspace-folder /absolute/path/to/HelloProject
```
