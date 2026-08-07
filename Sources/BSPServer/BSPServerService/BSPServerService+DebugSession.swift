import BuildServerProtocol
import Foundation
import JSONRPCConnection
import Logger

extension BSPServerService {
    func startDebugSession(
        targets: [BSPBuildTargetIdentifier],
        arguments: [String]?
    ) async throws -> DebugSessionConnection {
        guard let projectManager else {
            throw BuildServerError.invalidConfiguration("Project manager not initialized")
        }
        return try await projectManager.startDebugSession(
            targetIdentifiers: targets,
            arguments: arguments
        )
    }
}
