import BuildServerProtocol
import Foundation
import JSONRPCConnection
import Logger

extension BSPServerService {
    func startDebugSession(
        targets: [BSPBuildTargetIdentifier],
        originId: String? = nil,
        arguments: [String]?,
        buildBeforeLaunch: Bool = true
    ) async throws -> DebugSessionConnection {
        guard let projectManager else {
            throw BuildServerError.invalidConfiguration("Project manager not initialized")
        }
        let root = await projectManager.rootURL
        let directory = await projectManager.projectInfo?.derivedDataPath ?? root
            .appendingPathComponent(".sourcekit-bsp")
        let buildContext = buildBeforeLaunch ? BuildOutputContext(
            rootURL: root, logDirectory: directory.appendingPathComponent("Logs/sourcekit-bsp")
        ) : nil
        return try await taskManager.executeDebugWithProgress(
            originId: originId, buildContext: buildContext
        ) { progress, log in
            try await projectManager.startDebugSession(
                targetIdentifiers: targets,
                arguments: arguments,
                buildBeforeLaunch: buildBeforeLaunch,
                logHandler: log,
                progressHandler: progress
            )
        }
    }
}
