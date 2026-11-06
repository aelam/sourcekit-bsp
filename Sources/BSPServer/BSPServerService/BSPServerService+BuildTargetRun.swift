//  BSPServerService+BuildTargetRun.swift
import BuildServerProtocol
import Foundation

extension BSPServerService {
    func run(
        targetIdentifier: BSPBuildTargetIdentifier,
        originId: String? = nil,
        arguments: [String]?, // e.g. ["-configuration", "Debug", "-destination", "id=XXXX"]
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        executionContext reference: BuildContextReference? = nil,
    ) async throws -> StatusCode {
        try Task.checkCancellation()
        guard let projectManager else {
            throw BuildServerError.invalidConfiguration("Project not initialized")
        }

        let context = try await executionContext(reference, operation: .run, targets: [targetIdentifier])
        return try await taskManager.executeRunWithProgress(originId: originId) { progress in
            if let context {
                return try await projectManager.run(
                    targetIdentifier: targetIdentifier,
                    arguments: arguments,
                    environmentVariables: environmentVariables,
                    workingDirectory: workingDirectory,
                    progressHandler: progress,
                    context: context
                )
            }
            return try await projectManager.run(
                targetIdentifier: targetIdentifier,
                arguments: arguments,
                environmentVariables: environmentVariables,
                workingDirectory: workingDirectory,
                progressHandler: progress
            )
        }
    }
}
