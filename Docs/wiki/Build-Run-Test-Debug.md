# Build, run, test, and debug

Run these examples from the sourcekit-bsp repository root. Set the application
project directory and the server executable first:

```sh
bsp_project=/absolute/path/to/HelloProject
bsp_server=/absolute/path/to/sourcekit-bsp
xcrun simctl list devices available
bsp_destination='id=SIMULATOR-UUID'
```

Replace `SIMULATOR-UUID` with an available ID. Run/test/debug require a runnable
destination; generic destinations support compilation only.

## Compile and run

```sh
python3 Scripts/bsp_client.py --server "$bsp_server" --project "$bsp_project" \
  --method buildTarget/compile --target Hello --destination "$bsp_destination"

python3 Scripts/bsp_client.py --server "$bsp_server" --project "$bsp_project" \
  --method buildTarget/run --target Hello --destination "$bsp_destination"
```

`compile` streams Xcode output and uses `build-for-testing` for test bundles.
`run` launches an existing product; use the same configuration, destination, and
DerivedData as the compile request.

Run reports configuration lookup, simulator readiness, installation, and launch
through `build/taskStart`, `build/taskProgress`, and `build/taskFinish`. Each
stage also appears in `build/logMessage`. Notifications and the result preserve
the request's `originId`.

In vscode-bsp, the Run notification shows the current stage. The
`vscode-bsp-log` output channel keeps the stage history and final status.
Simulator success means that the app launched; the server does not monitor
its lifetime or stream app logs. A macOS Run completes when the app exits.

## Test

```sh
python3 Scripts/bsp_client.py --server "$bsp_server" --project "$bsp_project" \
  --method buildTarget/test --target HelloTests --destination "$bsp_destination"
```

Choose targets with `canTest: true`. `xcodebuild test` builds dependencies and
runs each selected test bundle; no separate compile request is needed.

To select a test suite or case, supply Xcode test-filter arguments:

```sh
python3 Scripts/bsp_client.py --server "$bsp_server" --project "$bsp_project" \
  --method buildTarget/test --target HelloTests --destination "$bsp_destination" \
  --build-setting=-only-testing:HelloTests/HelloTests
```

For several test targets, use `--params` with a `targets` array containing IDs
returned by `workspace/buildTargets`. Filters must refer to those targets.
To set `-resultBundlePath` explicitly, request one target per call. Otherwise,
Xcode writes result bundles under the selected DerivedData directory.

`environmentVariables` reaches Xcode and the test runner; `workingDirectory`
applies to Xcode, not the simulator app. These fields are server extensions.
Logs stream during execution; structured test results arrive after each target completes.

### Test discovery and selection

Xcode test bundles have the standard `test` tag. SourceKit-LSP uses this tag to
find XCTest and Swift Testing functions through `textDocument/tests` version 2.
`buildTarget/sources` identifies which target owns each source file.

Test targets advertise this optional extension in their `sourceKit` data:

```json
{
  "toolchain": "file:///Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain",
  "testDiscovery": {
    "provider": "sourcekit-lsp",
    "version": 1,
    "selectionDataKind": "sourcekit-test-selection"
  }
}
```

A client that supports the extension can send this `buildTarget/test` payload.
Use the target URI from `workspace/buildTargets`:

```json
{
  "targets": [{"uri": "xcode:///project/Hello.xcodeproj/HelloTests"}],
  "originId": "selected-test-1",
  "arguments": ["-configuration", "Debug", "-destination", "id=SIMULATOR-UUID"],
  "dataKind": "sourcekit-test-selection",
  "data": {
    "tests": [{
      "target": {"uri": "xcode:///project/Hello.xcodeproj/HelloTests"},
      "id": "HelloTests/example()",
      "style": "swift-testing"
    }]
  }
}
```

The identifier is the SourceKit-LSP test ID without its leading Swift module
prefix. Keep function parentheses and argument labels. Supported styles are
`XCTest` and `swift-testing`. Clients expand suites into their selected functions;
parameterized functions run all their arguments. IDs are scoped to a target.

The server converts selections into Xcode filters using the actual target name.
Empty, malformed, unsupported, or conflicting selections fail. A selected
function without a result also fails. Selection never falls back to a whole-target
run. Do not combine this payload with `-only-testing`, `-skip-testing`, or a test
plan. These metadata and selection fields are extensions, not standard BSP.

Both `test-start` and `test-finish` include an optional `testId` extension field
from the result bundle. It uses the same target-scoped identifier as discovery,
so clients can update the original test node without comparing display names.
Other clients can ignore the field and display standard reports.

## Debug

```sh
python3 Scripts/bsp_client.py --server "$bsp_server" --project "$bsp_project" \
  --method debugSession/start --target Hello --destination "$bsp_destination" \
  --breakpoint /absolute/path/to/HelloProject/Hello/HelloApp.swift:14
```

The server builds the app and returns an LLDB DAP endpoint. The probe connects,
checks the breakpoint and stack, then terminates the app. Use an executable line
for `--breakpoint`, or omit it to break at `main`.

Use `--destination platform=macOS` for a Mac app. Physical-device debugging is
not implemented.

## Results and cancellation

Compile/test/run results use BSP status `1` for success and `2` for failure.
The Python client exits with a nonzero status on failure. Add `--verbose` for the
full protocol trace, or `--timeout 600` for a longer request timeout.

Persistent clients can cancel requests with `$/cancelRequest`; cancellation
returns error `-32800` and compile/test/run task status `3`. The probe has no
interactive cancellation control.

### Test reports

Test requests send standard BSP task notifications. Each target starts a child
`test-task`. After Xcode finishes, the server reads its `.xcresult` and sends a
`test-start`/`test-finish` pair for each test, then a target `test-report` with
outcome counts and execution time in milliseconds when available. These case
notifications replay recorded results; they do not mark live test start times.

Reports support XCTest and Swift Testing. Each case uses the final result across
repetitions and devices. Expected failures count as passed, with an explanatory
message. Parent task IDs and `originId` link reports to the test request.
Clients can display these JSON payloads without parsing Xcode output.

Result bundles are saved under the effective DerivedData directory in `Logs/Test`,
unless the request supplies `-resultBundlePath`. A missing or unreadable report
produces a warning; build failures and cancellation still finish active tasks.
