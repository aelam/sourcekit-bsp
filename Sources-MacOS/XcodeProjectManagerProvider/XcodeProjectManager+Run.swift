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
    ) async -> StatusCode {
        let xcodeTargetIdentifier = XcodeTargetIdentifier(targetIdentifier)

        let result = await run(
            xcodeTargetIdentifier: xcodeTargetIdentifier,
            arguments: arguments,
            environmentVariables: environmentVariables,
            workingDirectory: workingDirectory?.fileURL
        )

        return switch result.statusCode {
        case .success:
            .ok
        case .error:
            .error
        }
    }
}
