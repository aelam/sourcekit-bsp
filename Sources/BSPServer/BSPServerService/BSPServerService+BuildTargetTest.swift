import Foundation

//  BSPServerService+BuildTargetRun.swift
import SourceKitBSPProtocol

extension BSPServerService {
    func test(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        originId: String? = nil,
        arguments: [String]?, // e.g. ["-configuration", "Debug", "-destination", "id=XXXX"]
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        dataKind: String? = nil,
        data: LSPAny? = nil,
        executionContext reference: BuildContextReference? = nil
    ) async throws -> StatusCode {
        guard let projectManager else {
            throw BuildServerError.invalidConfiguration("Project not initialized")
        }

        let execution = try await executionContext(reference, operation: .test, targets: targetIdentifiers)
        let arguments = try await projectManager.testArguments(
            targetIdentifiers: targetIdentifiers, arguments: arguments, dataKind: dataKind, data: data
        )
        let context = await BuildOutputContext.load(using: projectManager, targets: targetIdentifiers)
        return try await getTaskManager().executeTestsWithProgress(
            originId: originId, context: context
        ) { log, events in
            if let execution {
                return try await projectManager.test(
                    targetIdentifiers: targetIdentifiers,
                    arguments: arguments,
                    environmentVariables: environmentVariables,
                    workingDirectory: workingDirectory,
                    logHandler: log,
                    testEventHandler: events,
                    context: execution
                )
            }
            return try await projectManager.test(
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
