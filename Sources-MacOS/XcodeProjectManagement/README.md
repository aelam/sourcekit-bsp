# XcodeProjectManagement

A Swift library for managing Xcode projects, parsing settings, and building xcodebuild command arguments for BSP (Build Server Protocol) integration.

## Overview

This module provides comprehensive support for:

- **Project Discovery**: Automatically locate and resolve Xcode projects and workspaces
- **Settings Management**: Parse and manage Xcode build settings and configurations  
- **Command Building**: Generate properly formatted xcodebuild command arguments
- **BSP Integration**: Specialized support for Build Server Protocol workflows

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

BSP clients discover server connection files in `.bsp/*.json`. Create
`.bsp/sourcekit-bsp.json` in the application project root:

```json
{
  "name": "sourcekit-bsp",
  "version": "1.0",
  "bspVersion": "2.2.0",
  "languages": ["swift", "c", "cpp", "objective-c", "objective-cpp"],
  "argv": ["/absolute/path/to/sourcekit-bsp"]
}
```

The client starts the executable from `argv` and sends the project root URI in
`build/initialize`. To select an Xcode project or workspace when discovery is
ambiguous, create `.sourcekit-bsp/project.json`:

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

All public APIs are designed to be thread-safe:

- `XcodeProjectManager` is an `actor` for safe concurrent access
- `XcodeSettingsManager` is an `actor` for safe concurrent access  
- All data structures conform to `Sendable` where applicable

## Error Handling

The module provides comprehensive error handling through `XcodeProjectError`:

- `.notFound` - No Xcode project found
- `.multipleWorkspaces([URL])` - Multiple workspaces found, specify one in config
- `.invalidConfig(String)` - Invalid or malformed configuration

## Integration

This module integrates seamlessly with the main sourcekit-bsp for BSP support, but can also be used independently for general Xcode project management tasks.
