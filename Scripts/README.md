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
