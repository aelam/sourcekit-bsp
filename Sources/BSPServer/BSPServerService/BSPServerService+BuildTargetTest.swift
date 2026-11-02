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

        let context = await BuildOutputContext.load(using: projectManager, targets: targetIdentifiers)
        return try await getTaskManager().executeTestsWithProgress(
            originId: originId, context: context
        ) { log, events in
            try await projectManager.test(
                targetIdentifiers: targetIdentifiers,
                arguments: arguments,
                environmentVariables: environmentVariables,
                workingDirectory: workingDirectory,
                logHandler: log,
                testEventHandler: events
            )
        }
    }
}
