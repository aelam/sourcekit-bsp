import Foundation
import Support
import Testing
@testable import XcodeProjectManagement

struct SimulatorConsoleLaunchTests {
    @Test
    func startsSuspendedWithLiveOutputAndChildEnvironment() async throws {
        var commands = SimulatorCommandRunner { arguments, _ in
            #expect(arguments == ["simctl", "bootstatus", "SIM", "-b"])
            return .init(output: "", error: nil, exitCode: 0)
        }
        commands.startConsole = { arguments, environment, bundle in
            #expect(arguments == [
                "simctl", "launch", "--console", "--terminate-running-process", "--wait-for-debugger",
                "SIM", "test.App", "--flag"
            ])
            #expect(!arguments.contains("--console-pty"))
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
