import Foundation

public enum BuildError: Error, Sendable {
    case buildFailed(exitCode: Int32, output: String)
}

public extension XcodeProjectManager {
    // MARK: - Compile Target

    func compileTarget(
        targetIdentifier: XcodeTargetIdentifier,
        configuration: String?,
        arguments: [String]? = nil,
        outputHandler: ProcessOutputHandler? = nil
    ) async throws -> XcodeBuildExitCode {
        guard let projectSnapshot else {
            return 1
        }

        guard let xcodeTarget = projectSnapshot.xcodeTargets
            .first(where: { $0.targetIdentifier == targetIdentifier }) else {
            return 1
        }

        let projectBuildConfiguration = try buildConfiguration(for: xcodeTarget)
        let arguments = buildArguments(for: xcodeTarget, configuration: configuration, arguments: arguments)

        let buildAction: XcodeBuildCommand.BuildAction = xcodeTarget.xcodeProductType.isTestBundle ?
            .buildForTesting : .build
        let options = XcodeBuildOptions(
            command: .build(
                action: buildAction,
                sdk: nil,
                destination: nil,
                configuration: nil,
                derivedDataPath: nil,
                resultBundlePath: nil
            ),
            flags: XcodeBuildFlags(),
            customFlags: arguments
        )

        let commandBuilder = XcodeBuildCommandBuilder()
        let command = commandBuilder.buildCommand(
            project: projectBuildConfiguration,
            options: options
        )

        // Build scripts can change source lists even when the build fails.
        defer { invalidateSourceFileCache() }
        return try await buildExecutor.execute(
            command: command,
            workingDirectory: rootURL,
            outputHandler: outputHandler
        )
    }

    internal func resolvedBuildSettings(
        for target: XcodeTarget,
        arguments: [String]?
    ) async throws -> [String: String] {
        var settingsArguments = buildArguments(for: target, configuration: nil, arguments: arguments)
        if target.xcodeProductType.isTestBundle {
            settingsArguments.append("build-for-testing")
        }
        let settings = try await settingsLoader.loadBuildSettings(
            rootURL: rootURL,
            project: buildConfiguration(for: target),
            sdk: nil,
            configuration: nil,
            customFlags: settingsArguments
        )
        guard let buildSettings = settings.first(where: { $0.target == target.name })?.buildSettings else {
            throw XcodeProjectError.buildSettingsNotFound
        }
        return buildSettings
    }

    internal func buildConfiguration(for target: XcodeTarget) throws -> XcodeProjectConfiguration {
        guard let base = projectSnapshot else {
            throw XcodeProjectError.invalidConfig("Project not initialized")
        }
        let scheme = try findOrCreateScheme(for: target, in: base.schemes)
        return switch base.projectLocation {
        case let .explicitWorkspace(url):
            .workspace(
                workspaceURL: url,
                scheme: scheme.name
            )
        case let .implicitWorkspace(projectURL: url, workspaceURL: _), let .standaloneProject(url: url):
            .project(
                projectURL: url,
                buildMode: .scheme(scheme.name)
            )
        }
    }

    internal func buildArguments(
        for target: XcodeTarget,
        configuration: String?,
        arguments: [String]?
    ) -> [String] {
        var result = arguments ?? []
        if !result.contains("-configuration") {
            result += ["-configuration", configuration ?? projectSnapshot?.configuration ?? "Debug"]
        }
        if !result.contains("-destination"), !result.contains("-sdk") {
            let platform = target.xcodeTargetPlatform.simulatorVariant
            let destination = switch platform {
            case .macOS: "platform=macOS"
            case .iOSSimulator: "generic/platform=iOS Simulator"
            case .watchSimulator: "generic/platform=watchOS Simulator"
            case .tvSimulator: "generic/platform=tvOS Simulator"
            case .visionSimulator: "generic/platform=visionOS Simulator"
            default: "generic/platform=iOS Simulator"
            }
            result += ["-destination", destination]
        }
        if !result.contains("-derivedDataPath"), let base = projectSnapshot {
            result += ["-derivedDataPath", base.xcodeGlobalSettings.derivedDataPath.path]
        }
        return result
    }
}
