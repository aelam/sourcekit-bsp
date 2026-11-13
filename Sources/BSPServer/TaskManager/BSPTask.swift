//
//  BSPTask.swift
//
//  Copyright © 2024 Wang Lun.
//

import Foundation
import SourceKitBSPProtocol

/// Represents a BSP task with lifecycle management
public struct BSPTask: Sendable {
    public let taskId: String
    public let originId: String?
    public let startTime: Date

    public private(set) var currentMessage: String?
    public private(set) var progress: Double?
    public private(set) var total: Double?
    public private(set) var unit: String?
    public private(set) var status: StatusCode?
    public private(set) var finishTime: Date?

    init(
        taskId: String,
        originId: String?,
        message: String?,
    ) {
        self.taskId = taskId
        self.originId = originId
        self.currentMessage = message
        self.startTime = Date()
    }

    /// Update task progress (internal state only)
    public mutating func updateProgress(
        progress: Double?,
        total: Double? = nil,
        unit: String? = nil,
        message: String? = nil
    ) {
        self.progress = progress
        self.total = total
        self.unit = unit
        if let message {
            self.currentMessage = message
        }
    }

    /// Finish the task (internal state only)
    public mutating func finish(status: StatusCode, message: String? = nil) {
        self.status = status
        self.finishTime = Date()
        if let message {
            self.currentMessage = message
        }
    }

    /// Mark task as successful (internal state only)
    public mutating func succeed(message: String? = nil) {
        finish(status: .ok, message: message)
    }

    /// Mark task as failed (internal state only)
    public mutating func fail(message: String? = nil) {
        finish(status: .error, message: message)
    }

    /// Cancel the task (internal state only)
    public mutating func cancel(message: String? = nil) {
        finish(status: .cancelled, message: message)
    }

    /// Check if task is finished
    public var isFinished: Bool {
        status != nil
    }

    /// Get task duration
    public var duration: TimeInterval {
        let endTime = finishTime ?? Date()
        return endTime.timeIntervalSince(startTime)
    }
}
