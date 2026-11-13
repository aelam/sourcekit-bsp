# Swift Build indexing

This branch evaluates Swift Build as the Xcode indexing backend.

Enable dependency preparation with a server launch flag:

```sh
sourcekit-bsp --enable-build-target-prepare
```

For an editor, append `--enable-build-target-prepare` after the server executable
in `.bsp/*.json`'s `argv`. The Hello demo includes it in `.bsp/config.json`.
Omit the flag to keep preparation disabled. The flag takes no value.

This option selects Swift Build for compiler options and dependency preparation.
It does not turn SourceKit-LSP background indexing on or off. In VS Code, set
`swift.sourcekit-lsp.backgroundIndexing` to `"on"`; Hello already uses this value.
The server must be built with `SOURCEKIT_BSP_SWIFT_BUILD=1` and include the
matching `SWBBuildServiceBundle` executable and resources.

BSP connection initialization does not start Swift Build or create an indexing
plan. The first compiler-option or preparation request loads the workspace and
plans the requested target and its dependencies. Concurrent requests for the
same target share planning work. The server retains up to four recent plans
through Swift Build's description-lifetime API. Active queries retain their
plans until completion. Evicted plans are recreated when needed. Preparation
compares published options only for the target being prepared.
Logs distinguish queued work, work that has acquired the build lock, and elapsed
time. Initial planning can still take time for a target with many dependencies.

The platform follows the last destination resolved for Build, Run, Debug, or
Test. Before the first selection, the backend uses the project's simulator
platform when it can determine one, or iOS Simulator as the fallback.

The backend preserves the project's existing `Index.noindex/DataStore` and
`IndexDatabase.noIndex` paths. The BSP initialization response directs
SourceKit-LSP to these paths for both indexing backends. Restart SourceKit-LSP
after changing the server binary so it receives the current paths.

Preparation products use `Index.noindex/Build/Products`; intermediates use
`Index.noindex/Build/Intermediates.noindex`. The build request retains the
project's DerivedData root and identifies the normal `Build/Products` and
`Build/Intermediates.noindex` directories for the index overlay. Module and
compilation caches follow the build engine's settings.

The last executed destination is stored in
`Logs/sourcekit-bsp/indexing-selection.json`. No separate DerivedData tree is
created for this backend. A shared layout does not guarantee that ordinary
builds can reuse modules emitted with indexing-specific compiler flags.

## Validate with Hello

Run these commands from the repository root after building the server with
Swift Build support:

```sh
demo=Tests-MacOS/XcodeProjectManagementTests/Resources/DemoProjects/HelloProject
python3 Scripts/benchmark_indexing.py \
  --server .build/debug/sourcekit-bsp \
  --project "$demo" --target Hello \
  --source "$demo/Hello/ContentView.swift" \
  --backend swift-build --prepare \
  --output /tmp/hello-indexing.json
```

The report includes initialization time, compiler-option latency, two preparation
times, compiler arguments, and the index paths returned by BSP. The process-tree
RSS sample is an estimate, not a precise memory measurement. Repeated runs reuse
existing products and caches.

For a SourceKit-LSP indexing pass, first update Hello's `.bsp/config.json` to point
at your server binary and Xcode installation. Then run:

```sh
xcrun sourcekit-lsp --bypass-workspace-trust debug index --project "$demo"
```

Check that the reported index store is the project's `Index.noindex/DataStore`
and that preparation paths use `Index.noindex/Build`. A warm indexing pass may
finish without running compiler jobs.

To measure the default compiler-option provider, run the benchmark with
`--backend xcodebuild`. Default BSP preparation is a no-op, so its preparation
time is not a comparison with Swift Build's preparation work. Measure a cold
indexing pass and a source-change pass before drawing conclusions about project
indexing performance.
