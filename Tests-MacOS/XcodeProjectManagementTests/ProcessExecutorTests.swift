import Foundation
import Support
import Testing
import XcodeProjectManagement

struct ProcessExecutorTests {
    @Test
    func capturesAllOutputBeforeReturning() async throws {
        let executor = ProcessExecutor()
        for _ in 0 ..< 10 {
            let result = try await executor.execute(
                executable: "/bin/sh",
                arguments: ["-c", "printf 'first\\nlast\\n'; printf 'failure detail\\n' >&2; exit 7"]
            )
            #expect(result.exitCode == 7)
            #expect(result.output == "first\nlast\n")
            #expect(result.error == "failure detail\n")
        }
    }

    @Test
    func regularExecution() async throws {
        let processExecutor = ProcessExecutor()
        let result = try await processExecutor.execute(
            executable: "/bin/ls",
            arguments: ["-l"],
            workingDirectory: nil,
            environment: [:],
            timeout: 5.0
        )
        #expect(result.exitCode == 0)
    }

    @Test("ProcessExecutor timeout test")
    func timeoutError() async throws {
        let processExecutor = ProcessExecutor()
        let start = ContinuousClock.now
        let error = try await #require(throws: ProcessExecutorError.self) {
            try await processExecutor.execute(
                executable: "/bin/sleep",
                arguments: ["30"],
                workingDirectory: nil,
                environment: [:],
                timeout: 0.1
            )
        }
        #expect(error.isTimeout)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test
    func cancelsRunningProcess() async throws {
        let executor = ProcessExecutor()
        let start = ContinuousClock.now
        let task = Task {
            try await executor.execute(executable: "/bin/sleep", arguments: ["30"])
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}
