import Foundation
import Logger
import PathKit
import SourceKitBSPProtocol
import XcodeProj
import XcodeProjectManagement

public extension XcodeBSPProjectManager {
    func test(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?, // e.g. ["-configuration", "Debug"]
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        logHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> StatusCode {
        try await test(
            targetIdentifiers: targetIdentifiers,
            arguments: arguments,
            environmentVariables: environmentVariables,
            workingDirectory: workingDirectory,
            logHandler: logHandler,
            testEventHandler: nil
        )
    }

    // swiftlint:disable:next function_parameter_count
    func test(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?, // e.g. ["-configuration", "Debug"]
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        logHandler: (@Sendable (String) -> Void)?,
        testEventHandler: (@Sendable (TestExecutionEvent) async -> Void)?
    ) async throws -> StatusCode {
        let xcodeTargetIdentifiers = targetIdentifiers.map { XcodeTargetIdentifier($0) }

        let result = try await backend.test(
            xcodeTargetIdentifiers: xcodeTargetIdentifiers,
            arguments: arguments,
            environmentVariables: environmentVariables,
            workingDirectory: workingDirectory?.fileURL,
            outputHandler: logHandler.map { ClosureOutputHandler(onLine: $0) },
            testEventHandler: testEventHandler
        )

        return switch result.statusCode {
        case .success:
            .ok
        case .error:
            .error
        }
    }
}
