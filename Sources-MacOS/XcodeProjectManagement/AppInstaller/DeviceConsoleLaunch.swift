import Foundation

extension DeviceCommandRunner {
    /// CoreDevice can defer its launch JSON until console exit. Find the new process by its installed path.
    func launchConsole(
        deviceID: String,
        bundleID: String,
        localExecutable: String,
        settings: XcodeLaunchSettings,
        stopped: Bool,
        outputHandler: ApplicationOutputBuffer.Handler? = nil,
        timeout: Duration = .seconds(60)
    ) async throws -> (pid: Int?, console: ApplicationConsole) {
        let discovery = DeviceAttachDiscovery(commands: self)
        let executable = try await discovery.installedExecutable(
            deviceID: deviceID, bundleID: bundleID, localExecutable: localExecutable
        )
        let previous = try await discovery.processIDs(deviceID: deviceID, executable: executable)
        try Task.checkCancellation()
        var settings = settings
        settings.environment = settings.consoleEnvironment
        let console = try startConsole(launchArguments(
            deviceID: deviceID, bundleID: bundleID, stopped: stopped, settings: settings, options: ["--console"]
        ))
        if let outputHandler { await console.output.connect(outputHandler) }
        do {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                if console.exitCode != nil {
                    if !stopped { return (nil, console) }
                    let code = try await console.wait()
                    let text = await console.output.recentText
                    throw XcodeRunError
                        .failedToLaunchApp("Device console exited before launch completed (code \(code)): \(text)")
                }
                let matches = try await discovery.processIDs(deviceID: deviceID, executable: executable)
                    .subtracting(previous)
                if matches.count == 1, let pid = matches.first { return (pid, console) }
                guard matches.count <= 1 else {
                    throw XcodeRunError.failedToLaunchApp("Multiple new processes match \(bundleID)")
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            throw XcodeRunError.failedToLaunchApp("Timed out waiting for \(bundleID) to launch")
        } catch {
            await Task.detached {
                // A stopped app might not act on a forwarded signal. Identify it before closing the helper.
                let processes = try? await discovery.processIDs(deviceID: deviceID, executable: executable)
                    .subtracting(previous)
                if let processes, processes.count == 1, let pid = processes.first {
                    await terminate(deviceID: deviceID, pid: pid)
                }
                await console.stop(terminateApp: true)
            }.value
            throw error
        }
    }
}
