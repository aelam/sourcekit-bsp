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
            let scheme = schemes.first { scheme in
                scheme.primaryBuildTargetProjectURL == target.projectURL &&
                    (scheme.primaryProductName == target.productNameWithExtension ||
                        scheme.primaryTarget == target.productName
                    )
            }

            if let scheme {
                return scheme
            }
        }

        let scheme = schemes.first { scheme in
            scheme.primaryBuildTargetProjectURL == target.projectURL &&
                (scheme.primaryProductName == target.productNameWithExtension ||
                    scheme.primaryTarget == target.productName
                )
        }

        if let scheme {
            return scheme
        }

        return try createScheme(
            for: target,
            buildConfiguration: buildConfiguration
        )
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

        try xcscheme.write(path: .init(schemeURL.path), override: true)
        logger.info("Created scheme file at: \(schemeURL.path)")

        return schemeURL
    }
}
