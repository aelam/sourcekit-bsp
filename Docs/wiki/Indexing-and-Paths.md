# Indexing and paths

SourceKit-LSP provides navigation and references. sourcekit-bsp supplies source
files, compiler options, toolchain information, and the build inputs needed for
indexing. A BSP client does not need to implement symbol indexing itself.

## Preparation and indexing

`buildTarget/prepare` waits for an incremental Xcode build with indexing enabled
and code signing disabled. It uses the project's configured build configuration
and the target's simulator platform, or macOS for a Mac target. It currently
performs a regular build; dependency-only preparation is a future optimization.

```sh
python3 Scripts/bsp_client.py --server /absolute/path/to/sourcekit-bsp \
  --project /absolute/path/to/HelloProject \
  --method buildTarget/prepare --target Hello
```

Preparation is advertised to SourceKit-LSP. It is called when the language
server schedules preparation, such as during background indexing. Opening an
editor does not guarantee that the editor has enabled background indexing.

With a BSP connection file in the application project, run a full indexing pass:

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

Supported settings depend on the SourceKit-LSP version. The documented workflow
has been verified with the Xcode 26.6 toolchain.

Concurrent preparation requests are serialized. Subsequent requests still run
Xcode's incremental check, so changed sources and deleted products are detected.
Failures return an error with build output. Cancellation reaches the active
build; a later request can retry.

## Keep executable and project paths separate

| Purpose | Location |
| --- | --- |
| Server built with `swift build` | `<repository>/.build/debug/sourcekit-bsp` |
| Server built with Xcode | `<server DerivedData>/Build/Products/Debug/sourcekit-bsp` |
| Application products | `<project DerivedData>/Build/Products` |
| Compiler index data | `<project DerivedData>/Index.noindex/DataStore` |
| SourceKit-LSP index database | `<project DerivedData>/IndexDatabase.noIndex` |

Changing the server executable does not select the application's build directory.
The server calculates the project DerivedData path and passes it to Xcode.
Initialization, compiler options, and preparation use consistent index paths.

A manual `xcodebuild` invocation must use the same `-derivedDataPath` to share
products. Xcode preferences or another command-line path can select a different
directory. Use `buildTarget/outputPaths` to inspect the server's default product
root; it does not report every per-request path override.

The Python client's `--derived-data` option applies to compile/run/test/debug
requests. It does not relocate SourceKit-LSP's configured index directory.
Use matching options for compile and run, and rebuild the executable specified
by `argv` after changing the server's source.
