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
        return try await taskManager.executeDebugWithProgress(originId: originId) { progress in
            try await projectManager.startDebugSession(
                targetIdentifiers: targets, arguments: arguments, progressHandler: progress
            )
        }
    }
}
