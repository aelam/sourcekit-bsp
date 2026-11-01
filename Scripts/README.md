# BSP client

`bsp_client.py` requires Python 3 with no extra packages. Each invocation starts
the server, initializes it, sends one request, and shuts it down. Results go to
stdout; progress, errors, and protocol traces go to stderr. Request failures and
non-success `statusCode` values produce a nonzero exit status.

Build with `swift build`, then run from the repository root:

```sh
bsp_project=/absolute/path/to/HelloProject

# List targets.
python3 Scripts/bsp_client.py --project "$bsp_project"

# Compile a target.
python3 Scripts/bsp_client.py --project "$bsp_project" \
  --method buildTarget/compile --target Hello

# Inspect sources.
python3 Scripts/bsp_client.py --project "$bsp_project" \
  --method buildTarget/sources --target Hello

# Send explicit parameters and show protocol messages. Use a returned target ID.
python3 Scripts/bsp_client.py --project "$bsp_project" \
  --method buildTarget/outputPaths \
  --params '{"targets":[{"uri":"xcode:///path/to/Hello.xcodeproj/Hello"}]}' --verbose

# Reload metadata in this connection.
python3 Scripts/bsp_client.py --project "$bsp_project" --method workspace/reload
```

For simulator commands and test filters, see [Build, run, test, and debug](../Docs/wiki/Build-Run-Test-Debug.md).
For preparation commands and DerivedData paths, see [Indexing and paths](../Docs/wiki/Indexing-and-Paths.md).

## Options

| Option | Purpose |
| --- | --- |
| `--server` | BSP executable; defaults to `.build/debug/sourcekit-bsp` in this repository |
| `--developer-dir` | Xcode `Contents/Developer` directory |
| `--timeout` | Per-request timeout in seconds; defaults to 300 |
| `--configuration` | Xcode build configuration |
| `--destination` | Xcode destination, such as `id=SIMULATOR-UUID` or `platform=macOS` |
| `--derived-data` | Product path for compile/run/test/debug; does not move the language server's index |
| `--build-setting` | Additional Xcode argument; repeat as needed |
| `--params` | Explicit request parameters; its `arguments` array overrides build options |
| `--verbose` | Show protocol messages |

## Debug validation

For `debugSession/start`, the probe connects to LLDB DAP, launches or attaches,
checks a breakpoint, reads threads and stack frames, then terminates the debuggee.
Use `--breakpoint /path/to/File.swift:14`; the default breakpoint is `main`.
An adapter crash or timeout fails validation.

## Limits

The probe has no continuous file notifications or interactive cancellation.
`workspace/reload` affects only its own connection, not an editor's server.
For protocol payloads, see [BSP lifecycle](../Docs/BSP-Lifecycle.md).
