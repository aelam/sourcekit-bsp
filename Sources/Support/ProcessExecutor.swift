//
//  ProcessExecutor.swift
//
//  Copyright © 2024 Wang Lun.
//

import Foundation
import Logger

public struct ProcessExecutionResult: Sendable {
    public let output: String
    public let error: String?
    public let exitCode: Int32

    public var isSuccess: Bool {
        exitCode == 0
    }

    public init(output: String, error: String?, exitCode: Int32) {
        self.output = output
        self.error = error
        self.exitCode = exitCode
    }
}

/// Progress callback for real-time process output
typealias ProcessProgress = @Sendable (ProcessProgressEvent) async -> Void

/// Events that can be reported during process execution
enum ProcessProgressEvent {
    case outputLine(String)
    case errorLine(String)
}

public enum ProcessExecutorError: Error, LocalizedError, Equatable {
    case processStartFailed(String) // System error message
    case timeout(TimeInterval)

    public var isTimeout: Bool {
        if case .timeout = self { return true }
        return false
    }
}

/// Helper actor to accumulate results in thread-safe manner
private actor ProcessOutputAccumulator {
    private var outputBuffer = ""
    private var errorBuffer = ""

    func append(event: ProcessProgressEvent) {
        switch event {
        case let .outputLine(data):
            outputBuffer += data
        case let .errorLine(data):
            errorBuffer += data
        }
    }

    func getResult(exitCode: Int32) -> ProcessExecutionResult {
        ProcessExecutionResult(
            output: outputBuffer,
            error: errorBuffer.isEmpty ? nil : errorBuffer,
            exitCode: exitCode
        )
    }
}

public actor ProcessExecutor {
    public static func createProcess(
        executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:]
    ) -> Process {
        let process = Process()

        var environmentOverrides = ProcessInfo.processInfo.environment
        // Set environment
        if !environment.isEmpty {
            environmentOverrides.merge(environment) { _, new in new }
        }
        process.environment = environmentOverrides

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        // Set working directory
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        // Setup pipes
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        return process
    }

    public init() {}

    /// Execute process with streaming output support
    /// For large data streams, use executeWithProgress to avoid memory accumulation
    public func execute(
        executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) async throws -> ProcessExecutionResult {
        let result = ProcessOutputAccumulator()

        let exitCode = try await executeWithProgressInternal(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            timeout: timeout
        ) { event in
            await result.append(event: event)
        }

        return await result.getResult(exitCode: exitCode)
    }

    /// Internal method that returns raw exit code
    private func executeWithProgressInternal(
        executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:],
        timeout: TimeInterval? = nil,
        progress: ProcessProgress? = nil
    ) async throws -> Int32 {
        logger.debug("\(executable) \(arguments.joined(separator: " "))")

        let process = Self.createProcess(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment
        )

        // Start process
        do {
            try process.run()
            logger.debug("Process started successfully")
        } catch {
            throw ProcessExecutorError.processStartFailed(error.localizedDescription)
        }

        let startTime = Date()

        // Handle timeout if specified
        let exitCode: Int32
        if let timeout {
            do {
                exitCode = try await withTimeout(timeout) {
                    try await self.streamProcessOutput(
                        process: process,
                        progress: progress
                    )
                }
            } catch {
                // On timeout (or cancellation) the Swift task is cancelled but
                // the underlying OS process keeps running — terminate it so we
                // don't leak wedged children (e.g. a hung `simctl install`,
                // which otherwise piles up and blocks the whole BSP channel).
                if process.isRunning { process.terminate() }
                throw error
            }
        } else {
            exitCode = try await streamProcessOutput(
                process: process,
                progress: progress
            )
        }

        logger.debug(
            "Command completed - exit code: \(exitCode), duration: \(Date().timeIntervalSince(startTime))"
        )

        if exitCode != 0 {
            logger.error("Command failed with exit code \(exitCode)")
        }

        return exitCode
    }

    private func streamProcessOutput(
        process: Process,
        progress: ProcessProgress?
    ) async throws -> Int32 {
        guard
            let outputPipe = process.standardOutput as? Pipe,
            let errorPipe = process.standardError as? Pipe
        else {
            return 1
        }

        await withTaskGroup(of: Void.self) { group in
            // 启动 stdout 读取任务
            group.addTask {
                await self.streamPipeAsync(
                    outputPipe.fileHandleForReading,
                    isError: false,
                    progress: progress
                )
            }

            // 启动 stderr 读取任务
            group.addTask {
                await self.streamPipeAsync(
                    errorPipe.fileHandleForReading,
                    isError: true,
                    progress: progress
                )
            }
        }

        await Task {
            process.waitUntilExit()
        }.value

        return process.terminationStatus
    }

    private func streamPipeAsync(
        _ fileHandle: FileHandle,
        isError: Bool,
        progress: ProcessProgress?
    ) async {
        logger.debug("Starting to read from \(isError ? "error" : "output") pipe")

        await StreamingFileHandleReader.streamPipe(fileHandle) { line in
            let event: ProcessProgressEvent = isError ? .errorLine(line + "\n") : .outputLine(line + "\n")
            await progress?(event)
            logger.debug("Finished reading from \(isError ? "error" : "output") pipe")
        }
    }

    private func withTimeout<T: Sendable>(
        _ timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ProcessExecutorError.timeout(timeout)
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
