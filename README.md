# sourcekit-bsp

[![Swift](https://img.shields.io/badge/swift-6.1+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)](https://developer.apple.com/macos/)
[![Build Status](https://github.com/aelam/sourcekit-bsp/actions/workflows/ci.yml/badge.svg)](https://github.com/aelam/sourcekit-bsp/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

sourcekit-bsp connects Xcode projects to editors through the Build Server Protocol
(BSP). It supplies build targets and compiler arguments to SourceKit-LSP and runs
Xcode build, test, launch, and debug operations for BSP clients.

These instructions describe the current source tree. Older releases may provide
fewer features; clients should inspect `build/initialize` and target capabilities.
The server reports BSP 2.2.0 and implements a subset of the specification.

## Current support

| Area | Behavior |
| --- | --- |
| Projects | Discover Xcode projects/workspaces, targets, source files, and target dependencies |
| Code intelligence | Supply per-file Swift, C, C++, and Objective-C compiler arguments to SourceKit-LSP |
| Index preparation | Run incremental Xcode builds for `buildTarget/prepare`, using consistent DerivedData and index paths |
| Compile | Build application/library targets; use `build-for-testing` for test bundles; stream Xcode output |
| Run | Launch an existing application build; compile with the same configuration and destination first |
| Test | Build and run selected test targets with `xcodebuild test`, filters, logs, and failure status |
| Debug | Build an application and return an LLDB DAP connection for macOS or a simulator |
| Refresh | Reload after client file notifications or a `workspace/reload` request; notify clients of target changes |
| Cancellation | Stop the matching request; propagate cancellation to compile, test, and index preparation |

SourceKit-LSP provides completion, definition lookup, references, and editor
diagnostics. A BSP client can provide build/run/test/debug controls. An editor
may run separate BSP connections for these two roles.

Not yet implemented: standalone SwiftPM project management, physical-device debug
sessions, structured test-count reports, and compiler diagnostics published through
BSP. `inverseSources`, `dependencySources`, and `resources` providers are not
advertised. See the [protocol support table](Docs/wiki/Protocol-Support.md).

![Code navigation demo](Docs/Navigation.gif)

## Build the server

Requirements: macOS 13 or later, a full Xcode installation with Swift 6.1 or later,
and the SDK/runtime needed by your project. Python 3 is needed for the test client.
The Xcode backend requires macOS; Linux CI covers the portable components.

```sh
git clone https://github.com/aelam/sourcekit-bsp.git
cd sourcekit-bsp
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
```

This produces `.build/debug/sourcekit-bsp`. Use `swift build -c release` for
`.build/release/sourcekit-bsp`.

To produce an Xcode build in a predictable location:

```sh
xcodebuild -scheme sourcekit-bsp -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/sourcekit-bsp-build build
```

The executable is `/tmp/sourcekit-bsp-build/Build/Products/Debug/sourcekit-bsp`.
An Xcode GUI build uses its configured DerivedData directory. **Rebuild the
executable selected by your client**: `swift build` does not update Xcode's copy.

[GitHub Releases](https://github.com/aelam/sourcekit-bsp/releases) contains older
binaries. Build from source for the features documented here. Homebrew installation
is not available yet.

## Connect an editor

Create `buildServer.json` in the root of the application project you want to edit:

```json
{
  "name": "sourcekit-bsp",
  "version": "1.0",
  "bspVersion": "2.2.0",
  "languages": ["swift", "c", "cpp", "objective-c", "objective-cpp"],
  "argv": ["/absolute/path/to/sourcekit-bsp"]
}
```

Clients that discover standard BSP connection files can use
`.bsp/sourcekit-bsp.json` with the same contents. Use the location supported by
your client; `buildServer.json` is the compatibility setup for SourceKit-LSP.
Select the same Xcode toolchain for the editor and BSP process. If needed, the
`argv` array can start with `/usr/bin/env` and a `DEVELOPER_DIR=...` assignment.

For VS Code, install the Swift extension for SourceKit-LSP. Use a BSP client such
as [vscode-bsp](https://github.com/aelam/vscode-bsp) for build and debug controls.
After changing the executable or toolchain, restart the language server/BSP
connection or reload the VS Code window.

The client starts the server over stdin/stdout and sends `build/initialize` with
the project root URI. Running `sourcekit-bsp` alone waits for protocol messages;
it does not compile an application or open an interactive prompt.

If project discovery is ambiguous, create `.sourcekit-bsp/project.json`:

```json
{
  "project": "Hello.xcodeproj",
  "configuration": "Debug"
}
```

Use `workspace` instead of `project` for an explicit workspace. Paths can be
absolute or relative to the project root. A single discoverable project does not
require this file. The `scheme` field is currently parsed but does not force
scheme selection; the server resolves or creates schemes for the requested target.

## Try the interfaces without an editor

Run these examples from the repository root. They use the bundled Hello fixture
and the server built by `swift build`.

```sh
bsp_project="$PWD/Tests-MacOS/XcodeProjectManagementTests/Resources/DemoProjects/HelloProject"
bsp_server="$PWD/.build/debug/sourcekit-bsp"

python3 Scripts/bsp_client.py --server "$bsp_server" --project "$bsp_project"
python3 Scripts/bsp_client.py --server "$bsp_server" --project "$bsp_project" \
  --method buildTarget/compile --target Hello
python3 Scripts/bsp_client.py --server "$bsp_server" --project "$bsp_project" \
  --method buildTarget/prepare --target Hello
```

To run tests, select a concrete simulator ID from `xcrun simctl list devices available`:

```sh
python3 Scripts/bsp_client.py --server "$bsp_server" --project "$bsp_project" \
  --method buildTarget/test --target HelloTests --destination 'id=SIMULATOR-UUID'
```

The test command builds the test bundle and its dependencies before execution.
For run/debug examples, test filters, and Xcode build paths, see the
[client guide](Scripts/README.md) and [Wiki pages](Docs/wiki/README.md).
Build and debug operations may create shared schemes and install an application
on the selected simulator; use a project copy for isolated experiments.

## Indexing and project refresh

`buildTarget/prepare` prepares compiler inputs and index data. SourceKit-LSP then
builds the symbol index used for definition lookup and references. Preparation
currently uses a regular incremental build with code signing disabled.

For a project with a BSP connection file, run a full indexing pass with the
matching toolchain:

```sh
xcrun sourcekit-lsp debug index --project /path/to/HelloProject
```

For automatic indexing, enable background indexing in your editor or configure
`.sourcekit-lsp/config.json`. See [indexing and paths](Docs/wiki/Indexing-and-Paths.md).

The server advertises file watchers. The client must send
`workspace/didChangeWatchedFiles`; the server does not watch the disk itself.
Project/configuration changes and source creation/deletion refresh the build
state. An invalid save preserves the last usable project state. An explicit
`workspace/reload` is a request with an ID. See [BSP lifecycle](Docs/BSP-Lifecycle.md)
for payloads, ordering, cancellation, and test behavior.

## Development

```sh
CI=true MACOS_CI=true swift test --enable-code-coverage
```

`CI=true` skips tests that rely on personal project paths. Xcode integration tests
still use the bundled fixtures and require the relevant SDKs. The latest local
validation covered 52 tests, HelloTests success/failure/cancellation/retry on an
iOS simulator, and SourceKit-LSP indexing, definitions, and references.

The implementation uses Swift actors and checked `Sendable` conformances.
SwiftFormat preserves explicit `Sendable` declarations in protocol payloads.
See [development notes](Docs/wiki/Protocol-Support.md#concurrency-contracts).

## Documentation and troubleshooting

- [Wiki index and publication instructions](Docs/wiki/README.md)
- [Getting started](Docs/wiki/Getting-Started.md)
- [Build, run, test, and debug](Docs/wiki/Build-Run-Test-Debug.md)
- [Indexing and build paths](Docs/wiki/Indexing-and-Paths.md)
- [Protocol support](Docs/wiki/Protocol-Support.md)
- [Troubleshooting](Docs/wiki/Troubleshooting.md)

Server logs are written to `/tmp/sourcekit-bsp.log`. Add `--verbose` to the Python
client to inspect protocol messages. A stale device ID, a different BSP executable,
or a mismatched Xcode toolchain can explain apparently successful builds followed
by launch or navigation failures.

## References and license

- [Build Server Protocol](https://build-server-protocol.github.io/)
- [SourceKit-LSP](https://github.com/swiftlang/sourcekit-lsp)
- [Implementing a BSP server](https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/Implementing%20a%20BSP%20server.md)
- [Contributing](CONTRIBUTING.md)

Inspired by [sourcekit-bazel-bsp](https://github.com/spotify/sourcekit-bazel-bsp)
and [xcode-build-server](https://github.com/SolaWing/xcode-build-server).
Licensed under the [MIT License](LICENSE).
