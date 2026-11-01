import Foundation

public struct TaskStartParams: Codable, Sendable {
    public static let method = "build/taskStart"

    /** The task id. */
    public let taskId: TaskIdentifier
    public let originId: String?
    public let eventTime: Int64?
    public let message: String?
    public let dataKind: TaskStartDataKind?
    public let data: Data?

    public init(
        taskId: String,
        originId: String? = nil,
        eventTime: Int64? = nil,
        message: String? = nil,
        dataKind: TaskStartDataKind? = nil,
        data: Data? = nil
    ) {
        self.taskId = TaskIdentifier(id: taskId)
        self.originId = originId
        self.eventTime = eventTime
        self.message = message
        self.dataKind = dataKind
        self.data = data
    }
}

public typealias TaskStartDataKind = String

public extension TaskStartDataKind {
    static let compileTask: TaskStartDataKind = "compile-task"
    static let testStart: TaskStartDataKind = "test-start"
    static let testTask: TaskStartDataKind = "test-task"
}
