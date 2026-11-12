import Foundation
import Support
import Testing
@testable import XcodeProjectManagement

struct SimulatorConsoleLaunchTests {
    @Test
    func startsSuspendedWithLiveOutputAndChildEnvironment() async throws {
        var commands = SimulatorCommandRunner { arguments, _ in
            #expect(arguments == ["simctl", "bootstatus", "SIM", "-b"]
                || arguments == ["simctl", "spawn", "SIM", "launchctl", "list"])
            return .init(output: "", error: nil, exitCode: 0)
        }
        commands.startConsole = { arguments, environment, bundle in
            #expect(arguments == [
                "simctl", "launch", "--console-pty", "--terminate-running-process", "--wait-for-debugger",
                "SIM", "test.App", "--flag"
            ])
            #expect(!arguments.contains("--console"))
            #expect(environment["SIMCTL_CHILD_FEATURE"] == "enabled")
            #expect(environment["SIMCTL_CHILD_OS_ACTIVITY_DT_MODE"] == "enable")
            return try ApplicationConsole(
                executable: "/bin/sh",
                arguments: ["-c", "printf 'test.App: 4242\\napp output\\n'; exec sleep 30"],
                simulatorBundleID: bundle
            )
        }
        let launcher = SimulatorDebugLauncher(commands: commands)
        let (pid, console) = try await launcher.launchConsoleWaitingForDebugger(
            deviceID: "SIM", appIdentifier: "test.App",
            settings: .init(arguments: ["--flag"], environment: ["FEATURE": "enabled"])
        )
        #expect(pid == 4242)
        let received = CrossPlatformLock(initialState: "")
        await console.output.connect { output in received.withLock { $0 += output.text } }
        await console.stop(terminateApp: false)
        #expect(received.withLock { $0 } == "app output\n")
        #expect(console.exitCode != nil)
    }

    @Test
    func findsPausedApplicationWithoutConsolePIDAndIgnoresPreviousProcess() async throws {
        let queries = CrossPlatformLock(initialState: 0)
        var commands = SimulatorCommandRunner { arguments, _ in
            if arguments == ["simctl", "bootstatus", "SIM", "-b"] {
                return .init(output: "", error: nil, exitCode: 0)
            }
            #expect(arguments == ["simctl", "spawn", "SIM", "launchctl", "list"])
            let query = queries.withLock { value in
                value += 1
                return value
            }
            let pid = query < 3 ? 111 : 222
            return .init(output: "\(pid)\t0\tUIKitApplication:test.App[da9c][rb-legacy]\n", error: nil, exitCode: 0)
        }
        commands.startConsole = { _, _, bundle in
            try ApplicationConsole(
                executable: "/bin/sh", arguments: ["-c", "printf 'app output\\n'; exec sleep 30"],
                simulatorBundleID: bundle
            )
        }
        let launcher = SimulatorDebugLauncher(commands: commands)
        let (pid, console) = try await launcher.launchConsoleWaitingForDebugger(
            deviceID: "SIM", appIdentifier: "test.App", settings: .init()
        )
        #expect(pid == 222)
        #expect(queries.withLock { $0 } >= 3)
        await console.stop(terminateApp: false)
    }

    @Test
    func matchesOnlyTheRequestedApplicationLabel() {
        let output = """
        PID Status Label
        111 0 UIKitApplication:test.AppExtension[da9c][rb-legacy]
        - 0 UIKitApplication:test.App[da9c][rb-legacy]
        123 0 UIKitApplication:test.App[old][rb-legacy]
        222 0 UIKitApplication:test.App[da9c][rb-legacy]
        """
        #expect(SimulatorCommandRunner.parseApplicationPID(from: output, appIdentifier: "test.App") == 123)
        #expect(SimulatorCommandRunner
            .parseApplicationPID(from: output, appIdentifier: "test.App", excluding: 123) == 222)
        #expect(SimulatorCommandRunner.parseApplicationPID(from: output, appIdentifier: "other.App") == nil)
    }

    @Test
    func simulatorRunKeepsTheConsoleWithoutWaitingForADebugger() throws {
        var commands = SimulatorCommandRunner { _, _ in
            Issue.record("Run must not use the detached launch command")
            throw CancellationError()
        }
        commands.startConsole = { arguments, _, _ in
            #expect(arguments.contains("--console-pty"))
            #expect(!arguments.contains("--console"))
            #expect(!arguments.contains("--wait-for-debugger"))
            throw CancellationError()
        }
        #expect(throws: CancellationError.self) {
            try commands.launchConsole(deviceID: "SIM", appIdentifier: "test.App", settings: .init())
        }
    }
}
