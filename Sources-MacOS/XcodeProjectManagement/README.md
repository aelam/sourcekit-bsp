# XcodeProjectManagement

A Swift library for discovering Xcode projects, parsing build settings, and
generating `xcodebuild` arguments for BSP integration.

## Key Components

### XcodeProjectManager

The backend loads an `XcodeProjectSnapshot` from `XcodeProjectReference` and
runs Xcode operations. The snapshot contains targets, schemes, build settings,
and the selected toolchain.

`XcodeProjectManagerProvider` wraps the backend in `XcodeBSPProjectManager`.
After initialization or reload, the provider converts the snapshot and its
resolved dependencies into a `BSPProject`. This internal model stores BSP targets
by identifier; dependencies refer to identifiers rather than nested target copies.
It is not a BSP wire message.

```text
XcodeProjectReference → XcodeProjectSnapshot → BSPProject → BSP queries
                                                   ↓
                                         Xcode backend operations
```

Target queries and build-log dependency traversal use the stored BSP model.
Source queries load only requested targets through the backend's source cache.
Compile, run, test, and debug requests use the existing Xcode execution paths.
When `--enable-build-target-prepare` is enabled, compiler arguments and BSP preparation use
`SwiftBuildIndexingBackend`. Reload replaces the model after loading succeeds;
a failed reload retains the previous model.

### XcodeProjectStore

Each manager owns a store for parsed projects and source lists. Source queries
load only the requested targets and cache the results, including empty lists.
Compiler argument queries use the same source cache. Resolved build settings are
cached by target, configuration, toolchain, and DerivedData path. Index preparation
compares common arguments and source lists once per language, plus the arguments
that differ by file. Generated module maps and other build artifacts are checked
again for each comparison.

A project reload replaces the store only after the new project loads successfully.
A failed reload preserves the previous project and caches. Compile and test
operations invalidate source lists and resolved settings on completion, failure,
or cancellation because build scripts can change these inputs. Parsed projects
remain cached until reload.

### XcodeBuildExecutor

An internal executor runs compile, test, index preparation, and builds before debug.
It handles process cancellation and output. A shared scheduler serializes builds
by DerivedData directory within the server. Each manager owns its executor, so
shutdown cancels only that manager's builds.

### XcodeBuildCommandBuilder  

Generates xcodebuild command arguments with type-safe options.

```swift
let commandBuilder = XcodeBuildCommandBuilder(projectInfo: project)

// Build command for iOS Simulator
let buildCommand = commandBuilder.buildCommand(
    action: .build,
    destination: .iOSSimulator
)

// Get build settings as JSON
let settingsCommand = commandBuilder.buildSettingsCommand(forIndex: true)
```

### XcodeSettingsManager

Loads and manages Xcode build settings with async support.

```swift
let settingsManager = XcodeSettingsManager(commandBuilder: commandBuilder)

// Load build settings
try await settingsManager.loadBuildSettings()
try await settingsManager.loadIndexingPaths(target: "MyTarget")

```

### XcodeProjectLocator

Low-level project discovery with BSP configuration support.

```swift
let locator = XcodeProjectLocator(root: projectURL)
let projectLocation = try locator.resolveProjectType()

switch projectLocation {
case .explicitWorkspace(let url):
    print("Found workspace: \(url)")
case .implicitProjectWorkspace(let url):
    print("Found project: \(url)")
}
```

## Project Types

- **Explicit Workspace**: A `.xcworkspace` file found in the project directory
- **Implicit Project Workspace**: A `.xcodeproj` file that contains an embedded workspace

## Build Destinations

Supported build destinations for different Apple platforms:

- `.macOS` - macOS platform
- `.iOS` - iOS device
- `.iOSSimulator` - iOS Simulator  
- `.watchOS` - watchOS device
- `.watchOSSimulator` - watchOS Simulator
- `.tvOS` - tvOS device
- `.tvOSSimulator` - tvOS Simulator
- `.custom(String)` - Custom destination string

## Build Actions

Supported xcodebuild actions:

- `.build` - Build the target
- `.clean` - Clean build products
- `.test` - Run tests
- `.archive` - Create an archive
- `.analyze` - Run static analysis
- `.install` - Install build products
- `.installsrc` - Install source code

## BSP Configuration

Clients discover and start the server through `.bsp/*.json`; see
[connection setup](../../Docs/wiki/Getting-Started.md#configure-the-application-project).
For ambiguous project discovery, create `.sourcekit-bsp/project.json`:

```json
{
  "workspace": "MyProject.xcworkspace",
  "configuration": "Debug"
}
```

Use `project` instead of `workspace` to select an `.xcodeproj`. Paths can be
absolute or relative to the project root. The server resolves schemes for each
requested target; the optional `scheme` field does not override that selection.

The server launch flag `--enable-build-target-prepare` enables dependency preparation
for `buildTarget/prepare` requests. Add it after the executable in `.bsp/*.json`'s
`argv`. It is off by default and requires a server built with Swift Build support.
It is not a setting in this project configuration file.
SourceKit-LSP background indexing has a separate setting. See
[index preparation](../../README.md#index-preparation-for-xcode-projects) for setup,
destination synchronization, and DerivedData paths.

## Thread Safety

`XcodeProjectManager` and `XcodeSettingsManager` are actors. Data types use
`Sendable` where applicable.

## Error Handling

`XcodeProjectError` includes:

- `.notFound` - No Xcode project found
- `.multipleWorkspaces([URL])` - Multiple workspaces found, specify one in config
- `.invalidConfig(String)` - Invalid or malformed configuration
