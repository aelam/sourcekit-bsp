//  BSPServerService+BuildTargetRun.swift
import BuildServerProtocol
import Foundation

extension BSPServerService {
    func run(
        targetIdentifier: BSPBuildTargetIdentifier,
        arguments: [String]?, // e.g. ["-configuration", "Debug", "-destination", "id=XXXX"]
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
    ) async throws -> StatusCode {
        try Task.checkCancellation()
        guard let projectManager else {
            throw BuildServerError.invalidConfiguration("Project not initialized")
        }

        return try await projectManager.run(
            targetIdentifier: targetIdentifier,
            arguments: arguments,
            environmentVariables: environmentVariables,
            workingDirectory: workingDirectory
        )
    }
}
