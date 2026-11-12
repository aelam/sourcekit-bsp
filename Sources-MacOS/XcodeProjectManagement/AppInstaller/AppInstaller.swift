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
    var commands = DeviceCommandRunner()
    func installApp(
        appPath: String,
        deviceID: String,
        progressHandler: (@Sendable (String) async -> Void)?
    ) async throws -> ProcessExecutionResult {
        await progressHandler?("Installing app on device \(deviceID)")
        return try await commands.run(
            ["device", "install", "app", "--device", deviceID, appPath],
            timeout: 120,
            phase: "Installing app on device \(deviceID)"
        )
    }
}

struct SimulatorCommandRunner: Sendable {
    var execute: @Sendable ([String], [String: String], TimeInterval) async throws -> ProcessExecutionResult
    var startConsole: @Sendable ([String], [String: String], String) throws -> ApplicationConsole

    init(developerDirectory: URL? = nil) {
        let selected = developerDirectory.map { ["DEVELOPER_DIR": $0.path] } ?? [:]
        startConsole = { arguments, environment, bundle in
            try ApplicationConsole(
                arguments: arguments, environment: environment.merging(selected) { _, selected in selected },
                simulatorBundleID: bundle
            )
        }
        execute = { arguments, environment, timeout in
            try await ProcessExecutor().execute(
                executable: "/usr/bin/xcrun",
                arguments: arguments,
                environment: environment.merging(selected) { _, selected in selected },
                timeout: timeout
            )
        }
    }

    init(execute: @escaping @Sendable ([String], TimeInterval) async throws -> ProcessExecutionResult) {
        self.execute = { arguments, _, timeout in try await execute(arguments, timeout) }
        startConsole = { _, _, _ in throw XcodeRunError.failedToLaunchApp("A console launcher was not supplied") }
    }

    init(executeWithEnvironment: @escaping @Sendable ([String], [String: String], TimeInterval) async throws
        -> ProcessExecutionResult) {
        execute = executeWithEnvironment
        startConsole = { _, _, _ in throw XcodeRunError.failedToLaunchApp("A console launcher was not supplied") }
    }

    func launchConsole(
        deviceID: String, appIdentifier: String, settings: XcodeLaunchSettings, stopped: Bool = false
    ) throws -> ApplicationConsole {
        guard settings.workingDirectory == nil else {
            throw XcodeRunError.failedToLaunchApp("Custom working directories are not supported for simulator launches")
        }
        var arguments = ["simctl", "launch", "--console", "--terminate-running-process"]
        if stopped { arguments.append("--wait-for-debugger") }
        arguments += [deviceID, appIdentifier] + settings.arguments
        let environment = Dictionary(uniqueKeysWithValues: settings.consoleEnvironment.map {
            ("SIMCTL_CHILD_" + $0.key, $0.value)
        })
        return try startConsole(arguments, environment, appIdentifier)
    }

    func run(
        arguments: [String], environment: [String: String] = [:], timeout: TimeInterval, phase: String
    ) async throws -> ProcessExecutionResult {
        do {
            let result = try await execute(arguments, environment, timeout)
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
        // bootstatus -b accepts both stopped and booted devices.
        _ = try await run(
            arguments: ["simctl", "bootstatus", deviceID, "-b"],
            timeout: 90,
            phase: "Preparing simulator \(deviceID)"
        )
    }

    func launch(
        deviceID: String, appIdentifier: String, settings: XcodeLaunchSettings, stopped: Bool
    ) async throws -> ProcessExecutionResult {
        guard settings.workingDirectory == nil else {
            throw XcodeRunError.failedToLaunchApp("Custom working directories are not supported for simulator launches")
        }
        var arguments = ["simctl", "launch"]
        if stopped { arguments.append("--wait-for-debugger") }
        arguments += [deviceID, appIdentifier] + settings.arguments
        let environment = Dictionary(uniqueKeysWithValues: settings.environment.map { (
            "SIMCTL_CHILD_" + $0.key,
            $0.value
        ) })
        return try await run(
            arguments: arguments,
            environment: environment,
            timeout: 60,
            phase: "Launching \(appIdentifier) on simulator \(deviceID)"
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
        deviceID: String, appIdentifier: String, settings: XcodeLaunchSettings
    ) async throws -> ProcessExecutionResult
}

struct DeviceLauncher: AppLauncher {
    var commands = DeviceCommandRunner()

    func launchApp(
        deviceID: String, appIdentifier: String, settings: XcodeLaunchSettings = .init()
    ) async throws -> ProcessExecutionResult {
        let pid = try await commands.launch(
            deviceID: deviceID,
            bundleID: appIdentifier,
            stopped: false,
            settings: settings
        )
        return ProcessExecutionResult(output: "Launched \(appIdentifier) (pid \(pid))", error: nil, exitCode: 0)
    }
}

public protocol WaitForDebuggerLaunching: Sendable {
    func launchWaitingForDebugger(deviceID: String, appIdentifier: String) async throws -> Int
    func launchWaitingForDebugger(deviceID: String, appIdentifier: String, settings: XcodeLaunchSettings) async throws
        -> Int
}

public extension WaitForDebuggerLaunching {
    func launchWaitingForDebugger(
        deviceID: String,
        appIdentifier: String,
        settings: XcodeLaunchSettings
    ) async throws -> Int {
        guard settings == XcodeLaunchSettings() else {
            throw XcodeRunError.failedToLaunchApp("This launcher does not support scheme launch settings")
        }
        return try await launchWaitingForDebugger(deviceID: deviceID, appIdentifier: appIdentifier)
    }
}

public struct SimulatorDebugLauncher: WaitForDebuggerLaunching {
    var commands: SimulatorCommandRunner

    public init(developerDirectory: URL? = nil) {
        commands = SimulatorCommandRunner(developerDirectory: developerDirectory)
    }

    init(commands: SimulatorCommandRunner) {
        self.commands = commands
    }

    public func launchWaitingForDebugger(deviceID: String, appIdentifier: String) async throws -> Int {
        try await launchWaitingForDebugger(deviceID: deviceID, appIdentifier: appIdentifier, settings: .init())
    }

    public func launchWaitingForDebugger(
        deviceID: String,
        appIdentifier: String,
        settings: XcodeLaunchSettings
    ) async throws -> Int {
        try await commands.prepare(deviceID: deviceID)
        let result = try await commands.launch(
            deviceID: deviceID,
            appIdentifier: appIdentifier,
            settings: settings,
            stopped: true
        )
        guard let pid = Self.parsePID(from: result.output), pid > 0 else {
            throw XcodeRunError.failedToLaunchApp("The simulator did not report a valid process ID")
        }
        return pid
    }

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
    var commands = SimulatorCommandRunner()

    func launchApp(
        deviceID: String, appIdentifier: String, settings: XcodeLaunchSettings = .init()
    ) async throws -> ProcessExecutionResult {
        // --console waits for the app to exit, so normal Run must launch detached.
        try await commands.launch(deviceID: deviceID, appIdentifier: appIdentifier, settings: settings, stopped: false)
    }
}
