# XcodeProjectManagement

A Swift library for discovering Xcode projects, parsing build settings, and
generating `xcodebuild` arguments for BSP integration.

## Key Components

### XcodeProjectManager

The main entry point for project management operations.

```swift
import XcodeProjectManagement

let manager = XcodeProjectManager(rootURL: projectURL)
let project = try await manager.loadProject()

// Get available schemes and configurations
let schemes = try await manager.getAvailableSchemes()
let configurations = try await manager.getAvailableConfigurations()
```

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

## Thread Safety

`XcodeProjectManager` and `XcodeSettingsManager` are actors. Data types use
`Sendable` where applicable.

## Error Handling

`XcodeProjectError` includes:

- `.notFound` - No Xcode project found
- `.multipleWorkspaces([URL])` - Multiple workspaces found, specify one in config
- `.invalidConfig(String)` - Invalid or malformed configuration
