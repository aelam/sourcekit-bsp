# Getting started

## Requirements

macOS 13+, Xcode with Swift 6.1+, and your project's SDKs and simulator runtimes.
The command-line probe also requires Python 3.

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

The executable is `/tmp/sourcekit-bsp-build/Build/Products/Debug/sourcekit-bsp`.
For GUI builds, use Xcode's configured DerivedData directory. Rebuild the copy
selected by your client; `swift build` does not update Xcode's copy.

## Configure the application project

Create `.bsp/sourcekit-bsp.json` in the application project root:

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

Clients discover `.bsp/*.json` and start the executable in `argv`.

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
| `scheme` | Preferred existing scheme when it supports the requested target |

The server uses existing schemes and does not create scheme files. If a target has no
matching scheme, create or share one in Xcode before building, running, testing, or
debugging that target.

## Verify the connection

```sh
python3 Scripts/bsp_client.py \
  --server /absolute/path/to/sourcekit-bsp \
  --project /absolute/path/to/HelloProject \
  --method workspace/buildTargets --verbose
```

Use the returned target IDs in protocol requests.

In VS Code, use the Swift extension for SourceKit-LSP and
[vscode-bsp](https://github.com/aelam/vscode-bsp) for build/debug controls.
Select the same Xcode toolchain for both and restart connections after changing configuration.
