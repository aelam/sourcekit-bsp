# Server-side `debugSession/start` for Xcode targets — Design

Date: 2026-08-06
Status: Approved (design), pending implementation plan
Repos: `sourcekit-bsp` (server, primary), `vscode-bsp` (client)

## Goal

Implement BSP `debugSession/start` on the server so a BSP client (vscode-bsp)
can debug an Xcode build target with full breakpoint support. The server owns
all Xcode-specific orchestration and hosts the debug endpoint; the client only
connects a DAP debugger to it.

## Scope

- **In scope:** iOS / tvOS / watchOS **Simulator** and **macOS** app targets.
- **Deferred:** physical devices (needs `devicectl` + `debugserver` tunnel,
  signing/pairing) — separate later effort.
- Debugger: **lldb-dap** from the active Xcode toolchain (`xcrun --find lldb-dap`).

## Key decisions

1. **Transport: TCP.** The server starts `lldb-dap` in listen mode and returns
   `tcp://127.0.0.1:<port>`. DAP traffic flows over this dedicated socket,
   never over the BSP stdio channel (so BSP is never blocked by debugging).
2. **Server hosts the adapter (Option A).** Matches BSP `debugSession/start`
   semantics (return an address the client connects to) and makes the server
   genuinely "support debug".
3. **Launch/attach model (mirrors Xcode/lldb, which attaches by PID):**
   - **macOS** → DAP `launch` with `program = <built binary>` (lldb owns the process).
   - **Simulator** → `simctl launch --wait-for-debugger <udid> <bundleId>` yields
     a host **PID**; DAP `attach` with `pid`. `--wait-for-debugger` guarantees
     lldb attaches before the app runs, so early breakpoints hit.

## Message contract (BSP)

Register `DebugSessionStartRequest` (method `debugSession/start`) in
`Sources/BSPServer/BSPMessageRegistry.swift`.

Request params:
```
{ "targets": [BSPBuildTargetIdentifier], "originId"?: String, "arguments"?: [String] }
```
- `arguments` carries the selected destination / configuration (same convention
  as `buildTarget/compile`, e.g. `-destination`, `-configuration`).

Response — `DebugSessionAddress` (BSP defines only `uri`; we extend via `data`
since we own both ends):
```
{
  "uri": "tcp://127.0.0.1:<port>",
  "dataKind": "lldb",
  "data": {
    "request": "attach" | "launch",
    "pid"?: Int,          // simulator attach
    "program"?: String,   // macOS launch
    "bundleId"?: String,
    "cwd"?: String
  }
}
```

Failure → JSON-RPC error with a clear message (build failed, lldb-dap missing,
simulator unavailable, listen timeout). The client surfaces it to the user.

## Server flow (per target)

1. Resolve `XcodeTarget` from the BSP identifier (via `XcodeTargetIdentifier(bsp)` bridge).
2. Determine platform (macOS vs simulator) from the destination in `arguments`,
   else the target's platform.
3. **Build** the target for Debug with the correct destination (reuses the
   `buildTarget/compile` path, including the destination default fix so it does
   not pick the Mac Catalyst variant).
4. Resolve product: `PRODUCT_BUNDLE_IDENTIFIER` + built `.app` / binary path
   (reuse `getOutputPath` / build settings).
5. Branch:
   - **macOS:** `request = launch`, `program = <binary>`.
   - **Simulator:** `simctl boot <udid>` (idempotent) → `simctl install` →
     `simctl launch --wait-for-debugger <udid> <bundleId>` → parse **PID** →
     `request = attach`, `pid = <pid>`.
6. **Start lldb-dap:** locate via `xcrun --find lldb-dap`; spawn
   `lldb-dap --connection listen://127.0.0.1:<port>`; obtain the listening port.
7. Register the session (lldb-dap process + port + any launched sim PID) in the
   `DebugSessionManager` for later teardown.
8. Return the `DebugSessionAddress`.

## New components (server)

- **`DebugSessionManager`** (actor): orchestrates the flow above; owns lldb-dap
  process lifecycle, port allocation, the session registry, and cleanup. Depends
  on the build path, the launcher, and `LLDBDAPServer`.
- **`LLDBDAPServer`**: locates `lldb-dap`, starts it in listen mode, resolves the
  port, applies a startup/listen timeout and health check.
- **`DebugSessionStartRequest`** + response types (BSP message layer).
- **Launcher extension:** a `--wait-for-debugger` launch variant on the
  simulator launcher that returns the PID (extends existing
  `AppInstaller`/`SimulatorLauncher`).
- Register the request in `BSPMessageRegistry`; keep the `debugProvider`
  capability advertised (now backed by a real implementation).

Each unit has one purpose and a narrow interface so it can be tested with fakes
(no real Xcode/simulator needed for unit tests).

## Not blocking BSP + lifecycle

- Orchestration runs in the per-message Task the connection already spawns, so
  it never blocks the read loop or other requests.
- lldb-dap is a separate process on its own TCP port — DAP traffic is entirely
  off the BSP stdio channel.
- Sessions are tracked and torn down on `build/shutdown` / exit, when a new debug
  session starts for the same target, and on cancel — killing lldb-dap and not
  leaking simulator/debug processes.
- **Port strategy:** pre-bind `127.0.0.1:0` to obtain a free port, close it, and
  hand that port to lldb-dap (fallback: parse the port lldb-dap prints on
  startup). A short timeout guards the "waiting for lldb-dap to listen" step.

## Client (vscode-bsp) changes — second phase, after the server

- Implement a `bsp-debug` `DebugAdapterDescriptorFactory` that returns
  `vscode.DebugAdapterServer(port, host)` parsed from the returned `tcp://` uri.
- Rewrite `debugProvider.ts` (remove the Scala/Java leftovers);
  `resolveDebugConfiguration` builds `attach { pid }` or `launch { program }`
  from the response `data`.
- Register the factory in `extension.ts` (currently commented out).
- `handleDebugResult` already parses `tcp://` — extend it to thread the response
  `data` (pid/program) into the debug configuration.

## Error handling

- `lldb-dap` not found in toolchain → error "lldb-dap not found".
- Build failure → error with a build-log summary.
- Simulator boot/install/launch failure → error with the underlying message.
- Timeout waiting for lldb-dap to listen → error, and kill the spawned process.
- Any failure after partial setup cleans up already-started processes.

## Testing

- **Server unit tests:** inject fakes for the launcher and `LLDBDAPServer` into
  `DebugSessionManager`; assert macOS → `launch` + `program`, simulator →
  `attach` + `pid`, and that a `tcp://` uri is returned.
- **Protocol test:** via `Tests/BSPServerTests/Harness/BSPTestHarness`, send
  `debugSession/start` and assert the response shape (`uri` starts with
  `tcp://`, `data.request` and `data.pid|program`). The real lldb-dap spawn sits
  behind a protocol so the test needs no Xcode.
- **Manual:** HelloProject macOS target — set a breakpoint, F5, confirm it hits;
  then a simulator target.

## Out of scope / follow-ups

- Physical device debugging.
- `debugSession` for SwiftPM targets (tied to full SwiftPM support).
- Advanced DAP config (env vars, launch args UI) beyond what `arguments` carries.
