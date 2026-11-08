import BuildServerProtocol
import Foundation
import JSONRPCConnection
import Logger

extension BSPServerService {
    func startDebugSession(
        targets: [BSPBuildTargetIdentifier],
        originId: String? = nil,
        arguments: [String]?,
        executionContext reference: BuildContextReference? = nil
    ) async throws -> DebugSessionConnection {
        guard let projectManager else {
            throw BuildServerError.invalidConfiguration("Project manager not initialized")
        }
        let context = try await executionContext(reference, operation: .debug, targets: targets)
        let root = await projectManager.rootURL
        let directory = await projectManager.project?.buildRootURL ?? root
            .appendingPathComponent(".sourcekit-bsp")
        let buildContext = BuildOutputContext(
            rootURL: root, logDirectory: directory.appendingPathComponent("Logs/sourcekit-bsp")
        )
        return try await taskManager.executeDebugWithProgress(
            originId: originId, buildContext: buildContext
        ) { progress, log in
            if let context {
                return try await projectManager.startDebugSession(
                    targetIdentifiers: targets,
                    arguments: arguments,
                    logHandler: log,
                    progressHandler: progress,
                    context: context
                )
            }
            return try await projectManager.startDebugSession(
                targetIdentifiers: targets,
                arguments: arguments,
                logHandler: log,
                progressHandler: progress
            )
        }
    }
}
