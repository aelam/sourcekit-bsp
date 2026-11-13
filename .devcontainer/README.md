# sourcekit-bsp Dev Container

This Dev Container configuration allows you to develop sourcekit-bsp without needing an Xcode environment, while running code quality tools like SwiftLint and SwiftFormat.

## Features

- ✅ **Swift 6.1 Environment** - Complete Swift development environment
- ✅ **SwiftLint** - Code style checking and auto-fixing
- ✅ **SwiftFormat** - Code formatting tool
- ✅ **VSCode Swift Extension** - Syntax highlighting, IntelliSense, etc.
- ✅ **Debug Support** - Run BSP debug mode
- ✅ **Git Integration** - Full Git support

## Usage

### 1. Open Dev Container
1. Ensure **Dev Containers** extension is installed
2. Open the project folder
3. Press `Ctrl+Shift+P` (Windows/Linux) or `Cmd+Shift+P` (Mac)
4. Select **"Dev Containers: Reopen in Container"**
5. Wait for container build and setup completion

### 2. Development Commands

#### Basic Swift Commands
```bash
# Build project
swift build

# Run tests
swift test

# Run specific target
swift run sourcekit-bsp

# Clean build
swift package clean
```

#### Code Quality Tools
```bash
# Run SwiftLint check
swiftlint

# Auto-fix SwiftLint issues
swiftlint --fix

# Run SwiftFormat check
swiftformat --lint .

# Format code
swiftformat .
```

#### Convenient Aliases
The container sets up these aliases:
```bash
# Build and test
bsp-build          # swift build + success message
bsp-test          # swift test --parallel

# Debug
bsp-debug         # swift run sourcekit-bsp --debug

# Code quality
lint              # swiftlint && swiftformat --lint .
format            # swiftformat . && swiftlint --fix

# Scripts
./.devcontainer/scripts/lint.sh           # Complete code checking
./.devcontainer/scripts/format.sh         # Complete code formatting
./.devcontainer/scripts/build-and-test.sh # Build and test
```

### 3. Debug BSP Server

```bash
# Start debug mode
swift run sourcekit-bsp --debug

# Or use alias
bsp-debug

# Test JSON-RPC messages
echo '{"id":1,"jsonrpc":"2.0","method":"build/initialize","params":{"rootUri":"file:///tmp"}}' | bsp-debug
```

## Configuration Files

The project uses these configuration files:

- **`.swiftlint.yml`** - SwiftLint rules configuration
- **`.swiftformat`** - SwiftFormat formatting configuration
- **`.devcontainer/devcontainer.json`** - Dev Container configuration
- **`.devcontainer/setup.sh`** - Container initialization script

## Supported Workflows

### 1. Pure Swift Development
- Modify non-Xcode related code
- JSON-RPC protocol implementation
- Message handling logic
- Unit testing

### 2. Code Quality Maintenance
- Run SwiftLint to fix code style issues
- Use SwiftFormat to maintain consistent code formatting
- Automated code review preparation

### 3. Protocol Debugging
- Use `--debug` to observe JSON-RPC communication
- Test message handling logic
- Verify protocol compliance

## Limitations

⚠️ **Not supported**:
- Xcode project operations (requires macOS + Xcode)
- Actual Swift/Objective-C compilation (requires Xcode toolchain)
- iOS/macOS specific functionality testing

💡 **Suggested workflow**:
- Protocol development and testing in Dev Container
- Xcode integration testing in macOS environment

## Troubleshooting

### Container startup fails
```bash
# Rebuild container
Ctrl+Shift+P -> "Dev Containers: Rebuild Container"
```

### SwiftLint/SwiftFormat not found
```bash
# Re-run setup script
./.devcontainer/setup.sh
```

### Swift package dependency issues
```bash
# Clean and re-resolve dependencies
swift package clean
swift package resolve
```

## More Information

- [Swift Official Documentation](https://docs.swift.org/)
- [SwiftLint Documentation](https://github.com/realm/SwiftLint)
- [SwiftFormat Documentation](https://github.com/nicklockwood/SwiftFormat)
- [Dev Containers Documentation](https://containers.dev/)
