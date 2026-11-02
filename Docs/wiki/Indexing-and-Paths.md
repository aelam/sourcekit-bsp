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

Within one server process, compile, test, preparation, and builds before debug
share a queue for each DerivedData directory, including explicit path overrides.
Builds in different directories can run concurrently. Cancellation waits for the
process to exit and its output to drain before the next build starts. Separate
server processes and builds started directly in Xcode are outside this queue.

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
