//  BSPServerService+BuildTargetRun.swift
import BuildServerProtocol
import Foundation

extension BSPServerService {
    func test(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        originId: String? = nil,
        arguments: [String]?, // e.g. ["-configuration", "Debug", "-destination", "id=XXXX"]
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
    ) async throws -> StatusCode {
        guard let projectManager else {
            throw BuildServerError.invalidConfiguration("Project not initialized")
        }

        return try await getTaskManager().executeWithProgress(originId: originId, message: "Run tests") { log in
            try await projectManager.test(
                targetIdentifiers: targetIdentifiers,
                arguments: arguments,
                environmentVariables: environmentVariables,
                workingDirectory: workingDirectory,
                logHandler: log
            )
        }
    }
}
