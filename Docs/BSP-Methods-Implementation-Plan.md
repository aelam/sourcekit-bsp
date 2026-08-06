# BSP Methods — Cross-Repo Implementation Plan

> Plan for the BSP methods that are **advertised but not (fully) implemented**,
> covering BOTH sides of the protocol. Snapshot: 2026-08-06.
> Re-verify file paths/line numbers before acting — they drift.

## The two repos

| Repo | Path | Role | Stack | Key files |
|------|------|------|-------|-----------|
| **sourcekit-bsp** | `/Users/wang.lun/Work/sourcekit-bsp` | BSP **server** | Swift | `Sources/BSPServer/BSPMessages/*`, `BSPMessageRegistry.swift`, `Sources/JSONRPCConnection/*` |
| **vscode-bsp** | `/Users/wang.lun/Work/vscode-bsp` | BSP **client** | TypeScript | `src/bspTypes.ts`, `src/bspClient.ts`, `src/debugProvider.ts`, `src/targetManager.ts` |

**Rule for syncing:** a protocol change must land on both sides in lockstep.
Server adds/changes a method → client's `bspTypes.ts` (types) + `bspClient.ts`
(send/handle) + any UI must follow, or one end emits what the other ignores.

> Note: SourceKit-LSP is a *separate* BSP client of sourcekit-bsp (for indexing
> / `textDocument/sourceKitOptions`). vscode-bsp is the second client (targets /
> build / run / test / debug UI). Protocol bugs can crash either — validate
> against both.

## What each client already speaks (grounding, 2026-08-06)

vscode-bsp `bspClient.ts` currently **sends**: `build/initialize`,
`build/initialized`, `build/shutdown`, `build/exit`, `workspace/buildTargets`,
`workspace/reload`, `buildTarget/compile`, `buildTarget/test`,
`buildTarget/run`, `debugSession/start`.
It **handles notifications**: `build/publishDiagnostics`, `build/taskStart`,
`build/taskFinish`, `build/taskProgress`, `build/logMessage`,
`build/showMessage`.
It does **not** send `buildTarget/{inverseSources,dependencySources,resources,
outputPaths}` and does **not** handle `buildTarget/didChange`.

## Priority key

- 🔴 **P0** — a client actually calls/needs it today; real user impact.
- 🟠 **P1** — hygiene: advertised-but-broken; implement or stop advertising.
- 🟢 **P2** — no consumer yet on either side.

## Status legend

`TODO` · `IN PROGRESS` · `BLOCKED` · `DONE`

---

## 1. `buildTarget/didChange` (server→client) + `workspace/didChangeWatchedFiles`

- **Priority:** 🔴 P0 — reactive refresh for SourceKit-LSP (and vscode-bsp).
- **Server status:** ⚠️ IN PROGRESS / BLOCKED — initial impl on `update/doc_api`
  **crashes SourceKit-LSP**. Root cause unproven; candidates: (a) emitting
  `changes: nil` → LSP re-queries everything → burst exposes an unserialized
  stdout write race in `StdioJSONRPCConnectionTransport`; (b) malformed payload
  (`params:{}`, missing `changes`). Correct method name is `buildTarget/didChange`
  (NOT `build/targetDidChange`).
- **Client status:** TODO — vscode-bsp has **no** `onNotification('buildTarget/didChange')`
  handler, so it never refreshes targets when the server signals a change.
- **Server plan:** serialize stdout writes (see Cross-cutting §A); send concrete
  `changes` (affected targets) not `nil`; debounce `didChangeWatchedFiles`
  bursts; fix `WorkspaceDidChangeWatchedFilesNotification.Params` to
  `changes: [FileEvent]`; invalidate caches (`updateBuildGraph()` → `clearCaches()`).
- **Client plan:** add `onNotification('buildTarget/didChange', …)` in
  `bspClient.ts` → invalidate & re-fetch `workspace/buildTargets`
  (`targetManager` refresh). Add `DidChangeBuildTarget` type to `bspTypes.ts`.
- **Verify:** reproduce with vscode-bsp (or `mock-xcode-bsp-server.js`) before
  re-testing the editor's SourceKit-LSP, to avoid crash-looping the editor.

## 2. `workspace/reload`

- **Priority:** 🔴 P0 — **vscode-bsp already sends it** (`bspClient.ts:152`);
  today it's a no-op on the server, so the extension's reload does nothing.
- **Server status:** TODO — handler empty (`WorkspaceReloadNotification.swift`).
- **Client status:** DONE (already sends). May want a follow-up refresh after.
- **Server plan:** re-run project resolution (reload `XcodeProjectBaseInfo`),
  `clearCaches()`, then emit `buildTarget/didChange` so the client re-queries.
  Shares the cache-invalidation path with item 1.

## 3. `debugSession/start` (`debugProvider`)

- **Priority:** 🔴 P0 (reclassified up) — **vscode-bsp already sends it**
  (`bspClient.ts:280`, `debugProvider.ts`); server advertises `debugProvider`
  but does not implement it, so **debug from the extension fails**.
- **Server status:** TODO (advertised, unimplemented).
- **Client status:** DONE (already sends `debugSession/start`, expects
  `DebugSessionAddressResult`).
- **Server plan:** implement `debugSession/start` → return a debug adapter
  address/URI the client can attach to (needs a concrete debug story — e.g.
  lldb / codelldb). If a full impl is out of scope short-term, **coordinate with
  the client**: either stub a clear "unsupported" error the client surfaces
  gracefully, or gate the client's debug command off. Do NOT leave it silently
  broken.

## 4. `buildTarget/outputPaths`

- **Priority:** 🟠 P1.
- **Server status:** TODO — stubbed, returns `[]`
  (`BuildTargetOutputPathsRequest.swift`).
- **Client status:** not consumed yet.
- **Server plan:** compose from `XcodeGlobalSettings.buildDir` +
  `<Configuration>` + `productName` + product extension.
- **Client plan (optional):** consume for a "reveal build product" affordance.

## 5. `buildTarget/dependencySources`

- **Priority:** 🟢 P2.
- **Server status:** TODO — not registered.
- **Client status:** not consumed yet.
- **Server plan:** dependency graph (`XcodeBuildGraphResolver.buildOrder`) +
  `SourceFileLister`; register in `BSPMessageRegistry`.

## 6. `buildTarget/inverseSources`

- **Priority:** 🟢 P2.
- **Server status:** TODO — not registered.
- **Client status:** not consumed yet.
- **Server plan:** invert the per-target source map into `sourceURL → [targetId]`
  (ties into activating `sourceFileMapCache`); register the request.

## 7. `buildTarget/resources`

- **Priority:** 🟢 P2.
- **Server status:** TODO — not registered; resource data not modeled.
- **Client status:** not consumed yet.
- **Server plan:** add a resource lister over `PBXResourcesBuildPhase`.

## 8. `buildTarget/cleanCache`

- **Priority:** 🟢 P2 — currently returns `-32603 "Not implemented"`.
- **Server status:** TODO.
- **Client status:** not sent yet (could add a "clean" command).
- **Server plan:** delete index store / module caches
  (`XcodeGlobalSettings.indexStoreURL`, module cache), return `cleaned: true`.

## 9. Notification method-name mismatches (fix while syncing)

- **Priority:** 🟠 P1 — silent message loss between the two repos.
- **`window/showMessage` vs `build/showMessage`:** server sends
  `window/showMessage` (`BSPServerService`), client listens for
  `build/showMessage` (`bspClient.ts:436`) → messages dropped. Pick one name and
  align both repos.
- **Verify** `build/publishDiagnostics`, `build/taskStart|Finish|Progress`,
  `build/logMessage` method strings match on both ends (client handles them;
  confirm the server's TaskProgress emitter uses the same strings).

## 10. SwiftPM provider (separate, larger effort)

- `Sources/SwiftPMProjectManagerProvider` is a disabled stub. Real SwiftPM
  support (Package.swift parsing, deps, C targets) is out of scope here — see
  `Docs/Project-Analysis-And-Roadmap.md`.

---

## Suggested order

1. 🔴 Item 1 — unblock the reactive-refresh crash (server + client together).
2. 🔴 Items 2, 3 — reload + debug: the client already calls these, so they're
   the highest-impact "advertised but broken" gaps.
3. 🟠 Items 4, 9 — outputPaths + fix the notification name mismatches.
4. 🟢 Items 5, 6, 7, 8 — query methods + cleanCache; share source-map/graph
   plumbing; add client consumers as needed.

## Cross-cutting prerequisites

- **§A Serialize stdout writes** (`StdioJSONRPCConnectionTransport`) before
  shipping anything that increases response concurrency — currently under
  investigation as (part of) the item-1 crash.
- **§B Activate `sourceFileMapCache`** — items 5 & 6 need an efficient
  source↔target index; see `Docs/Project-Analysis-And-Roadmap.md` §1.
- **§C Registry**: every new server request type must be added to
  `Sources/BSPServer/BSPMessageRegistry.swift` or it silently won't route.
- **§D Client types**: mirror every new/changed method in
  `vscode-bsp/src/bspTypes.ts` and wire it in `src/bspClient.ts`.
- **§E Tests**: server → `Tests/BSPServerTests/Harness/BSPTestHarness`;
  client → `mock-xcode-bsp-server.js` for end-to-end without the real server.
