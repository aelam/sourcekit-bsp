import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

struct SwiftPMCommandResult: Sendable {
    let standardOutput: Data
    let standardError: Data
    let exitCode: Int32
}

protocol SwiftPMCommandExecuting: Sendable {
    func execute(executable: URL, arguments: [String], workingDirectory: URL) async throws -> SwiftPMCommandResult
    func execute(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        outputHandler: (@Sendable (String) -> Void)?
    ) async throws -> SwiftPMCommandResult
}

extension SwiftPMCommandExecuting {
    func execute(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        outputHandler: (@Sendable (String) -> Void)?
    ) async throws -> SwiftPMCommandResult {
        let result = try await execute(executable: executable, arguments: arguments, workingDirectory: workingDirectory)
        if !result.standardOutput.isEmpty { outputHandler?(swiftPMOutputText(result.standardOutput)) }
        if !result.standardError.isEmpty { outputHandler?(swiftPMOutputText(result.standardError)) }
        return result
    }
}

struct SwiftPMProcessExecutor: SwiftPMCommandExecuting {
    func execute(executable: URL, arguments: [String], workingDirectory: URL) async throws -> SwiftPMCommandResult {
        try await execute(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: [:],
            outputHandler: nil
        )
    }

    func execute(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        outputHandler: (@Sendable (String) -> Void)?
    ) async throws -> SwiftPMCommandResult {
        let invocation = ProcessInvocation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try continuation.resume(
                            returning: invocation.run(
                                executable: executable,
                                arguments: arguments,
                                workingDirectory: workingDirectory,
                                environment: environment,
                                outputHandler: outputHandler
                            )
                        )
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            invocation.cancel()
        }
    }
}

/// The lock protects process launch and cancellation. Waiting occurs on a Dispatch worker.
private final class ProcessInvocation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private let cancellationFinished = DispatchGroup()

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        guard let process, process.isRunning else { return }
        cancellationFinished.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { self.cancellationFinished.leave() }
            self.cancelProcessTree(process)
        }
    }

    private func cancelProcessTree(_ child: Process) {
        #if os(Linux) || os(macOS)
        var descendants = Set<CommandProcessIdentity>()
        let gracefulDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        let cleanupDeadline = gracefulDeadline.advanced(by: .seconds(3))
        repeat {
            if child.isRunning {
                descendants.formUnion(CommandProcessIdentity.descendants(of: child.processIdentifier))
            }
            let remaining = descendants.filter(\.isCurrent)
            if remaining.isEmpty { break }
            let signal = ContinuousClock.now < gracefulDeadline ? SIGTERM : SIGKILL
            for descendant in remaining {
                descendant.send(signal)
            }
            // Keep SwiftPM alive so that it can reap its manifest and compiler processes.
            Thread.sleep(forTimeInterval: 0.02)
        } while ContinuousClock.now < cleanupDeadline
        #endif

        lock.lock()
        if child.isRunning { child.interrupt() }
        lock.unlock()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while child.isRunning, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        lock.lock()
        defer { lock.unlock() }
        if child.isRunning {
            #if os(Linux) || os(macOS)
            _ = kill(child.processIdentifier, SIGKILL)
            #else
            child.terminate()
            #endif
        }
    }

    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        outputHandler: (@Sendable (String) -> Void)?
    ) throws -> SwiftPMCommandResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sourcekit-bsp-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        try Data().write(to: outputURL)
        try Data().write(to: errorURL)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let errorOutput = try FileHandle(forWritingTo: errorURL)
        defer { try? errorOutput.close() }
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = workingDirectory
        child.environment = ProcessInfo.processInfo.environment.merging(environment) { _, value in value }
        child.standardInput = FileHandle.nullDevice
        // Files keep both output streams draining without pipe limits or cooperative-thread waits.
        child.standardOutput = output
        child.standardError = errorOutput
        let outputReader = try FileHandle(forReadingFrom: outputURL)
        let errorReader = try FileHandle(forReadingFrom: errorURL)
        defer { try? outputReader.close(); try? errorReader.close() }
        var outputBuffer = Data()
        var errorBuffer = Data()
        func drain(_ handle: FileHandle, buffer: inout Data, final: Bool = false) {
            buffer.append(handle.availableData)
            while let end = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(through: end)
                outputHandler?(swiftPMOutputText(Data(line)))
                buffer.removeSubrange(...end)
            }
            if final, !buffer.isEmpty {
                outputHandler?(swiftPMOutputText(buffer))
                buffer.removeAll()
            }
        }
        try launch(child)
        if outputHandler != nil {
            while child.isRunning {
                drain(outputReader, buffer: &outputBuffer)
                drain(errorReader, buffer: &errorBuffer)
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        child.waitUntilExit()
        if outputHandler != nil {
            drain(outputReader, buffer: &outputBuffer, final: true)
            drain(errorReader, buffer: &errorBuffer, final: true)
        }
        lock.lock()
        process = nil
        let wasCancelled = cancelled
        lock.unlock()
        cancellationFinished.wait()
        if wasCancelled { throw CancellationError() }
        return try SwiftPMCommandResult(
            standardOutput: Data(contentsOf: outputURL),
            standardError: Data(contentsOf: errorURL),
            exitCode: child.terminationStatus
        )
    }

    private func launch(_ child: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        do {
            #if os(Linux)
            // Foundation 6.1 inherits the Dispatch worker's blocked signals on Linux.
            // Restore the worker's mask after spawning, including when Process.run throws.
            var signals = sigset_t()
            sigemptyset(&signals)
            sigaddset(&signals, SIGINT)
            sigaddset(&signals, SIGTERM)
            var previousMask = sigset_t()
            let status = pthread_sigmask(SIG_UNBLOCK, &signals, &previousMask)
            guard status == 0 else {
                throw SwiftPMProjectError.launchFailed("Cannot unblock process cancellation signals (error \(status)).")
            }
            defer { pthread_sigmask(SIG_SETMASK, &previousMask, nil) }
            #endif
            try child.run()
            process = child
        } catch {
            throw SwiftPMProjectError.launchFailed(
                "\(child.executableURL?.path ?? "swift"): \(error.localizedDescription)"
            )
        }
    }
}

#if os(Linux) || os(macOS)
/// A start time prevents cancellation from signalling a process that reused a PID.
private struct CommandProcessIdentity: Hashable {
    let pid: Int32
    let startTime: String

    var isCurrent: Bool {
        Self.read(pid) == self
    }

    func send(_ signal: Int32) {
        if isCurrent { _ = kill(pid, signal) }
    }

    static func descendants(of parent: Int32) -> Set<Self> {
        var result = Set<Self>()
        var pending = [parent]
        var visited: Set<Int32> = [parent]
        while let pid = pending.popLast() {
            for child in children(of: pid) where visited.insert(child).inserted {
                if let identity = read(child) {
                    result.insert(identity)
                    pending.append(child)
                }
            }
        }
        return result
    }

    private static func read(_ pid: Int32) -> Self? {
        #if os(Linux)
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let end = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: end)...].split(separator: " ")
        // Field 22 is the start time; the suffix begins at field 3, after the process name.
        guard fields.count > 19 else { return nil }
        return Self(pid: pid, startTime: String(fields[19]))
        #else
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Self(pid: pid, startTime: "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)")
        #endif
    }

    private static func children(of pid: Int32) -> [Int32] {
        #if os(Linux)
        let taskDirectory = "/proc/\(pid)/task"
        // SwiftPM can spawn a child from any worker thread, not only its main thread.
        let threads = (try? FileManager.default.contentsOfDirectory(atPath: taskDirectory)) ?? []
        return threads.flatMap { thread -> [Int32] in
            guard let children = try? String(
                contentsOfFile: "\(taskDirectory)/\(thread)/children", encoding: .utf8
            ) else { return [] }
            return children.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        }
        #else
        let estimatedCount = proc_listchildpids(pid, nil, 0)
        guard estimatedCount > 0 else { return [] }
        // Leave space for children created between the size query and the second call.
        var buffer = [Int32](repeating: 0, count: Int(estimatedCount) + 16)
        let capacity = Int32(buffer.count * MemoryLayout<Int32>.stride)
        let count = buffer.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, capacity) }
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count))).filter { $0 > 0 }
        #endif
    }
}
#endif

func swiftPMOutputText(_ data: Data) -> String {
    // Preserve diagnostics when a process writes invalid UTF-8.
    // swiftlint:disable:next optional_data_string_conversion
    String(decoding: data, as: UTF8.self)
}
