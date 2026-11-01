# Protocol support

This table describes the current source tree. The server reports BSP 2.2.0;
it does not implement every method in that specification. Inspect
`build/initialize` and each target's capabilities before offering an operation.

## Requests and notifications

| Method | Direction and status | Behavior |
| --- | --- | --- |
| `build/initialize` | Client request; implemented | Load the project and return capabilities, index paths, and watchers |
| `build/initialized` | Client notification; implemented | Complete initialization handshake |
| `build/shutdown`, `build/exit` | Client request / notification; implemented | Shut down project services and exit |
| `workspace/buildTargets` | Client request; implemented | Return targets, capabilities, dependencies, and server-specific metadata |
| `buildTarget/sources` | Client request; implemented | Return target source files, including Xcode synchronized folders |
| `textDocument/sourceKitOptions` | SourceKit extension request; implemented | Return compiler arguments for a source file |
| `buildTarget/prepare` | SourceKit extension request; implemented | Build inputs and index data for SourceKit-LSP |
| `buildTarget/compile` | Client request; implemented | Compile targets with Xcode and stream build logs |
| `buildTarget/run` | Client request; implemented | Install/launch an existing application product |
| `buildTarget/test` | Client request; implemented | Build and run selected test bundles; return aggregate status |
| `debugSession/start` | Client request; implemented for macOS/simulators | Build and return an LLDB DAP connection |
| `buildTarget/outputPaths` | Client request; implemented | Return the default project product directory for each requested target |
| `buildTarget/cleanCache` | Client request; implemented with project scope | Clear shared project products and index directories, not isolated per-target caches |
| `workspace/reload` | Client request; implemented | Reload project state and emit target changes |
| `workspace/didChangeWatchedFiles` | Client notification; implemented | Process relevant source/configuration file events |
| `workspace/waitForBuildSystemUpdates` | SourceKit extension request; implemented | Wait for pending project updates |
| `buildTarget/didChange` | Server notification; implemented | Report created, changed, and deleted targets after refresh; report changed options after preparation |
| `$/cancelRequest` | Client notification; implemented | Cancel a matching in-flight request |
| `build/logMessage`, `build/taskStart`, `build/taskFinish` | Server notifications; implemented | Stream compile/test output and report task status |
| `buildTarget/inverseSources` | Not implemented; provider false | No registered request handler |
| `buildTarget/dependencySources` | Not implemented; provider false | No registered request handler |
| `buildTarget/resources` | Not implemented; provider false | No registered request handler |
| `build/publishDiagnostics` | Not connected to compiler output | Types exist; structured BSP compiler diagnostics remain future work |

Method/type declarations in the source tree do not imply a registered or complete
implementation. SourceKit-LSP can still provide editor diagnostics independently
of BSP compiler diagnostics.

## Refresh contract

The initialization response advertises watcher patterns. The client must register
them and send `workspace/didChangeWatchedFiles` with a `changes` array. File event
types are `1` (created), `2` (changed), and `3` (deleted).

Project/workspace files, schemes, configuration files, and
`.sourcekit-bsp/project.json` trigger reloads. Source creation/deletion also
triggers reloads; ordinary source edits do not. DerivedData and `.build` events
are filtered. A failed project parse retains the previous usable project state.

Notifications are processed in arrival order. Requests received after a
notification wait for it to finish. `workspace/reload` must have a request ID;
clients must not send it as a notification. The wait-for-updates request reports
reload failure, and a later change or reload request can retry.

## Cancellation and result status

`$/cancelRequest` bypasses the notification queue and cancels the request with
the supplied ID. Unknown or completed IDs have no effect. Compile/test/index
preparation propagates cancellation to Xcode. A cancelled request returns error
`-32800`; compile/test task-finish notifications also use status `3`.

A normal compile/test/run result uses status `1` for success or `2` for failure.
A JSON-RPC response is not itself evidence that the requested operation succeeded.
Test responses preserve `originId` and report an aggregate status; structured
per-test reports are not implemented.

## Client-specific fields

The server exposes Xcode configurations and destinations through target metadata.
A client needs Xcode-specific UI to interpret them. Generic BSP clients can still
use the standard target and operation methods, but BSP does not define a universal
iOS device picker. Test/run environment and working-directory fields are server
extensions. A debugging client must implement DAP after obtaining the BSP endpoint.

## Concurrency contracts

Protocol payloads retain explicit, checked `Sendable` declarations. For internal
structs and enums whose stored values are sendable, Swift can infer conformance.
That inference explains why removing an explicit declaration can still compile;
it does not disable Swift's concurrency checking.

The repository disables SwiftFormat's `redundantSendable` rule to keep these
contracts visible and prevent unrelated formatting changes. Keep checked
conformance on payloads; do not replace it with `@unchecked Sendable` to suppress
a compiler error. Public types should state the intended API contract explicitly.

## Remaining work

- Standalone SwiftPM project support.
- Physical-device debug sessions.
- Structured compiler diagnostics and individual test reports over BSP.
- The three unadvertised source/resource methods above.
- Broader compatibility testing for complex workspaces, packages, and test plans.
