import BuildServerProtocol
import Foundation
import JSONRPCConnection
import Logger

extension BSPServerService {
    func compileTargets(
        _ targetIdentifiers: [BSPBuildTargetIdentifier],
        originId: String? = nil,
        arguments: [String]? = nil
    ) async throws -> StatusCode {
        guard let projectManager else {
            logger.error("Project not initialized")
            return .error
        }

        let taskManager = getTaskManager()

        return try await taskManager.executeCompileWithProgress(
            using: projectManager,
            targets: targetIdentifiers,
            originId: originId,
            arguments: arguments
        )
    }
}
