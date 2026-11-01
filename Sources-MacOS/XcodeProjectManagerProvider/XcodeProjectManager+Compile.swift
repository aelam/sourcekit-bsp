import BuildServerProtocol
import Foundation
import Logger
import PathKit
import XcodeProj
import XcodeProjectManagement

public extension XcodeProjectManager {
    func startBuild(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]? = nil,
        logHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> StatusCode {
        logger.info("Starting build for targets: \(targetIdentifiers) with arguments: \(arguments ?? [])")
        var results: [XcodeBuildExitCode] = []

        // Forward each build line to the BSP layer (which streams it to the
        // client) when a log handler was provided.
        let outputHandler: ProcessOutputHandler? = logHandler.map { handler in
            ClosureOutputHandler(onLine: handler)
        }

        for identifier in targetIdentifiers {
            let xcodeTargetIdentifier = XcodeTargetIdentifier(identifier)

            let xcodeBuildResult = try await compileTarget(
                targetIdentifier: xcodeTargetIdentifier,
                configuration: nil, // arguments has "-configuration" flag
                arguments: arguments,
                outputHandler: outputHandler
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
