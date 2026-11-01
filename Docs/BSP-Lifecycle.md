# BSP lifecycle

## Project changes

The initialization response advertises file watchers. The client must watch those
paths and send `workspace/didChangeWatchedFiles` notifications. SourceKit-LSP can
use these watchers; a standalone BSP client must implement this step.

```json
{
  "jsonrpc": "2.0",
  "method": "workspace/didChangeWatchedFiles",
  "params": {
    "changes": [{ "uri": "file:///project/App/NewFile.swift", "type": 1 }]
  }
}
```

Event types are `1` for creation, `2` for changes, and `3` for deletion. The server
reloads Xcode project files, workspace files, schemes, build configuration files,
and `.sourcekit-bsp/project.json`. It also reloads when a source file is created
or deleted. Ordinary source edits do not reload the project. Generated files in
the project's DerivedData directory and `.build` directories are ignored.

A successful reload sends `buildTarget/didChange`. If parsing fails during a
save, the server keeps the previous project state and reports the error. A later
file notification or explicit reload can retry the operation.

To request a reload explicitly, send a **request** with an ID:

```json
{ "jsonrpc": "2.0", "id": 7, "method": "workspace/reload", "params": {} }
```

`workspace/waitForBuildSystemUpdates` waits for queued file notifications and the
current reload. Requests received after a file notification wait for that
notification to finish.

## Cancellation

Send the ID of the request to cancel:

```json
{
  "jsonrpc": "2.0",
  "method": "$/cancelRequest",
  "params": { "id": 8 }
}
```

The connection cancels the matching task. Compile and test requests propagate
cancellation to `xcodebuild`; index preparation also propagates cancellation.
Cancellation bypasses the file notification queue. The cancelled request returns
JSON-RPC error `-32800`. Compile and test tasks also send `build/taskFinish` with
status `3` (cancelled). An unknown or completed request ID has no effect.

## Running Xcode tests

Use targets whose `canTest` capability is `true`, such as `HelloTests` or
`HelloUITests`. The server validates all targets before it starts execution.
It runs `xcodebuild test` for each selected target, with a valid test scheme and
a target filter. A separate compile request is not required.

```shell
python3 Scripts/bsp_client.py \
  --server /path/to/Xcode/Build/Products/Debug/sourcekit-bsp \
  --project /path/to/HelloProject \
  --method buildTarget/test \
  --target HelloTests \
  --destination 'id=SIMULATOR-UUID'
```

Use `xcrun simctl list devices available` to find a simulator ID. A generic
simulator destination cannot execute tests. If no destination is supplied, the
server selects an available simulator for the target, or the local Mac for a
macOS target. Specify a destination to control the device and runtime version.

The request's `arguments` array accepts Xcode options such as `-configuration`,
`-derivedDataPath`, `-only-testing:HelloTests/Suite/test`, and `-skip-testing:...`.
Filters only select tests within the requested targets. When requesting multiple
targets, omit `-resultBundlePath`; Xcode creates a result bundle for each run in
DerivedData. To set that path explicitly, request one target at a time.

The optional `environmentVariables` and `workingDirectory` fields are server
extensions. Environment variables are passed to Xcode and forwarded to the test
runner through `TEST_RUNNER_` variables. The working directory controls the Xcode
process; it does not set the working directory inside a simulator application.

The server sends task start/finish notifications and streams Xcode output through
`build/logMessage`. The test result contains `statusCode: 1` on success or
`statusCode: 2` on failure, and preserves `originId`. Individual test events and
structured test-count reports are not implemented yet.
