import XCTest
@testable import XcodeProjectManagement

final class DebugSessionManagerTests: XCTestCase {
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
            DebugAdapterEndpoint(uri: "tcp://127.0.0.1:9999", terminate: {})
        }
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
