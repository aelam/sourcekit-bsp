import Foundation
import Support
import Testing
@testable import XcodeProjectManagement

private actor SimulatorCalls {
    private(set) var arguments: [[String]] = []
    func append(_ arguments: [String]) {
        self.arguments.append(arguments)
    }
}

struct SimulatorInstallerTests {
    @Test
    func alreadyBootedDeviceCanInstallWithoutBootRequest() async throws {
        let calls = SimulatorCalls()
        let commands = SimulatorCommandRunner { arguments, _ in
            await calls.append(arguments)
            if arguments[1] == "boot" { throw ProcessExecutorError.timeout(90) }
            return ProcessExecutionResult(output: "Device already booted, nothing to do.", error: nil, exitCode: 0)
        }
        let result = try await SimulatorInstaller(commands: commands).installApp(
            appPath: "/tmp/Hello.app", deviceID: "SIM", progressHandler: nil
        )
        #expect(result.isSuccess)
        #expect(await calls.arguments == [
            ["simctl", "bootstatus", "SIM", "-b"],
            ["simctl", "install", "SIM", "/tmp/Hello.app"]
        ])
    }

    @Test(arguments: ["bootstatus", "install"])
    func timeoutIdentifiesTheFailedStage(command: String) async throws {
        let commands = SimulatorCommandRunner { arguments, timeout in
            if arguments[1] == command { throw ProcessExecutorError.timeout(timeout) }
            return ProcessExecutionResult(output: "", error: nil, exitCode: 0)
        }
        let error = try await #require(throws: XcodeRunError.self) {
            try await SimulatorInstaller(commands: commands).installApp(
                appPath: "/tmp/Hello.app", deviceID: "SIM", progressHandler: nil
            )
        }
        #expect(error.localizedDescription.contains(command == "bootstatus" ? "Preparing simulator" : "Installing app"))
        #expect(error.localizedDescription.contains("timed out"))
        #expect(!error.localizedDescription.contains("Invalid configuration"))
    }

    @Test
    func failedPreparationPreventsInstallation() async throws {
        let calls = SimulatorCalls()
        let commands = SimulatorCommandRunner { arguments, _ in
            await calls.append(arguments)
            return ProcessExecutionResult(output: "", error: "Device unavailable", exitCode: 1)
        }
        let error = try await #require(throws: XcodeRunError.self) {
            try await SimulatorInstaller(commands: commands).installApp(
                appPath: "/tmp/Hello.app", deviceID: "SIM", progressHandler: nil
            )
        }
        #expect(error.localizedDescription.contains("Device unavailable"))
        #expect(await calls.arguments.count == 1)
    }

    @Test
    func cancellationIsNotConvertedToALaunchFailure() async {
        let commands = SimulatorCommandRunner { _, _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await SimulatorInstaller(commands: commands).installApp(
                appPath: "/tmp/Hello.app", deviceID: "SIM", progressHandler: nil
            )
        }
    }
}
