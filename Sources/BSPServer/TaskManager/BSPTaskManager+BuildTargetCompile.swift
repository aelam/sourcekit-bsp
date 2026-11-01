import BuildServerProtocol
import Foundation

public extension BSPTaskManager {
    func executeCompileWithProgress(
        using projectManager: any ProjectManager,
        targets: [BSPBuildTargetIdentifier],
        originId: String? = nil,
        arguments: [String]? = nil
    ) async throws -> StatusCode {
        let context = await BuildOutputContext.load(using: projectManager, targets: targets)
        return try await executeWithProgress(originId: originId, message: "Compile targets", context: context) { log in
            try await projectManager.startBuild(targetIdentifiers: targets, arguments: arguments, logHandler: log)
        }
    }

    internal func executeWithProgress(
        originId: String?,
        message: String,
        context: BuildOutputContext = BuildOutputContext(),
        operation: @Sendable (@escaping @Sendable (String) -> Void) async throws -> StatusCode
    ) async throws -> StatusCode {
        try await executeTask(originId: originId, message: message, context: context) { log in
            let status = try await operation(log)
            return (status, status)
        }
    }

    internal func executeTask<Result: Sendable>(
        originId: String?,
        message: String,
        context: BuildOutputContext,
        operation: @Sendable (@escaping @Sendable (String) -> Void) async throws -> (Result, StatusCode)
    ) async throws -> Result {
        let task = try await startTask(originId: originId, message: message)
        let reporter = BuildOutputReporter(manager: self, task: task, context: context)
        await reporter.start(context: context)
        let batcher = BuildLogBatcher()
        let flusher = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                await reporter.consume(batcher.drain())
            }
        }
        func stopStreaming() async {
            flusher.cancel()
            await flusher.value
            await reporter.consume(batcher.drain())
            await reporter.finish()
        }
        do {
            let (result, status) = try await operation { batcher.append($0) }
            try Task.checkCancellation()
            await stopStreaming()
            try await finishTask(
                taskId: task.taskId,
                status: status,
                message: status == .ok ? "Task completed successfully" : "Task completed with errors"
            )
            return result
        } catch {
            await stopStreaming()
            try await finishTask(
                taskId: task.taskId,
                status: error is CancellationError ? .cancelled : .error,
                message: error is CancellationError ? "Task cancelled" : "Task failed: \(error.localizedDescription)"
            )
            throw error
        }
    }
}
