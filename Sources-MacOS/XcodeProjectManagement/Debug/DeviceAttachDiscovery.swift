import Foundation
import Support

struct DeviceProcessIdentity: Sendable, Equatable {
    let deviceID: String
    let bundleID: String
    let pid: Int
    let executable: String
    let localExecutable: String
}

/// Matches an installed app to a running process on the selected device.
struct DeviceAttachDiscovery: Sendable {
    let commands: DeviceCommandRunner
    private let timing = AttachTiming.current ?? AttachTiming()

    func resolve(product: DebugProduct, pid: Int?) async throws -> DeviceProcessIdentity {
        try Task.checkCancellation()
        try product.validate()
        guard product.platform == .iOS, let device = product.destinationID,
              let bundle = product.bundleId, let local = product.executablePath else {
            throw HostAttachError.invalid("Device Attach requires an iOS application and a physical device.")
        }
        guard FileManager.default.fileExists(atPath: local) else {
            throw DebugSessionError.productNotFound(local)
        }
        let apps: DeviceApps = try await query("apps", deviceID: device)
        let installed = apps.apps.filter { $0.bundleIdentifier == bundle }
        guard installed.count == 1, let appURL = installed[0].url,
              let appPath = Self.devicePath(appURL), appPath.hasSuffix(".app") else {
            throw HostAttachError
                .invalid("App \(bundle) is not installed on device \(device). Install a development build first.")
        }
        let executable = appPath + "/" + URL(fileURLWithPath: local).lastPathComponent
        let processes: DeviceProcesses = try await query("processes", deviceID: device)
        let matches = processes.runningProcesses.filter {
            $0.processIdentifier > 0 && $0.executable.flatMap(Self.devicePath) == executable
        }
        let selected: DeviceProcess
        if let pid {
            guard let match = matches.first(where: { $0.processIdentifier == pid }) else {
                throw HostAttachError.invalid("PID \(pid) does not belong to \(bundle) on device \(device).")
            }
            selected = match
        } else {
            guard !matches.isEmpty else {
                throw HostAttachError.invalid("App \(bundle) is not running on device \(device). Start the app first.")
            }
            guard matches.count == 1 else {
                throw HostAttachError
                    .invalid("Multiple processes match \(bundle). Set pid in launch.json to the required process ID.")
            }
            selected = matches[0]
        }
        try Task.checkCancellation()
        return DeviceProcessIdentity(
            deviceID: device,
            bundleID: bundle,
            pid: selected.processIdentifier,
            executable: executable,
            localExecutable: local
        )
    }

    func validate(_ identity: DeviceProcessIdentity) async throws {
        let processes: DeviceProcesses = try await query("processes", deviceID: identity.deviceID)
        guard processes.runningProcesses.contains(where: {
            $0.processIdentifier == identity.pid && $0.executable.flatMap(Self.devicePath) == identity.executable
        }) else {
            throw HostAttachError.invalid("The selected device process exited or changed. Start Attach again.")
        }
    }

    private func query<Result: Decodable>(_ subject: String, deviceID: String) async throws -> Result {
        try await timing.measure("device.\(subject)") {
            try await readReport(subject, deviceID: deviceID)
        }
    }

    private func readReport<Result: Decodable>(_ subject: String, deviceID: String) async throws -> Result {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("result.json")
        _ = try await commands.run(
            ["device", "info", subject, "--device", deviceID, "--json-output", output.path],
            timeout: 30,
            phase: "Reading \(subject) on device \(deviceID)"
        )
        try Task.checkCancellation()
        guard let report = try? JSONDecoder().decode(DeviceInfoReport<Result>.self, from: Data(contentsOf: output)),
              report.info.outcome == "success" else {
            throw HostAttachError
                .invalid("devicectl did not return a successful \(subject) report for device \(deviceID).")
        }
        return report.result
    }

    /// Device paths must not be resolved through the host filesystem.
    static func devicePath(_ value: String) -> String? {
        let url: URL
        if value.hasPrefix("/") {
            url = URL(fileURLWithPath: value)
        } else if let parsed = URL(string: value), parsed.isFileURL,
                  (parsed.host?.isEmpty ?? true) || parsed.host == "localhost",
                  parsed.query == nil, parsed.fragment == nil {
            url = parsed
        } else {
            return nil
        }
        let path = url.standardized.path
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n") else { return nil }
        return path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }
}

private struct DeviceInfoReport<Result: Decodable>: Decodable {
    struct Info: Decodable { let outcome: String }
    let info: Info
    let result: Result
}

private struct DeviceApps: Decodable {
    let apps: [DeviceApp]
}

private struct DeviceApp: Decodable {
    let bundleIdentifier: String
    let url: String?
}

private struct DeviceProcesses: Decodable {
    let runningProcesses: [DeviceProcess]
}

private struct DeviceProcess: Decodable {
    let processIdentifier: Int
    let executable: String?
}
