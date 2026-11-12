import Foundation
import Support

/// Runs CoreDevice commands with the project's selected Xcode installation.
struct DeviceCommandRunner: Sendable {
    var execute: @Sendable ([String], TimeInterval) async throws -> ProcessExecutionResult
    var startConsole: @Sendable ([String]) throws -> ApplicationConsole

    init(developerDirectory: URL? = nil) {
        let environment = developerDirectory.map { ["DEVELOPER_DIR": $0.path] } ?? [:]
        startConsole = { arguments in
            try ApplicationConsole(arguments: ["devicectl"] + arguments, environment: environment)
        }
        execute = { arguments, timeout in
            try await ProcessExecutor().execute(
                executable: "/usr/bin/xcrun",
                arguments: arguments,
                environment: environment,
                timeout: timeout
            )
        }
    }

    init(execute: @escaping @Sendable ([String], TimeInterval) async throws -> ProcessExecutionResult) {
        self.execute = execute
        startConsole = { _ in
            throw XcodeRunError.failedToLaunchApp("A console launcher was not supplied")
        }
    }

    func run(_ arguments: [String], timeout: TimeInterval, phase: String) async throws -> ProcessExecutionResult {
        do {
            let result = try await execute(["devicectl", "--timeout", String(Int(timeout))] + arguments, timeout + 5)
            guard result.isSuccess else {
                throw XcodeRunError.failedToLaunchApp(result.error ?? result.output)
            }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw XcodeRunError.failedToLaunchApp("\(phase): \(error.localizedDescription)")
        }
    }

    func launch(
        deviceID: String, bundleID: String, stopped: Bool, settings: XcodeLaunchSettings = .init()
    ) async throws -> Int {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resultURL = directory.appendingPathComponent("launch.json")
        let arguments = try launchArguments(
            deviceID: deviceID, bundleID: bundleID, stopped: stopped, settings: settings,
            options: ["--json-output", resultURL.path]
        )
        do {
            _ = try await run(arguments, timeout: 60, phase: "Launching \(bundleID) on device \(deviceID)")
            return try Self.launchPID(from: Data(contentsOf: resultURL))
        } catch {
            if stopped, let data = try? Data(contentsOf: resultURL), let pid = try? Self.launchPID(from: data) {
                await Task.detached { await terminate(deviceID: deviceID, pid: pid) }.value
            }
            throw error
        }
    }

    func launchArguments(
        deviceID: String, bundleID: String, stopped: Bool, settings: XcodeLaunchSettings, options: [String]
    ) throws -> [String] {
        var arguments = ["device", "process", "launch", "--device", deviceID, "--terminate-existing"] + options
        if stopped { arguments.append("--start-stopped") }
        if !settings.environment.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: settings.environment, options: .sortedKeys)
            guard let json = String(data: data, encoding: .utf8) else {
                throw XcodeRunError.failedToLaunchApp("Cannot encode the launch environment")
            }
            arguments += ["--environment-variables", json]
        }
        if let directory = settings.workingDirectory { arguments += ["--working-directory", directory] }
        return arguments + [bundleID] + (settings.arguments.isEmpty ? [] : ["--"] + settings.arguments)
    }

    static func launchPID(from data: Data) throws -> Int {
        guard let report = try? JSONDecoder().decode(DeviceLaunchReport.self, from: data),
              report.info.outcome == "success", report.result.process.processIdentifier > 0 else {
            throw XcodeRunError
                .failedToLaunchApp("devicectl did not report a successful launch with a valid process ID")
        }
        return report.result.process.processIdentifier
    }

    func terminate(deviceID: String, pid: Int) async {
        _ = try? await run(
            ["device", "process", "terminate", "--device", deviceID, "--pid", String(pid), "--kill"],
            timeout: 15,
            phase: "Stopping debug process \(pid) on device \(deviceID)"
        )
    }
}

private struct DeviceLaunchReport: Decodable {
    struct Info: Decodable { let outcome: String }
    struct Result: Decodable { let process: Process }
    struct Process: Decodable { let processIdentifier: Int }
    let info: Info
    let result: Result
}
