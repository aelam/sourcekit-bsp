import BuildServerProtocol
import Foundation

public struct TaskFinishParams: Codable, Sendable {
    public static let method = "build/taskFinish"

    public let taskId: TaskIdentifier
    public let originId: String?
    public let eventTime: Int64?
    public let message: String?
    public let status: StatusCode
    public let dataKind: TaskFinishDataKind?
    public let data: LSPAny?

    public init(
        taskId: String,
        parents: [String]? = nil,
        originId: String? = nil,
        eventTime: Int64? = nil,
        message: String? = nil,
        status: StatusCode,
        dataKind: TaskFinishDataKind? = nil,
        data: LSPAny? = nil
    ) {
        self.taskId = TaskIdentifier(id: taskId, parents: parents)
        self.originId = originId
        self.eventTime = eventTime
        self.message = message
        self.status = status
        self.dataKind = dataKind
        self.data = data
    }
}

public typealias TaskFinishDataKind = String

public extension TaskFinishDataKind {
    static let CompileReport: TaskFinishDataKind = "compile-report"
    static let TestFinish: TaskFinishDataKind = "test-finish"
    static let TestReport: TaskFinishDataKind = "test-report"
}
