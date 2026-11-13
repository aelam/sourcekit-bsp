import Foundation
import Logger
import PathKit
import SourceKitBSPProtocol
import XcodeProj
import XcodeProjectManagement

public extension XcodeBSPProjectManager {
    func run(
        targetIdentifier: BSPBuildTargetIdentifier,
        arguments: [String]?, // e.g. ["-configuration", "Debug"]
        environmentVariables: [String: String]?,
        workingDirectory: URI?
    ) async throws -> StatusCode {
        try await run(
            targetIdentifier: targetIdentifier,
            arguments: arguments,
            environmentVariables: environmentVariables,
            workingDirectory: workingDirectory,
            progressHandler: nil
        )
    }

    func run(
        targetIdentifier: BSPBuildTargetIdentifier,
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        progressHandler: (@Sendable (String) async -> Void)?
    ) async throws -> StatusCode {
        try Task.checkCancellation()
        let xcodeTargetIdentifier = XcodeTargetIdentifier(targetIdentifier)

        let result = await backend.run(
            xcodeTargetIdentifier: xcodeTargetIdentifier,
            arguments: arguments,
            environmentVariables: environmentVariables,
            workingDirectory: workingDirectory?.fileURL,
            progressHandler: progressHandler
        )

        try Task.checkCancellation()
        switch result.statusCode {
        case .success:
            return .ok
        case .error:
            throw XcodeRunError.failedToLaunchApp(result.message ?? "Failed to run target")
        }
    }
}
