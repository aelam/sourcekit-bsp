# Indexing and paths

sourcekit-bsp supplies compiler arguments and can prepare indexing dependencies.
SourceKit-LSP builds the symbol index used for navigation and references.

## Preparation and indexing

By default, `buildTarget/prepare` completes without building. To prepare dependency
modules and generated files with Swift Build, enable `prepareForIndexing` in
`.sourcekit-bsp/project.json`:

```json
{
  "prepareForIndexing": true
}
```

This requires a server built with `SOURCEKIT_BSP_SWIFT_BUILD=1` and its matching
build service and resources. See [build and setup](../../README.md#index-preparation-for-xcode-projects).
`SOURCEKIT_BSP_PREPARE_FOR_INDEXING=1` also enables preparation; `0` disables it.
This environment variable overrides the project setting.

Preparation generates indexing inputs without linking or packaging the application.
The last destination and configuration resolved when Build, Run, Test, or Debug
starts also apply to indexing. Menu selection alone does not update them.

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

Settings depend on the SourceKit-LSP version. The VS Code Swift extension also
supports `"swift.sourcekit-lsp.backgroundIndexing": "on"`. This controls the language
server, independently of the BSP preparation setting. Swift Build checks changed
inputs on each preparation; a failed or cancelled preparation can be retried.

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
| Index preparation products | `<project DerivedData>/Index.noindex/Build/Products` |
| Index preparation intermediates | `<project DerivedData>/Index.noindex/Build/Intermediates.noindex` |
| Compiler index data | `<project DerivedData>/Index.noindex/DataStore` |
| SourceKit-LSP index database | `<project DerivedData>/IndexDatabase.noIndex` |

The server passes a project DerivedData path to Xcode and uses consistent index
paths for initialization, compiler options, and preparation. Manual Xcode builds
must use the same `-derivedDataPath` to share products.

Index preparation emits reduced modules for language analysis. These do not
replace application build products. A shared index store also does not guarantee
reuse of all index records when compiler arguments differ.

`buildTarget/outputPaths` reports the default product root. The probe's
`--derived-data` overrides compile/run/test/debug paths without moving the language
server's index. Use matching paths for compile and run.
