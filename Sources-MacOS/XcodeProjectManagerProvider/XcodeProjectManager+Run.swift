import BuildServerProtocol
import Foundation
import Logger
import PathKit
import XcodeProj
import XcodeProjectManagement

public extension XcodeProjectManager {
    func run(
        targetIdentifier: BSPBuildTargetIdentifier,
        arguments: [String]?, // e.g. ["-configuration", "Debug"]
        environmentVariables: [String: String]?,
        workingDirectory: URI?
    ) async throws -> StatusCode {
        let xcodeTargetIdentifier = XcodeTargetIdentifier(targetIdentifier)

        let result = await run(
            xcodeTargetIdentifier: xcodeTargetIdentifier,
            arguments: arguments,
            environmentVariables: environmentVariables,
            workingDirectory: workingDirectory?.fileURL
        )

        switch result.statusCode {
        case .success:
            return .ok
        case .error:
            throw XcodeProjectError.invalidConfig(result.message ?? "Failed to run target")
        }
    }
}
