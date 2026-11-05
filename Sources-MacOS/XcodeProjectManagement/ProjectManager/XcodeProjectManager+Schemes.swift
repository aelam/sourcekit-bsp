import Foundation
import Logger
import PathKit
import XcodeProj

extension XcodeProjectManager {
    func findOrCreateScheme(
        for target: XcodeTarget,
        in schemes: [XcodeScheme],
        buildConfiguration: String = "Debug"
    ) throws -> XcodeScheme {
        if target.xcodeProductType.isTestBundle {
            if let scheme = schemes.first(where: { containsTestTarget(scheme: $0, target: target) }) {
                return scheme
            }
            return try createScheme(for: target, buildConfiguration: buildConfiguration)
        }

        let candidates = schemes.filter { scheme in
            scheme.primaryBuildTargetProjectURL?.standardizedFileURL.path == target.projectURL.standardizedFileURL
                .path &&
                (scheme.primaryProductName == target.productNameWithExtension ||
                    scheme.primaryTarget == target.name
                ) && buildsForRunning(scheme: scheme, target: target)
        }

        if let preferred = candidates.first(where: { $0.name == preferredSchemeName }) {
            return preferred
        }
        if let scheme = candidates.min(by: { lhs, rhs in
            if (lhs.name == target.name) != (rhs.name == target.name) { return lhs.name == target.name }
            if (lhs.buildConfiguration == buildConfiguration) != (rhs.buildConfiguration == buildConfiguration) {
                return lhs.buildConfiguration == buildConfiguration
            }
            return lhs.name < rhs.name
        }) {
            return scheme
        }

        return try createScheme(
            for: target,
            buildConfiguration: buildConfiguration
        )
    }

    private func buildsForRunning(scheme: XcodeScheme, target: XcodeTarget) -> Bool {
        guard let nativeTarget = loadXcodeProjCache(projectURL: target.projectURL)?
            .pbxproj.nativeTargets.first(where: { $0.name == target.name }),
            let parsed = try? XCScheme(pathString: scheme.path.path) else { return false }
        let components = scheme.path.pathComponents
        guard let containerIndex = components.lastIndex(where: {
            $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace")
        }) else { return false }
        let container = URL(fileURLWithPath: NSString.path(withComponents: Array(components[..<containerIndex])))
        return parsed.buildAction?.buildActionEntries.contains { entry in
            let reference = entry.buildableReference
            let path = reference.referencedContainer.replacingOccurrences(of: "container:", with: "")
            return entry.buildFor.contains(.running) && reference.blueprintIdentifier == nativeTarget.uuid &&
                container.appendingPathComponent(path).standardizedFileURL.path == target.projectURL.standardizedFileURL
                .path
        } == true
    }

    private func containsTestTarget(scheme: XcodeScheme, target: XcodeTarget) -> Bool {
        guard let nativeTarget = loadXcodeProjCache(projectURL: target.projectURL)?
            .pbxproj.nativeTargets.first(where: { $0.name == target.name }),
            let parsed = try? XCScheme(pathString: scheme.path.path) else { return false }
        let components = scheme.path.pathComponents
        guard let containerIndex = components.lastIndex(where: {
            $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace")
        }) else { return false }
        let container = URL(fileURLWithPath: NSString.path(withComponents: Array(components[..<containerIndex])))
        return parsed.testAction?.testables.contains { testable in
            let reference = testable.buildableReference
            let projectPath = reference.referencedContainer.replacingOccurrences(of: "container:", with: "")
            return reference.blueprintIdentifier == nativeTarget.uuid && !testable.skipped &&
                container.appendingPathComponent(projectPath).standardizedFileURL == target.projectURL
                .standardizedFileURL
        } == true
    }

    private func isSchemeContainedTarget(scheme: XcodeScheme, target: XcodeTarget) -> Bool {
        guard
            let projectURL = scheme.primaryBuildTargetProjectURL,
            let productName = scheme.primaryProductName ?? scheme.primaryTarget
        else {
            return false
        }
        return target.projectURL == projectURL && target.productNameWithExtension == productName
    }

    private func createScheme(
        for xcodeTarget: XcodeTarget,
        buildConfiguration: String
    ) throws -> XcodeScheme {
        guard let nativeTarget = loadXcodeProjCache(projectURL: xcodeTarget.projectURL)?
            .pbxproj.nativeTargets.first(where: { $0.name == xcodeTarget.name }) else {
            throw XcodeProjectError.invalidConfig("Target not found: \(xcodeTarget.name)")
        }
        let schemeName = "sourcekit-bsp-\(xcodeTarget.name)"
        let xcscheme = XCScheme(name: schemeName, lastUpgradeVersion: nil, version: "1.7")

        // Create BuildAction with the target
        let buildableReference = XCScheme.BuildableReference(
            referencedContainer: "container:\(xcodeTarget.projectURL.lastPathComponent)",
            blueprintIdentifier: nativeTarget.uuid,
            buildableName: xcodeTarget.productNameWithExtension ?? xcodeTarget.name,
            blueprintName: xcodeTarget.name
        )

        if xcodeTarget.xcodeProductType.isTestBundle {
            // For test targets, BuildAction is empty and TestAction contains the testable
            xcscheme.buildAction = XCScheme.BuildAction(
                buildActionEntries: [],
                parallelizeBuild: true,
                buildImplicitDependencies: true
            )

            let testableReference = XCScheme.TestableReference(
                skipped: false,
                parallelization: .none,
                randomExecutionOrdering: false,
                buildableReference: buildableReference
            )

            xcscheme.testAction = XCScheme.TestAction(
                buildConfiguration: buildConfiguration,
                macroExpansion: nil,
                testables: [testableReference]
            )
        } else {
            // For non-test targets, BuildAction contains the entry
            let buildActionEntry = XCScheme.BuildAction.Entry(
                buildableReference: buildableReference,
                buildFor: [.running, .testing, .profiling, .archiving, .analyzing]
            )

            xcscheme.buildAction = XCScheme.BuildAction(
                buildActionEntries: [buildActionEntry],
                parallelizeBuild: true,
                buildImplicitDependencies: true
            )

            xcscheme.testAction = XCScheme.TestAction(
                buildConfiguration: buildConfiguration,
                macroExpansion: nil,
                testables: []
            )
        }

        // Create LaunchAction
        if xcodeTarget.xcodeProductType.isApplication {
            let runnable = XCScheme.BuildableProductRunnable(
                buildableReference: buildableReference,
                runnableDebuggingMode: "0"
            )
            xcscheme.launchAction = XCScheme.LaunchAction(
                runnable: runnable,
                buildConfiguration: buildConfiguration
            )
        } else {
            xcscheme.launchAction = XCScheme.LaunchAction(
                runnable: nil,
                buildConfiguration: buildConfiguration,
                macroExpansion: buildableReference
            )
        }

        // Create ProfileAction
        if xcodeTarget.xcodeProductType.isApplication {
            xcscheme.profileAction = XCScheme.ProfileAction(
                runnable: nil,
                buildConfiguration: "Release"
            )
        } else {
            xcscheme.profileAction = XCScheme.ProfileAction(
                runnable: nil,
                buildConfiguration: "Release",
                macroExpansion: buildableReference
            )
        }

        // Create AnalyzeAction
        xcscheme.analyzeAction = XCScheme.AnalyzeAction(
            buildConfiguration: buildConfiguration
        )

        // Create ArchiveAction
        xcscheme.archiveAction = XCScheme.ArchiveAction(
            buildConfiguration: "Release",
            revealArchiveInOrganizer: true
        )

        // Write scheme to file
        let schemeURL = try writeSchemeToFile(xcscheme: xcscheme, for: xcodeTarget)

        // Create XcodeScheme wrapper
        return XcodeScheme(
            xcscheme: xcscheme,
            isInWorkspace: xcodeTarget.isFromWorkspace,
            isUserScheme: false,
            projectURL: xcodeTarget.projectURL,
            path: schemeURL
        )
    }

    private func writeSchemeToFile(xcscheme: XCScheme, for xcodeTarget: XcodeTarget) throws -> URL {
        let projectURL = xcodeTarget.projectURL
        let schemesDir = projectURL.appendingPathComponent("xcshareddata/xcschemes")

        // Create schemes directory if it doesn't exist
        try FileManager.default.createDirectory(at: schemesDir, withIntermediateDirectories: true)

        let schemeURL = schemesDir.appendingPathComponent("\(xcscheme.name).xcscheme")

        guard let data = try xcscheme.dataRepresentation() else {
            throw XcodeProjectError.invalidConfig("Cannot encode scheme: \(xcscheme.name)")
        }
        // Keep the modification time stable when another request needs the same helper scheme.
        if (try? Data(contentsOf: schemeURL)) != data {
            try data.write(to: schemeURL, options: .atomic)
            logger.debug("Updated generated scheme: \(schemeURL.path)")
        }

        return schemeURL
    }
}
