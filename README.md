# sourcekit-bsp

[![Swift](https://img.shields.io/badge/swift-6.1+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)](https://developer.apple.com/macos/)
[![Build Status](https://github.com/aelam/sourcekit-bsp/actions/workflows/ci.yml/badge.svg)](https://github.com/aelam/sourcekit-bsp/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A Build Server Protocol (BSP) server for Xcode projects. It supplies targets and
compiler arguments to SourceKit-LSP and runs Xcode build, run, test, and debug
operations for BSP clients.

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
sudo mv XcodeProjectCLI /usr/local/bin/
sourcekit-bsp --help
```

Or build and install the executables directly from this Swift package with Mint:

```sh
mint install aelam/sourcekit-bsp
```

## Build

Requires macOS 13+, Xcode with Swift 6.1+, and your project's SDKs and simulator runtimes.

```sh
git clone https://github.com/aelam/sourcekit-bsp.git
cd sourcekit-bsp
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
```

The executable is `.build/debug/sourcekit-bsp`; `swift build -c release` produces
`.build/release/sourcekit-bsp`. See [Getting started](Docs/wiki/Getting-Started.md)
for Xcode builds and executable paths.

## Release

Releases are built by GitHub Actions when a `v*.*.*` tag is pushed. The tag
must match `SourceKitBSPVersion.current`; otherwise the release workflow stops
before it builds or uploads artifacts.

```sh
version="$(
  sed -n 's/^[[:space:]]*static let current = "\(.*\)"[[:space:]]*$/\1/p' \
    Sources/sourcekit-bsp/SourceKitBSPVersion.swift
)"
git tag -a "v$version" -m "Release v$version"
git push origin "v$version"
```

## Connect an editor

Create `.bsp/sourcekit-bsp.json` in your application project:

```json
{
  "name": "sourcekit-bsp",
  "version": "1.0",
  "bspVersion": "2.2.0",
  "languages": ["swift", "c", "cpp", "objective-c", "objective-cpp"],
  "argv": ["/absolute/path/to/sourcekit-bsp"]
}
```

The client discovers `.bsp/*.json` and starts the executable in `argv`.
Running the server directly waits for protocol messages on stdin.

In VS Code, use the Swift extension for code navigation and
[vscode-bsp](https://github.com/aelam/vscode-bsp) for build and debug controls.
Use the same Xcode toolchain for both. After rebuilding the selected executable,
restart their server connections.

For projects with multiple workspaces, configure `.sourcekit-bsp/project.json`;
see [project configuration](Docs/wiki/Getting-Started.md#configure-the-application-project).

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

`CI=true` skips tests that use personal project paths. Integration tests use bundled
fixtures and require Xcode SDKs. Linux CI covers the portable components.
See [Contributing](CONTRIBUTING.md).

## References and license

- [Build Server Protocol](https://build-server-protocol.github.io/)
- [SourceKit-LSP](https://github.com/swiftlang/sourcekit-lsp)
- [Implementing a BSP server](https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/Implementing%20a%20BSP%20server.md)

Inspired by [sourcekit-bazel-bsp](https://github.com/spotify/sourcekit-bazel-bsp)
and [xcode-build-server](https://github.com/SolaWing/xcode-build-server).
Licensed under the [MIT License](LICENSE).
