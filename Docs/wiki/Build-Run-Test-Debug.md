# Build, run, test, and debug

Run these examples from the sourcekit-bsp repository root. Set the application
project directory and the server executable first:

```sh
bsp_project=/absolute/path/to/HelloProject
bsp_server=/absolute/path/to/sourcekit-bsp
xcrun simctl list devices available
bsp_destination='id=SIMULATOR-UUID'
```

Replace `SIMULATOR-UUID` with an available simulator ID. A physical-device ID
cannot select a simulator. A generic destination is suitable for compilation
but cannot run an application or execute tests.

## Compile and run

```sh
python3 Scripts/bsp_client.py --server "$bsp_server" --project "$bsp_project" \
  --method buildTarget/compile --target Hello --destination "$bsp_destination"

python3 Scripts/bsp_client.py --server "$bsp_server" --project "$bsp_project" \
  --method buildTarget/run --target Hello --destination "$bsp_destination"
```

`compile` invokes Xcode with a matching scheme. For test bundles it uses
`build-for-testing`. Output is sent through `build/logMessage`, with task start
and finish notifications.

`run` launches an existing product. Use the same configuration, destination, and
DerivedData as the compile request. It reports an error when the product is
missing or installation/launch fails. A completed JSON-RPC exchange alone does
not mean success: inspect the result's `statusCode`.

## Test

```sh
python3 Scripts/bsp_client.py --server "$bsp_server" --project "$bsp_project" \
  --method buildTarget/test --target HelloTests --destination "$bsp_destination"
```

The server validates every requested target and runs `xcodebuild test` for each
selected test bundle. It deduplicates repeated targets and builds dependencies
before execution. Choose targets with `canTest: true`.

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

`environmentVariables` and `workingDirectory` are server extensions. Environment
variables reach Xcode and the test runner. The working directory applies to the
Xcode process, not to an application inside the simulator. Test output is streamed;
individual test events and structured test-count reports remain unimplemented.

## Debug

```sh
python3 Scripts/bsp_client.py --server "$bsp_server" --project "$bsp_project" \
  --method debugSession/start --target Hello --destination "$bsp_destination" \
  --breakpoint /absolute/path/to/HelloProject/Hello/HelloApp.swift:14
```

Use an executable source line for the breakpoint. Without `--breakpoint`, the
probe uses `main`. The server builds the application and returns an LLDB DAP
endpoint. The client must then connect over DAP; a BSP response alone does not
start the complete debugger interaction.

The Python probe checks a breakpoint, threads, and stack frames, then terminates
the debuggee when it disconnects. Use `--destination platform=macOS` for a macOS
application. Physical-device debugging is not implemented.

## Results and cancellation

Compile/test/run results use BSP status `1` for success and `2` for failure.
The Python client exits with a nonzero status on failure. Add `--verbose` for the
full protocol trace, or `--timeout 600` for a longer request timeout.

A persistent client can cancel an active request by sending `$/cancelRequest`
with the request ID. Compile/test/index work propagates cancellation to Xcode.
The cancelled request returns JSON-RPC error `-32800`; compile and test tasks
also finish with status `3`. The command-line probe does not provide an
interactive cancellation control.
