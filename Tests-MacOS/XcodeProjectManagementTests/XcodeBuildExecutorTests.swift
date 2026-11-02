import Foundation
import Support
import Testing
@testable import XcodeProjectManagement

struct XcodeBuildExecutorTests {
    @Test
    func serializesDirectoryAliasesAcrossExecutors() async throws {
        let fixture = try BuildFixture()
        defer { fixture.remove() }
        let real = fixture.root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("alias"),
            withDestinationURL: real
        )
        let executors = [shellExecutor(), shellExecutor()]
        let paths = [real.appendingPathComponent("DerivedData").path, "alias/DerivedData", "real/./DerivedData/"]

        try await withThrowingTaskGroup(of: Int32.self) { group in
            for index in 0 ..< 12 {
                group.addTask {
                    try await executors[index % 2].execute(
                        command: [
                            "mkdir lock || exit 42; sleep 0.05; rmdir lock",
                            "-derivedDataPath", "unused-\(index)", "-derivedDataPath", paths[index % paths.count]
                        ],
                        workingDirectory: fixture.root
                    )
                }
            }
            for try await status in group {
                #expect(status == 0)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("lock").path))
    }

    @Test
    func allowsIndependentDirectoriesToBuildConcurrently() async throws {
        let fixture = try BuildFixture()
        defer { fixture.remove() }
        let executor = shellExecutor()
        let running = Task {
            try await executor.execute(command: fixture.longBuild, workingDirectory: fixture.root)
        }
        defer { running.cancel() }
        try await fixture.waitForStart()

        let status = try await executor.execute(
            command: ["exit 0", "-derivedDataPath", "OtherData"], workingDirectory: fixture.root
        )
        #expect(status == 0)
        try fixture.expectRunning()
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        try fixture.expectTerminated()
    }

    @Test
    func cancelsQueuedBuildWithoutWaitingForRunningBuild() async throws {
        let fixture = try BuildFixture()
        defer { fixture.remove() }
        let executor = shellExecutor()
        let running = Task {
            try await executor.execute(command: fixture.longBuild, workingDirectory: fixture.root)
        }
        defer { running.cancel() }
        try await fixture.waitForStart()

        let queued = Task {
            try await executor.execute(command: fixture.command("touch unexpected"), workingDirectory: fixture.root)
        }
        // Let the request reach the executor before cancellation.
        try await Task.sleep(for: .milliseconds(50))
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        try fixture.expectRunning()
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("unexpected").path))

        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        let status = try await executor.execute(command: fixture.command("exit 0"), workingDirectory: fixture.root)
        #expect(status == 0)
    }

    @Test
    func drainsCancellationOutputBeforeStartingNextBuild() async throws {
        let fixture = try BuildFixture()
        defer { fixture.remove() }
        let output = BuildOutput()
        let executor = shellExecutor()
        let running = Task {
            try await executor.execute(
                command: fixture.longBuild, workingDirectory: fixture.root, outputHandler: output
            )
        }
        defer { running.cancel() }
        try await fixture.waitForStart()
        let nextExecutor = shellExecutor()
        let next = Task {
            try await nextExecutor.execute(
                command: fixture.command("test -f terminated"), workingDirectory: fixture.root
            )
        }
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(try await next.value == 0)
        try fixture.expectTerminated()
        #expect(await output.lines.contains("terminated stdout"))
        #expect(await output.lines.contains("terminated stderr"))
        #expect(await output.completionCount == 1)
        #expect(await output.linesAtCompletion == output.lines.count)
    }

    @Test
    func releasesDirectoryAfterLaunchAndBuildFailures() async throws {
        let fixture = try BuildFixture()
        defer { fixture.remove() }
        let invalid = XcodeBuildExecutor { _, _, _ in
            let process = Process()
            process.executableURL = fixture.root.appendingPathComponent("missing-executable")
            return process
        }
        await #expect(throws: (any Error).self) {
            try await invalid.execute(command: fixture.command(""), workingDirectory: fixture.root)
        }
        let executor = shellExecutor()
        #expect(try await executor.execute(command: fixture.command("exit 7"), workingDirectory: fixture.root) == 7)
        #expect(try await executor.execute(command: fixture.command("exit 0"), workingDirectory: fixture.root) == 0)
    }

    @Test
    func preservesEnvironmentDirectoryAndAllOutput() async throws {
        let fixture = try BuildFixture()
        defer { fixture.remove() }
        let output = BuildOutput()
        let script = """
        test "$VALUE" = 'custom value' || exit 41
        test -f marker || exit 42
        i=0
        while [ "$i" -lt 4000 ]; do
          printf 'out-%s\n' "$i"
          printf 'err-%s\n' "$i" >&2
          i=$((i+1))
        done
        printf 'last stdout'
        printf 'last stderr' >&2
        exit 7
        """
        try Data().write(to: fixture.root.appendingPathComponent("marker"))
        let status = try await shellExecutor().execute(
            command: fixture.command(script),
            environment: ["VALUE": "custom value"],
            workingDirectory: fixture.root,
            outputHandler: output
        )
        #expect(status == 7)
        #expect(await output.lines.count == 8002)
        #expect(await output.lines.contains("last stdout"))
        #expect(await output.lines.contains("last stderr"))
        #expect(await output.linesAtCompletion == 8002)
        #expect(await output.completionCount == 1)
        #expect(await output.exitCode == 7)
    }

    @Test
    func shutdownCancelsOwnedBuildsAndLeavesOtherExecutorsUsable() async throws {
        let fixture = try BuildFixture()
        defer { fixture.remove() }
        let executor = shellExecutor()
        let running = Task {
            try await executor.execute(command: fixture.longBuild, workingDirectory: fixture.root)
        }
        defer { running.cancel() }
        try await fixture.waitForStart()
        let queued = Task {
            try await executor.execute(command: fixture.command("touch unexpected"), workingDirectory: fixture.root)
        }
        let other = shellExecutor()
        let otherBuild = Task {
            try await other.execute(command: fixture.command("test -f terminated"), workingDirectory: fixture.root)
        }
        await executor.shutdown()
        await #expect(throws: CancellationError.self) { try await running.value }
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(try await otherBuild.value == 0)
        try fixture.expectTerminated()
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("unexpected").path))
        await #expect(throws: CancellationError.self) {
            try await executor.execute(command: fixture.command("touch unexpected"), workingDirectory: fixture.root)
        }
    }

    @Test
    func rejectsBuildsWithoutDerivedDataPath() async throws {
        let fixture = try BuildFixture()
        defer { fixture.remove() }
        let executor = shellExecutor()
        for arguments in [[], ["-derivedDataPath"], ["-derivedDataPath", ""]] {
            await #expect(throws: XcodeProjectError.self) {
                try await executor.execute(command: ["touch unexpected"] + arguments, workingDirectory: fixture.root)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("unexpected").path))
    }
}

private func shellExecutor() -> XcodeBuildExecutor {
    XcodeBuildExecutor { command, directory, environment in
        ProcessExecutor.createProcess(
            executable: "/bin/sh",
            arguments: ["-c", command[0]],
            workingDirectory: directory,
            environment: environment
        )
    }
}

private actor BuildOutput: ProcessOutputHandler {
    var lines: [String] = []
    var linesAtCompletion = 0
    var completionCount = 0
    var exitCode: Int32?

    func handleProcess(output: FileHandle, error: FileHandle) async {
        await withTaskGroup(of: Void.self) { group in
            for handle in [output, error] {
                group.addTask {
                    await StreamingFileHandleReader.streamPipe(handle) { await self.append($0) }
                }
            }
        }
    }

    private func append(_ line: String) {
        lines.append(line)
    }

    func handleCompletion(_ exitCode: Int32) {
        linesAtCompletion = lines.count
        completionCount += 1
        self.exitCode = exitCode
    }
}

private struct BuildFixture: Sendable {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BSP Executor \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func command(_ script: String) -> [String] {
        [script, "-derivedDataPath", "DerivedData"]
    }

    var longBuild: [String] {
        command("""
        trap '
          kill "$child" 2>/dev/null
          wait "$child" 2>/dev/null
          touch terminated
          printf "terminated stdout\n"
          printf "terminated stderr\n" >&2
          exit 0
        ' TERM
        sleep 30 &
        child=$!
        printf '%s' "$$" > pid
        wait "$child"
        """)
    }

    func waitForStart() async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        let file = root.appendingPathComponent("pid")
        while ContinuousClock.now < deadline {
            if let value = try? String(contentsOf: file, encoding: .utf8), Int32(value) != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "BuildFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Process did not start"])
    }

    func expectRunning() throws {
        let pid = try #require(Int32(String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8)))
        #expect(kill(pid, 0) == 0)
    }

    func expectTerminated() throws {
        let pid = try #require(Int32(String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8)))
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("terminated").path))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
