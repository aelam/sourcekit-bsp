import Foundation
import Support
import Testing
@testable import XcodeProjectManagement

struct XcodeBuildFileLockTests {
    @Test
    func excludesAnotherProcessAndReleasesAfterTheOperation() async throws {
        let fixture = try FileLockFixture()
        defer { fixture.remove() }
        let scheduler = XcodeBuildScheduler(lockDirectory: fixture.locks)
        let status = try await scheduler.withBuild(in: fixture.derivedData) {
            try await fixture.tryExternalLock()
        }
        #expect(status == 42)
        #expect(try await fixture.tryExternalLock() == 0)
    }

    @Test
    func cancellationWhileAnotherProcessHoldsTheLockLeavesItHeld() async throws {
        let fixture = try FileLockFixture()
        defer { fixture.remove() }
        try await fixture.withExternalLock { holder in
            let scheduler = XcodeBuildScheduler(lockDirectory: fixture.locks)
            let started = AsyncStream<Void>.makeStream()
            let pending = Task {
                started.continuation.yield(())
                started.continuation.finish()
                return try await scheduler.withBuild(in: fixture.derivedData) {
                    try Data().write(to: fixture.root.appendingPathComponent("unexpected"))
                    return 0
                }
            }
            defer { pending.cancel() }
            for await _ in started.stream {
                break
            }
            pending.cancel()
            await #expect(throws: CancellationError.self) { try await pending.value }
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("unexpected").path))
            #expect(try await fixture.tryExternalLock() == 42)
            try holder.release()
            #expect(await holder.exit.value == 0)
            #expect(try await scheduler.withBuild(in: fixture.derivedData) { 7 } == 7)
            #expect(try await fixture.tryExternalLock() == 0)
        }
    }

    @Test
    func reportsExternalLockStartupFailure() async throws {
        let fixture = try FileLockFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.lockFile, withIntermediateDirectories: true)
        await #expect(throws: FileLockFixture.Failure.helperExited(1)) {
            try await fixture.withExternalLock { _ in
                Issue.record("The lock helper must report a startup failure before the operation starts.")
            }
        }
    }

    @Test
    func aliasesAndCacheRemovalKeepTheSameLock() async throws {
        let fixture = try FileLockFixture()
        defer { fixture.remove() }
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.real)
        let aliasDirectory = alias.appendingPathComponent("DerivedData", isDirectory: false)
        #expect(XcodeBuildFileLock.lockFile(in: aliasDirectory, lockDirectory: fixture.locks) == fixture.lockFile)
        let scheduler = XcodeBuildScheduler(lockDirectory: fixture.locks)
        let status = try await scheduler.withBuild(in: aliasDirectory) {
            try FileManager.default.createDirectory(at: fixture.derivedData, withIntermediateDirectories: true)
            try FileManager.default.removeItem(at: fixture.derivedData)
            return try await fixture.tryExternalLock()
        }
        #expect(status == 42)
        #expect(FileManager.default.fileExists(atPath: fixture.lockFile.path))
        #expect(try await fixture.tryExternalLock() == 0)
    }

    @Test
    func operationErrorsReleaseTheLock() async throws {
        let fixture = try FileLockFixture()
        defer { fixture.remove() }
        let scheduler = XcodeBuildScheduler(lockDirectory: fixture.locks)
        await #expect(throws: FileLockFixture.Failure.self) {
            try await scheduler.withBuild(in: fixture.derivedData) { () throws -> Int in
                throw FileLockFixture.Failure.expected
            }
        }
        #expect(try await fixture.tryExternalLock() == 0)
    }

    @Test
    func settingsQueriesUseTheSameDerivedDataPathRulesAsBuilds() throws {
        let directory = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let result = try XcodeBuildScheduler.derivedDataDirectory(
            command: ["-showBuildSettings", "-derivedDataPath", "ignored", "-derivedDataPath", "build data"],
            workingDirectory: directory
        )
        #expect(result?.path == "/tmp/project/build data")
        let directoryWithoutHint = URL(fileURLWithPath: "/tmp/project", isDirectory: false)
        #expect(!directoryWithoutHint.hasDirectoryPath)
        let withoutHint = try XcodeBuildScheduler.derivedDataDirectory(
            command: ["-derivedDataPath", "build data"], workingDirectory: directoryWithoutHint
        )
        #expect(withoutHint?.path == result?.path)
        #expect(try XcodeBuildScheduler.derivedDataDirectory(command: ["-version"], workingDirectory: nil) == nil)
        let inherited = try XcodeBuildScheduler.derivedDataDirectory(
            command: ["-derivedDataPath", "build data"], workingDirectory: nil
        )
        #expect(inherited?.path == URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build data").path)
        #expect(throws: XcodeProjectError.self) {
            try XcodeBuildScheduler.derivedDataDirectory(command: ["-derivedDataPath"], workingDirectory: directory)
        }
    }
}

private struct FileLockFixture: Sendable {
    enum Failure: Error, Equatable { case expected, helperExited(Int32) }
    let root: URL
    let real: URL
    let locks: URL
    let derivedData: URL

    var lockFile: URL {
        XcodeBuildFileLock.lockFile(in: derivedData, lockDirectory: locks)
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BSP File Lock \(UUID().uuidString)")
        real = root.appendingPathComponent("real", isDirectory: true)
        locks = root.appendingPathComponent("locks", isDirectory: true)
        derivedData = real.appendingPathComponent("DerivedData", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
    }

    func tryExternalLock() async throws -> Int32 {
        let script = """
        import fcntl, os, sys
        with open(sys.argv[1], 'a+b') as file:
            try:
                fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                sys.exit(42)
        """
        return try await ProcessExecutor().execute(
            executable: "/usr/bin/python3", arguments: ["-c", script, lockFile.path], timeout: 60
        ).exitCode
    }

    func withExternalLock(_ operation: @Sendable (ExternalLockProcess) async throws -> Void) async throws {
        let holder = try holdExternalLock()
        do {
            try await holder.waitUntilAcquired()
            try await operation(holder)
            await holder.stop()
        } catch {
            await holder.stop()
            throw error
        }
    }

    private func holdExternalLock() throws -> ExternalLockProcess {
        let script = """
        import fcntl, sys
        with open(sys.argv[1], 'a+b') as file:
            fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            sys.stdout.buffer.write(bytes([1]))
            sys.stdout.buffer.flush()
            if sys.stdin.buffer.read(1) != bytes([1]):
                sys.exit(43)
        """
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, lockFile.path]
        process.standardInput = input
        process.standardOutput = output
        let watchdog = Task {
            try await Task.sleep(for: .seconds(60))
            if process.isRunning { process.terminate() }
        }
        let exits = AsyncStream<Int32> { continuation in
            process.terminationHandler = { process in
                watchdog.cancel()
                continuation.yield(process.terminationStatus)
                continuation.finish()
            }
        }
        do {
            try process.run()
        } catch {
            watchdog.cancel()
            throw error
        }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        return ExternalLockProcess(
            process: process,
            input: input.fileHandleForWriting,
            output: output.fileHandleForReading,
            watchdog: watchdog,
            exit: Task {
                for await status in exits {
                    return status
                }
                return -1
            }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct ExternalLockProcess: Sendable {
    let process: Process
    let input: FileHandle
    let output: FileHandle
    let watchdog: Task<Void, any Error>
    let exit: Task<Int32, Never>

    func waitUntilAcquired() async throws {
        // Read the readiness byte outside Swift's cooperative thread pool.
        let data: Data? = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try continuation.resume(returning: output.read(upToCount: 1))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        guard data == Data([1]) else { throw await FileLockFixture.Failure.helperExited(exit.value) }
    }

    func release() throws {
        try input.write(contentsOf: Data([1]))
        try input.close()
    }

    func stop() async {
        watchdog.cancel()
        try? input.close()
        if process.isRunning { process.terminate() }
        _ = await exit.value
        try? output.close()
    }
}
