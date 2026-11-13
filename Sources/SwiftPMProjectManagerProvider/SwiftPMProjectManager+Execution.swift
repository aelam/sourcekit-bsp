import Foundation
import SourceKitBSPProtocol

public extension SwiftPMProjectManager {
    func startBuild(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        logHandler: (@Sendable (String) -> Void)?
    ) async throws -> StatusCode {
        let options = try buildOptions(arguments)
        guard !targetIdentifiers.isEmpty else {
            throw SwiftPMProjectError.invalidArguments("Select at least one build target.")
        }
        let targets = try targetIdentifiers.map { try executionTarget($0) }
        var built = Set<BSPBuildTargetIdentifier>()
        var builtTests = false
        for target in targets where built.insert(target.id).inserted {
            if testModules[target.id] != nil {
                if builtTests { continue }
                builtTests = true
            }
            let selection: [String] = if let product = executableTargets[target.id] {
                ["--product", product]
            } else if testModules[target.id] != nil {
                ["--build-tests"]
            } else {
                ["--target", target.displayName!]
            }
            let result = try await executeCommand(
                executable: commandExecutable,
                arguments: ["build", "--package-path", rootURL.path] + options + selection,
                outputHandler: logHandler
            )
            if result.exitCode != 0 { return .error }
            let outputTargets = testModules[target.id] == nil ? [target.id] : project?.targets.map(\.id) ?? []
            recordOutputArguments(options, for: outputTargets)
        }
        return .ok
    }

    func run(
        targetIdentifier: BSPBuildTargetIdentifier,
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?
    ) async throws -> StatusCode {
        try await run(
            targetIdentifier: targetIdentifier,
            arguments: arguments,
            environmentVariables: environmentVariables,
            workingDirectory: workingDirectory,
            progressHandler: nil
        )
    }

    func run(
        targetIdentifier: BSPBuildTargetIdentifier,
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        progressHandler: (@Sendable (String) async -> Void)?
    ) async throws -> StatusCode {
        let program = try await builtExecutable(for: targetIdentifier, arguments: arguments)
        return try await runExecutable(
            program,
            arguments: [],
            environmentVariables: environmentVariables,
            workingDirectory: workingDirectory,
            progressHandler: progressHandler
        )
    }

    internal func runExecutable(
        _ program: URL,
        arguments: [String],
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        progressHandler: (@Sendable (String) async -> Void)?
    )
        async throws -> StatusCode {
        let directory: URL
        if let workingDirectory {
            guard let url = workingDirectory.fileURL else {
                throw SwiftPMProjectError.invalidArguments("The working directory must be a file URI.")
            }
            directory = url
        } else {
            directory = rootURL
        }
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let reporter = Task {
            for await output in stream {
                await progressHandler?(output)
            }
        }
        do {
            let result = try await executeCommand(
                executable: program,
                arguments: arguments,
                workingDirectory: directory,
                environment: environmentVariables ?? [:]
            ) { continuation.yield($0) }
            continuation.finish()
            await reporter.value
            return result.exitCode == 0 ? .ok : .error
        } catch {
            continuation.finish()
            await reporter.value
            throw error
        }
    }

    func startDebugSession(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        logHandler: (@Sendable (String) -> Void)?,
        progressHandler: (@Sendable (String) async -> Void)?
    ) async throws -> DebugSessionConnection {
        guard targetIdentifiers.count == 1, let target = targetIdentifiers.first else {
            throw SwiftPMProjectError.invalidArguments("Select one executable or root test target to debug.")
        }
        guard debugAdapter != nil else { throw SwiftPMProjectError.unsupported("debug sessions on this host") }
        let launch: SwiftPMDebugLaunch
        if testModules[target] != nil {
            await progressHandler?("Finding the built test bundle")
            launch = try await testDebugLaunch(for: target, arguments: arguments, logHandler: logHandler)
        } else {
            launch = try await SwiftPMDebugLaunch(program: builtExecutable(for: target, arguments: arguments))
        }
        return try await startDebugLaunch(launch, progressHandler: progressHandler)
    }

    internal func startDebugLaunch(
        _ launch: SwiftPMDebugLaunch,
        progressHandler: (@Sendable (String) async -> Void)?
    )
        async throws -> DebugSessionConnection {
        guard let debugAdapter else { throw SwiftPMProjectError.unsupported("debug sessions on this host") }
        await progressHandler?("Starting the debug adapter for \(launch.program.lastPathComponent)")
        try Task.checkCancellation()
        guard !isShutDown else { throw SwiftPMProjectError.shutDown }
        let id = UUID()
        let task = Task {
            let endpoint = try await debugAdapter.start()
            do {
                try Task.checkCancellation()
                guard !isShutDown else { throw SwiftPMProjectError.shutDown }
                debugEndpoints[id] = endpoint
                return DebugSessionConnection(
                    uri: endpoint.uri,
                    request: .launch,
                    program: launch.program.path,
                    args: launch.arguments,
                    env: launch.environment,
                    cwd: launch.workingDirectory
                )
            } catch {
                endpoint.terminate()
                throw error
            }
        }
        debugStartupTasks[id] = task
        defer { debugStartupTasks[id] = nil }
        do {
            return try await withTaskCancellationHandler {
                let connection = try await task.value
                try Task.checkCancellation()
                guard !isShutDown else { throw SwiftPMProjectError.shutDown }
                return connection
            } onCancel: {
                task.cancel()
            }
        } catch {
            debugEndpoints.removeValue(forKey: id)?.terminate()
            throw error
        }
    }

    internal func executionTarget(_ identifier: BSPBuildTargetIdentifier) throws -> BSPBuildTarget {
        guard !isShutDown else { throw SwiftPMProjectError.shutDown }
        guard let project else { throw SwiftPMProjectError.notInitialized }
        guard let target = project.target(for: identifier) else {
            throw SwiftPMProjectError.unknownTarget(identifier.uri.stringValue)
        }
        guard target.capabilities.canCompile == true, target.displayName != nil else {
            throw SwiftPMProjectError.unsupported("building dependency targets outside the root package")
        }
        return target
    }

    internal func builtExecutable(for identifier: BSPBuildTargetIdentifier, arguments: [String]?) async throws -> URL {
        _ = try executionTarget(identifier)
        guard let product = executableTargets[identifier] else {
            throw SwiftPMProjectError.invalidArguments("Select a target with one executable product.")
        }
        let directory = try await binaryDirectory(arguments: arguments)
        #if os(Windows)
        let file = product + ".exe"
        #else
        let file = product
        #endif
        let program = directory.appendingPathComponent(file)
        guard FileManager.default.isExecutableFile(atPath: program.path) else {
            throw SwiftPMProjectError.productNotBuilt(program.path)
        }
        return program
    }

    internal func binaryDirectory(arguments: [String]?) async throws -> URL {
        let options = try buildOptions(arguments)
        let command = ["build", "--package-path", rootURL.path] + options + ["--show-bin-path"]
        let result = try await executeCommand(executable: commandExecutable, arguments: command)
        guard result.exitCode == 0 else {
            throw SwiftPMProjectError.commandFailed(
                command: command.joined(separator: " "),
                status: result.exitCode,
                output: swiftPMOutputText(result.standardError)
            )
        }
        let path = swiftPMOutputText(result.standardOutput)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (path as NSString).isAbsolutePath, !path.contains("\n") else {
            throw SwiftPMProjectError.invalidMetadata(
                package: rootURL.path,
                details: "SwiftPM returned no binary path."
            )
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    internal func buildOptions(_ arguments: [String]?) throws -> [String] {
        let arguments = arguments ?? []
        let controlled: Set = [
            "--package-path", "--target", "--product", "--build-tests", "--show-bin-path", "--help", "-help", "-h",
            "--version",
            "--"
        ]
        let values: Set = [
            "--configuration", "-c", "--scratch-path", "--cache-path", "--config-path", "--security-path",
            "--sdk", "--triple", "--swift-sdk", "--toolchain", "--arch", "--jobs", "-j",
            "-Xswiftc", "-Xcc", "-Xcxx", "-Xlinker", "-Xmanifest", "--build-system"
        ]
        var index = 0
        while index < arguments.count {
            let option = String(arguments[index].split(separator: "=", maxSplits: 1).first ?? "")
            guard !controlled.contains(option) else {
                throw SwiftPMProjectError.invalidArguments("The BSP target controls \(option).")
            }
            if values.contains(option), !arguments[index].contains("=") { index += 1 }
            index += 1
        }
        return arguments
    }

    internal func executeCommand(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:],
        outputHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> SwiftPMCommandResult {
        guard !isShutDown else { throw SwiftPMProjectError.shutDown }
        try Task.checkCancellation()
        let executor = commandExecutor
        let directory = workingDirectory ?? rootURL
        let task = Task {
            try await executor.execute(
                executable: executable,
                arguments: arguments,
                workingDirectory: directory,
                environment: environment,
                outputHandler: outputHandler
            )
        }
        let id = UUID()
        executionTasks[id] = task
        defer { executionTasks[id] = nil }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            guard !isShutDown else { throw SwiftPMProjectError.shutDown }
            return result
        } onCancel: {
            task.cancel()
        }
    }
}
