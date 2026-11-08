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
        let holder = try fixture.holdExternalLock()
        defer { if holder.process.isRunning { holder.process.terminate() } }
        try await fixture.waitForFile("acquired")
        let scheduler = XcodeBuildScheduler(lockDirectory: fixture.locks)
        let pending = Task {
            try Data().write(to: fixture.root.appendingPathComponent("waiting"))
            return try await scheduler.withBuild(in: fixture.derivedData) {
                try Data().write(to: fixture.root.appendingPathComponent("unexpected"))
                return 0
            }
        }
        try await fixture.waitForFile("waiting")
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("unexpected").path))
        #expect(try await fixture.tryExternalLock() == 42)
        try Data().write(to: fixture.root.appendingPathComponent("release"))
        #expect(await holder.exit.value == 0)
        #expect(try await scheduler.withBuild(in: fixture.derivedData) { 7 } == 7)
        #expect(try await fixture.tryExternalLock() == 0)
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
    enum Failure: Error { case expected, timeout }
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
            executable: "/usr/bin/python3", arguments: ["-c", script, lockFile.path]
        ).exitCode
    }

    func holdExternalLock() throws -> ExternalLockProcess {
        let script = """
        import fcntl, pathlib, sys, time
        with open(sys.argv[1], 'a+b') as file:
            fcntl.flock(file, fcntl.LOCK_EX)
            pathlib.Path(sys.argv[2]).touch()
            while not pathlib.Path(sys.argv[3]).exists():
                time.sleep(0.01)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            script,
            lockFile.path,
            root.appendingPathComponent("acquired").path,
            root.appendingPathComponent("release").path
        ]
        process.standardInput = FileHandle.nullDevice
        let exits = AsyncStream<Int32> { continuation in
            process.terminationHandler = { process in
                continuation.yield(process.terminationStatus)
                continuation.finish()
            }
        }
        try process.run()
        return ExternalLockProcess(process: process, exit: Task {
            for await status in exits {
                return status
            }
            return -1
        })
    }

    func waitForFile(_ name: String) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct ExternalLockProcess {
    let process: Process
    let exit: Task<Int32, Never>
}
