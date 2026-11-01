//
//  BSPTaskManager.swift
//
//  Copyright © 2024 Wang Lun.
//

import BuildServerProtocol
import Foundation
import JSONRPCConnection
import Logger
import Support

/// Manages BSP task lifecycle including taskStart, taskProgress, and taskFinish notifications
public final class BSPTaskManager: @unchecked Sendable {
    private let taskState = CrossPlatformLock(initialState: TaskState())
    weak var notificationService: BSPNotificationService?

    private struct TaskState {
        var activeTasks: [String: BSPTask] = [:]
        var taskCounter: Int = 0
    }

    public init(notificationService: BSPNotificationService) {
        self.notificationService = notificationService
    }

    /// Generate a unique task ID
    private func generateTaskId() -> String {
        taskState.withLock { state in
            state.taskCounter += 1
            return "sourcekit-bsp-\(state.taskCounter)-\(Date().timeIntervalSince1970)"
        }
    }

    /// Start a new task
    public func startTask(
        originId: String? = nil,
        message: String
    ) async throws -> BSPTask {
        let taskId = generateTaskId()
        let task = BSPTask(
            taskId: taskId,
            originId: originId,
            message: message
        )

        taskState.withLock { state in
            state.activeTasks[taskId] = task
        }

        // Send taskStart notification
        try await sendTaskStartNotification(task: task)

        logger.debug("Started task: \(taskId) - \(message)")
        return task
    }

    /// Update task progress
    func updateTaskProgress(
        taskId: String,
        progress: Double,
        message: String? = nil
    ) async throws {
        let task = taskState.withLock { state in
            state.activeTasks[taskId]
        }

        guard let task else {
            logger.warning("Attempted to update progress for unknown task: \(taskId)")
            return
        }

        // Update task internal state
        task.updateProgress(progress: progress, message: message)

        // Send taskProgress notification
        try await sendTaskProgressNotification(task: task)

        logger.debug("Updated task progress: \(taskId) - \(progress * 100)%")
    }

    /// Finish a task
    func finishTask(
        taskId: String,
        status: StatusCode,
        message: String? = nil
    ) async throws {
        let task = taskState.withLock { state in
            let task = state.activeTasks[taskId]
            if task != nil {
                state.activeTasks.removeValue(forKey: taskId)
            }
            return task
        }

        guard let task else {
            logger.warning("Attempted to finish unknown task: \(taskId)")
            return
        }

        // Update task internal state
        task.finish(status: status, message: message)

        // Send taskFinish notification
        try await sendTaskFinishNotification(task: task)

        logger.debug("Finished task: \(taskId) - \(status)")
    }

    /// Get active task by ID
    public func getTask(taskId: String) -> BSPTask? {
        taskState.withLock { state in
            state.activeTasks[taskId]
        }
    }

    /// Get all active tasks
    public func getActiveTasks() -> [BSPTask] {
        taskState.withLock { state in
            Array(state.activeTasks.values)
        }
    }

    /// Cancel all active tasks
    public func cancelAllTasks() async throws {
        let tasks = taskState.withLock { state in
            Array(state.activeTasks.values)
        }

        for task in tasks {
            try await finishTask(
                taskId: task.taskId,
                status: .cancelled,
                message: "Task cancelled"
            )
        }
    }

    // MARK: - Notification Sending

    private func sendTaskStartNotification(task: BSPTask) async throws {
        try await sendTaskStartNotification(
            taskId: task.taskId,
            originId: task.originId,
            eventTime: task.startTime.timeIntervalSince1970,
            message: task.currentMessage ?? ""
        )
    }

    private func sendTaskProgressNotification(task: BSPTask) async throws {
        try await sendTaskProgressNotification(
            taskId: task.taskId,
            originId: task.originId,
            eventTime: Date().timeIntervalSince1970,
            progress: task.progress,
            message: task.currentMessage
        )
    }

    private func sendTaskFinishNotification(task: BSPTask) async throws {
        try await sendTaskFinishNotification(
            taskId: task.taskId,
            originId: task.originId,
            eventTime: task.finishTime?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
            status: task.status ?? .error,
            message: task.currentMessage
        )
    }

    // MARK: - Public Notification Methods

    func sendTaskStartNotification(
        taskId: String,
        originId: String?,
        eventTime: TimeInterval? = nil,
        message: String
    ) async throws {
        let params = TaskStartParams(
            taskId: taskId,
            originId: originId,
            eventTime: eventTime ?? Date().timeIntervalSince1970,
            message: message
        )

        let notification = ServerJSONRPCNotification(
            method: TaskStartParams.method,
            params: params
        )

        try await notificationService?.sendNotification(notification)
    }

    func sendTaskProgressNotification(
        taskId: String,
        originId: String? = nil,
        eventTime: TimeInterval? = nil,
        progress: Double,
        message: String?
    ) async throws {
        let params = TaskProgressParams(
            taskId: taskId,
            originId: originId,
            eventTime: eventTime ?? Date().timeIntervalSince1970,
            message: message,
            progress: progress,
            unit: nil,
            dataKind: nil,
            data: nil
        )

        let notification = ServerJSONRPCNotification(
            method: TaskProgressParams.method,
            params: params
        )

        try await notificationService?.sendNotification(notification)
    }

    func sendTaskFinishNotification(
        taskId: String,
        originId: String? = nil,
        eventTime: TimeInterval? = nil,
        status: StatusCode,
        message: String?
    ) async throws {
        let params = TaskFinishParams(
            taskId: taskId,
            originId: originId,
            eventTime: eventTime ?? Date().timeIntervalSince1970,
            message: message,
            status: status
        )

        let notification = ServerJSONRPCNotification(
            method: TaskFinishParams.method,
            params: params
        )

        try await notificationService?.sendNotification(notification)
    }
}

/// Protocol for sending BSP notifications
public protocol BSPNotificationService: AnyObject, Sendable {
    func sendNotification(_ notification: ServerJSONRPCNotification<some Codable & Sendable>) async throws
}
