import Foundation
import SourceKitBSPProtocol
import Support

enum XcodeTestResultReader {
    static func read(bundle: URL, toolchain: XcodeToolchain) async throws -> TestExecutionReport {
        guard let installation = await toolchain.getSelectedInstallation() else {
            throw XcodeToolchainError.xcodeNotFound
        }
        let result = try await ProcessExecutor().execute(
            executable: installation.developerDir.appendingPathComponent("usr/bin/xcresulttool").path,
            arguments: ["get", "test-results", "tests", "--path", bundle.path, "--compact"],
            timeout: 30
        )
        guard result.exitCode == 0 else {
            throw XcodeProjectError.invalidConfig(result.error ?? result.output)
        }
        return try decode(Data(result.output.utf8))
    }

    static func decode(_ data: Data) throws -> TestExecutionReport {
        let tree = try JSONDecoder().decode(TestTree.self, from: data)
        let tests = try tree.testNodes.flatMap { try cases(in: $0) }
        // Use execution durations from the result bundle, never build elapsed time.
        let durations = tree.testNodes.compactMap(\.durationInSeconds)
        let seconds = durations.reduce(0, +)
        let time = durations.count == tree.testNodes.count && !durations.isEmpty
            && seconds.isFinite && seconds >= 0 && seconds < Double(Int64.max) / 1000
            ? Int64((seconds * 1000).rounded()) : nil
        return TestExecutionReport(tests: tests, time: time)
    }

    private static func cases(in node: TestNode) throws -> [TestCaseResult] {
        if node.nodeType == "Test Case" {
            let status: TestStatus
            switch node.result {
            case "Passed", "Expected Failure": status = .passed
            case "Failed": status = .failed
            case "Skipped": status = .skipped
            case "Cancelled": status = .cancelled
            default:
                throw XcodeProjectError
                    .invalidConfig("Unknown test result for \(node.name): \(node.result ?? "missing")")
            }
            let messages = failureMessages(in: node)
            let test = TestCaseResult(
                displayName: node.nodeIdentifier ?? node.name,
                status: status,
                message: messages.isEmpty ? (node.result == "Expected Failure" ? "Expected failure" : nil)
                    : messages.joined(separator: "\n"),
                testId: node.nodeIdentifier
            )
            return [test]
        }
        return try (node.children ?? []).flatMap { try cases(in: $0) }
    }

    private static func failureMessages(in node: TestNode) -> [String] {
        if node.nodeType == "Failure Message" { return [node.details ?? node.name] }
        return (node.children ?? []).flatMap { failureMessages(in: $0) }
    }

    private struct TestTree: Decodable {
        let testNodes: [TestNode]
    }

    private struct TestNode: Decodable {
        let nodeType: String
        let name: String
        let nodeIdentifier: String?
        let result: String?
        let details: String?
        let durationInSeconds: Double?
        let children: [TestNode]?
    }
}
