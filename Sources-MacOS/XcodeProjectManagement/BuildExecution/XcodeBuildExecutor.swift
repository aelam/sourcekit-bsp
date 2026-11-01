import Foundation

/// Runs build processes and owns their cancellation and output lifetimes.
actor XcodeBuildExecutor {
    typealias ProcessFactory = @Sendable ([String], URL, [String: String]) async throws -> Process

    private let processFactory: ProcessFactory
    private let scheduler: XcodeBuildScheduler
    private var builds: [UUID: Task<XcodeBuildExitCode, Error>] = [:]
    private var isShutdown = false

    init(toolchain: XcodeToolchain) {
        self.processFactory = { command, directory, environment in
            try await toolchain.createXcodeBuildProcess(
                arguments: command, workingDirectory: directory, xcodeBuildEnvironments: environment
            )
        }
        self.scheduler = .shared
    }

    init(scheduler: XcodeBuildScheduler = .shared, processFactory: @escaping ProcessFactory) {
        self.processFactory = processFactory
        self.scheduler = scheduler
    }

    func execute(
        command: [String],
        environment: [String: String] = [:],
        workingDirectory: URL,
        outputHandler: ProcessOutputHandler? = nil
    ) async throws -> XcodeBuildExitCode {
        try Task.checkCancellation()
        guard !isShutdown else { throw CancellationError() }
        let directory = try derivedDataDirectory(command: command, workingDirectory: workingDirectory)
        let id = UUID()
        let build = Task {
            try await scheduler.withBuild(in: directory) {
                let process = try await self.processFactory(command, workingDirectory, environment)
                return try await Self.run(process, outputHandler: outputHandler ?? DefaultOutputHandler())
            }
        }
        builds[id] = build
        defer { builds[id] = nil }
        return try await withTaskCancellationHandler {
            try await build.value
        } onCancel: {
            build.cancel()
        }
    }

    func shutdown() async {
        isShutdown = true
        let pending = Array(builds.values)
        for build in pending {
            build.cancel()
        }
        for build in pending {
            _ = await build.result
        }
    }

    private func derivedDataDirectory(command: [String], workingDirectory: URL) throws -> URL {
        guard let flag = command.lastIndex(of: "-derivedDataPath"),
              command.indices.contains(flag + 1), !command[flag + 1].isEmpty else {
            throw XcodeProjectError.invalidConfig("Build commands require an explicit -derivedDataPath")
        }
        let base = URL(fileURLWithPath: workingDirectory.path, isDirectory: true)
        return URL(fileURLWithPath: command[flag + 1], isDirectory: true, relativeTo: base).absoluteURL
    }

    private static func run(
        _ process: Process, outputHandler: ProcessOutputHandler
    ) async throws -> XcodeBuildExitCode {
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        defer {
            process.terminationHandler = nil
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
        }

        let exits = AsyncStream<Int32> { continuation in
            process.terminationHandler = { process in
                continuation.yield(process.terminationStatus)
                continuation.finish()
            }
        }
        try Task.checkCancellation()
        try process.run()

        // Keep draining both pipes after cancellation, until the process exits and closes them.
        let completion = Task {
            async let output: Void = outputHandler.handleProcess(
                output: outputPipe.fileHandleForReading, error: errorPipe.fileHandleForReading
            )
            for await _ in exits {}
            await output
            let status = process.terminationStatus
            await outputHandler.handleCompletion(status)
            return status
        }
        let status = await withTaskCancellationHandler {
            if Task.isCancelled, process.isRunning { process.terminate() }
            return await completion.value
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        return status
    }
}
