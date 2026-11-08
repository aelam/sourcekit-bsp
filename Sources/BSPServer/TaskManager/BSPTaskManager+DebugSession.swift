import BuildServerProtocol
import Foundation
import JSONRPCConnection

extension BSPTaskManager {
    func executeDebugWithProgress(
        originId: String?,
        buildContext: BuildOutputContext? = nil,
        cancellationCleanup: @Sendable (DebugSessionConnection) async -> Void = { _ in },
        operation: @Sendable (
            @escaping @Sendable (String) async -> Void, @escaping @Sendable (String) -> Void
        ) async throws -> DebugSessionConnection
    ) async throws -> DebugSessionConnection {
        let task = try await startTask(originId: originId, message: "Prepare debug session")
        let reporter = buildContext.map { BuildOutputReporter(manager: self, task: task, context: $0) }
        if let buildContext { await reporter?.start(context: buildContext) }
        let batcher = BuildLogBatcher()
        let flusher = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                await reporter?.consume(batcher.drain())
            }
        }
        func stopStreaming() async {
            flusher.cancel()
            await flusher.value
            await reporter?.consume(batcher.drain())
            await reporter?.finish()
        }
        do {
            let result = try await operation({ message in
                try? await self.updateTaskProgress(taskId: task.taskId, progress: nil, message: message)
                try? await self.notificationService?.sendNotification(ServerJSONRPCNotification(
                    method: "build/logMessage",
                    params: BuildLogMessageParams(type: 3, originId: originId, message: message)
                ))
            }, { batcher.append($0) })
            if Task.isCancelled {
                await cancellationCleanup(result)
                throw CancellationError()
            }
            await stopStreaming()
            try? await finishTask(
                taskId: task.taskId,
                status: .ok,
                message: "Debug adapter ready"
            )
            return result
        } catch {
            let message = if error is CancellationError {
                "Debug preparation cancelled"
            } else {
                "Debug failed: \(error.localizedDescription)"
            }
            await Task {
                await stopStreaming()
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
