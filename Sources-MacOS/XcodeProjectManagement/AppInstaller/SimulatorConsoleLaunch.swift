import Foundation

protocol ConsoleDebuggerLaunching: WaitForDebuggerLaunching {
    func launchConsoleWaitingForDebugger(
        deviceID: String, appIdentifier: String, settings: XcodeLaunchSettings
    ) async throws -> (Int, ApplicationConsole)
}

extension SimulatorDebugLauncher: ConsoleDebuggerLaunching {
    func launchConsoleWaitingForDebugger(
        deviceID: String, appIdentifier: String, settings: XcodeLaunchSettings
    ) async throws -> (Int, ApplicationConsole) {
        try await commands.prepare(deviceID: deviceID)
        let console = try commands.launchConsole(
            deviceID: deviceID, appIdentifier: appIdentifier, settings: settings, stopped: true
        )
        do {
            guard let pid = try await console.waitForSimulatorLaunch() else {
                _ = try await console.wait()
                let text = await console.output.recentText
                throw XcodeRunError.failedToLaunchApp("The simulator exited before the debugger could attach: \(text)")
            }
            return (pid, console)
        } catch {
            await Task.detached { await console.stop(terminateApp: true) }.value
            throw error
        }
    }
}

extension ApplicationConsole {
    func waitForSimulatorLaunch() async throws -> Int? {
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let pid = await output.simulatorPID { return pid }
            if exitCode != nil { return nil }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XcodeRunError.failedToLaunchApp("Timed out waiting for the simulator application to launch")
    }
}
