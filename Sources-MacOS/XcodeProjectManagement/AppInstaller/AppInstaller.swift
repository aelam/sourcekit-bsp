import Foundation
import Support

protocol AppInstaller {
    func installApp(
        appPath: String,
        deviceID: String
    ) async throws -> ProcessExecutionResult
}

struct DeviceInstaller: AppInstaller {
    func installApp(
        appPath: String,
        deviceID: String
    ) async throws -> ProcessExecutionResult {
        let executor = ProcessExecutor()
        return try await executor.execute(
            executable: "/usr/bin/xcrun",
            arguments: ["devicectl", "install", "--device", deviceID, "--path", appPath]
        )
    }
}

struct SimulatorInstaller: AppInstaller {
    func installApp(
        appPath: String,
        deviceID: String
    ) async throws -> ProcessExecutionResult {
        let executor = ProcessExecutor()

        _ = try? await executor.execute(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "boot", deviceID]
        )
        return try await executor.execute(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "install", deviceID, appPath]
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
        return try await executor.execute(
            executable: "/usr/bin/xcrun",
            arguments: ["devicectl", "launch", "--device", deviceID, "--bundle-id", appIdentifier]
        )
    }
}

/// Launch seam that spawns the app paused for the debugger and returns its PID.
public protocol WaitForDebuggerLaunching: Sendable {
    func launchWaitingForDebugger(deviceID: String, appIdentifier: String) async throws -> Int
}

public struct SimulatorDebugLauncher: WaitForDebuggerLaunching {
    public init() {}

    public func launchWaitingForDebugger(deviceID: String, appIdentifier: String) async throws -> Int {
        // Booting is idempotent; we don't parse its output so the shared executor is fine.
        let executor = ProcessExecutor()
        _ = try? await executor.execute(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "boot", deviceID]
        )

        // Read stdout synchronously to EOF so we reliably capture the
        // "<bundleId>: <pid>" line. (ProcessExecutor.execute accumulates output
        // via detached tasks and may return before they run, which would make
        // PID parsing intermittently fail.)
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
