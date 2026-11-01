# Getting started

## Requirements

- macOS 13 or later for the Xcode backend.
- A full Xcode installation with Swift 6.1 or later to build the server.
- The project's SDK and a compatible simulator runtime for simulator execution.
- Python 3 to use `Scripts/bsp_client.py`; no Python packages are required.

The repository also tests portable modules on Linux. Its SwiftPM project provider
is not implemented, so Linux builds do not provide an Xcode or SwiftPM backend.

## Choose the server executable

From the repository root:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
```

This produces `.build/debug/sourcekit-bsp`. To use an Xcode build:

```sh
xcodebuild -scheme sourcekit-bsp -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/sourcekit-bsp-build build
```

This produces `/tmp/sourcekit-bsp-build/Build/Products/Debug/sourcekit-bsp`.
An Xcode GUI build can use another DerivedData directory. Select the actual
executable in the connection file and in the Python client's `--server` option.

## Configure the application project

Create `buildServer.json` in the project root for SourceKit-LSP compatibility:

```json
{
  "name": "sourcekit-bsp",
  "version": "1.0",
  "bspVersion": "2.2.0",
  "languages": ["swift", "c", "cpp", "objective-c", "objective-cpp"],
  "argv": [
    "/usr/bin/env",
    "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer",
    "/absolute/path/to/sourcekit-bsp"
  ]
}
```

For a client that discovers `.bsp/*.json`, use `.bsp/sourcekit-bsp.json` with the
same contents. Check the discovery behavior of the client version you use.
Avoid leaving connection files that select different server builds.

If automatic project discovery is ambiguous, create `.sourcekit-bsp/project.json`:

```json
{
  "workspace": "Example.xcworkspace",
  "configuration": "Debug"
}
```

| Field | Meaning |
| --- | --- |
| `workspace` | Workspace path, absolute or relative to the root; takes precedence over `project` |
| `project` | Xcode project path, absolute or relative to the root |
| `configuration` | Default build configuration; defaults to `Debug` |
| `scheme` | Parsed for compatibility; does not currently override target-based scheme selection |

The file is optional for a single discoverable project. Schemes are resolved for
the requested targets; the server can create `sourcekit-bsp-<Target>.xcscheme`
files when it needs a scheme.

## Verify the connection

```sh
python3 Scripts/bsp_client.py \
  --server /absolute/path/to/sourcekit-bsp \
  --project /absolute/path/to/HelloProject \
  --method workspace/buildTargets --verbose
```

The script starts the server, initializes it, sends a request, and shuts it down.
Use the returned target identifiers in protocol requests. Do not construct them
from filesystem paths: paths can have aliases, spaces, or normalized forms.

In VS Code, the Swift extension starts SourceKit-LSP. A BSP client such as
vscode-bsp adds build/run/test/debug controls. Select the same Xcode toolchain
for both clients and restart their server connections after a configuration change.

Running `sourcekit-bsp` directly waits for framed JSON-RPC messages on stdin.
Project loading starts when the client sends `build/initialize` with `rootUri`.
