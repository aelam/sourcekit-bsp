import Foundation
import Support

/// Resolves the installed app on the selected simulator without booting or launching it.
struct SimulatorAttachDiscovery: Sendable {
    typealias Execute = @Sendable ([String], [String: String]) async throws -> ProcessExecutionResult

    let developerDirectory: URL
    var execute: Execute = { arguments, environment in
        try await ProcessExecutor().execute(
            executable: "/usr/bin/xcrun", arguments: arguments, environment: environment, timeout: 30
        )
    }

    func executable(deviceID: String, bundleID: String) async throws -> String {
        let result = try await execute(
            ["simctl", "get_app_container", deviceID, bundleID, "app"],
            ["DEVELOPER_DIR": developerDirectory.path]
        )
        guard result.isSuccess else {
            throw HostAttachError.invalid(
                "Cannot find the installed app on simulator \(deviceID). " +
                    "The simulator must already be booted and the app installed. " + (result.error ?? result.output)
            )
        }
        return try Self.executable(
            appPath: result.output.trimmingCharacters(in: .whitespacesAndNewlines),
            bundleID: bundleID
        )
    }

    static func executable(appPath: String, bundleID: String) throws -> String {
        guard appPath.hasPrefix("/"), !appPath.contains("\n") else {
            throw HostAttachError.invalid("The simulator returned an invalid app container path.")
        }
        let app = URL(fileURLWithPath: appPath)
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil
        ) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == bundleID,
              let executable = info?["CFBundleExecutable"] as? String, !executable.isEmpty,
              executable != ".", executable != "..", !executable.contains("/") else {
            throw HostAttachError.invalid("The installed app identity does not match the selected target.")
        }
        return app.appendingPathComponent(executable).resolvingSymlinksInPath().path
    }
}
