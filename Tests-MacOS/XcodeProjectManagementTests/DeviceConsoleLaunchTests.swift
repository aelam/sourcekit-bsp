import Foundation
import Support
import Testing
@testable import XcodeProjectManagement

struct DeviceConsoleLaunchTests {
    @Test
    func findsOnlyTheNewProcessForTheInstalledBundle() async throws {
        let queries = CrossPlatformLock(initialState: 0)
        let consoleArguments = CrossPlatformLock(initialState: [String]())
        var commands = DeviceCommandRunner { arguments, _ in
            let result: String
            if arguments.contains("apps") {
                result = #"{"apps":[{"bundleIdentifier":"test.App","url":"file:///private/var/apps/App.app"}]}"#
            } else {
                let count = queries.withLock { $0 += 1; return $0 }
                let new = count >= 3 ? #",{"processIdentifier":43,"executable":"/var/apps/App.app/App"}"# : ""
                result =
                    #"{"runningProcesses":[{"processIdentifier":41,"executable":"/var/apps/App.app/App"},{"processIdentifier":42,"executable":"/var/other/App.app/App"}"# +
                    new + "]}"
            }
            try writeReport(result, arguments: arguments)
            return .init(output: "", error: nil, exitCode: 0)
        }
        commands.startConsole = { arguments in
            consoleArguments.withLock { $0 = arguments }
            return try ApplicationConsole(executable: "/bin/sleep", arguments: ["30"])
        }
        let launched = try await commands.launchConsole(
            deviceID: "PHONE", bundleID: "test.App", localExecutable: "/build/App.app/App",
            settings: .init(arguments: ["--flag"], environment: ["FEATURE": "yes"]), stopped: true
        )
        #expect(launched.pid == 43)
        #expect(queries.withLock { $0 } == 3)
        let arguments = consoleArguments.withLock { $0 }
        #expect(arguments.contains("--console"))
        #expect(arguments.contains("--start-stopped"))
        #expect(!arguments.contains("--timeout"))
        #expect(arguments.suffix(3) == ["test.App", "--", "--flag"])
        let environmentIndex = try #require(arguments.firstIndex(of: "--environment-variables"))
        let environment = try JSONDecoder().decode(
            [String: String].self,
            from: Data(arguments[environmentIndex + 1].utf8)
        )
        #expect(environment["FEATURE"] == "yes")
        #expect(environment["OS_ACTIVITY_DT_MODE"] == "enable")
        #expect(environment["OS_ACTIVITY_MODE"] == "debug")
        await launched.console.stop(terminateApp: false)
    }

    @Test
    func failedConsoleLaunchIncludesTheDeviceError() async throws {
        var commands = emptyDevice()
        commands.startConsole = { _ in
            try ApplicationConsole(executable: "/bin/sh", arguments: ["-c", "printf 'Device is locked\\n' >&2; exit 1"])
        }
        let error = try await #require(throws: XcodeRunError.self) {
            try await commands.launchConsole(
                deviceID: "PHONE", bundleID: "test.App", localExecutable: "/build/App",
                settings: .init(), stopped: true
            )
        }
        #expect(error.localizedDescription.contains("Device is locked"))
    }

    @Test
    func launchTimeoutClosesTheConsole() async throws {
        let process = CrossPlatformLock<ApplicationConsole?>(initialState: nil)
        var commands = emptyDevice()
        commands.startConsole = { _ in
            let console = try ApplicationConsole(executable: "/bin/sleep", arguments: ["30"])
            process.withLock { $0 = console }
            return console
        }
        await #expect(throws: XcodeRunError.self) {
            try await commands.launchConsole(
                deviceID: "PHONE", bundleID: "test.App", localExecutable: "/build/App",
                settings: .init(), stopped: true, timeout: .milliseconds(10)
            )
        }
        #expect(process.withLock { $0?.exitCode } != nil)
    }

    private func emptyDevice() -> DeviceCommandRunner {
        DeviceCommandRunner { arguments, _ in
            let result = arguments.contains("apps")
                ? #"{"apps":[{"bundleIdentifier":"test.App","url":"file:///var/apps/App.app"}]}"#
                : #"{"runningProcesses":[]}"#
            try writeReport(result, arguments: arguments)
            return .init(output: "", error: nil, exitCode: 0)
        }
    }
}

private func writeReport(_ result: String, arguments: [String]) throws {
    let index = try #require(arguments.firstIndex(of: "--json-output"))
    try "{\"info\":{\"outcome\":\"success\"},\"result\":\(result)}"
        .write(toFile: arguments[index + 1], atomically: true, encoding: .utf8)
}
