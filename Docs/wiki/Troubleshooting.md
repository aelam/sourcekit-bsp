# Troubleshooting

## The server appears idle

sourcekit-bsp communicates over stdin/stdout. It waits for a client to send
`build/initialize` with `rootUri`. Running the executable alone does not start a
build. Use `Scripts/bsp_client.py` to initialize a connection and call a method.
Raw JSON piped to stdin is insufficient: messages need JSON-RPC framing.

## A source change has no effect on the running server

Check the executable selected in `.bsp/sourcekit-bsp.json`. A server
built with `swift build` is under `.build`; an Xcode build is under DerivedData.
Rebuild the selected copy and restart the client connection. Use the same path
in the Python client's `--server` option.

Project refresh also requires a client that sends file notifications. The server
advertises watcher patterns but does not watch the filesystem itself. To refresh
explicitly, send `workspace/reload` as a request with an ID.

## Definition lookup or references do not work

1. Confirm that the editor's Swift extension and SourceKit-LSP are running.
2. Use `workspace/buildTargets` and `buildTarget/sources` to check project discovery.
3. Confirm that the source file has compiler options from `textDocument/sourceKitOptions`.
4. Enable background preparation/indexing or run a full indexing pass.
5. Check that the editor and BSP process use the same Xcode toolchain.

```sh
xcrun sourcekit-lsp debug index --project /absolute/path/to/HelloProject
```

A BSP build UI alone does not implement definition lookup. SourceKit-LSP performs
that operation, using settings and index data provided through the build system.

## "Cannot call write after a stream was destroyed"

This message means the client tried to use a closed connection. It is a symptom,
not the underlying server error. Check the earlier SourceKit-LSP output, the BSP
executable path, the selected toolchain, and `/tmp/sourcekit-bsp.log`. Reproduce
initialization with the Python client and `--verbose` to inspect the protocol.

## "Unable to find a destination"

A stored device ID may no longer exist or may refer to a physical device.
List current simulators and select one compatible with the target:

```sh
xcrun simctl list devices available
xcodebuild -project /path/to/Hello.xcodeproj -scheme Hello -showdestinations
```

Use `-workspace` instead of `-project` for a workspace. Compilation can use a
generic simulator destination, but run/test/debug need a runnable destination.
The test command selects an available simulator when none is supplied; specify
an ID to control its device and runtime.

## Compile succeeds but run fails

`buildTarget/run` uses an existing product. Compile with the same configuration,
destination, and DerivedData path before running. Inspect the result's
`statusCode`; a response can report failure even when the protocol exchange
completed normally. `buildTarget/outputPaths` shows the default product root,
not paths selected by per-request overrides.

## Tests fail or stop during launch

Select a target with `canTest: true`, such as `HelloTests`, and use a concrete
simulator destination. `buildTarget/test` builds the test bundle itself; it does
not require a guessed `.xctestrun` path or a separate compile request.

Inspect `build/logMessage`, `build/taskFinish`, and the Xcode result bundle path
printed in the log. A paused debug session for the same application can interfere
with installation or launch. End that session or select another simulator.

For an XCTest/Swift Testing assertion failure, the BSP test result has status
`2`. Cancellation returns JSON-RPC error `-32800`. A later request can retry.
Individual test reports are not yet available through BSP.

## Diagnostics and validation

Server logs: `/tmp/sourcekit-bsp.log`.

```sh
python3 Scripts/bsp_client.py --server /absolute/path/to/sourcekit-bsp \
  --project /absolute/path/to/HelloProject --method workspace/buildTargets --verbose

swift run XcodeProjectCLI resolveProject --workspace-folder /absolute/path/to/HelloProject
```

Use `--developer-dir /Applications/Xcode.app/Contents/Developer` on the Python
client when the default Xcode differs from the intended one. Use target IDs from
`workspace/buildTargets`, rather than constructing them from directory names.
