import Foundation
import Support
import Testing
import XcodeProjectManagement

struct ProcessExecutorTests {
    @Test
    func describesTimeoutsAndStartFailures() {
        #expect(ProcessExecutorError.timeout(120).localizedDescription.contains("120"))
        #expect(ProcessExecutorError.timeout(120).localizedDescription.contains("timed out"))
        #expect(ProcessExecutorError.processStartFailed("missing tool").localizedDescription.contains("missing tool"))
    }

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
        let probe = try TerminationProbe()
        defer { probe.removeFiles() }
        let error = try await #require(throws: ProcessExecutorError.self) {
            try await processExecutor.execute(
                executable: "/bin/sh",
                arguments: probe.arguments,
                workingDirectory: nil,
                environment: [:],
                timeout: 1.0
            )
        }
        #expect(error.isTimeout)
        try probe.expectTerminated()
    }

    @Test
    func cancelsRunningProcess() async throws {
        let executor = ProcessExecutor()
        let probe = try TerminationProbe()
        defer { probe.removeFiles() }
        let task = Task {
            try await executor.execute(executable: "/bin/sh", arguments: probe.arguments)
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: probe.pidFile.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: probe.pidFile.path))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        try probe.expectTerminated()
    }
}

private struct TerminationProbe {
    let directory: URL
    var pidFile: URL {
        directory.appendingPathComponent("pid")
    }

    var resultFile: URL {
        directory.appendingPathComponent("result")
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var arguments: [String] {
        [
            "-c", """
            trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; printf terminated > "$2"; exit 0' TERM
            sleep 30 &
            child=$!
            printf '%s' "$$" > "$1"
            wait "$child"
            printf completed > "$2"
            """,
            "bsp-process-test", pidFile.path, resultFile.path
        ]
    }

    func expectTerminated() throws {
        #expect(try String(contentsOf: resultFile, encoding: .utf8) == "terminated")
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: directory)
    }
}
