# sourcekit-bsp

[![Swift](https://img.shields.io/badge/swift-6.1+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey.svg)](https://www.swift.org/install/)
[![Build Status](https://github.com/aelam/sourcekit-bsp/actions/workflows/ci.yml/badge.svg)](https://github.com/aelam/sourcekit-bsp/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/aelam/sourcekit-bsp/branch/main/graph/badge.svg)](https://app.codecov.io/gh/aelam/sourcekit-bsp)
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
macros, and binary targets are omitted from the build target list with warnings. Dependency edges are not yet
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
targets in the package. Without the context extension, run and debug use the
existing product without building it. Compile first, with the same SwiftPM build
arguments, such as `--configuration release` or `--scratch-path /path/to/build`.
The target controls product selection; package-path and target-selection overrides
are rejected. Run supports the server's environment and working-directory fields. Process output is streamed, and cancellation stops active commands.

With the [context extension](#execution-configuration-extension), run and debug
prepare products using the resolved configuration. Run arguments are application
arguments on this path; the context supplies the build settings.

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

Test debugging lists the existing test bundle's tests without running them.
Without the context extension, compile the test target first with the same build
arguments. Context execution prepares the bundle first. The debugger launches Xcode's `xctest` runner with
the selected module's test identifiers. XCTest and Swift Testing run in the same
process, so source breakpoints work for both frameworks. The server supports
SwiftPM's separate test bundles and native build system's combined test bundle.
Test targets do not support ordinary Run. Test identifiers that contain commas
cannot be passed to the XCTest selector and return an error. The client must
forward the debug response's `args`, `env`, and `cwd` fields to DAP. This requires
an updated client, such as [vscode-bsp PR #14](https://github.com/aelam/vscode-bsp/pull/14).

Build output paths come from `swift build --show-bin-path`; this query does not
compile the package. After a successful build or test in the current connection,
the server uses its configuration and scratch directory for the affected targets.
Before a build, or after reconnecting, it uses SwiftPM's default build options.

This provider does not yet supply compiler arguments or prepare indexes.
It advertises these capabilities as unsupported. SourceKit-LSP's native SwiftPM
integration remains the option for SwiftPM code navigation.

On macOS, an Xcode project takes precedence when the folder also contains
`Package.swift`. Native Windows server support is not verified.

## Dependency modules

Both providers advertise `dependencyModulesProvider` and handle
`buildTarget/dependencyModules`. The response contains one item per requested
target, including an empty module list for targets without external libraries.
Unknown targets return an invalid-parameters error. The query uses the loaded
project snapshot and does not run a build or resolve packages.

SwiftPM reports external package products, including binary products, and follows
transitive dependencies in the loaded target graph. Xcode reports package products
and linked external frameworks and libraries for each target and its workspace
target dependencies. Xcode does not enumerate dependencies inside package products;
SDK libraries and products of workspace targets are excluded.

Package versions come from `Package.resolved` formats 1, 2, and 3. A revision is
used when no version is available, followed by a branch name. Local packages,
unresolved packages, and linked binaries have an empty version. Version constraints
are not reported as resolved versions. Workspace reloads refresh the module list.

The optional `data` field uses these server-specific kinds:

- `swiftpm`: package `identity`, `repository`, and source-root `uri`, when available.
- `xcode`: library `path`, `sourceTree`, and resolved file `uri`, when available.

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

## Execution configuration extension

The optional `vscode-bsp.build-context` extension, version `0.1`, discovers and
resolves execution settings for Xcode and SwiftPM. It is an experimental extension,
not part of the BSP standard. Other clients can keep using the standard requests.

Compiler-information requests such as `buildTarget/scalacOptions`,
`buildTarget/javacOptions`, and SourceKit compiler options describe the current
compiler inputs. This extension instead lists selectable execution settings.
Selecting these settings does not change the language server's indexing context.

### Negotiate the extension

Add this object to `build/initialize` parameters under `data.bspExtensions`:

```json
{
  "vscode-bsp.build-context": { "version": "0.1" }
}
```

The server accepts the extension by returning the following entry under
`result.data.bspExtensions`. It preserves `dataKind: "sourceKit"` and the existing
SourceKit initialization fields. The supported operation list can vary by provider.

```json
{
  "vscode-bsp.build-context": {
    "version": "0.1",
    "required": true,
    "operations": ["compile", "run", "test", "debug"]
  }
}
```

Only an exact version match enables this mode. After acceptance, all compile,
run, test, and debug requests on that connection must include a resolved
`executionContext`. Missing or invalid context references fail; the server does
not fall back to default settings. Clients that do not negotiate the extension
keep the existing request behavior.

### Discover and resolve settings

| Method | Purpose |
| --- | --- |
| `workspace/contextOptions` | Return available configuration dimensions and effective selections. |
| `workspace/resolveContext` | Validate a selection and return a context ID and its target set. |

The discovery parameters contain only `scope` and `selection`. `operation` is
part of resolution, not configuration discovery.

Start discovery without an operation or target:

```json
{
  "scope": { "workspaceUri": "file:///workspace/Demo" },
  "selection": {}
}
```

For Xcode, the response supplies all three dimensions: Scheme, Configuration,
and Destination. Scheme contains the full list. The other fields remain visible
with `enabled: false` and a reason until a Scheme is chosen. Send its ID in the
next query to fill their options and enable them:

```json
{
  "selection": { "xcode.scheme": "scheme-id-returned-by-the-server" }
}
```

Discovery does not require the user to choose Build, Run, Test, or Debug first.
Only after an action is chosen does resolution require its `operation`:

```json
{
  "operation": "run",
  "selection": {
    "xcode.scheme": "scheme-id-returned-by-the-server",
    "xcode.configuration": "Release",
    "xcode.destination": "destination-id-returned-by-the-server"
  }
}
```

`scope`, `workspaceUri`, `targets`, and `selection` are optional. An explicit
workspace must match the initialized workspace. Omit `targets` to discover a
workspace execution entry, such as an Xcode scheme. An explicit target list
restricts the execution scope; an empty list is invalid. A resolve operation is one of
`compile`, `run`, `test`, or `debug`.

The options result contains `dimensions`, `selection`, and optional `operations`
for the selected scope. Each dimension has
`id`, `label`, `kind`, `required`, `options`, and an optional current `value`.
Optional `enabled` and `reason` fields describe whether the user can edit the
dimension. Omitted `enabled` means enabled. Clients display disabled dimensions
and their reasons, but do not open an option picker for them.
Version `0.1` supports `kind: "enum"`. Each option has an opaque `id`, a display
`label`, and optional `description`, `reason`, and boolean `availability` fields.
An explicit `availability: false` marks an unavailable option. Do not infer
capabilities or build-tool arguments from an ID. Unknown required dimension kinds
must prevent execution in the client.

Options can also include `dataKind` and `data` for structured display metadata.
The custom `execution-destination` data kind describes a destination:

```json
{
  "id": "destination-id-returned-by-the-server",
  "label": "iPhone 16",
  "availability": true,
  "dataKind": "execution-destination",
  "data": {
    "kind": "simulator",
    "platform": { "id": "ios", "label": "iOS" },
    "osVersion": "18.5"
  }
}
```

The `kind` field is an open string. The `platform` object contains `id` and
`label`. Known kinds include `host`, `device`, `simulator`,
`emulator`, `remote`, `container`, and `generic`. Optional `osVersion`,
`architecture`, and `state` fields describe known properties. Providers omit
unknown values. Clients use these fields for display only; they must not infer
execution capabilities from a destination kind or state. Unknown data kinds or
destination kinds fall back to the option's label and description.

Xcode supplies platform, destination type, and known OS versions from its device
inventory. Its current simulator inventory does not report boot state, so that
field is omitted. SwiftPM reports its host platform and architecture from the
selected toolchain's target information; a deployment version is not a host OS
version. `availability` and execution validation remain independent of metadata.

Dimensions are ordered from earlier choices to dependent choices. When the user
changes a dimension, the client clears explicit choices for later dimensions and
queries options again. Server defaults returned by discovery do not become saved
user preferences. Version `0.1` uses this ordered model rather than a dependency
graph; servers must supply a suitable order.

Xcode workspace discovery always orders its fields as Scheme, Configuration,
and Destination. The provider enables dependent fields after their prerequisites
are satisfied. An automatic value can satisfy a prerequisite; display order does
not require the user to click every field. A target scope limits the applicable
scheme actions. Common discovery does not invent a single default configuration
for all actions. Omitted configuration and destination choices are resolved when
an action is requested. Run and test defaults come from their scheme actions. SwiftPM supplies
configuration and the supported host destination, with a target selection when
needed. It does not supply a scheme. Unknown selection keys fail. Xcode discovery
can retain an invalid choice as unavailable with a reason so the user can change
it. Resolution rejects incompatible selections. Discovery and resolution do not build targets, generate
schemes, or change a global selection.

Xcode destinations come from the local device inventory and platform build
settings. These checks do not replace `xcodebuild -showdestinations` validation
for a scheme. Generic destinations can be used for builds; run, test, and debug
require a concrete destination. Refresh options after changing a scheme or
configuration, and before using a saved selection. Xcode option discovery reuses
an inventory snapshot for up to two seconds. Queries without a valid scheme do
not scan devices. Context resolution and execution always refresh the inventory;
a refresh failure prevents execution instead of using an older snapshot.

The first Xcode implementation rejects test plans and ambiguous scheme names.
It also rejects custom launch settings that the run/debug backend cannot apply,
including enabled scheme arguments, environment variables, and action scripts.
Test debugging supports one app-hosted unit test target on an iOS simulator.
Unavailable options include a reason. These restrictions apply to the new
context path; they do not add support to the legacy execution path.

The resolve response contains `id`, `operation`, `targets`, and the effective
`selection`. IDs belong to the current connection. They can be reused while valid;
they are not task IDs or persistent settings. The server keeps at most 128 resolved
contexts. Reconnection, project reload, cache eviction, or a changed selection can
require resolution again. Execute requests revalidate the stored selection.

### Execute with a resolved context

Use the existing BSP methods. For example, after resolving a test context:

```json
{
  "jsonrpc": "2.0",
  "id": 12,
  "method": "buildTarget/test",
  "params": {
    "targets": [{ "uri": "target-uri-returned-by-the-server" }],
    "originId": "test-12",
    "executionContext": { "id": "context-id-returned-by-resolve" }
  }
}
```

The additional `executionContext` field is also an extension. The request's
operation and target set must match the resolved context; `buildTarget/run` still
uses its standard single `target` field. Results, diagnostics, task events, test
reports, cancellation, and DAP connections keep their existing formats.

Execution settings stay separate from application arguments, test selection data,
environment variables, and the working directory. Conflicting build flags fail
instead of overriding the selected configuration. Context execution prepares
required products using that same configuration. It does not require the client
to compile under a separately resolved configuration first.

This version does not provide a configuration-change notification or a general
UI schema. Query options when configuring an operation and resolve before starting
it. Invalid extension parameters and context references return JSON-RPC
`InvalidParams` (`-32602`). Do not parse error text or automatically retry with
default settings.

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
