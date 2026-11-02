public struct TestReport: Codable, Hashable, Sendable {
    public let target: BSPBuildTargetIdentifier
    public let passed: Int
    public let failed: Int
    public let ignored: Int
    public let cancelled: Int
    public let skipped: Int
    /// Test execution time in milliseconds, excluding compilation.
    public let time: Int64?

    public init(target: BSPBuildTargetIdentifier, results: [TestCaseResult], time: Int64? = nil) {
        self.target = target
        self.passed = results.count { $0.status == .passed }
        self.failed = results.count { $0.status == .failed }
        self.ignored = results.count { $0.status == .ignored }
        self.cancelled = results.count { $0.status == .cancelled }
        self.skipped = results.count { $0.status == .skipped }
        self.time = time
    }
}
