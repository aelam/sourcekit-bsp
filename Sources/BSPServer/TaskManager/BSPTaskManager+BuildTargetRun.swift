import BuildServerProtocol
import Foundation
import JSONRPCConnection

extension BSPTaskManager {
    func executeRunWithProgress(
        originId: String?,
        operation: @Sendable (@escaping @Sendable (String) async -> Void) async throws -> StatusCode
    ) async throws -> StatusCode {
        let task = try await startTask(originId: originId, message: "Run target")
        do {
            let status = try await operation { message in
                try? await self.updateTaskProgress(taskId: task.taskId, progress: nil, message: message)
                try? await self.notificationService?.sendNotification(ServerJSONRPCNotification(
                    method: "build/logMessage",
                    params: BuildLogMessageParams(type: 3, originId: originId, message: message)
                ))
            }
            try Task.checkCancellation()
            let message = switch status {
            case .ok: "Run completed"
            case .cancelled: "Run cancelled"
            case .error: "Run failed"
            }
            try? await finishTask(taskId: task.taskId, status: status, message: message)
            return status
        } catch {
            // Deliver the final status even when the request task is cancelled.
            await Task {
                try? await self.finishTask(
                    taskId: task.taskId,
                    status: error is CancellationError ? .cancelled : .error,
                    message: error is CancellationError ? "Run cancelled" : "Run failed: \(error.localizedDescription)"
                )
            }.value
            throw error
        }
    }
}
