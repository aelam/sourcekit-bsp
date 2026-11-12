import Support
import XCTest
@testable import XcodeProjectManagement

final class DebugSessionManagerTests: XCTestCase {
    func testResolvesActualProductPathsAndCompositeDestination() throws {
        let product = try DebugProduct(buildSettings: [
            "PLATFORM_NAME": "iphonesimulator",
            "TARGET_BUILD_DIR": "/tmp/Custom/Build/Products/Release-iphonesimulator",
            "FULL_PRODUCT_NAME": "Renamed.app",
            "PRODUCT_BUNDLE_IDENTIFIER": "com.example.Renamed"
        ], arguments: ["-destination", "platform=iOS Simulator,id=SIM-UDID,OS=latest"])
        XCTAssertEqual(product.binaryPath, "/tmp/Custom/Build/Products/Release-iphonesimulator/Renamed.app")
        XCTAssertEqual(product.simulatorUDID, "SIM-UDID")
        let mac = try DebugProduct(buildSettings: [
            "PLATFORM_NAME": "macosx", "TARGET_BUILD_DIR": "/tmp/Products",
            "EXECUTABLE_PATH": "Renamed.app/Contents/MacOS/CustomExecutable"
        ], arguments: [])
        XCTAssertEqual(mac.binaryPath, "/tmp/Products/Renamed.app/Contents/MacOS/CustomExecutable")
    }

    func testRealAdapterAcceptsFirstDAPClient() async throws {
        let endpoint = try await LLDBDAPServer().start()
        defer { endpoint.terminate() }
        let port = try XCTUnwrap(URL(string: endpoint.uri)?.port)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let body = try JSONSerialization.data(withJSONObject: [
            "seq": 1, "type": "request", "command": "initialize",
            "arguments": ["adapterID": "lldb", "pathFormat": "path", "linesStartAt1": true, "columnsStartAt1": true]
        ])
        let request = Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
        let written = request.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        XCTAssertEqual(written, request.count)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var initializeResponse: [String: Any]?
        while initializeResponse == nil {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else {
                XCTFail("The adapter closed or timed out before the initialize response")
                return
            }
            response.append(contentsOf: buffer.prefix(count))
            while let separator = response.range(of: Data("\r\n\r\n".utf8)) {
                let headers = try XCTUnwrap(String(data: response[..<separator.lowerBound], encoding: .utf8))
                let length =
                    try XCTUnwrap(try Int(XCTUnwrap(headers.split(separator: ":").last?
                            .trimmingCharacters(in: .whitespacesAndNewlines))))
                let payload = response[separator.upperBound...]
                if payload.count < length { break }
                let json = try XCTUnwrap(JSONSerialization
                    .jsonObject(with: Data(payload.prefix(length))) as? [String: Any])
                response = Data(response[(separator.upperBound + length)...])
                if json["request_seq"] as? Int == 1 {
                    initializeResponse = json
                    break
                }
            }
        }
        XCTAssertEqual(initializeResponse?["success"] as? Bool, true)
    }

    func testParseSimctlLaunchPID() {
        // `simctl launch --wait-for-debugger` prints "<bundleId>: <pid>"
        let output = "com.example.Hello: 54321\n"
        XCTAssertEqual(SimulatorDebugLauncher.parsePID(from: output), 54321)
        XCTAssertNil(SimulatorDebugLauncher.parsePID(from: "no pid here"))
    }

    func testAllocatesFreeTCPPort() throws {
        let port = try LLDBDAPServer.reserveFreePort()
        XCTAssertGreaterThan(port, 0)
        let port2 = try LLDBDAPServer.reserveFreePort()
        XCTAssertGreaterThan(port2, 0)
    }

    // MARK: - DebugSessionManager branches (fakes, no Xcode/simulator needed)

    private struct FakeLauncher: WaitForDebuggerLaunching {
        let pid: Int
        func launchWaitingForDebugger(deviceID _: String, appIdentifier _: String) async throws -> Int {
            pid
        }
    }

    private struct FakeAdapter: DebugAdapterServing {
        func start() async throws -> DebugAdapterEndpoint {
            DebugAdapterEndpoint(uri: "tcp://127.0.0.1:9999") {}
        }
    }

    func testHostAttachUsesVerifiedPIDWithoutPreloadingFileDependencies() async throws {
        let manager = DebugSessionManager(adapter: FakeAdapter(), simulatorLauncher: FakeLauncher(pid: 1))
        let identity = HostProcessIdentity(pid: 42, executable: "/Applications/Hello.app/Hello", startToken: "one")
        let connection = try await manager.makeAttachConnection(identity: identity)
        XCTAssertEqual(connection.request, .attach)
        XCTAssertEqual(connection.pid, identity.pid)
        XCTAssertNil(connection.program)
        await manager.stopConnection(uri: connection.uri)
    }

    func testMacOSProducesLaunchConnection() async throws {
        let manager = DebugSessionManager(adapter: FakeAdapter(), simulatorLauncher: FakeLauncher(pid: 1))
        let product = DebugProduct(
            platform: .macOS,
            binaryPath: "/tmp/Hello.app/Contents/MacOS/Hello",
            bundleId: "com.example.Hello",
            simulatorUDID: nil
        )
        let conn = try await manager.makeConnection(for: product)
        XCTAssertEqual(conn.request, .launch)
        XCTAssertEqual(conn.program, "/tmp/Hello.app/Contents/MacOS/Hello")
        XCTAssertNil(conn.pid)
        XCTAssertEqual(conn.uri, "tcp://127.0.0.1:9999")
    }

    func testMacOSPreservesSchemeLaunchArgumentsAndEnvironment() async throws {
        let manager = DebugSessionManager(adapter: FakeAdapter(), simulatorLauncher: FakeLauncher(pid: 1))
        let settings = XcodeLaunchSettings(
            arguments: ["--message", "hello world", ""],
            environment: ["MODE": "test", "EMPTY": ""],
            workingDirectory: "/tmp/My Project"
        )
        let product = DebugProduct(
            platform: .macOS,
            binaryPath: "/tmp/App",
            bundleId: "com.example.App",
            simulatorUDID: nil,
            launchSettings: settings
        )
        let connection = try await manager.makeConnection(for: product)
        XCTAssertEqual(connection.args, settings.arguments)
        XCTAssertEqual(connection.env, settings.consoleEnvironment)
        XCTAssertEqual(connection.cwd, settings.workingDirectory)
    }

    private struct RecordingLauncher: WaitForDebuggerLaunching {
        let received: CrossPlatformLock<XcodeLaunchSettings?>

        func launchWaitingForDebugger(deviceID: String, appIdentifier: String) async throws -> Int {
            XCTFail("The scheme launch settings were dropped")
            return 1
        }

        func launchWaitingForDebugger(
            deviceID: String, appIdentifier: String, settings: XcodeLaunchSettings
        ) async throws -> Int {
            XCTAssertEqual(deviceID, "SIM-UDID")
            XCTAssertEqual(appIdentifier, "com.example.App")
            received.withLock { $0 = settings }
            return 4242
        }
    }

    func testSimulatorAppliesSchemeSettingsBeforeAttaching() async throws {
        let received = CrossPlatformLock<XcodeLaunchSettings?>(initialState: nil)
        let manager = DebugSessionManager(
            adapter: FakeAdapter(), simulatorLauncher: RecordingLauncher(received: received)
        )
        let settings = XcodeLaunchSettings(arguments: ["--feature"], environment: ["MODE": "test"])
        let product = DebugProduct(
            platform: .iOSSimulator,
            binaryPath: "/tmp/App.app",
            bundleId: "com.example.App",
            simulatorUDID: "SIM-UDID",
            launchSettings: settings
        )
        let connection = try await manager.makeConnection(for: product)
        XCTAssertEqual(received.withLock { $0 }, settings)
        XCTAssertEqual(connection.request, .attach)
        XCTAssertEqual(connection.pid, 4242)
        XCTAssertNil(connection.args)
        XCTAssertNil(connection.env)
    }

    func testSimulatorProducesAttachConnection() async throws {
        let manager = DebugSessionManager(adapter: FakeAdapter(), simulatorLauncher: FakeLauncher(pid: 4242))
        let product = DebugProduct(
            platform: .iOSSimulator,
            binaryPath: "/tmp/Hello.app",
            bundleId: "com.example.Hello",
            simulatorUDID: "SIM-UDID"
        )
        let conn = try await manager.makeConnection(for: product)
        XCTAssertEqual(conn.request, .attach)
        XCTAssertEqual(conn.pid, 4242)
        XCTAssertNil(conn.program)
    }
}

extension DebugSessionManagerTests {
    func testPendingSimulatorLaunchIsCleanedUpUntilDAPOwnsIt() async throws {
        for didStart in [false, true] {
            let stopped = CrossPlatformLock(initialState: [Int]())
            let manager = DebugSessionManager(adapter: FakeAdapter(), simulatorLauncher: FakeLauncher(pid: 4242))
            await manager.setPendingLaunchFixture(stopped: stopped)
            let connection = try await manager.makeConnection(for: .init(
                platform: .iOSSimulator,
                binaryPath: "/build/Hello.app",
                bundleId: "test.Hello",
                simulatorUDID: "selected"
            ))
            if didStart { await manager.didStartConnection(uri: connection.uri) }
            await manager.stopConnection(uri: connection.uri)
            await manager.terminateAll()
            XCTAssertEqual(stopped.withLock { $0 }, didStart ? [] : [4242])
        }
    }
}

private extension DebugSessionManager {
    func setPendingLaunchFixture(stopped: CrossPlatformLock<[Int]>) {
        captureLaunchedProcess = { pid, _ in .init(pid: pid, executable: "/fixture/Hello", startToken: "one") }
        stopPendingProcess = { identity in stopped.withLock { $0.append(identity.pid) } }
    }
}
