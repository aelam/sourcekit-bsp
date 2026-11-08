import Foundation
import Support
import Testing
@testable import XcodeProjectManagement

struct SimulatorAttachDiscoveryTests {
    @Test
    func usesInstalledExecutableWithOnlyAReadOnlyContainerQuery() async throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("Attach-\(UUID())/Hello.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "test.Hello", "CFBundleExecutable": "Hello"],
            format: .xml,
            options: 0
        )
        try plist.write(to: app.appendingPathComponent("Info.plist"))
        let developer = URL(fileURLWithPath: "/Selected Xcode/Developer")
        let discovery = SimulatorAttachDiscovery(developerDirectory: developer) { arguments, environment in
            #expect(arguments == ["simctl", "get_app_container", "SIM-ID", "test.Hello", "app"])
            #expect(environment == ["DEVELOPER_DIR": developer.path])
            return .init(output: app.path + "\n", error: nil, exitCode: 0)
        }
        let executable = try await discovery.executable(deviceID: "SIM-ID", bundleID: "test.Hello")
        #expect(executable == app.appendingPathComponent("Hello").resolvingSymlinksInPath().path)
        #expect(throws: HostAttachError.self) {
            try SimulatorAttachDiscovery.executable(appPath: app.path, bundleID: "test.Other")
        }
    }

    @Test
    func missingOrUnavailableSimulatorNeverFallsBackToLaunch() async throws {
        let discovery = SimulatorAttachDiscovery(developerDirectory: URL(fileURLWithPath: "/Xcode")) { arguments, _ in
            #expect(arguments == ["simctl", "get_app_container", "offline", "test.Hello", "app"])
            return .init(output: "", error: "Device is not booted", exitCode: 1)
        }
        await #expect(throws: HostAttachError.self) {
            try await discovery.executable(deviceID: "offline", bundleID: "test.Hello")
        }
    }
}
