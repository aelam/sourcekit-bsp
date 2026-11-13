import Foundation
import SourceKitBSPProtocol
import XcodeProj

struct XcodeContextScheme {
    let scheme: XcodeScheme
    let targets: [XcodeTarget]
    let configuration: String
    let buildsTests: Bool
}

extension XcodeProjectManager {
    func contextDefaultDebugMode(scheme: XcodeScheme, requested: [XcodeTarget]?) throws -> String {
        if let requested { return requested.allSatisfy(\.xcodeProductType.isTestBundle) ? "test" : "run" }
        let parsed = try XCScheme(pathString: scheme.path.path)
        if parsed.launchAction?.runnable != nil || parsed.launchAction?.launchStyle == .wait ||
            parsed.launchAction?.askForAppToLaunch == true {
            return "run"
        }
        return "test"
    }

    func contextScheme(
        _ scheme: XcodeScheme,
        operation: BuildContextOperation,
        debugMode: String?,
        requested: [XcodeTarget]?,
        validateExecution: Bool = true
    ) throws -> XcodeContextScheme {
        guard let base = projectSnapshot else { throw BuildContextError.invalid("Project not initialized") }
        guard base.schemes.count(where: { $0.name == scheme.name }) == 1 else {
            throw BuildContextError.invalid("Scheme '\(scheme.name)' has multiple definitions in this container")
        }
        let parsed = try XCScheme(pathString: scheme.path.path)
        let buildsTests = operation == .test || (operation == .debug && debugMode == "test") ||
            (operation == .compile && requested?.allSatisfy(\.xcodeProductType.isTestBundle) == true)
        let candidates: [XcodeTarget]
        let configuration: String
        if buildsTests {
            (candidates, configuration) = try contextTestAction(
                parsed,
                scheme: scheme,
                operation: operation,
                requested: requested,
                validateExecution: validateExecution
            )
        } else if operation == .run || operation == .debug {
            (candidates, configuration) = try contextLaunchAction(
                parsed, scheme: scheme, validateExecution: validateExecution
            )
        } else {
            candidates = try contextBuildTargets(parsed, scheme: scheme)
            configuration = parsed.launchAction?.buildConfiguration ?? base.configuration
        }
        guard !candidates.isEmpty else {
            throw BuildContextError.invalid("Scheme '\(scheme.name)' has no targets for this operation")
        }
        let targets: [XcodeTarget]
        if let requested {
            let identifiers = Set(requested.map(\.targetIdentifier))
            guard requested
                .allSatisfy({ target in candidates.contains { $0.targetIdentifier == target.targetIdentifier } }) else {
                throw BuildContextError.invalid("The selected scheme action does not include all requested targets")
            }
            if validateExecution, operation == .compile, !buildsTests,
               !candidates.allSatisfy({ identifiers.contains($0.targetIdentifier) }) {
                throw BuildContextError
                    .invalid("The scheme would build additional root targets; select the complete scheme scope")
            }
            targets = candidates.filter { identifiers.contains($0.targetIdentifier) }
        } else {
            targets = candidates
        }
        if validateExecution, operation == .debug, buildsTests {
            guard targets.count == 1, targets[0].xcodeProductType == .unitTestBundle else {
                throw BuildContextError.invalid("Debug Tests requires one app-hosted unit test target")
            }
        }
        return XcodeContextScheme(
            scheme: scheme,
            targets: targets,
            configuration: configuration,
            buildsTests: buildsTests
        )
    }

    private func contextTestAction(
        _ parsed: XCScheme,
        scheme: XcodeScheme,
        operation: BuildContextOperation,
        requested: [XcodeTarget]?,
        validateExecution: Bool
    ) throws -> ([XcodeTarget], String) {
        guard let action = parsed.testAction else {
            throw BuildContextError.invalid("Scheme '\(scheme.name)' has no test action")
        }
        guard !validateExecution || operation != .debug || action.testPlans?.isEmpty != false else {
            throw BuildContextError.invalid("Test debugging does not support test plans yet")
        }
        let candidates = try uniqueContextTargets(contextTestTargets(action, scheme: scheme))
        guard candidates.allSatisfy(\.xcodeProductType.isTestBundle) else {
            throw BuildContextError.invalid("The test action must contain test bundles")
        }
        guard validateExecution else { return (candidates, action.buildConfiguration) }
        guard Set(candidates.map(\.name)).count == candidates.count else {
            throw BuildContextError.invalid("The test action must contain test bundles with distinct target names")
        }
        if operation == .debug {
            guard action.preActions.isEmpty, action.postActions.isEmpty,
                  action.commandlineArguments?.arguments.contains(where: \.enabled) != true,
                  action.environmentVariables?.contains(where: \.enabled) != true,
                  !action.enableAddressSanitizer, !action.enableThreadSanitizer, !action.enableUBSanitizer,
                  action.language == nil, action.region == nil,
                  action.additionalOptions.isEmpty,
                  action.testables.allSatisfy({ $0.selectedTests.isEmpty && $0.skippedTests.isEmpty }) else {
                throw BuildContextError.invalid("Test debugging cannot apply this scheme's test action settings")
            }
            if action.shouldUseLaunchSchemeArgsEnv, let launch = parsed.launchAction {
                try validateContextLaunchSettings(launch, allowRuntimeSettings: false)
            }
        } else if operation == .test, (requested?.count ?? candidates.count) > 1,
                  !action.preActions.isEmpty || !action.postActions.isEmpty ||
                  parsed.buildAction?.preActions.isEmpty == false || parsed.buildAction?.postActions
                  .isEmpty == false {
            throw BuildContextError.invalid("Tests with action scripts require a single test target")
        }
        return (candidates, action.buildConfiguration)
    }

    private func contextLaunchAction(
        _ parsed: XCScheme,
        scheme: XcodeScheme,
        validateExecution: Bool
    ) throws -> ([XcodeTarget], String) {
        guard let action = parsed.launchAction,
              action.runnable is XCScheme.BuildableProductRunnable,
              let reference = action.runnable?.buildableReference else {
            throw BuildContextError.invalid("This scheme does not launch a buildable application")
        }
        if validateExecution {
            guard action.runnable?.runnableDebuggingMode == "0",
                  action.launchStyle == .auto, action.askForAppToLaunch != true else {
                throw BuildContextError.invalid("This scheme requires an unsupported launch mode")
            }
            try validateContextLaunchSettings(action)
        }
        let target = try contextTarget(for: reference, scheme: scheme)
        guard target.xcodeProductType.isApplication else {
            throw BuildContextError.invalid("Running and debugging require an application target")
        }
        guard try parsed.buildAction?.buildActionEntries.contains(where: {
            guard $0.buildFor.contains(.running) else { return false }
            return try contextTarget(for: $0.buildableReference, scheme: scheme).targetIdentifier == target
                .targetIdentifier
        }) == true else {
            throw BuildContextError.invalid("The scheme does not build its application for running")
        }
        return ([target], action.buildConfiguration)
    }

    private func contextBuildTargets(_ parsed: XCScheme, scheme: XcodeScheme) throws -> [XcodeTarget] {
        let entries = parsed.buildAction?.buildActionEntries.filter { $0.buildFor.contains(.running) } ?? []
        let targets = try uniqueContextTargets(entries.map { try contextTarget(
            for: $0.buildableReference,
            scheme: scheme
        ) })
        return targets.filter { candidate in
            !targets.contains { other in
                other.targetIdentifier != candidate.targetIdentifier &&
                    contextDependencies(of: other).contains(candidate.targetIdentifier)
            }
        }
    }

    func contextTarget(for reference: XCScheme.BuildableReference, scheme: XcodeScheme) throws -> XcodeTarget {
        let path: URL
        if reference.referencedContainer.hasPrefix("container:") {
            path = try contextSchemeContainer(scheme).deletingLastPathComponent()
                .appendingPathComponent(String(reference.referencedContainer.dropFirst("container:".count)))
        } else if reference.referencedContainer.hasPrefix("absolute:") {
            path = URL(fileURLWithPath: String(reference.referencedContainer.dropFirst("absolute:".count)))
        } else {
            throw BuildContextError.invalid("Unsupported scheme container reference: \(reference.referencedContainer)")
        }
        guard let identifier = reference.blueprintIdentifier,
              let target = projectStore.contextTarget(projectURL: path, blueprintIdentifier: identifier) else {
            throw BuildContextError.invalid("Scheme target '\(reference.blueprintName)' is not in the loaded project")
        }
        return target
    }

    func contextSchemeContainer(_ scheme: XcodeScheme) throws -> URL {
        var path = scheme.path.deletingLastPathComponent()
        while path.path != "/" {
            if ["xcodeproj", "xcworkspace"].contains(path.pathExtension) { return path }
            path.deleteLastPathComponent()
        }
        throw BuildContextError.invalid("Cannot locate the scheme container")
    }

    private func uniqueContextTargets(_ targets: [XcodeTarget]) -> [XcodeTarget] {
        var seen = Set<XcodeTargetIdentifier>()
        return targets.filter { seen.insert($0.targetIdentifier).inserted }
    }

    private func contextDependencies(of target: XcodeTarget) -> Set<XcodeTargetIdentifier> {
        guard let project = loadXcodeProjCache(projectURL: target.projectURL),
              let native = project.pbxproj.nativeTargets.first(where: { $0.name == target.name }) else { return [] }
        var visited = Set<String>()
        var result = Set<XcodeTargetIdentifier>()
        func visit(_ target: PBXTarget) {
            guard visited.insert(target.uuid).inserted else { return }
            for dependency in target.dependencies.compactMap(\.target) {
                result.insert(XcodeTargetIdentifier(
                    projectFilePath: targetProjectPath(dependency),
                    targetName: dependency.name
                ))
                visit(dependency)
            }
        }
        func targetProjectPath(_ dependency: PBXTarget) -> String {
            projectSnapshot?.xcodeTargets.first { item in
                let containsDependency = loadXcodeProjCache(projectURL: item.projectURL)?.pbxproj.nativeTargets
                    .contains {
                        $0 === dependency
                    }
                return containsDependency == true
            }?.projectURL.path ?? target.projectURL.path
        }
        visit(native)
        return result
    }

    private func validateContextLaunchSettings(
        _ action: XCScheme.LaunchAction, allowRuntimeSettings: Bool = true
    ) throws {
        guard action.preActions.isEmpty, action.postActions.isEmpty,
              !action.useCustomWorkingDirectory, action.customLaunchCommand == nil,
              action.storeKitConfigurationFileReference == nil,
              action.language == nil, action.region == nil, action.additionalOptions.isEmpty,
              !action.enableAddressSanitizer, !action.enableThreadSanitizer, !action.enableUBSanitizer else {
            throw BuildContextError.invalid("This scheme has launch settings that the run/debug backend cannot apply")
        }
        if !allowRuntimeSettings {
            guard action.commandlineArguments?.arguments.contains(where: \.enabled) != true,
                  action.environmentVariables?.contains(where: \.enabled) != true else {
                throw BuildContextError.invalid("Test debugging cannot apply this scheme's launch settings")
            }
        }
    }
}
