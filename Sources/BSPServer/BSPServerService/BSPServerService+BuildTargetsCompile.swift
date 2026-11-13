import Foundation
import JSONRPCConnection
import Logger
import SourceKitBSPProtocol

extension BSPServerService {
    func compileTargets(
        _ targetIdentifiers: [BSPBuildTargetIdentifier],
        originId: String? = nil,
        arguments: [String]? = nil,
        executionContext reference: BuildContextReference? = nil
    ) async throws -> StatusCode {
        guard let projectManager else {
            logger.error("Project not initialized")
            return .error
        }

        let context = try await executionContext(reference, operation: .compile, targets: targetIdentifiers)
        let taskManager = getTaskManager()

        return try await taskManager.executeCompileWithProgress(
            using: projectManager,
            targets: targetIdentifiers,
            originId: originId,
            arguments: arguments,
            executionContext: context
        )
    }
}
