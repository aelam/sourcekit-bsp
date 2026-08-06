# Debug Session (server) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement BSP `debugSession/start` on the server for macOS and simulator Xcode targets, returning a `tcp://` lldb-dap endpoint the client attaches to.

**Architecture:** A `DebugSessionManager` (actor, macOS-only) orchestrates: build → resolve product → (macOS: prepare `launch`; simulator: `simctl launch --wait-for-debugger` → PID → `attach`) → start `lldb-dap` in TCP listen mode → return a `DebugSessionConnection`. The manager depends on injected seams (`WaitForDebuggerLaunching`, `DebugAdapterServing`) so it is unit-testable without Xcode. A new BSP `DebugSessionStartRequest` calls into it via `BSPServerService` → `ProjectManager.startDebugSession`. Debug traffic runs over lldb-dap's own TCP socket, never the BSP stdio channel.

**Tech Stack:** Swift 6.1, SwiftPM, XcodeProj, `xcrun simctl`, `lldb-dap`, XCTest.

**Scope:** Server only (macOS + simulator). The vscode-bsp client changes are a separate follow-up plan. Physical devices are out of scope.

---

## File Structure

**Create:**
- `Sources/BuildServerProtocol/ProjectManager/DebugSessionConnection.swift` — cross-platform result value type returned by `ProjectManager.startDebugSession`.
- `Sources/BSPServer/BSPMessages/debugSession/DebugSessionStartRequest.swift` — BSP request + response.
- `Sources/BSPServer/BSPServerService/BSPServerService+DebugSession.swift` — context method.
- `Sources-MacOS/XcodeProjectManagement/Debug/LLDBDAPServer.swift` — locate + spawn `lldb-dap` listen, resolve port, teardown; plus the `DebugAdapterServing` seam.
- `Sources-MacOS/XcodeProjectManagement/Debug/DebugSessionManager.swift` — orchestrator actor + `WaitForDebuggerLaunching` seam.
- `Sources-MacOS/XcodeProjectManagerProvider/XcodeProjectManager+DebugSession.swift` — implements `ProjectManager.startDebugSession`, wires the manager.
- `Tests-MacOS/XcodeProjectManagementTests/DebugSessionManagerTests.swift` — unit tests with fakes.
- `Tests/BSPServerTests/DebugSessionRequestTests.swift` — protocol-level test via `BSPTestHarness`.

**Modify:**
- `Sources/BuildServerProtocol/ProjectManager/ProjectManager.swift` — add `startDebugSession` protocol requirement.
- `Sources/SwiftPMProjectManagerProvider/SwiftPMProjectManagerProvider.swift` (or its `ProjectManager` conformance file) — stub throwing `.notImplemented`.
- `Sources/BSPServer/BSPMessageRegistry.swift` — register `DebugSessionStartRequest`.
- `Sources-MacOS/XcodeProjectManagement/AppInstaller/AppInstaller.swift` — add a wait-for-debugger simulator launch returning a PID.

---

## Task 1: Cross-platform `DebugSessionConnection` + protocol requirement + SwiftPM stub

**Files:**
- Create: `Sources/BuildServerProtocol/ProjectManager/DebugSessionConnection.swift`
- Modify: `Sources/BuildServerProtocol/ProjectManager/ProjectManager.swift`
- Modify: `Sources/SwiftPMProjectManagerProvider` ProjectManager conformance (the file with the other stubbed methods)

- [ ] **Step 1: Create the value type**

Create `Sources/BuildServerProtocol/ProjectManager/DebugSessionConnection.swift`:

```swift
import Foundation

/// Everything the client needs to attach a DAP debugger for a target.
/// `uri` is the lldb-dap TCP endpoint; the remaining fields are the DAP
/// launch/attach configuration the client should send once connected.
public struct DebugSessionConnection: Sendable, Equatable {
    public enum Request: String, Sendable, Equatable {
        case launch
        case attach
    }

    public let uri: String          // e.g. "tcp://127.0.0.1:52345"
    public let request: Request
    public let program: String?     // macOS launch: built binary path
    public let pid: Int?            // simulator attach: host PID
    public let bundleId: String?

    public init(uri: String, request: Request, program: String? = nil, pid: Int? = nil, bundleId: String? = nil) {
        self.uri = uri
        self.request = request
        self.program = program
        self.pid = pid
        self.bundleId = bundleId
    }
}
```

- [ ] **Step 2: Add the protocol requirement**

In `Sources/BuildServerProtocol/ProjectManager/ProjectManager.swift`, add to the `ProjectManager` protocol body (next to `run`):

```swift
    func startDebugSession(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?
    ) async throws -> DebugSessionConnection
```

- [ ] **Step 3: Stub it in the SwiftPM provider**

In the SwiftPM provider's `ProjectManager` conformance (same file/extension as its other `throw ... .notImplemented` methods), add:

```swift
    public func startDebugSession(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?
    ) async throws -> DebugSessionConnection {
        throw SwiftPMProjectManagerProviderError.notImplemented
    }
```

- [ ] **Step 4: Add a throwing stub in the Xcode provider (keeps the build green until Task 6)**

Create `Sources-MacOS/XcodeProjectManagerProvider/XcodeProjectManager+DebugSession.swift`:

```swift
import BuildServerProtocol
import Foundation
import XcodeProjectManagement

public extension XcodeProjectManager {
    // Stub — real implementation added in Task 6. Present now so the package
    // keeps building on macOS while the protocol requirement lands.
    func startDebugSession(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?
    ) async throws -> DebugSessionConnection {
        throw XcodeProjectError.toolchainError("debugSession/start not yet implemented")
    }
}
```

If `XcodeProjectError.toolchainError` is not the right error case, use any existing `XcodeProjectError`/thrown error in that module; the body is replaced in Task 6.

- [ ] **Step 5: Build to verify the whole package compiles**

Run: `swift build`
Expected: PASS (both providers now satisfy the protocol; Xcode side is a stub).

- [ ] **Step 6: Commit**

```bash
git add Sources/BuildServerProtocol Sources/SwiftPMProjectManagerProvider Sources-MacOS/XcodeProjectManagerProvider/XcodeProjectManager+DebugSession.swift
git commit -m "feat(debug): add DebugSessionConnection + ProjectManager.startDebugSession requirement (+ stubs)"
```

---

## Task 2: BSP `debugSession/start` message + registry + context method

**Files:**
- Create: `Sources/BSPServer/BSPMessages/debugSession/DebugSessionStartRequest.swift`
- Create: `Sources/BSPServer/BSPServerService/BSPServerService+DebugSession.swift`
- Modify: `Sources/BSPServer/BSPMessageRegistry.swift`

- [ ] **Step 1: Create the request + response types**

Create `Sources/BSPServer/BSPMessages/debugSession/DebugSessionStartRequest.swift`:

```swift
import BuildServerProtocol
import Foundation
import JSONRPCConnection

public struct DebugSessionStartRequest: ContextualRequestType, Sendable {
    public typealias RequiredContext = BSPServerService

    public static func method() -> String { "debugSession/start" }

    public struct Params: Codable, Sendable {
        public let targets: [BSPBuildTargetIdentifier]
        public let originId: String?
        public let arguments: [String]?
    }

    public let params: Params

    public func handle<Handler: ContextualMessageHandler>(
        contextualHandler: Handler,
        id: RequestID
    ) async -> ResponseType? where Handler.Context == BSPServerService {
        await contextualHandler.withContext { context in
            do {
                let connection = try await context.startDebugSession(
                    targets: params.targets,
                    arguments: params.arguments
                )
                return DebugSessionStartResponse(id: id, connection: connection)
            } catch {
                logger.error("debugSession/start failed: \(String(describing: error))")
                return JSONRPCErrorResponse(
                    id: id,
                    error: JSONRPCError(code: -32603, message: "debugSession/start failed: \(error.localizedDescription)")
                )
            }
        }
    }
}

public struct DebugSessionStartResponse: ResponseType, Hashable {
    public let id: JSONRPCID?
    public let jsonrpc: String
    public let result: Result

    public struct Result: Codable, Hashable, Sendable {
        public let uri: String
        public let dataKind: String
        public let data: DebugData

        public struct DebugData: Codable, Hashable, Sendable {
            public let request: String
            public let program: String?
            public let pid: Int?
            public let bundleId: String?
        }
    }

    public init(id: JSONRPCID?, jsonrpc: String = "2.0", connection: DebugSessionConnection) {
        self.id = id
        self.jsonrpc = jsonrpc
        self.result = Result(
            uri: connection.uri,
            dataKind: "lldb",
            data: .init(
                request: connection.request.rawValue,
                program: connection.program,
                pid: connection.pid,
                bundleId: connection.bundleId
            )
        )
    }
}
```

- [ ] **Step 2: Add the context method**

Create `Sources/BSPServer/BSPServerService/BSPServerService+DebugSession.swift`:

```swift
import BuildServerProtocol
import Foundation
import JSONRPCConnection
import Logger

extension BSPServerService {
    func startDebugSession(
        targets: [BSPBuildTargetIdentifier],
        arguments: [String]?
    ) async throws -> DebugSessionConnection {
        guard let projectManager else {
            throw BuildServerError.invalidConfiguration("Project manager not initialized")
        }
        return try await projectManager.startDebugSession(
            targetIdentifiers: targets,
            arguments: arguments
        )
    }
}
```

- [ ] **Step 3: Register the request**

In `Sources/BSPServer/BSPMessageRegistry.swift`, add to the `requestTypes` array (under a `// debugSession` comment):

```swift
    DebugSessionStartRequest.self, // debugSession/start
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: still FAILS only on the missing Xcode `startDebugSession` conformance (Task 6). No errors in the new files.

- [ ] **Step 5: Commit**

```bash
git add Sources/BSPServer
git commit -m "feat(debug): add debugSession/start BSP request, response, and registry entry"
```

---

## Task 3: Wait-for-debugger simulator launch returning a PID

**Files:**
- Modify: `Sources-MacOS/XcodeProjectManagement/AppInstaller/AppInstaller.swift`
- Test: `Tests-MacOS/XcodeProjectManagementTests/DebugSessionManagerTests.swift` (PID-parse test only, in this task)

- [ ] **Step 1: Write the failing test for PID parsing**

Create `Tests-MacOS/XcodeProjectManagementTests/DebugSessionManagerTests.swift`:

```swift
import XCTest
@testable import XcodeProjectManagement

final class DebugSessionManagerTests: XCTestCase {
    func testParseSimctlLaunchPID() {
        // `simctl launch --wait-for-debugger` prints "<bundleId>: <pid>"
        let output = "com.example.Hello: 54321\n"
        XCTAssertEqual(SimulatorDebugLauncher.parsePID(from: output), 54321)
        XCTAssertNil(SimulatorDebugLauncher.parsePID(from: "no pid here"))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter DebugSessionManagerTests/testParseSimctlLaunchPID`
Expected: FAIL — `SimulatorDebugLauncher` not defined.

- [ ] **Step 3: Add the launcher + seam**

Append to `Sources-MacOS/XcodeProjectManagement/AppInstaller/AppInstaller.swift`:

```swift
/// Launch seam that spawns the app paused for the debugger and returns its PID.
protocol WaitForDebuggerLaunching: Sendable {
    func launchWaitingForDebugger(deviceID: String, appIdentifier: String) async throws -> Int
}

struct SimulatorDebugLauncher: WaitForDebuggerLaunching {
    func launchWaitingForDebugger(deviceID: String, appIdentifier: String) async throws -> Int {
        let executor = ProcessExecutor()
        _ = try? await executor.execute(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "boot", deviceID]
        )
        let result = try await executor.execute(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "launch", "--wait-for-debugger", deviceID, appIdentifier]
        )
        guard result.exitCode == 0, let pid = Self.parsePID(from: result.output ?? "") else {
            throw XcodeRunError.failedToLaunchApp(
                "Failed to launch \(appIdentifier) on simulator \(deviceID) for debugging"
            )
        }
        return pid
    }

    /// Parse the PID from `simctl launch` output "<bundleId>: <pid>".
    static func parsePID(from output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) {
            if let colon = line.lastIndex(of: ":") {
                let tail = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if let pid = Int(tail) { return pid }
            }
        }
        return nil
    }
}
```

Note: `ProcessExecutionResult` exposes `output: String?` (see `Sources/Support/ProcessExecutor.swift`). If the property differs, adapt `result.output` accordingly.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DebugSessionManagerTests/testParseSimctlLaunchPID`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources-MacOS/XcodeProjectManagement/AppInstaller/AppInstaller.swift Tests-MacOS/XcodeProjectManagementTests/DebugSessionManagerTests.swift
git commit -m "feat(debug): add wait-for-debugger simulator launch returning PID"
```

---

## Task 4: `LLDBDAPServer` — locate, spawn in listen mode, resolve port, teardown

**Files:**
- Create: `Sources-MacOS/XcodeProjectManagement/Debug/LLDBDAPServer.swift`
- Test: `Tests-MacOS/XcodeProjectManagementTests/DebugSessionManagerTests.swift`

- [ ] **Step 1: Write the failing test for free-port allocation**

Add to `DebugSessionManagerTests.swift`:

```swift
    func testAllocatesFreeTCPPort() throws {
        let port = try LLDBDAPServer.reserveFreePort()
        XCTAssertGreaterThan(port, 0)
        // A second call should also succeed and (almost always) differ.
        let port2 = try LLDBDAPServer.reserveFreePort()
        XCTAssertGreaterThan(port2, 0)
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter DebugSessionManagerTests/testAllocatesFreeTCPPort`
Expected: FAIL — `LLDBDAPServer` not defined.

- [ ] **Step 3: Implement `LLDBDAPServer` + `DebugAdapterServing` seam**

Create `Sources-MacOS/XcodeProjectManagement/Debug/LLDBDAPServer.swift`:

```swift
import Foundation
import Logger
import Support

/// A running debug-adapter endpoint the client connects to over TCP.
public struct DebugAdapterEndpoint: Sendable {
    public let uri: String            // "tcp://127.0.0.1:<port>"
    public let terminate: @Sendable () -> Void
}

/// Seam so `DebugSessionManager` can be unit-tested without spawning lldb-dap.
public protocol DebugAdapterServing: Sendable {
    func start() async throws -> DebugAdapterEndpoint
}

public enum LLDBDAPError: Error, LocalizedError {
    case notFound
    case failedToStart(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: "lldb-dap not found in the active Xcode toolchain"
        case let .failedToStart(msg): "lldb-dap failed to start: \(msg)"
        }
    }
}

public struct LLDBDAPServer: DebugAdapterServing {
    public init() {}

    public func start() async throws -> DebugAdapterEndpoint {
        let lldbDAPPath = try Self.locateLLDBDAP()
        let port = try Self.reserveFreePort()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: lldbDAPPath)
        process.arguments = ["--connection", "listen://127.0.0.1:\(port)"]
        // Long-lived: do NOT wait for exit. Detach stdio so it doesn't touch ours.
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw LLDBDAPError.failedToStart(error.localizedDescription)
        }
        logger.info("Started lldb-dap on tcp://127.0.0.1:\(port) (pid \(process.processIdentifier))")

        return DebugAdapterEndpoint(
            uri: "tcp://127.0.0.1:\(port)",
            terminate: { if process.isRunning { process.terminate() } }
        )
    }

    /// `xcrun --find lldb-dap`.
    static func locateLLDBDAP() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "lldb-dap"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            throw LLDBDAPError.notFound
        }
        return path
    }

    /// Bind 127.0.0.1:0, read the assigned port, close — then hand it to lldb-dap.
    static func reserveFreePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LLDBDAPError.failedToStart("socket() failed") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw LLDBDAPError.failedToStart("bind() failed") }
        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameResult == 0 else { throw LLDBDAPError.failedToStart("getsockname() failed") }
        return Int(UInt16(bigEndian: boundAddr.sin_port))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DebugSessionManagerTests/testAllocatesFreeTCPPort`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources-MacOS/XcodeProjectManagement/Debug/LLDBDAPServer.swift Tests-MacOS/XcodeProjectManagementTests/DebugSessionManagerTests.swift
git commit -m "feat(debug): add LLDBDAPServer (locate, listen, free port, teardown)"
```

---

## Task 5: `DebugSessionManager` orchestrator (unit-tested with fakes)

**Files:**
- Create: `Sources-MacOS/XcodeProjectManagement/Debug/DebugSessionManager.swift`
- Test: `Tests-MacOS/XcodeProjectManagementTests/DebugSessionManagerTests.swift`

The manager takes injected seams so tests avoid real Xcode/simulator: a build
closure, a product resolver closure, the `WaitForDebuggerLaunching`, and the
`DebugAdapterServing`.

- [ ] **Step 1: Write the failing tests for both branches**

Add to `DebugSessionManagerTests.swift`:

```swift
    private struct FakeLauncher: WaitForDebuggerLaunching {
        let pid: Int
        func launchWaitingForDebugger(deviceID: String, appIdentifier: String) async throws -> Int { pid }
    }
    private struct FakeAdapter: DebugAdapterServing {
        func start() async throws -> DebugAdapterEndpoint {
            DebugAdapterEndpoint(uri: "tcp://127.0.0.1:9999", terminate: {})
        }
    }

    func testMacOSProducesLaunchConnection() async throws {
        let manager = DebugSessionManager(adapter: FakeAdapter(), simulatorLauncher: FakeLauncher(pid: 1))
        let product = DebugProduct(platform: .macOS, binaryPath: "/tmp/Hello.app/Contents/MacOS/Hello",
                                   bundleId: "com.example.Hello", simulatorUDID: nil)
        let conn = try await manager.makeConnection(for: product) { }
        XCTAssertEqual(conn.request, .launch)
        XCTAssertEqual(conn.program, "/tmp/Hello.app/Contents/MacOS/Hello")
        XCTAssertNil(conn.pid)
        XCTAssertEqual(conn.uri, "tcp://127.0.0.1:9999")
    }

    func testSimulatorProducesAttachConnection() async throws {
        let manager = DebugSessionManager(adapter: FakeAdapter(), simulatorLauncher: FakeLauncher(pid: 4242))
        let product = DebugProduct(platform: .iOSSimulator, binaryPath: "/tmp/Hello.app",
                                   bundleId: "com.example.Hello", simulatorUDID: "SIM-UDID")
        let conn = try await manager.makeConnection(for: product) { }
        XCTAssertEqual(conn.request, .attach)
        XCTAssertEqual(conn.pid, 4242)
        XCTAssertNil(conn.program)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DebugSessionManagerTests`
Expected: FAIL — `DebugSessionManager` / `DebugProduct` not defined.

- [ ] **Step 3: Implement the manager**

Create `Sources-MacOS/XcodeProjectManagement/Debug/DebugSessionManager.swift`:

```swift
import BuildServerProtocol
import Foundation
import Logger

/// The build product to debug, resolved from a target.
public struct DebugProduct: Sendable {
    public let platform: Platform
    public let binaryPath: String     // macOS: executable; simulator: .app path
    public let bundleId: String?
    public let simulatorUDID: String?

    public init(platform: Platform, binaryPath: String, bundleId: String?, simulatorUDID: String?) {
        self.platform = platform
        self.binaryPath = binaryPath
        self.bundleId = bundleId
        self.simulatorUDID = simulatorUDID
    }
}

public enum DebugSessionError: Error, LocalizedError {
    case buildFailed
    case missingBundleId
    case missingSimulatorUDID
    case unsupportedPlatform(Platform)

    public var errorDescription: String? {
        switch self {
        case .buildFailed: "Build failed before starting the debug session"
        case .missingBundleId: "Could not resolve the app's bundle identifier"
        case .missingSimulatorUDID: "No simulator destination selected"
        case let .unsupportedPlatform(p): "Debugging is not supported for platform \(p.rawValue)"
        }
    }
}

public actor DebugSessionManager {
    private let adapter: DebugAdapterServing
    private let simulatorLauncher: WaitForDebuggerLaunching
    private var liveEndpoints: [DebugAdapterEndpoint] = []

    public init(adapter: DebugAdapterServing, simulatorLauncher: WaitForDebuggerLaunching) {
        self.adapter = adapter
        self.simulatorLauncher = simulatorLauncher
    }

    /// Build (via the injected closure), then produce a connection for the product.
    public func startSession(build: @Sendable () async throws -> Bool, product: DebugProduct) async throws -> DebugSessionConnection {
        guard try await build() else { throw DebugSessionError.buildFailed }
        return try await makeConnection(for: product, build: {})
    }

    /// Product → connection. `build` already ran; kept as a param so tests can
    /// exercise this step in isolation.
    func makeConnection(for product: DebugProduct, build: @Sendable () async throws -> Void) async throws -> DebugSessionConnection {
        try await build()

        let endpoint = try await adapter.start()
        liveEndpoints.append(endpoint)

        switch product.platform {
        case .macOS:
            return DebugSessionConnection(
                uri: endpoint.uri, request: .launch,
                program: product.binaryPath, pid: nil, bundleId: product.bundleId
            )
        case .iOSSimulator, .watchSimulator, .tvSimulator, .visionSimulator:
            guard let udid = product.simulatorUDID else { throw DebugSessionError.missingSimulatorUDID }
            guard let bundleId = product.bundleId else { throw DebugSessionError.missingBundleId }
            let pid = try await simulatorLauncher.launchWaitingForDebugger(deviceID: udid, appIdentifier: bundleId)
            return DebugSessionConnection(
                uri: endpoint.uri, request: .attach,
                program: nil, pid: pid, bundleId: bundleId
            )
        default:
            throw DebugSessionError.unsupportedPlatform(product.platform)
        }
    }

    /// Terminate every lldb-dap we started (call on shutdown).
    public func terminateAll() {
        for endpoint in liveEndpoints { endpoint.terminate() }
        liveEndpoints.removeAll()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DebugSessionManagerTests`
Expected: PASS (all four tests).

- [ ] **Step 5: Commit**

```bash
git add Sources-MacOS/XcodeProjectManagement/Debug/DebugSessionManager.swift Tests-MacOS/XcodeProjectManagementTests/DebugSessionManagerTests.swift
git commit -m "feat(debug): add DebugSessionManager orchestrator with unit tests"
```

---

## Task 6: Implement `XcodeProjectManager.startDebugSession` (wire it all together)

**Files:**
- Modify: `Sources-MacOS/XcodeProjectManagerProvider/XcodeProjectManager+DebugSession.swift` (replace the Task 1 stub)

- [ ] **Step 1: Replace the stub with the real conformance**

Replace the stub body in `Sources-MacOS/XcodeProjectManagerProvider/XcodeProjectManager+DebugSession.swift` with:

```swift
import BuildServerProtocol
import Foundation
import Logger
import XcodeProjectManagement

public extension XcodeProjectManager {
    func startDebugSession(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?
    ) async throws -> DebugSessionConnection {
        guard let bspID = targetIdentifiers.first else {
            throw DebugSessionError.buildFailed
        }
        let xcodeID = XcodeTargetIdentifier(bspID)

        // 1. Build the target for Debug (reuses the compile path, which now
        //    injects a platform-correct -destination).
        let exitCode = try await compileTarget(
            targetIdentifier: xcodeID,
            configuration: "Debug",
            arguments: arguments
        )

        // 2. Resolve the product (platform, binary/app path, bundle id, udid).
        let product = try resolveDebugProduct(for: xcodeID, arguments: arguments)

        // 3. Orchestrate.
        let manager = DebugSessionManager(
            adapter: LLDBDAPServer(),
            simulatorLauncher: SimulatorDebugLauncher()
        )
        return try await manager.startSession(build: { exitCode == 0 }, product: product)
    }

    /// Resolve `DebugProduct` from build settings for the target.
    private func resolveDebugProduct(for xcodeID: XcodeTargetIdentifier, arguments: [String]?) throws -> DebugProduct {
        guard let base = xcodeProjectBaseInfo,
              let target = base.xcodeTargets.first(where: { $0.targetIdentifier == xcodeID }) else {
            throw DebugSessionError.buildFailed
        }
        // Reuse existing output-path + bundle-id resolution used by `run`.
        let binaryPath = try debugBinaryPath(for: target, arguments: arguments)
        let bundleId = debugBundleId(for: target)
        let udid = Self.destinationID(from: arguments)   // -destination id=... if present
        return DebugProduct(
            platform: target.xcodeTargetPlatform,
            binaryPath: binaryPath,
            bundleId: bundleId,
            simulatorUDID: udid
        )
    }
}
```

Reuse the existing helpers from `XcodeProjectManager+Run.swift` for `debugBinaryPath`, `debugBundleId`, and destination parsing. If those helpers are `private`, promote them to `internal` (same module) or extract shared functions — match the exact resolution `run()` already performs (`PRODUCT_BUNDLE_IDENTIFIER`, `getOutputPath`, `getDestination`). Do NOT duplicate the logic; call the existing implementation.

- [ ] **Step 2: Build the whole package**

Run: `swift build`
Expected: PASS — the `ProjectManager` conformance is now complete; no errors.

- [ ] **Step 3: Run the full test suite**

Run: `swift test`
Expected: PASS — existing tests plus `DebugSessionManagerTests`.

- [ ] **Step 4: Commit**

```bash
git add Sources-MacOS/XcodeProjectManagerProvider/XcodeProjectManager+DebugSession.swift
git commit -m "feat(debug): implement XcodeProjectManager.startDebugSession"
```

---

## Task 7: Protocol-level test + teardown on shutdown + manual verification

**Files:**
- Create: `Tests/BSPServerTests/DebugSessionRequestTests.swift`
- Modify: `Sources/BSPServer/BSPServerService/BSPServerService.swift` (teardown hook, if a shutdown path exists)

- [ ] **Step 1: Write the protocol-level error-path test**

Create `Tests/BSPServerTests/DebugSessionRequestTests.swift`:

```swift
import XCTest
@testable import BSPServer
@testable import JSONRPCConnection

final class DebugSessionRequestTests: XCTestCase {
    /// With no project initialized, debugSession/start returns a JSON-RPC error
    /// (not a crash), proving routing + context wiring work end-to-end.
    func testDebugSessionStartWithoutProjectReturnsError() async throws {
        let harness = await BSPTestHarness.make()
        defer { Task { await harness.shutdown() } }

        let data = try await harness.request(
            method: "debugSession/start",
            id: 1,
            params: #"{"targets":[{"uri":"xcode:///tmp/None.xcodeproj/None"}],"arguments":[]}"#
        )
        let json = try harness.json(data)
        XCTAssertEqual(json["id"] as? Int, 1)
        XCTAssertNotNil(json["error"], "expected an error response when no project is initialized")
    }
}
```

- [ ] **Step 2: Run to verify it passes**

Run: `swift test --filter DebugSessionRequestTests`
Expected: PASS — routing reaches the handler, `startDebugSession` throws "Project manager not initialized", handler returns a JSON-RPC error.

- [ ] **Step 3: Add teardown on shutdown (only if the manager is retained)**

The current design creates a `DebugSessionManager` per request. If a later change retains sessions across requests (to support stop/cancel), hold them on `XcodeProjectManager` and call `terminateAll()` from `BSPServerService.stop()` / the `build/exit` path. For this plan (per-request manager), document that lldb-dap processes are terminated when the client disconnects the DAP socket; add a `// TODO(debug-followup): retain + terminateAll on shutdown` note where the manager is created. (This is an intentional, logged limitation, not a silent gap.)

- [ ] **Step 4: Manual verification (documented, run by a human with Xcode)**

Drive the built server against `HelloProject` with a small script that sends `build/initialize` → `build/initialized` → `debugSession/start` (mac target) and asserts the response contains `"uri": "tcp://..."` and `"request": "launch"`. Reuse the Python stdio driver pattern already used in this repo's session notes. Confirm an lldb-dap process is listening on the returned port (`lsof -iTCP:<port>`).

- [ ] **Step 5: Commit**

```bash
git add Tests/BSPServerTests/DebugSessionRequestTests.swift Sources/BSPServer
git commit -m "test(debug): add debugSession/start protocol test; note shutdown teardown follow-up"
```

---

## Follow-up (separate plan): vscode-bsp client

Implement the `bsp-debug` `DebugAdapterDescriptorFactory` returning
`DebugAdapterServer(port, host)` from the `tcp://` uri; rewrite `debugProvider.ts`
to build `attach {pid}` / `launch {program}` from the response `data`; register
the factory in `extension.ts` (currently commented out). Tracked in the design
doc §"Client (vscode-bsp) changes".

## Self-Review

- **Spec coverage:** message contract (Task 2), server flow build→product→branch→lldb-dap (Tasks 3-6), components DebugSessionManager/LLDBDAPServer/request (Tasks 2,4,5), not-blocking (lldb-dap separate process/socket — Task 4), lifecycle/teardown (Task 5 `terminateAll`, Task 7 note), error handling (LLDBDAPError/DebugSessionError, error response in Task 2), testing (unit Tasks 3-5, protocol Task 7, manual Task 7). Simulator + macOS both covered (Task 5 branches). Device explicitly out of scope. ✅
- **Placeholders:** the only deferred item (retain-and-teardown-on-shutdown) is an explicit, logged design limitation with a follow-up note, not a vague TODO. ✅
- **Type consistency:** `DebugSessionConnection(uri,request,program,pid,bundleId)`, `DebugProduct(platform,binaryPath,bundleId,simulatorUDID)`, `DebugAdapterServing.start() -> DebugAdapterEndpoint`, `WaitForDebuggerLaunching.launchWaitingForDebugger(deviceID:appIdentifier:) -> Int` used consistently across Tasks 1,3,4,5,6. ✅
