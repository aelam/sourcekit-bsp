import BuildServerProtocol
import Foundation
import Logger
import PathKit
import XcodeProj
import XcodeProjectManagement

public extension XcodeProjectManager {
    func startBuild(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]? = nil
    ) async throws -> StatusCode {
        logger.info("Starting build for targets: \(targetIdentifiers) with arguments: \(arguments ?? [])")
        var results: [XcodeBuildExitCode] = []

        for identifier in targetIdentifiers {
            let xcodeTargetIdentifier = XcodeTargetIdentifier(identifier)

            let xcodeBuildResult = try await compileTarget(
                targetIdentifier: xcodeTargetIdentifier,
                configuration: nil, // arguments has "-configuration" flag
                arguments: arguments
            )
            results.append(xcodeBuildResult)
        }

        for result in results where result != 0 {
            logger.error("Build failed with exit code \(result)")
            return .error
        }

        return .ok
    }
}
