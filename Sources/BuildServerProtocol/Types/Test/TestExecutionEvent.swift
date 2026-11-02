public struct TestCaseResult: Codable, Hashable, Sendable {
    public let displayName: String
    public let status: TestStatus
    public let message: String?
    public let testId: String?

    public init(displayName: String, status: TestStatus, message: String? = nil, testId: String? = nil) {
        self.displayName = displayName
        self.status = status
        self.message = message
        self.testId = testId
    }
}

public struct TestExecutionReport: Sendable {
    public let tests: [TestCaseResult]
    public let time: Int64?

    public init(tests: [TestCaseResult], time: Int64? = nil) {
        self.tests = tests
        self.time = time
    }
}

public enum TestExecutionEvent: Sendable {
    case warning(String)
    case started(BSPBuildTargetIdentifier)
    case finished(BSPBuildTargetIdentifier, StatusCode, TestExecutionReport?)
}
