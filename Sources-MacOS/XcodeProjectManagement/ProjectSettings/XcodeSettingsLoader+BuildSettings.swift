import Foundation
import Logger

public extension XcodeSettingsLoader {
    // MARK: - BuildSettings

    func loadBuildSettings(
        rootURL: URL,
        project: XcodeProjectConfiguration,
        sdk: XcodeSDK? = .iOSSimulator,
        destination: XcodeBuildDestination? = nil,
        configuration: String? = "Debug",
        customFlags: [String] = [],
    ) async throws -> [XcodeBuildSettings] {
        let command = commandBuilder.buildCommand(
            project: project,
            options: XcodeBuildOptions.buildSettingsJSON(
                sdk: sdk,
                destination: destination,
                configuration: configuration,
                customFlags: customFlags
            )
        )
        let output = try await runXcodeBuild(arguments: command, workingDirectory: rootURL)
        guard let jsonString = output, !jsonString.isEmpty else {
            throw XcodeProjectError.invalidConfig("Failed to load build settings")
        }

        let data = Data(jsonString.utf8)
        do {
            return try jsonDecoder.decode([XcodeBuildSettings].self, from: data)
        } catch {
            logger.debug("Invalid build settings JSON: \(data.count) bytes")
            throw XcodeProjectError.invalidConfig("Failed to decode build settings: \(error)")
        }
    }
}

public extension XcodeSettingsLoader {
    // MARK: - BuildSettingsForIndex

    /// Load buildSettingsMap for targets
    func loadBuildSettingsMap(
        rootURL: URL,
        targets: [XcodeTarget],
        configuration: String? = "Debug",
        xcodeGlobalSettings: XcodeGlobalSettings,
        customFlags: [String] = []
    ) async throws -> XcodeBuildSettingsMap {
        try await withThrowingTaskGroup(of: XcodeBuildSettingsMap.self) { taskGroup in
            // group targets under same project with same platform
            let groupedTargets = Dictionary(grouping: targets) { GroupedTargetsKey(
                projectURL: $0.projectURL,
                platform: $0.xcodeTargetPlatform
            ) }

            for (groupedTargetsKey, targets) in groupedTargets {
                let projectURL = groupedTargetsKey.projectURL
                let sdk = groupedTargetsKey.platform.simulatorVariant
                taskGroup.addTask {
                    let buildSettings = try await self.loadBuildSettings(
                        rootURL: rootURL,
                        project: .project(
                            projectURL: projectURL,
                            buildMode: .targets(targets.map(\.name))
                        ),
                        sdk: sdk,
                        destination: nil,
                        configuration: configuration,
                        customFlags: customFlags
                    )
                    var targetBuildSettings: XcodeBuildSettingsMap = [:]
                    for settings in buildSettings {
                        let targetIdentifier = "xcode://" + projectURL.appendingPathComponent(settings.target).path
                        targetBuildSettings[targetIdentifier] = settings
                    }
                    return targetBuildSettings
                }
            }

            var buildSettingsMap = XcodeBuildSettingsMap()
            for try await targetSettings in taskGroup {
                buildSettingsMap.merge(targetSettings) { _, new in new }
            }
            return buildSettingsMap
        }
    }
}
