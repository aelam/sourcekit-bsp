import BuildServerProtocol
import Foundation
import JSONRPCConnection

extension BSPTaskManager {
    func executeDebugWithProgress(
        originId: String?,
        operation: @Sendable (@escaping @Sendable (String) async -> Void) async throws -> DebugSessionConnection
    ) async throws -> DebugSessionConnection {
        let task = try await startTask(originId: originId, message: "Prepare debug session")
        do {
            let result = try await operation { message in
                try? await self.updateTaskProgress(taskId: task.taskId, progress: nil, message: message)
                try? await self.notificationService?.sendNotification(ServerJSONRPCNotification(
                    method: "build/logMessage",
                    params: BuildLogMessageParams(type: 3, originId: originId, message: message)
                ))
            }
            try? await finishTask(
                taskId: task.taskId,
                status: .ok,
                message: "Debug adapter ready; waiting for DAP attach"
            )
            return result
        } catch {
            let message = if error is CancellationError {
                "Debug preparation cancelled"
            } else {
                "Debug failed: \(error.localizedDescription)"
            }
            await Task {
                try? await self.finishTask(
                    taskId: task.taskId,
                    status: error is CancellationError ? .cancelled : .error,
                    message: message
                )
            }.value
            throw error
        }
    }
}
