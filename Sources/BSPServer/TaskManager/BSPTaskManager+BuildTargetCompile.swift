//
//  BSPTaskManager+BuildTargetCompile.swift
//
//  Copyright © 2024 Wang Lun.
//

import BuildServerProtocol
import Foundation
import JSONRPCConnection

public extension BSPTaskManager {
    /// Execute build with progress parsed from xcodebuild output
    func executeCompileWithProgress(
        using projectManager: any ProjectManager,
        targets: [BSPBuildTargetIdentifier],
        originId: String? = nil,
        arguments: [String]? = nil
    ) async throws -> StatusCode {
        let targetNames = targets.map(\.uri.stringValue).joined(separator: ", ")

        return try await executeWithProgress(originId: originId, message: "Compile targets: \(targetNames)") { log in
            try await projectManager.startBuild(targetIdentifiers: targets, arguments: arguments, logHandler: log)
        }
    }

    internal func executeWithProgress(
        originId: String?,
        message: String,
        operation: @Sendable (@escaping @Sendable (String) -> Void) async throws -> StatusCode
    ) async throws -> StatusCode {
        let task = try await startTask(
            originId: originId,
            message: message
        )

        let taskId = task.taskId

        // Batch build output and stream it to the client via `build/logMessage`
        // on a ~100ms cadence (see BuildLogBatcher: we don't send per line, to
        // avoid head-of-line contention with normal BSP traffic on stdout).
        let batcher = BuildLogBatcher()
        let sendBatch: @Sendable ([String])
            async -> Void = { [weak self] lines in
                guard let self, !lines.isEmpty else { return }
                try? await self.notificationService?.sendNotification(ServerJSONRPCNotification(
                    method: "build/logMessage",
                    params: BuildLogMessageParams(originId: originId, message: lines.joined(separator: "\n"))
                ))
            }
        let flusher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                await sendBatch(batcher.drain())
            }
        }
        func stopStreaming() async {
            flusher.cancel()
            await flusher.value
            await sendBatch(batcher.drain()) // flush the remainder
        }

        do {
            let status = try await operation { batcher.append($0) }
            try Task.checkCancellation()
            await stopStreaming()
            try await finishTask(
                taskId: taskId,
                status: status,
                message: status == .ok ? "Task completed successfully" : "Task completed with errors"
            )

            return status
        } catch {
            await stopStreaming()
            try await finishTask(
                taskId: taskId,
                status: error is CancellationError ? .cancelled : .error,
                message: error is CancellationError ? "Task cancelled" : "Task failed: \(error.localizedDescription)"
            )
            throw error
        }
    }
}
