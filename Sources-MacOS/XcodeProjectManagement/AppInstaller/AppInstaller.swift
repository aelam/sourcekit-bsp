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
        let executor = ProcessExecutor()
        _ = try? await executor.execute(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "boot", deviceID]
        )
        let result = try await executor.execute(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "launch", "--wait-for-debugger", deviceID, appIdentifier]
        )
        guard result.exitCode == 0, let pid = Self.parsePID(from: result.output) else {
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
        appIdentifier: String,
    ) async throws -> ProcessExecutionResult {
        let executor = ProcessExecutor()

        var isLaunched = false
        for _ in 0 ..< 30 {
            let result = try await executor.execute(
                executable: "/usr/bin/xcrun",
                arguments: ["simctl", "launch", "--console", deviceID, appIdentifier]
            )
            if result.exitCode == 0 {
                isLaunched = true
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 等待 1 秒再试
        }

        if !isLaunched {
            throw XcodeRunError.failedToLaunchApp("Failed to launch app \(appIdentifier) on simulator \(deviceID)")
        } else {
            return ProcessExecutionResult(output: "App launched", error: nil, exitCode: 0)
        }
    }
}
