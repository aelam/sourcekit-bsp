# Protocol support

The server implements a subset of BSP 2.2.0. Clients should check
`build/initialize` and target capabilities before offering an operation.

## Requests and notifications

| Method | Type | Behavior |
| --- | --- | --- |
| `build/initialize` | Client request | Load the project; return capabilities, index paths, and watchers |
| `build/initialized` | Client notification | Complete initialization |
| `build/shutdown`, `build/exit` | Client request / notification | Shut down services and exit |
| `workspace/buildTargets` | Client request | Return targets, capabilities, dependencies, and metadata |
| `buildTarget/sources` | Client request | Return sources, including Xcode synchronized folders |
| `textDocument/sourceKitOptions` | SourceKit extension request | Return per-file compiler arguments |
| `buildTarget/prepare` | SourceKit extension request | Prepare build inputs and index data |
| `buildTarget/compile` | Client request | Compile targets and stream logs |
| `buildTarget/run` | Client request | Install/launch an existing product |
| `buildTarget/test` | Client request | Build and run test bundles; return aggregate status |
| `debugSession/start` | Client request | Build and return an LLDB DAP connection for macOS/simulators |
| `buildTarget/outputPaths` | Client request | Return each target's default project product directory |
| `buildTarget/cleanCache` | Client request | Clear shared project products and indexes, not isolated target caches |
| `workspace/reload` | Client request | Reload state and emit target changes |
| `workspace/didChangeWatchedFiles` | Client notification | Process source/configuration file events |
| `workspace/waitForBuildSystemUpdates` | SourceKit extension request | Wait for pending updates; report reload errors |
| `buildTarget/didChange` | Server notification | Report target changes after refresh and option changes after preparation |
| `$/cancelRequest` | Client notification | Cancel the matching request |
| `build/logMessage`, `build/taskStart`, `build/taskProgress`, `build/taskFinish` | Server notifications | Stream compile/test/index stages and readable output; retain raw logs in DerivedData |
| `build/publishDiagnostics` | Server notification | Publish compiler diagnostics by file and target; clear stale diagnostics on the next build |

## Refresh and cancellation

Clients must register the advertised watchers and send file notifications.
The server reloads project/configuration changes and source creation/deletion;
it preserves the previous state if parsing fails. `workspace/reload` requires an ID.

Cancellation reaches compile, test, and index builds. It returns error `-32800`;
compile/test/index tasks also finish with status `3`. Normal compile/test/run results
use status `1` for success and `2` for failure. Test results preserve `originId`.
See [BSP lifecycle](https://github.com/aelam/sourcekit-bsp/blob/main/Docs/BSP-Lifecycle.md)
for payloads, ordering, and test execution details.

## Client extensions

Xcode configurations and destinations are target metadata that requires client UI
support. BSP does not define an iOS device picker. Test/run environment and
working-directory fields are server extensions. Debug clients must connect over
DAP after obtaining the BSP endpoint.

## Concurrency contracts

Protocol payloads use checked `Sendable` conformances. Swift can infer conformance
for internal value types; the formatter's `redundantSendable` rule is disabled to
retain explicit declarations. Do not use `@unchecked Sendable` to hide an error.

## Limitations

- No standalone SwiftPM project provider or physical-device debugging.
- Compiler diagnostics are parsed from text output. Diagnostics with ambiguous target ownership remain in the log.
- No individual BSP test reports. SourceKit-LSP provides editor diagnostics independently.
- `inverseSources`, `dependencySources`, and `resources` have no handlers and are not advertised.
- Complex workspaces, packages, and test plans need broader compatibility testing.
