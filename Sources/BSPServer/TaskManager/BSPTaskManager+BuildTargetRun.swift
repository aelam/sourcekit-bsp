import Foundation
import JSONRPCConnection
import SourceKitBSPProtocol

extension BSPTaskManager {
    func executeRunWithProgress(
        originId: String?,
        buildContext: BuildOutputContext? = nil,
        operation: @Sendable (
            @escaping @Sendable (String) async -> Void, RunBuildOutput?
        ) async throws -> StatusCode
    ) async throws -> StatusCode {
        let task = try await startTask(originId: originId, message: "Run target")
        let reporter = buildContext.map { BuildOutputReporter(manager: self, task: task, context: $0) }
        if let buildContext { await reporter?.start(context: buildContext) }
        let batcher = BuildLogBatcher()
        let flusher: Task<Void, Never>? = reporter.map { reporter in
            Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                    await reporter.consume(batcher.drain())
                }
            }
        }
        let finishBuildOutput: @Sendable ()
            async -> Void = {
                if let flusher {
                    flusher.cancel()
                    await flusher.value
                }
                await reporter?.consume(batcher.drain())
                await reporter?.finish()
            }
        let buildOutput = reporter.map { _ in
            RunBuildOutput(onLine: { batcher.append($0) }, finish: finishBuildOutput)
        }
        do {
            let status = try await operation({ message in
                try? await self.updateTaskProgress(taskId: task.taskId, progress: nil, message: message)
                try? await self.notificationService?.sendNotification(ServerJSONRPCNotification(
                    method: "build/logMessage",
                    params: BuildLogMessageParams(type: 3, originId: originId, message: message)
                ))
            }, buildOutput)
            await finishBuildOutput()
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
                await finishBuildOutput()
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
