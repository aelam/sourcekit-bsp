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
        let buildContext: BuildOutputContext?
        if context?.buildPolicy == .build {
            let root = await projectManager.rootURL
            let project = await projectManager.project
            let directory = project?.buildRootURL ?? root.appendingPathComponent(".sourcekit-bsp")
            buildContext = BuildOutputContext(
                rootURL: root,
                logDirectory: directory.appendingPathComponent("Logs/sourcekit-bsp"),
                targets: project?.targets ?? [],
                affectedTargets: project?.dependencyClosure(for: [targetIdentifier]) ?? [targetIdentifier]
            )
        } else {
            buildContext = nil
        }
        return try await taskManager.executeRunWithProgress(
            originId: originId,
            buildContext: buildContext
        ) { progress, buildOutput in
            if let context {
                return try await projectManager.run(
                    targetIdentifier: targetIdentifier,
                    arguments: arguments,
                    environmentVariables: environmentVariables,
                    workingDirectory: workingDirectory,
                    progressHandler: progress,
                    buildOutput: buildOutput,
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
