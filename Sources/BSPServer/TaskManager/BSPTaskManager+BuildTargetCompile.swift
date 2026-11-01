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
    /// 避免在 Actor 上下文中长时间等待，使用 Task.detached 在独立上下文中执行构建
    func executeCompileWithProgress(
        using projectManager: any ProjectManager,
        targets: [BSPBuildTargetIdentifier],
        originId: String? = nil,
        arguments: [String]? = nil
    ) async throws -> StatusCode {
        let targetNames = targets.map(\.uri.stringValue).joined(separator: ", ")

        let task = try await startTask(
            originId: originId,
            message: "compile targets: \(targetNames)"
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
            await sendBatch(batcher.drain()) // flush the remainder
        }

        do {
            let status = try await projectManager.startBuild(
                targetIdentifiers: targets,
                arguments: arguments,
                logHandler: { batcher.append($0) }
            )
            await stopStreaming()
            try await finishTask(
                taskId: taskId,
                status: status,
                message: status == .ok ? "Build completed successfully" : "Build completed with errors"
            )

            return status
        } catch {
            await stopStreaming()
            try await finishTask(
                taskId: taskId,
                status: .error,
                message: "Build failed: \(error.localizedDescription)"
            )
            throw error
        }
    }
}
