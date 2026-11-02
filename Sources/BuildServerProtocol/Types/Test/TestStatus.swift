public enum TestStatus: Int, Codable, Sendable {
    /** The test passed successfully. */
    case passed = 1

    /** The test failed. */
    case failed = 2

    /** The test was marked as ignored. */
    case ignored = 3

    /** The test execution was cancelled. */
    case cancelled = 4

    /** The was not included in execution. */
    case skipped = 5
}
