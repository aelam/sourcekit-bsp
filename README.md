# sourcekit-bsp

[![Swift](https://img.shields.io/badge/swift-6.1+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey.svg)](https://www.swift.org/install/)
[![Build Status](https://github.com/aelam/sourcekit-bsp/actions/workflows/ci.yml/badge.svg)](https://github.com/aelam/sourcekit-bsp/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A Build Server Protocol (BSP) server for Xcode projects and SwiftPM packages.
For Xcode projects, it supplies compiler arguments to SourceKit-LSP and runs build,
run, test, and debug operations. For SwiftPM packages, it loads targets, dependencies,
and source lists on macOS and Linux. It builds root package targets, runs executable
products, runs root test targets, and supports executable and test debugging on macOS.

- Discover projects, workspaces, sources, and target dependencies.
- Prepare compiler inputs and index data for SourceKit-LSP.
- Build and test targets; launch applications and debug on macOS or a simulator.
- Refresh project state after client file notifications and cancel active builds.
- Report build/test/index stages, compiler diagnostics, and readable output through standard BSP notifications.

The server implements a subset of BSP 2.2.0. See [protocol support](Docs/wiki/Protocol-Support.md)
for capabilities and limitations. These docs describe the current source tree;
older releases may have fewer features.

![Code navigation demo](Docs/Navigation.gif)

## Install

Download the latest `sourcekit-bsp-macos-universal.tar.gz` from the
[GitHub Releases](https://github.com/aelam/sourcekit-bsp/releases/latest) page.

```sh
tar -xzf sourcekit-bsp-macos-universal.tar.gz
sudo mv sourcekit-bsp /usr/local/bin/
sourcekit-bsp --help
```

Or build and install the executables directly from this Swift package with Mint:

```sh
mint install aelam/sourcekit-bsp
```

## Build

Requires Swift 6.1 or later. Xcode operations also require macOS 13+, Xcode, and
your project's SDKs and simulator runtimes. On Linux, install the Swift toolchain
and run `swift build` without `DEVELOPER_DIR`.

```sh
git clone https://github.com/aelam/sourcekit-bsp.git
cd sourcekit-bsp
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
```

The executable is `.build/debug/sourcekit-bsp`; `swift build -c release` produces
`.build/release/sourcekit-bsp`. See [Getting started](Docs/wiki/Getting-Started.md)
for Xcode builds and executable paths.

Xcode project diagnostics are available as subcommands:

```sh
sourcekit-bsp xcode-project --help
sourcekit-bsp xcode-project resolve-project --workspace-folder /path/to/project-folder
```

Use the folder that contains the `.xcodeproj` or `.xcworkspace`.

## Release

Use the **Release** workflow in GitHub Actions to prepare a release. Run it from
`main` and enter the new version, for example `0.2.4`. The workflow creates a
release pull request that updates `SourceKitBSPVersion.current`.

After the release pull request is merged, the same workflow creates the matching
`v*.*.*` tag and uploads the release assets.

Manual release preparation requires a `RELEASE_TOKEN` secret with permission to
push branches and create pull requests. This lets the release pull request start
the required checks before merge.

Tag pushes are still supported. The tag must match `SourceKitBSPVersion.current`;
otherwise the release workflow stops before it builds or uploads artifacts.

```sh
version="$(
  sed -n 's/^[[:space:]]*static let current = "\(.*\)"[[:space:]]*$/\1/p' \
    Sources/sourcekit-bsp/SourceKitBSPVersion.swift
)"
git tag -a "v$version" -m "Release v$version"
git push origin "v$version"
```

## Connect an editor

[vscode-bsp](https://github.com/aelam/vscode-bsp) is a general BSP client for VS Code
that provides build, run, test, and debug controls. The
[Swift extension](https://github.com/swiftlang/vscode-swift) runs SourceKit-LSP
for code completion and navigation. Each client uses its own BSP connection.

1. Install the server as described [above](#install) and follow the
   [vscode-bsp installation steps](https://github.com/aelam/vscode-bsp#installation).
   For Swift editing, also install the Swift extension.
2. Create `.bsp/sourcekit-bsp.json` in your application's root folder,
   alongside its `.xcodeproj` or `.xcworkspace`:

   ```json
   {
     "name": "sourcekit-bsp",
     "version": "1.0",
     "bspVersion": "2.2.0",
     "languages": ["swift", "c", "cpp", "objective-c", "objective-cpp"],
     "argv": ["/absolute/path/to/sourcekit-bsp"]
   }
   ```

3. Replace the `argv` path with the absolute path to your installed or built executable.
4. Open that application folder in VS Code, or add it as a folder in a workspace.
   Its `.bsp` directory must be at that folder's root.
5. vscode-bsp discovers and connects to the server on activation.
   If needed, run **BSP: Connect BSP Servers** from the Command Palette.
6. Run **BSP: Show Build Targets** to open **BSP Targets**.
   Expand a target and select its **Configuration** and **Destination**.
   Use its **Compile Target**, **Build and Run**, **Build and Test**, or **Build and Debug Target** action, as supported.

Use the same Xcode toolchain for the server and Swift extension.
After rebuilding the selected executable, restart both clients' server connections.
The clients start the executable in `argv`; running it directly waits for protocol messages on stdin.

For projects with multiple workspaces, configure `.sourcekit-bsp/project.json`;
see [project configuration](Docs/wiki/Getting-Started.md#configure-the-application-project).

## SwiftPM packages

Use a folder that contains `Package.swift` as the BSP workspace root. The SwiftPM
provider loads package metadata with `swift package describe --type json`. It
exposes targets, source files, dependencies, and workspace reloads without building
package products. It loads local packages and uses `swift package show-dependencies`
to locate resolved remote dependencies. Resolution can download packages. Plugins,
macros, and binary targets are omitted with warnings. Dependency edges are not yet
filtered by platform or build configuration.

The Swift executable must be on `PATH`. If `SWIFT_EXEC` selects a `swiftc`
compiler, the provider uses the `swift` executable in the same directory.

Root package targets support `buildTarget/compile`. Executable targets with one
product support `buildTarget/run` and, on macOS, `debugSession/start` through the
active Xcode toolchain's LLDB adapter. Root test targets also support debugging.
Library and dependency targets do not
advertise run or debug support. Dependency targets are built through their root
package dependents.

Compile builds the selected target or executable product. For a test target, it
uses `swift build --build-tests` to link the test runner; this can build other test
targets in the package. Run and debug use the
existing product without building it. Compile first, with the same SwiftPM build
arguments, such as `--configuration release` or `--scratch-path /path/to/build`.
The target controls product selection; package-path and target-selection overrides
are rejected. Run supports the server's environment and working-directory fields. Process output is streamed, and cancellation stops active commands.

Root test targets support `buildTarget/test`. The server uses `swift test` and a
module filter to run only the selected targets, including XCTest and Swift Testing.
SwiftPM can build other test targets as part of this command. Test arguments accept
build configuration options, `--skip-build`, parallel execution, and code coverage.
Clients can select individual functions with the optional
`sourcekit-test-selection` payload. Parameterized functions run all their arguments.
The server rejects extra test filters and commands that do not run tests. Tests
run from the package root and support environment variables. SwiftPM can buffer
output; the server forwards it as it arrives. After each target completes, the
server reports case results from XCTest output and Swift Testing events. Missing
selected results and test failures return an error. Cancellation stops the runner.
See [test discovery and selection](Docs/wiki/Build-Run-Test-Debug.md#test-discovery-and-selection).
The server locates SourceKit-LSP through the selected Swift executable's runtime
metadata, so a toolchain shim does not become the language-server path. When the
toolchain includes SourceKit-LSP, root test targets advertise discovery metadata
for source navigation and editor test actions. Without it, target testing remains
available.

Test debugging uses the existing test bundle and lists its tests without building
or running them. Compile the test target first with the same build arguments. The debugger launches Xcode's `xctest` runner with
the selected module's test identifiers. XCTest and Swift Testing run in the same
process, so source breakpoints work for both frameworks. The server supports
SwiftPM's separate test bundles and native build system's combined test bundle.
Test targets do not support ordinary Run. Test identifiers that contain commas
cannot be passed to the XCTest selector and return an error. The client must
forward the debug response's `args`, `env`, and `cwd` fields to DAP. This requires
an updated client, such as [vscode-bsp PR #14](https://github.com/aelam/vscode-bsp/pull/14).

This provider does not yet supply compiler arguments or prepare indexes.
It advertises these capabilities as unsupported. SourceKit-LSP's native SwiftPM
integration remains the option for SwiftPM code navigation.

On macOS, an Xcode project takes precedence when the folder also contains
`Package.swift`. Native Windows server support is not verified.

## Try without an editor

With Python 3, run from this repository root:

```sh
bsp_project="$PWD/Tests-MacOS/XcodeProjectManagementTests/Resources/DemoProjects/HelloProject"
python3 Scripts/bsp_client.py --project "$bsp_project"
python3 Scripts/bsp_client.py --project "$bsp_project" \
  --method buildTarget/compile --target Hello
```

The probe uses `.build/debug/sourcekit-bsp` by default. Use `--server` to select
another build. See the [client guide](Scripts/README.md) for options.

## Documentation

- [Getting started](Docs/wiki/Getting-Started.md)
- [Build, run, test, and debug](Docs/wiki/Build-Run-Test-Debug.md)
- [Indexing and build paths](Docs/wiki/Indexing-and-Paths.md)
- [Protocol support](Docs/wiki/Protocol-Support.md) and [lifecycle payloads](Docs/BSP-Lifecycle.md)
- [Troubleshooting](Docs/wiki/Troubleshooting.md)
- [Wiki sources](Docs/wiki/README.md)

## Development

```sh
CI=true MACOS_CI=true swift test --enable-code-coverage
```

`CI=true` skips tests that use personal project paths. Xcode integration tests use bundled
fixtures and require Xcode SDKs. SwiftPM loading tests use temporary local packages
on macOS and Linux without Xcode or remote package dependencies.
See [Contributing](CONTRIBUTING.md).

## References and license

- [Build Server Protocol](https://build-server-protocol.github.io/)
- [SourceKit-LSP](https://github.com/swiftlang/sourcekit-lsp)
- [Implementing a BSP server](https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/Implementing%20a%20BSP%20server.md)

Inspired by [sourcekit-bazel-bsp](https://github.com/spotify/sourcekit-bazel-bsp)
and [xcode-build-server](https://github.com/SolaWing/xcode-build-server).
Licensed under the [MIT License](LICENSE).
