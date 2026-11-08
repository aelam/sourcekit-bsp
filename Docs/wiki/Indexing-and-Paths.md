# Indexing and paths

sourcekit-bsp prepares compiler inputs and index data. SourceKit-LSP builds the
symbol index used for navigation and references.

## Preparation and indexing

`buildTarget/prepare` runs a regular incremental Xcode build with indexing enabled
and code signing disabled. It uses the configured build configuration and the
target's simulator platform or macOS, independently of the selected run device.

```sh
python3 Scripts/bsp_client.py --server /absolute/path/to/sourcekit-bsp \
  --project /absolute/path/to/HelloProject \
  --method buildTarget/prepare --target Hello
```

SourceKit-LSP requests preparation when indexing is enabled. With a BSP connection
file in the project, run a full indexing pass:

```sh
xcrun sourcekit-lsp debug index --project /absolute/path/to/HelloProject
```

Use the same Xcode toolchain as the BSP server. To configure automatic indexing,
set your editor's SourceKit-LSP options or create `.sourcekit-lsp/config.json`:

```json
{
  "backgroundIndexing": true,
  "backgroundPreparationMode": "enabled"
}
```

Settings depend on the SourceKit-LSP version. Each preparation checks for changed
sources or deleted products. Failures include build output; a failed or cancelled
build can be retried.

Compile, test, preparation, builds before debug, and build-settings queries with
an explicit DerivedData path share a queue for that directory. An operating-system
file lock also coordinates separate sourcekit-bsp processes, including the servers
started by vscode-bsp and SourceKit-LSP. Different directories can run concurrently.
Cancellation removes a waiting request or waits for its running process and output
to finish before releasing the lock.

Lock files remain in `~/Library/Caches/sourcekit-bsp/build-locks`, outside DerivedData,
so cache cleanup cannot replace a lock that another process is waiting for. The
operating system releases a process's lock when it closes the file or exits.

After upgrading, restart both the vscode-bsp connection and SourceKit-LSP's server.
Let builds from older server processes finish first. Xcode GUI builds and manual
`xcodebuild` commands do not use this lock; avoid running them concurrently against
the same DerivedData directory.

## Keep executable and project paths separate

| Purpose | Location |
| --- | --- |
| Server built with `swift build` | `<repository>/.build/debug/sourcekit-bsp` |
| Server built with Xcode | `<server DerivedData>/Build/Products/Debug/sourcekit-bsp` |
| Application products | `<project DerivedData>/Build/Products` |
| Compiler index data | `<project DerivedData>/Index.noindex/DataStore` |
| SourceKit-LSP index database | `<project DerivedData>/IndexDatabase.noIndex` |

The server passes a project DerivedData path to Xcode and uses consistent index
paths for initialization, compiler options, and preparation. Manual Xcode builds
must use the same `-derivedDataPath` to share products.

`buildTarget/outputPaths` reports the default product root. The probe's
`--derived-data` overrides compile/run/test/debug paths without moving the language
server's index. Use matching paths for compile and run.
