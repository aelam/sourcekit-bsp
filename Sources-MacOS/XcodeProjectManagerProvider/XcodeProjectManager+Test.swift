import BuildServerProtocol
import Foundation
import Logger
import PathKit
import XcodeProj
import XcodeProjectManagement

public extension XcodeProjectManager {
    func test(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?, // e.g. ["-configuration", "Debug"]
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        logHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> StatusCode {
        let xcodeTargetIdentifiers = targetIdentifiers.map { XcodeTargetIdentifier(rawValue: $0.uri.stringValue) }

        let result = try await test(
            xcodeTargetIdentifiers: xcodeTargetIdentifiers,
            arguments: arguments,
            environmentVariables: environmentVariables,
            workingDirectory: workingDirectory?.fileURL,
            outputHandler: logHandler.map { ClosureOutputHandler(onLine: $0) }
        )

        return switch result.statusCode {
        case .success:
            .ok
        case .error:
            .error
        }
    }
}
