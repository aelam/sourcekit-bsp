import BuildServerProtocol
import Foundation
import JSONRPCConnection
import Logger

extension BSPServerService {
    func startDebugSession(
        targets: [BSPBuildTargetIdentifier],
        originId: String? = nil,
        arguments: [String]?
    ) async throws -> DebugSessionConnection {
        guard let projectManager else {
            throw BuildServerError.invalidConfiguration("Project manager not initialized")
        }
        let root = await projectManager.rootURL
        let directory = await projectManager.project?.buildRootURL ?? root
            .appendingPathComponent(".sourcekit-bsp")
        let buildContext = BuildOutputContext(
            rootURL: root, logDirectory: directory.appendingPathComponent("Logs/sourcekit-bsp")
        )
        return try await taskManager.executeDebugWithProgress(
            originId: originId, buildContext: buildContext
        ) { progress, log in
            try await projectManager.startDebugSession(
                targetIdentifiers: targets,
                arguments: arguments,
                logHandler: log,
                progressHandler: progress
            )
        }
    }
}
