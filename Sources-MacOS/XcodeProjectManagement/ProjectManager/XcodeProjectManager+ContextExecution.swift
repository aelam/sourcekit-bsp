import BuildServerProtocol
import Foundation

public extension XcodeProjectManager {
    func validateContext(_ context: BuildContext) throws {
        let resolved = try resolvedContext(BuildContextParams(
            scope: BuildContextScope(targets: context.targets),
            operation: context.operation,
            selection: context.selection
        ))
        guard resolved == context else { throw BuildContextError.invalid("The context changed; resolve it again") }
    }

    func contextArguments(_ context: BuildContext, arguments: [String]?) throws -> [String] {
        try validateContext(context)
        guard let base = projectSnapshot,
              let scheme = base.schemes.first(where: {
                  $0.path.resolvingSymlinksInPath().standardizedFileURL.absoluteString == context
                      .selection["xcode.scheme"]
              }),
              let configuration = context.selection["xcode.configuration"],
              let destination = context.selection["xcode.destination"] else {
            throw BuildContextError.invalid("The context is incomplete")
        }
        let extra = arguments ?? []
        if context.operation != .test,
           extra.contains(where: { $0.hasPrefix("-only-testing") || $0.hasPrefix("-skip-testing") }) {
            throw BuildContextError.invalid("Test filters require a test context")
        }
        // Build settings can change the product path or platform after context resolution.
        let forbidden = [
            "-scheme", "-configuration", "-destination", "-sdk", "-arch", "-project", "-workspace", "-target",
            "-derivedDataPath", "-xcconfig", "-testPlan", "-only-test-configuration", "-skip-test-configuration",
            "-alltargets", "-list", "-showBuildSettings", "-showdestinations", "-showTestPlans",
            "-showBuildSettingsForIndex",
            "-exportArchive", "-exportNotarizedApp", "-resolvePackageDependencies", "-downloadPlatform",
            "-downloadAllPlatforms"
        ]
        for argument in extra {
            if argument.contains("=") || forbidden.contains(where: {
                argument == $0 || argument.hasPrefix($0 + "=") || argument.hasPrefix($0 + ":")
            }) || ["build", "build-for-testing", "test", "test-without-building", "clean", "archive", "analyze"]
                .contains(argument) {
                throw BuildContextError.invalid("Argument conflicts with the resolved context: \(argument)")
            }
        }
        return [
            "-scheme", scheme.name, "-configuration", configuration,
            "-destination", destination.contains("platform=") ? destination : "id=\(destination)",
            "-derivedDataPath", base.xcodeGlobalSettings.derivedDataPath.path
        ] + extra
    }

    func compileContext(
        _ context: BuildContext, arguments: [String]?, outputHandler: ProcessOutputHandler? = nil
    ) async throws -> XcodeBuildExitCode {
        let command = try contextBuildCommand(context, arguments: arguments)
        defer { invalidateSourceFileCache() }
        return try await buildExecutor.execute(
            command: command,
            workingDirectory: rootURL,
            outputHandler: outputHandler
        )
    }
}

extension XcodeProjectManager {
    func contextBuildCommand(_ context: BuildContext, arguments: [String]?) throws -> [String] {
        let flags = try contextArguments(context, arguments: arguments)
        let targets = try contextRequestedTargets(BuildContextScope(targets: context.targets)) ?? []
        guard let scheme = projectSnapshot?.schemes.first(where: { $0.name == flags[1] }) else {
            throw BuildContextError.invalid("The selected scheme no longer exists")
        }
        let plan = try contextScheme(
            scheme, operation: context.operation, debugMode: context.selection["xcode.debugMode"], requested: targets
        )
        var buildFlags = try argumentsWithoutScheme(flags)
        if plan.buildsTests {
            buildFlags.append("SWIFT_DEBUG_INFORMATION_VERSION=dwarf4")
            for target in targets {
                buildFlags.append("-only-testing:\(target.name)")
            }
        }
        return try XcodeBuildCommandBuilder().buildCommand(
            project: projectConfiguration(scheme: scheme),
            options: XcodeBuildOptions(
                command: .build(
                    action: plan.buildsTests ? .buildForTesting : .build,
                    sdk: nil,
                    destination: nil,
                    configuration: nil,
                    derivedDataPath: nil,
                    resultBundlePath: nil
                ),
                flags: XcodeBuildFlags(),
                customFlags: buildFlags
            )
        )
    }
}
