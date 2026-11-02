import Foundation
import Support

/// Runs CoreDevice commands with the project's selected Xcode installation.
struct DeviceCommandRunner: Sendable {
    var execute: @Sendable ([String], TimeInterval) async throws -> ProcessExecutionResult

    init(developerDirectory: URL? = nil) {
        let environment = developerDirectory.map { ["DEVELOPER_DIR": $0.path] } ?? [:]
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

    func launch(deviceID: String, bundleID: String, stopped: Bool) async throws -> Int {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resultURL = directory.appendingPathComponent("launch.json")
        var arguments = ["device", "process", "launch", "--device", deviceID, "--terminate-existing"]
        if stopped { arguments.append("--start-stopped") }
        arguments += ["--json-output", resultURL.path, bundleID]
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
