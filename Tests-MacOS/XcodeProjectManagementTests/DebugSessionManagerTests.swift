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
