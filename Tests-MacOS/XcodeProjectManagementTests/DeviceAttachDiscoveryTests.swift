import Foundation
import Support
import Testing
@testable import XcodeProjectManagement

struct DeviceAttachDiscoveryTests {
    @Test
    func selectsTheInstalledAppExecutableWithoutChangingDeviceState() async throws {
        let calls = CrossPlatformLock(initialState: [String]())
        let discovery = DeviceAttachDiscovery(commands: Self.runner(calls: calls))
        let identity = try await discovery.resolve(product: Self.product, pid: nil)
        #expect(identity.deviceID == "PHONE")
        #expect(identity.bundleID == "test.Hello")
        #expect(identity.pid == 42)
        #expect(identity.executable == "/var/containers/Bundle/Application/ONE/Hello App.app/sleep")
        #expect(identity.localExecutable == "/bin/sleep")
        try await discovery.validate(identity)
        #expect(calls.withLock { $0 } == ["apps", "processes", "processes"])
    }

    @Test(arguments: [nil, 42])
    func acceptsAnAutomaticOrExplicitMatchingPID(pid: Int?) async throws {
        let identity = try await DeviceAttachDiscovery(commands: Self.runner()).resolve(product: Self.product, pid: pid)
        #expect(identity.pid == 42)
    }

    @Test(arguments: [0, -1, 99, 43, 44])
    func rejectsPIDsFromOtherAppsOrExtensions(pid: Int) async throws {
        await #expect(throws: HostAttachError.self) {
            try await DeviceAttachDiscovery(commands: Self.runner()).resolve(product: Self.product, pid: pid)
        }
    }

    @Test
    func multipleMatchesRequireAnExplicitPID() async throws {
        let processes = Self.processes.replacingOccurrences(
            of: "\"processIdentifier\":43",
            with: "\"processIdentifier\":45"
        )
        .replacingOccurrences(of: "TWO/Hello%20App", with: "ONE/Hello%20App")
        let discovery = DeviceAttachDiscovery(commands: Self.runner(processes: processes))
        await #expect(throws: HostAttachError.self) { try await discovery.resolve(product: Self.product, pid: nil) }
        #expect(try await discovery.resolve(product: Self.product, pid: 45).pid == 45)
    }

    @Test(arguments: [
        #"{"info":{"outcome":"success"},"result":{"apps":[]}}"#,
        #"{"info":{"outcome":"failed"},"result":{"apps":[]}}"#,
        "{}", "not JSON"
    ])
    func invalidOrMissingAppFailsBeforeProcessLookup(apps: String) async throws {
        let calls = CrossPlatformLock(initialState: [String]())
        await #expect(throws: HostAttachError.self) {
            try await DeviceAttachDiscovery(commands: Self.runner(apps: apps, calls: calls))
                .resolve(product: Self.product, pid: nil)
        }
        #expect(calls.withLock { $0 } == ["apps"])
    }

    @Test
    func aStoppedOrChangedProcessCannotBeAttached() async throws {
        let identity = try await DeviceAttachDiscovery(commands: Self.runner()).resolve(product: Self.product, pid: nil)
        let discovery = DeviceAttachDiscovery(commands: Self.runner(processes: Self.processes
                .replacingOccurrences(of: "ONE/Hello%20App", with: "REINSTALLED/Hello%20App")))
        await #expect(throws: HostAttachError.self) { try await discovery.validate(identity) }
        await #expect(throws: HostAttachError.self) { try await discovery.resolve(product: Self.product, pid: nil) }
    }

    @Test
    func reportsLockedDeviceAndPreservesCancellation() async throws {
        let locked = DeviceAttachDiscovery(commands: DeviceCommandRunner { _, _ in
            ProcessExecutionResult(output: "", error: "Device is locked", exitCode: 1)
        })
        let error = try await #require(throws: XcodeRunError.self) {
            try await locked.resolve(product: Self.product, pid: nil)
        }
        #expect(error.localizedDescription.contains("Reading apps on device PHONE"))
        #expect(error.localizedDescription.contains("Device is locked"))
        let cancelled = DeviceAttachDiscovery(commands: DeviceCommandRunner { _, _ in throw CancellationError() })
        await #expect(throws: CancellationError.self) { try await cancelled.resolve(product: Self.product, pid: nil) }
    }

    @Test
    func missingLocalSymbolsFailWithoutQueryingOrBuilding() async throws {
        let calls = CrossPlatformLock(initialState: [String]())
        let product = DebugProduct(
            platform: .iOS,
            binaryPath: "/missing/Hello.app",
            bundleId: "test.Hello",
            destinationID: "PHONE",
            executablePath: "/missing/Hello.app/Hello"
        )
        await #expect(throws: DebugSessionError.self) {
            try await DeviceAttachDiscovery(commands: Self.runner(calls: calls)).resolve(product: product, pid: nil)
        }
        #expect(calls.withLock { $0.isEmpty })
    }

    @Test(arguments: ["https://example.com/App", "file://other-host/App", "file:///App?x=y", "relative/App"])
    func rejectsNonDevicePaths(path: String) {
        #expect(DeviceAttachDiscovery.devicePath(path) == nil)
    }

    private static let product = DebugProduct(
        platform: .iOS,
        binaryPath: "/tmp/Hello.app",
        bundleId: "test.Hello",
        destinationID: "PHONE",
        executablePath: "/bin/sleep"
    )

    private static let apps = #"""
    {"info":{"outcome":"success"},"result":{"apps":[
        {"bundleIdentifier":"other.App","url":"file:///var/containers/Bundle/Application/TWO/Hello%20App.app/"},
        {"bundleIdentifier":"test.Hello","url":"file:///private/var/containers/Bundle/Application/ONE/Hello%20App.app/"}
    ]}}
    """#

    private static let processes = #"""
    {"info":{"outcome":"success"},"result":{"runningProcesses":[
        {"processIdentifier":1},
        {"processIdentifier":0,"executable":"file:///var/containers/Bundle/Application/ONE/Hello%20App.app/sleep"},
        {"processIdentifier":42,"executable":"file:///var/containers/Bundle/Application/ONE/Hello%20App.app/sleep"},
        {"processIdentifier":43,"executable":"file:///var/containers/Bundle/Application/TWO/Hello%20App.app/sleep"},
        {"processIdentifier":44,"executable":"file:///var/containers/Bundle/Application/ONE/Hello%20App.app/PlugIns/Widget.appex/sleep"}
    ]}}
    """#

    private static func runner(
        apps: String = apps,
        processes: String = processes,
        calls: CrossPlatformLock<[String]> = .init(initialState: [])
    ) -> DeviceCommandRunner {
        DeviceCommandRunner { arguments, timeout in
            #expect(arguments.prefix(5) == ["devicectl", "--timeout", "30", "device", "info"])
            #expect(timeout == 35)
            let subject = arguments[5]
            #expect(subject == "apps" || subject == "processes")
            #expect(arguments[6 ... 7] == ["--device", "PHONE"])
            calls.withLock { $0.append(subject) }
            let index = try #require(arguments.firstIndex(of: "--json-output"))
            try (subject == "apps" ? apps : processes).write(
                toFile: arguments[index + 1],
                atomically: true,
                encoding: .utf8
            )
            return ProcessExecutionResult(output: "Human-readable output is ignored", error: nil, exitCode: 0)
        }
    }
}
