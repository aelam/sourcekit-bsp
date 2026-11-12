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

Run streams application output through standard `build/logMessage` notifications
with the request's `originId`. In vscode-bsp, these messages appear in the run
task output and Build Output. Run completes when the application exits. Cancel
the request to stop the application and close its console connection.

The server keeps `simctl launch --console-pty` or `devicectl device process launch
--console` connected for the application lifetime. The launch deadline does not
limit how long the application can run. macOS applications use local pipes.

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

Xcode test bundles and root SwiftPM test targets have the standard `test` tag. SourceKit-LSP uses this tag to
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

SwiftPM also supplies `testDiscovery.moduleName`, the target's exact Swift module
name. SourceKit-LSP can return IDs with or without that prefix. Clients remove
only the advertised prefix and preserve dots within test names. If the selected
Swift toolchain has no SourceKit-LSP executable, SwiftPM omits this metadata.

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

For Xcode, the server converts selections into filters using the actual target
name. For SwiftPM, it builds anchored filters from the target's Swift module and
the selected function IDs. It escapes IDs before use in a regular expression.
Empty, malformed, unsupported, or conflicting selections fail. A selected
function without a result also fails. Selection never falls back to a whole-target
run. Do not combine this payload with `-only-testing`, `-skip-testing`, or a test
plan. SwiftPM selections cannot be combined with command-line test filters.
These metadata and selection fields are extensions, not standard BSP.

Both `test-start` and `test-finish` include an optional `testId` extension field
from the execution report. Xcode reads its result bundle; SwiftPM reads XCTest
output and Swift Testing events. The field uses the same target-scoped identifier as discovery,
so clients can update the original test node without comparing display names.
Other clients can ignore the field and display standard reports.

## Debug

```sh
python3 Scripts/bsp_client.py --server "$bsp_server" --project "$bsp_project" \
  --method debugSession/start --target Hello --destination "$bsp_destination" \
  --breakpoint /absolute/path/to/HelloProject/Hello/HelloApp.swift:14
```

`debugSession/start` returns a DAP endpoint without building, installing, or
launching the app. After connecting, send `initialize`, then `launch` or `attach`.
The server prepares the selected target when it receives that DAP request.

DAP `launch` uses existing products unless the resolved Build Context requests a
build. Without Build Context, compile the target first. The probe sends `launch`,
checks the breakpoint and stack, then terminates the app. Use an executable line
for `--breakpoint`, or omit it to break at `main`.

DAP `attach` finds an existing process for the selected target and destination.
It does not build, install, or launch the app. If exactly one process matches, the
server uses it automatically. If several processes match, supply DAP `pid`; the
PID must match the selected target. Attach requires a resolved debug Build Context
and supports iOS simulator apps, physical iOS devices, and macOS executables.
Test Attach is not supported.

For a physical iOS device, the server reads the installed app and running process
reports from `devicectl`. It matches the exact bundle identifier and executable
path, then rechecks the PID before attaching. The matching local build product is
required for debug symbols. Attach does not install that product or launch the app.
Disconnecting leaves the existing app running.

Use `--destination platform=macOS` for a Mac app or `--destination id=DEVICE-UDID`
for an iPhone. The server uses the project's signing settings through
`xcodebuild`. The device must be paired, unlocked, and have Developer Mode enabled.

For DAP `launch` on iOS devices, the server installs the app with `devicectl` and launches it
with `--start-stopped`. A server-side DAP relay supplies LLDB's `device select`
and `device process attach` commands and the local executable path. The client
sends `launch` to the returned DAP address. This requires an Xcode LLDB with these
device commands and `lldb-dap` support for `attachCommands`.

Launch preparation emits BSP task and log notifications. Preparation errors and
debugger output also arrive through DAP. Unused endpoints expire. If launch
preparation created a suspended app, cleanup stops that app when attachment fails.
An Attach session detaches from its existing process during cleanup.

### Application console

Debug launches stream application output through standard DAP `output` events,
which appear in the client's Debug Console. The server captures output from
launch onward, including output written before the debugger connects. Build and
launch progress remains in BSP `build/logMessage` notifications. The server keeps
up to 4 MiB of startup output and reports overflow. Disconnecting closes the
console helper; it does not signal an application that the debugger detached from.

For applications launched by the server, the default environment includes
`OS_ACTIVITY_DT_MODE=enable` and `OS_ACTIVITY_MODE=debug`. These are the Darwin
logging settings used by LLDB to mirror `NSLog`, `Logger`, and `os_log` messages
to standard error, including debug-level messages. `NSUnbufferedIO=YES` reduces
standard-stream buffering. Explicit scheme and request environment values take
precedence; `IDE_DISABLED_OS_ACTIVITY_DT_MODE` disables the default mirror setting.

Unified logs appear as text. Structured subsystem/category filtering and exact
Xcode Console parity are not provided. An Attach request for an application
started elsewhere cannot retroactively connect its standard streams or change
its launch environment. Device log delivery still needs validation on hardware
with the selected Xcode and iOS versions.

The iPhone path has automated command, protocol, and cleanup tests. Breakpoints,
stepping, and variables still need validation on a physical device. Other physical
Apple device platforms are not enabled for debugging.

### Debug unit tests on an iOS simulator

Debug sessions use existing products. The selected configuration, destination
and DerivedData directory must match the products that are already built. Missing
products produce an error; the server does not silently build them.

Request `debugSession/start` with an app-hosted unit test target such as
`HelloTests` and a concrete iOS simulator destination, then send DAP `launch`.
The server resolves the
existing test host and bundle, installs the host, and launches it with XCTest's
bundle injection environment. The process waits for the debugger before
executing tests. Use `stopOnEntry: false` in the launch request. Set breakpoints, then send `configurationDone` to start the
tests.

For test debug sessions, the server resolves settings with
`SWIFT_DEBUG_INFORMATION_VERSION=dwarf4` unless the request already sets that
value. Clients that compile before test debugging should pass the same setting.
This makes Swift write macro expansion sources to files that LLDB-DAP can open
when stepping through `@Test` wrappers. Ordinary builds and test runs keep their
existing settings.

With Xcode 26.6, a breakpoint directly on `#expect` can still show disassembly
because the compiler assigns part of the expansion to `<stdin>` without a source
line. Put the breakpoint on an ordinary statement before the assertion to inspect
its inputs. After the test returns, stepping can enter generated wrappers or the
Testing runtime.

This runs the entire target, including XCTest and Swift Testing cases. UI tests,
non-hosted test bundles, physical devices, and test filters are not supported by
this debug path. It does not run the scheme's Test Plan or create an `.xcresult`
report. Use `buildTarget/test` for normal test reports. The client does not need
to know the test host, injection library, or simulator commands.

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
