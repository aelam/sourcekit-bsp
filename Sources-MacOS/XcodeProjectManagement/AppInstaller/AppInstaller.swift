import Foundation
import Support

protocol AppInstaller {
    func installApp(
        appPath: String,
        deviceID: String,
        progressHandler: (@Sendable (String) async -> Void)?
    ) async throws -> ProcessExecutionResult
}

struct DeviceInstaller: AppInstaller {
    func installApp(
        appPath: String,
        deviceID: String,
        progressHandler: (@Sendable (String) async -> Void)?
    ) async throws -> ProcessExecutionResult {
        let executor = ProcessExecutor()
        await progressHandler?("Installing app on device \(deviceID)")
        let result = try await executor.execute(
            executable: "/usr/bin/xcrun",
            arguments: ["devicectl", "install", "--device", deviceID, "--path", appPath]
        )
        guard result.isSuccess else {
            throw XcodeRunError.failedToLaunchApp(result.error ?? result.output)
        }
        return result
    }
}

struct SimulatorCommandRunner: Sendable {
    var execute: @Sendable ([String], TimeInterval) async throws -> ProcessExecutionResult = { arguments, timeout in
        try await ProcessExecutor().execute(executable: "/usr/bin/xcrun", arguments: arguments, timeout: timeout)
    }

    func run(arguments: [String], timeout: TimeInterval, phase: String) async throws -> ProcessExecutionResult {
        do {
            let result = try await execute(arguments, timeout)
            guard result.isSuccess else {
                throw XcodeRunError.failedToLaunchApp("Exit \(result.exitCode): \(result.error ?? result.output)")
            }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw XcodeRunError.failedToLaunchApp("\(phase): \(error.localizedDescription)")
        }
    }

    func prepare(deviceID: String) async throws {
        // bootstatus -b also boots a stopped device and accepts an already booted device.
        _ = try await run(
            arguments: ["simctl", "bootstatus", deviceID, "-b"],
            timeout: 90,
            phase: "Preparing simulator \(deviceID)"
        )
    }
}

struct SimulatorInstaller: AppInstaller {
    var commands = SimulatorCommandRunner()

    func installApp(
        appPath: String,
        deviceID: String,
        progressHandler: (@Sendable (String) async -> Void)?
    ) async throws -> ProcessExecutionResult {
        await progressHandler?("Preparing simulator \(deviceID) (timeout: 90s)")
        try await commands.prepare(deviceID: deviceID)
        await progressHandler?("Installing app on simulator \(deviceID) (timeout: 120s)")
        return try await commands.run(
            arguments: ["simctl", "install", deviceID, appPath],
            timeout: 120,
            phase: "Installing app on simulator \(deviceID)"
        )
    }
}

protocol AppLauncher {
    func launchApp(
        deviceID: String,
        appIdentifier: String
    ) async throws -> ProcessExecutionResult
}

struct DeviceLauncher: AppLauncher {
    func launchApp(
        deviceID: String,
        appIdentifier: String
    ) async throws -> ProcessExecutionResult {
        let executor = ProcessExecutor()
        let result = try await executor.execute(
            executable: "/usr/bin/xcrun",
            arguments: ["devicectl", "launch", "--device", deviceID, "--bundle-id", appIdentifier]
        )
        guard result.isSuccess else {
            throw XcodeRunError.failedToLaunchApp(result.error ?? result.output)
        }
        return result
    }
}

/// Launch seam that spawns the app paused for the debugger and returns its PID.
public protocol WaitForDebuggerLaunching: Sendable {
    func launchWaitingForDebugger(deviceID: String, appIdentifier: String) async throws -> Int
}

public struct SimulatorDebugLauncher: WaitForDebuggerLaunching {
    public init() {}

    public func launchWaitingForDebugger(deviceID: String, appIdentifier: String) async throws -> Int {
        try await SimulatorCommandRunner().prepare(deviceID: deviceID)

        // Read stdout to EOF before parsing the launched process ID.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "launch", "--wait-for-debugger", deviceID, appIdentifier]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw XcodeRunError.failedToLaunchApp(
                "Failed to launch \(appIdentifier) on simulator \(deviceID): \(error.localizedDescription)"
            )
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0, let pid = Self.parsePID(from: output) else {
            throw XcodeRunError.failedToLaunchApp(
                "Failed to launch \(appIdentifier) on simulator \(deviceID) for debugging"
            )
        }
        return pid
    }

    /// Parse the PID from `simctl launch` output "<bundleId>: <pid>".
    static func parsePID(from output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) {
            if let colon = line.lastIndex(of: ":") {
                let tail = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if let pid = Int(tail) { return pid }
            }
        }
        return nil
    }
}

struct SimulatorLauncher: AppLauncher {
    func launchApp(
        deviceID: String,
        appIdentifier: String
    ) async throws -> ProcessExecutionResult {
        let executor = ProcessExecutor()

        // IMPORTANT: no `--console`. `--console` attaches to the app's stdout and
        // blocks until the app exits, which hangs `run` forever for a GUI app.
        // Launch detached and return immediately; the app keeps running in the
        // simulator (its logs can be streamed separately via notifications).
        let result = try await executor.execute(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "launch", deviceID, appIdentifier]
        )
        guard result.exitCode == 0 else {
            throw XcodeRunError.failedToLaunchApp(
                "simctl launch failed for \(appIdentifier) on \(deviceID) " +
                    "(exit \(result.exitCode)): \(result.error ?? result.output)"
            )
        }
        return result
    }
}
