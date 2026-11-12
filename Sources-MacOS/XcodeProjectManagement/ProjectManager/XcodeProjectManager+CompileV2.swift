import Foundation
import XcodeProj

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

        let projectBuildConfiguration = try buildConfiguration(for: xcodeTarget, arguments: arguments)
        let arguments = try argumentsWithoutScheme(buildArguments(
            for: xcodeTarget,
            configuration: configuration,
            arguments: arguments
        ))

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
        guard let installation = projectSnapshot?.xcodeInstallation
        else { throw XcodeProjectError.buildSettingsNotFound }
        let project = try buildConfiguration(for: target, arguments: arguments)
        let flags = try argumentsWithoutScheme(settingsArguments)
        let key = ResolvedBuildSettingsCache.Key(
            target: target.targetIdentifier, arguments: settingsArguments,
            developerDirectory: installation.developerDir, buildVersion: installation.buildVersion
        )
        // External xcconfig includes may be outside the client's watched workspace.
        let reuse = !settingsArguments.contains { $0 == "-xcconfig" || $0.hasPrefix("XCODE_XCCONFIG_FILE=") }
            && ProcessInfo.processInfo.environment["XCODE_XCCONFIG_FILE"] == nil
        return try await resolvedSettingsCache.settings(for: key, reuse: reuse) { [settingsLoader, rootURL] in
            let settings = try await settingsLoader.loadBuildSettings(
                rootURL: rootURL, project: project, sdk: nil, configuration: nil, customFlags: flags
            )
            guard let buildSettings = settings.first(where: { $0.target == target.name })?.buildSettings else {
                throw XcodeProjectError.buildSettingsNotFound
            }
            return buildSettings
        }
    }

    internal func buildConfiguration(
        for target: XcodeTarget,
        arguments: [String]? = nil
    ) throws -> XcodeProjectConfiguration {
        guard let base = projectSnapshot else {
            throw XcodeProjectError.invalidConfig("Project not initialized")
        }
        let scheme: XcodeScheme
        if let index = arguments?.firstIndex(of: "-scheme"), let arguments {
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-"),
                  arguments.count(where: { $0 == "-scheme" }) == 1 else {
                throw XcodeProjectError.invalidConfig("Specify exactly one scheme name")
            }
            let matches = base.schemes.filter { $0.name == arguments[index + 1] }
            guard matches.count == 1, let selected = matches.first else {
                throw XcodeProjectError.invalidConfig("Unknown or ambiguous scheme: \(arguments[index + 1])")
            }
            let parsed = try XCScheme(pathString: selected.path.path)
            let references = (parsed.buildAction?.buildActionEntries.map(\.buildableReference) ?? []) +
                (parsed.testAction?.testables.filter { !$0.skipped }.map(\.buildableReference) ?? []) +
                [parsed.launchAction?.runnable?.buildableReference].compactMap(\.self)
            let directTarget = references.contains {
                (try? contextTarget(for: $0, scheme: selected).targetIdentifier) == target.targetIdentifier
            }
            let planTarget = try !directTarget && parsed.testAction.map { action in
                try contextTestTargets(action, scheme: selected).contains {
                    $0.targetIdentifier == target.targetIdentifier
                }
            } == true
            guard directTarget || planTarget else {
                throw XcodeProjectError.invalidConfig("The selected scheme does not include \(target.name)")
            }
            scheme = selected
        } else {
            scheme = try findExistingScheme(for: target, in: base.schemes)
        }
        return try projectConfiguration(scheme: scheme)
    }

    internal func projectConfiguration(scheme: XcodeScheme) throws -> XcodeProjectConfiguration {
        guard let base = projectSnapshot else { throw XcodeProjectError.invalidConfig("Project not initialized") }
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

    internal func argumentsWithoutScheme(_ arguments: [String]) throws -> [String] {
        guard let index = arguments.firstIndex(of: "-scheme") else { return arguments }
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-"),
              arguments.count(where: { $0 == "-scheme" }) == 1 else {
            throw XcodeProjectError.invalidConfig("Specify exactly one scheme name")
        }
        var result = arguments
        result.removeSubrange(index ... index + 1)
        return result
    }

    internal func buildArguments(
        for target: XcodeTarget,
        configuration: String?,
        arguments: [String]?
    ) -> [String] {
        var result = arguments ?? []
        // LLDB-DAP needs macro expansion sources on disk. Apply DWARF 4 during
        // test builds, because debugging reuses the existing product.
        if target.xcodeProductType.isTestBundle,
           !result.contains(where: { $0.hasPrefix("SWIFT_DEBUG_INFORMATION_VERSION=") }) {
            result.append("SWIFT_DEBUG_INFORMATION_VERSION=dwarf4")
        }
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
