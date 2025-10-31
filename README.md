# sourcekit-bsp

[![Swift](https://img.shields.io/badge/swift-6.1+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)](https://developer.apple.com/macos/)
[![Build Status](https://github.com/aelam/sourcekit-bsp/workflows/CI/badge.svg)](https://github.com/aelam/sourcekit-bsp/actions)
[![codecov](https://codecov.io/github/aelam/sourcekit-bsp/graph/badge.svg?token=SUL2UI5FQD)](https://codecov.io/github/aelam/sourcekit-bsp)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A Build Server Protocol (BSP) implementation for Xcode projects, enabling better IDE integration with Swift and Objective-C codebases.

## Features

- 🔧 **BSP 2.0 Support**: Full compatibility with Build Server Protocol 2.0
- 🏗️ **Xcode Integration**: Seamless integration with Xcode build system
- ⚡ **Fast Indexing**: Efficient source code indexing and navigation
- 📁 **Multi-target Support**: Support for complex Xcode project structures
- 🔍 **SourceKit Integration**: Native Swift language server capabilities with complete `textDocument/sourceKitOptions` implementation
- 🛡️ **Thread-safe**: Robust concurrent operations with Swift actors
- 📊 **Comprehensive Build Settings**: Full support for per-file compiler arguments via `XcodeProj`

## Demo

See sourcekit-bsp in action with seamless code navigation and jump-to-definition:

![Navigation Demo](Docs/Navigation.gif)

## Installation

### Manual Installation
1. Download the latest release from [GitHub Releases](https://github.com/aelam/sourcekit-bsp/releases)
2. Extract and move to your PATH:
   ```bash
   tar -xzf sourcekit-bsp-macos-universal.tar.gz
   sudo mv release/sourcekit-bsp /usr/local/bin/
   chmod +x /usr/local/bin/sourcekit-bsp
   ```

### Build from Source
```shell
git clone https://github.com/wang.lun/sourcekit-bsp.git
cd sourcekit-bsp
swift build -c release
cp .build/release/sourcekit-bsp /usr/local/bin/sourcekit-bsp
```

### Homebrew (Coming Soon)
```shell
# Not yet available
brew install sourcekit-bsp
```

## Configuration

### BSP Configuration

 Create a `buildServer.json` ~~`.bsp/sourcekit-bsp.json`~~ file in your project root:

```json
{
   "name": "sourcekit-bsp",
   "version": "0.2",
   "bspVersion": "2.2.0",
   "languages": [
      "objective-c",
      "objective-cpp",
      "swift"
   ],
   "argv": [
      "path/to/sourcekit-bsp"
   ]
}
```

sourcekit-lsp looks for configuration in the following order:
1. `.bsp/*.json` files (BSP standard)
   - `*.json` in `.bsp/` directory for your project/workspace
2. `buildServer.json` in project root (legacy support)

NOTE: `vscode-swift` requires the `buildServer.json` file to be located in the root of your non-SwiftPM project.


### Project Configuration

For complex projects, create a `.sourcekit-bsp/project.json` configuration file:

```json
{
  "workspace": "YourProject.xcworkspace",
  "project": "YourProject.xcodeproj",
  "scheme": "YourScheme",
  "configuration": "Debug"
}
```

#### Configuration Options

| Option | Description | Required |
|--------|-------------|----------|
| `workspace` | Path to .xcworkspace file | Yes* |
| `project` | Path to .xcodeproj file | Yes* |
| `scheme` | Xcode scheme to use | Yes |
| `configuration` | Build configuration (Debug/Release) | No (defaults to Debug) |

*Either `workspace` or `project` is required.

#### When Project Configuration is Required

The `.sourcekit-bsp/project.json` file is required for:
- Multiple workspaces
- Multiple projects without a workspace
- Custom build configurations
- Projects/workspaces with multiple schemes for multi iOS apps that sourcekit-bsp can not guess which one is main 

## Quick Start

1. **Install sourcekit-bsp** using one of the installation methods above

2. **Configure your project** following the configuration section

3. **Validate your project**:
   ```shell
   XcodeProjectCLI /path/to/projectFolder
   ```
   This will check your project settings and report any issues.

4. **Start the server**:
   ```shell
   sourcekit-bsp
   ```

5. **Connect from your IDE**: Configure your IDE to connect to the BSP server (typically on stdio).

## IDE Integration

### VS Code with SourceKit-LSP

Install the VSCode-Swift extension. For Swift versions lower than 6.1, configure:

```json
{
  "swift.sourcekit-lsp.serverPath": "/path/to/sourcekit-lsp",
  "swift.sourcekit-lsp.toolchainPath": "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain"
}
```

### Vim/Neovim

Use with [vim-lsp](https://github.com/prabirshrestha/vim-lsp) or [coc.nvim](https://github.com/neoclide/coc.nvim).


## Development

### Prerequisites
- macOS 12.0+
- Xcode 14.0+
- Swift 6.1+

### Building
```bash
swift build
```

### Testing
```bash
swift test
```

## Architecture

```
┌─────────────────┐    JSON-RPC     ┌──────────────────┐
│       IDE       │ ◄─────────────► │  sourcekit-bsp   │
└─────────────────┘                 └──────────────────┘
                                            │
                                            ▼
                                    ┌─────────────────┐
                                    │ Xcode Build     │
                                    │ System          │
                                    └─────────────────┘
```

### Key Components

- **BSPServerService**: Core BSP protocol implementation
- **JSONRPCConnection**: JSON-RPC transport layer
- **ProjectManagerProvider** : Provides access to the ProjectManager
- **ProjectManager**: Manages Xcode project/workspace parsing and build settings extraction
- **XcodeProjectManager**: Handles Xcode-specific project operations
- **XcodeBuild Integration**: Interface with xcodebuild tool
- **SwiftPMProjectManager**: (TODO)Handles SwiftPM-specific project operations


### BSP Method Support

| Method | Status | Description |
|--------|--------|-------------|
| `build/initialize` | ✅ Complete | Server initialization with capabilities |
| `build/initialized` | ✅ Complete | Post-initialization notification |
| `workspace/buildTargets` | ✅ Complete | List all build targets |
| `buildTarget/sources` | ✅ Complete | Get source files for targets |
| `textDocument/sourceKitOptions` | ✅ **Complete** | **Per-file compiler arguments from buildSettingsForIndex** |
| `buildTarget/prepare` | [ ] | Background indexing preparation |
| `buildTarget/didChange` | [ ] | Build target change notifications, need a BSP client with full feature |
| `workspace/didChangeWatchedFiles` | [] | File system change handling |

## Troubleshooting

### Common Issues

1. **Server not starting**: Check that your configuration file is valid JSON
2. **Build failures**: Ensure your Xcode project builds successfully first
3. **Index not updating**: Verify that the scheme and configuration are correct

### Logging

Logs are written to `/tmp/sourcekit-bsp.log`

### Verify if sourcekit-bsp can resolve your project

```sh
# See if project can be resolved
XcodeProjectCLI resolveProject --workspace-folder /path/to/projectFolder

# See if buildSettings of project can be resolved
XcodeProjectCLI buildSettings \
--workspace-folder /path/to/projectFolder \
--xcodeproj relative/path/of/workspace-folder/to/{project}.xcodeproj \
--target targetNameInXcodeProj

# See if a source file compile arguments can be generated
XcodeProjectCLI compileArguments \
--workspace-folder /path/to/projectFolder \ 
--xcodeproj relative/path/of/workspace-folder/to/{project}.xcodeproj \
--target targetNameInXcodeProj \
--source-file relative/path/of/workspace-folder/to/source-file

```


## Contributing

We welcome contributions! Please see our [Contributing Guidelines](CONTRIBUTING.md) for details.

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests
5. Submit a pull request

## References

- [Build Server Protocol Specification](https://build-server-protocol.github.io/)
- [SourceKit-LSP](https://github.com/apple/sourcekit-lsp)
  - [Implementing a BSP server](https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/Implementing%20a%20BSP%20server.md)

Inspired by [sourcekit-bazel-bsp](https://github.com/spotify/sourcekit-bazel-bsp)
and [xcode-build-server](https://github.com/SolaWing/xcode-build-server)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Apple for SourceKit and the Swift toolchain
- The Build Server Protocol community
- Contributors to the Swift ecosystem
