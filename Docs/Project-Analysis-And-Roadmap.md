# Project Analysis & Roadmap

> Analysis snapshot: 2026-08-06 (branch `main`). A working audit of performance,
> functional, and dependency-coverage gaps in sourcekit-bsp, plus a prioritized
> roadmap. File paths / line numbers are approximate to the snapshot commit —
> re-verify before acting on an item.

sourcekit-bsp is a **Build Server Protocol 2.0** implementation for **Xcode
projects** that feeds per-file compiler arguments to SourceKit-LSP. The Xcode
path is functional; the gaps below are the areas worth investing in.

---

## 1. Performance

**Core issue: every `textDocument/sourceKitOptions` request recomputes compiler
arguments from scratch with almost no caching.** The editor fires this request
on every file open / switch, so it becomes a bottleneck on large projects.

| Issue | Location | Severity |
|---|---|---|
| Compiler args never cached — each request re-runs `SourceFileLister.loadSourceFiles()` + a fresh `CompileArgGenerator` (20+ providers) | `Sources-MacOS/XcodeProjectManagement/ProjectManager/XcodeProjectManager+SourceKitOptions.swift:11` | High |
| `sourceFileMapCache` is declared but never read/written (dead cache) | `Sources-MacOS/XcodeProjectManagement/ProjectManager/XcodeProjectManager.swift:86` | High |
| Synchronous directory scan per source file | `SwiftFilesProvider.swift:15`, `ModuleMapFilesProvider.swift:8`, `VFSOverlayProvider.swift:22` (`FileManager.contentsOfDirectory` / `fileExists` on every request) | High |
| xcconfig re-parsed with no memoization; `#include` diamonds parsed repeatedly | `BuildSettings/XCConfigParser.swift:15` | Medium |
| Build settings recomputed every time (no cache) | `BuildSettings/BuildSettingResolver.swift` | Medium |
| JSON-RPC: unbounded Task spawn, no backpressure | `Sources/JSONRPCConnection/JSONRPCConnection.swift:45` | Low-Medium |

**Recommendations (highest ROI first):**
1. Activate `sourceFileMapCache`, and add a `[targetID: [file: [String]]]` compiler-args cache. Invalidate on `didChangeWatchedFiles` / reload — **note those handlers are currently empty (see §2), so cache invalidation must be built together with them.**
2. Cache directory-scan results (GeneratedModuleMaps, swift file lists, VFS existence) at target level.
3. Memoize `XCConfigParser` results.
4. `SwiftProvider.swift:20` hardcodes `-j14` → use `ProcessInfo.processInfo.activeProcessorCount`.

---

## 2. Functional (implemented but flawed)

**⚠️ Most severe: `-suppress-warnings` is hardcoded** at
`Sources-MacOS/XcodeProjectManagement/CompilerArgumentsProvider/Providers/CompilerOptions/SwiftProvider.swift:24`.
This makes SourceKit-LSP swallow **all** Swift warnings — no warning diagnostics
appear in the editor. For an IDE-integration tool this is a real regression;
remove it or make it configurable.

Other defects:
- **`.h` header dialect mapping is wrong** — `.h` maps to `.objcCpp` (should be `.objc`/`.c`). `BuildSettings/XcodeBuildSettings.swift` + `XcodeProjectManagerProvider/Conversions/Language+XcodeLanguageDialect.swift`. Pure-C headers get treated as ObjC++.
- **File watching declared but inert** — `build/initialize` advertises file watchers, but the handlers are empty:
  - `Sources/BSPServer/BSPMessages/workspace/WorkspaceDidChangeWatchedFilesNotification.swift:22`
  - `Sources/BSPServer/BSPMessages/workspace/WorkspaceReloadNotification.swift:22`
  → After editing `.pbxproj` or adding/removing files, BSP never tells SourceKit-LSP to refresh; user must restart the editor. **Highest-ROI functional fix.**
- **`buildTarget/didChange` notification type defined but not registered** in `Sources/BSPServer/BSPMessageRegistry.swift` — clients never receive target-change events.
- **Crash risk**: `Sources-MacOS/XcodeProjectManagement/ProjectManager/XcodeProjectManager+SourcesItems.swift:5` calls `fatalError` if invoked before `initialize()`; should throw.
- Wrong error code (FIXME): `Sources/BSPServer/BSPMessages/textDocument/TextDocumentSourceKitOptionsRequest.swift:132` uses LSP's `-32002`.

---

## 3. Missing features: SPM libraries / C library dependencies

### SwiftPM support — a **disabled stub**
- `Sources/SwiftPMProjectManagerProvider/SwiftPMProjectManagerProvider.swift:19` — `canHandle()` hardcoded `return false`.
- `createProjectManager` throws `.notImplemented`.
- `SwiftPMProjectInfo.swift` is entirely commented out (contains Chinese TODOs).

→ **Pure Swift Package projects are currently unsupported**, despite the README implying package support. Missing:
- Package.swift parsing (via `swift package dump-package` or libSwiftPM)
- External package dependency resolution
- Compiler-args generation / target enumeration / source-file listing

### C / C++ / Objective-C system-library dependencies — **none**
- No `systemLibrary` target support, no module-map generation, no `pkgConfig` integration.
- A Clang provider exists on the Xcode side, but SPM-side C targets / C-library deps are entirely absent.

### SPM packages inside Xcode projects — **half-supported**
- `Sources-MacOS/XcodeProjectManagement/CompilerArgumentsProvider/Providers/SearchPaths/FrameworkSearchPathProvider.swift:23` just appends `CONFIGURATION_BUILD_DIR/PackageFrameworks` to framework search paths, assuming Xcode already built the packages. If unresolved/unbuilt, compiler args are incomplete.

### Other missing BSP methods
`buildTarget/inverseSources`, `buildTarget/dependencySources`, `buildTarget/resources` (advertised in capabilities but unimplemented), `buildTarget/cleanCache` (returns "Not implemented"), `buildTarget/outputPaths` (returns empty array).

---

## Prioritized roadmap

| Priority | Item | Category |
|---|---|---|
| 🔴 P0 | Remove / make configurable `-suppress-warnings` | Functional fix |
| 🔴 P0 | Implement file-watch handlers + target cache invalidation + compiler-args cache | Functional + Performance |
| 🟠 P1 | Activate `sourceFileMapCache`; cache directory scans / xcconfig parses | Performance |
| 🟠 P1 | Decide on SwiftPM: implement for real (libSwiftPM), or explicitly drop from README/capabilities | Feature gap |
| 🟡 P2 | Fix `.h` dialect mapping, `fatalError`, `-j14` hardcode, register `didChange` | Correctness |
| 🟢 P3 | SPM / C-library dependencies, remaining BSP methods | Long-term capability |

---

## Testing

Four layers, fastest → most realistic:

1. **Unit tests** (`swift test`) — compiler-args / build-settings logic against the demo Xcode projects in `Tests*/…/Resources/DemoProjects`. Best place for cache, `-suppress-warnings`, and `.h`-dialect regression tests.
2. **CLI direct** — `XcodeProjectCLI` bypasses JSON-RPC entirely: `swift run XcodeProjectCLI compileArguments -w <folder> -x <proj>.xcodeproj -t <target> --source-file <file>`. Fastest way to debug per-file args against a real project. Subcommands: `resolveProject`, `compileTarget`, `buildSettings`, `compileArguments`.
3. **Protocol / message-sequence tests** — `Tests/BSPServerTests/Harness/` provides `BSPTestHarness` + `InMemoryTransport`: drives a real `BSPServerService` over an in-memory transport (no stdio/subprocess). Inject requests, await responses by id or notifications by method. See `BSPServerProtocolTests.swift` for the pattern. **This layer was previously empty** — it's where cross-request state bugs (file watching, `didChange`, cache invalidation) should be caught.
4. **Real editor** — `buildServer.json` pointing at the built binary + VS Code / SourceKit-LSP; `BSP_DEBUG=1` for logs.

Harness quick start:

```swift
let h = await BSPTestHarness.make()
let data = try await h.request(method: "build/shutdown", id: 1)
XCTAssertEqual(try h.json(data)["id"] as? Int, 1)
await h.shutdown()
```
