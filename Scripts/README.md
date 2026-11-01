# BSP Client

`bsp_client.py` uses the Python 3 standard library. It starts the server, sends
the initialization messages, calls one BSP method, and shuts the server down.
Results go to stdout. Progress, errors, and optional protocol traces go to stderr.
The process exits with a nonzero status when the request or validation fails.

Build the server with `swift build`. Run these commands from the repository root.
Use a disposable copy of a project: compilation can create schemes and build
products, and debug validation installs and launches the selected application.

```sh
# List targets.
python3 Scripts/bsp_client.py --project /path/to/project

# Compile an application or test target.
python3 Scripts/bsp_client.py --project /path/to/project \
  --method buildTarget/compile --target Hello

# Prepare dependencies and index data without launching the application.
python3 Scripts/bsp_client.py --project /path/to/project \
  --method buildTarget/prepare --target Hello

# Inspect source files or output paths.
python3 Scripts/bsp_client.py --project /path/to/project \
  --method buildTarget/sources --target Hello

# Send a request with explicit parameters and inspect all protocol messages.
python3 Scripts/bsp_client.py --project /path/to/project \
  --method buildTarget/outputPaths \
  --params '{"targets":[{"uri":"xcode:///path/to/Hello.xcodeproj/Hello"}]}' \
  --verbose

# List available simulator identifiers.
xcrun simctl list devices available

# Verify simulator debugging, including a breakpoint and stack trace.
python3 Scripts/bsp_client.py --project /path/to/project \
  --method debugSession/start --target Hello --destination id=SIMULATOR-UDID \
  --breakpoint /path/to/project/Hello/HelloApp.swift:14

# Verify macOS debugging. Omit --breakpoint to use the main function.
python3 Scripts/bsp_client.py --project /path/to/mac-project \
  --method debugSession/start --target App --destination platform=macOS
```

`debugSession/start` also connects to the returned DAP endpoint. The client
initializes LLDB, launches or attaches to the application, verifies a breakpoint,
reads threads and stack frames, and disconnects with `terminateDebuggee: true`.
It reports an adapter crash or timeout as a failure.

Use `--server` to select a different BSP executable, `--developer-dir` to select
an Xcode installation, and `--timeout` to allow more than 300 seconds per BSP
request. `--configuration`, `--derived-data`, and repeated `--build-setting`
options control build arguments. An `arguments` array in `--params` takes
precedence over those options. Requests that need file URIs or other fields can
receive them through `--params`.

This client sends requests. It does not implement an interactive editor or
continuous workspace notifications. A successful response only verifies the
returned result; a method that is still a stub can return success without doing
the requested work. Debug validation also checks the breakpoint, threads, and stack.

`buildTarget/prepare` waits for an incremental Xcode build with indexing enabled
and code signing disabled. It uses the server's configured build configuration,
the target's simulator platform (or macOS), and the same DerivedData directory as
`textDocument/sourceKitOptions`. It does not take the run command's selected device.
SourceKit-LSP builds its symbol index after preparation. Concurrent preparation
requests are serialized; later requests still run Xcode's incremental check so
source edits and deleted products are detected. Build failures return a JSON-RPC
error with the last build output. This implementation uses a regular build;
dependency-only compilation is a future optimization.

For a full indexing pass, run `sourcekit-lsp debug index --project /path/to/project`
with the same Xcode toolchain as the BSP server. The project must have a BSP
connection file that selects the intended executable. For automatic background
indexing, enable it in your editor or in `.sourcekit-lsp/config.json`:

```json
{
  "backgroundIndexing": true,
  "backgroundPreparationMode": "enabled"
}
```

The BSP executable and the project's build products have separate paths:

| Purpose | Default location |
| --- | --- |
| BSP executable from `swift build` | `<repository>/.build/debug/sourcekit-bsp` |
| BSP executable from Xcode | `<BSP DerivedData>/Build/Products/Debug/sourcekit-bsp` |
| Application build products | `<project DerivedData>/Build/Products` |
| Compiler index data | `<project DerivedData>/Index.noindex/DataStore` |
| SourceKit-LSP index database | `<project DerivedData>/IndexDatabase.noIndex` |

Use `--server /absolute/path/to/sourcekit-bsp` to test the executable configured
in the project's BSP connection file. Rebuild that executable after server changes,
then restart the editor's server connection. Building with `swift build` does not
update an executable in Xcode's DerivedData.

Preparation, compiler arguments, and the initialization response use the same
project DerivedData and index-store paths. BSP passes `-derivedDataPath` explicitly
to Xcode. A manual `xcodebuild` command must use that same path to share its products;
Xcode preferences or another `-derivedDataPath` can otherwise select a different
directory. Per-request `--derived-data` overrides for compile/run/debug do not move
the language server's indexing directory.
