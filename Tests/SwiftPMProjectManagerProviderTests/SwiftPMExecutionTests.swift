import BuildServerProtocol
import Foundation
import Testing
@testable import SwiftPMProjectManagerProvider

struct SwiftPMExecutionTests {
    @Test
    func buildsTheSelectedProductAndRejectsTargetOverrides() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let executor = try ActionRecorder(fixture: fixture)
        let manager = fixture.manager(executor: executor)
        try await manager.initialize()
        let app = try #require(await manager.getTargetList().first { $0.displayName == "App" })
        let logs = CapturedLines()
        let result = try await manager.startBuild(
            targetIdentifiers: [app.id, app.id], arguments: ["-c", "release"]
        ) { logs.append($0) }
        #expect(result == .ok)
        let calls = await executor.calls.filter { $0.arguments.first == "build" }
        #expect(calls.count == 1)
        #expect(calls[0].arguments == [
            "build",
            "--package-path",
            fixture.root.path,
            "-c",
            "release",
            "--product",
            "app-tool"
        ])
        #expect(logs.lines == ["  build output\n"])
        for arguments in [["--target", "Other"], ["--package-path=/tmp"], ["--help"], ["--show-bin-path"]] {
            await #expect(throws: SwiftPMProjectError.self) {
                try await manager.startBuild(targetIdentifiers: [app.id], arguments: arguments, logHandler: nil)
            }
        }
        await executor.setExitCode(1)
        #expect(try await manager.startBuild(targetIdentifiers: [app.id], arguments: nil, logHandler: nil) == .error)
    }

    @Test
    func runUsesExistingProductEnvironmentAndDirectory() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let executor = try ActionRecorder(fixture: fixture)
        let manager = fixture.manager(executor: executor)
        try await manager.initialize()
        let targets = await manager.getTargetList()
        let app = try #require(targets.first { $0.displayName == "App" })
        let core = try #require(targets.first { $0.displayName == "Core" })
        let logs = CapturedLines()
        #expect(try await manager.run(
            targetIdentifier: app.id,
            arguments: ["--configuration", "release"],
            environmentVariables: ["PROBE": "value"],
            workingDirectory: URI(fixture.directory)
        ) { logs.append($0) } == .ok)
        let calls = await executor.calls
        let launch = try #require(calls.last)
        #expect(launch.executable.lastPathComponent == "app-tool")
        #expect(launch.arguments.isEmpty)
        #expect(launch.environment == ["PROBE": "value"])
        #expect(launch.directory == fixture.directory)
        #expect(logs.lines == ["  build output\n"])
        #expect(calls.filter { $0.arguments.first == "build" }.allSatisfy { $0.arguments.contains("--show-bin-path") })
        await #expect(throws: SwiftPMProjectError.self) {
            try await manager.run(
                targetIdentifier: core.id,
                arguments: nil,
                environmentVariables: nil,
                workingDirectory: nil
            )
        }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("bin/app-tool"))
        do {
            _ = try await manager.run(
                targetIdentifier: app.id,
                arguments: nil,
                environmentVariables: nil,
                workingDirectory: nil
            )
            Issue.record("Expected a missing build product")
        } catch let SwiftPMProjectError.productNotBuilt(path) {
            #expect(path.hasSuffix("app-tool"))
        }
    }

    @Test
    func debugAdvertisesOnlyExecutablesAndStopsOnShutdown() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let executor = try ActionRecorder(fixture: fixture)
        let stops = CapturedLines()
        let manager = SwiftPMProjectManager(
            rootURL: fixture.root,
            executable: fixture.root.appendingPathComponent("swift"),
            executor: executor,
            debugAdapter: FixtureDebugAdapter(stops: stops)
        )
        try await manager.initialize()
        let targets = await manager.getTargetList()
        let app = try #require(targets.first { $0.displayName == "App" })
        #expect(app.capabilities.canDebug == true)
        #expect(targets.filter { $0.displayName != "App" }.allSatisfy { $0.capabilities.canDebug == false })
        let connection = try await manager.startDebugSession(
            targetIdentifiers: [app.id],
            arguments: nil,
            logHandler: nil,
            progressHandler: nil
        )
        #expect(connection.request == .launch)
        #expect(connection.program == fixture.root.appendingPathComponent("bin/app-tool").path)
        #expect(connection.uri == "tcp://127.0.0.1:12345")
        #expect(await executor.calls.filter { $0.arguments.first == "build" }.allSatisfy {
            $0.arguments.contains("--show-bin-path")
        })
        await manager.shutdown()
        #expect(stops.lines == ["stopped"])
        await #expect(throws: SwiftPMProjectError.self) {
            try await manager.startBuild(targetIdentifiers: [app.id], arguments: nil, logHandler: nil)
        }
    }

    @Test(.timeLimit(.minutes(2)), arguments: [[], ["-c", "release", "--scratch-path", "custom build"]])
    func buildsAndRunsARealExecutableWithADifferentProductName(buildArguments: [String]) async throws {
        let fixture = try TemporarySwiftPMPackage()
        try fixture.write("""
        // swift-tools-version: 6.1
        import PackageDescription
        let package = Package(name: "ActionProbe", products: [.executable(name: "probe-tool", targets: ["App"])],
                              targets: [.executableTarget(name: "App")])
        """, to: "Package.swift")
        try fixture.write("""
        import Foundation
        print(ProcessInfo.processInfo.environment["BSP_PROBE"] ?? "missing")
        print(FileManager.default.currentDirectoryPath)
        """, to: "Sources/App/main.swift")
        let manager = try await SwiftPMProjectManagerProvider().createProjectManager(rootURL: fixture.root, config: nil)
        try await manager.initialize()
        let app = try #require(await manager.getTargetList().first)
        let buildLogs = CapturedLines()
        #expect(try await manager.startBuild(
            targetIdentifiers: [app.id],
            arguments: buildArguments
        ) { buildLogs.append($0) } == .ok)
        #expect(!buildLogs.lines.isEmpty)
        let runLogs = CapturedLines()
        #expect(try await manager.run(
            targetIdentifier: app.id,
            arguments: buildArguments,
            environmentVariables: ["BSP_PROBE": "environment 世界 value"],
            workingDirectory: URI(fixture.directory)
        ) { runLogs.append($0) } == .ok)
        let output = runLogs.lines.joined()
        #expect(output.contains("environment 世界 value\n"))
        #expect(output.contains(fixture.directory.path + "\n"))
        await manager.shutdown()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func shutdownCancelsPendingDebugStartup(returnsEndpointAfterCancellation: Bool) async throws {
        let fixture = try TemporarySwiftPMPackage()
        let executor = try ActionRecorder(fixture: fixture)
        let stops = CapturedLines()
        let adapter = WaitingDebugAdapter(
            stops: stops,
            returnsEndpointAfterCancellation: returnsEndpointAfterCancellation
        )
        let manager = SwiftPMProjectManager(
            rootURL: fixture.root,
            executable: fixture.root.appendingPathComponent("swift"),
            executor: executor,
            debugAdapter: adapter
        )
        try await manager.initialize()
        let app = try #require(await manager.getTargetList().first { $0.displayName == "App" })
        let startup = Task {
            try await manager.startDebugSession(
                targetIdentifiers: [app.id], arguments: nil, logHandler: nil, progressHandler: nil
            )
        }
        defer { startup.cancel() }
        for _ in 0 ..< 100 {
            if await adapter.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await adapter.started)
        await manager.shutdown()
        let cancelledByShutdown = await adapter.cancelled
        startup.cancel()
        await #expect(throws: CancellationError.self) { try await startup.value }
        #expect(cancelledByShutdown)
        #expect(stops.lines == (returnsEndpointAfterCancellation ? ["stopped"] : []))
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownCancelsAnActiveBuild() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let executor = try ActionRecorder(fixture: fixture)
        let manager = fixture.manager(executor: executor)
        try await manager.initialize()
        let target = try #require(await manager.getTargetList().first)
        await executor.waitDuringBuild()
        let build = Task {
            try await manager.startBuild(targetIdentifiers: [target.id], arguments: nil, logHandler: nil)
        }
        for _ in 0 ..< 100 {
            if await executor.calls.contains(where: { $0.arguments.first == "build" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await executor.calls.contains { $0.arguments.first == "build" })
        await manager.shutdown()
        await #expect(throws: CancellationError.self) { try await build.value }
    }

    @Test(.timeLimit(.minutes(1)))
    func streamsOutputBeforeTheProcessExitsAndCancels() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let output = CapturedLines()
        let executable = try swiftExecutable(root: fixture.root)
        let command = Task {
            try await SwiftPMProcessExecutor().execute(
                executable: executable,
                arguments: [
                    "-e",
                    "import Foundation; print(\"ready\"); fflush(stdout); Thread.sleep(forTimeInterval: 60)"
                ],
                workingDirectory: fixture.root,
                environment: [:]
            ) { output.append($0) }
        }
        for _ in 0 ..< 1000 {
            if output.lines.contains("ready\n") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        command.cancel()
        #expect(output.lines.contains("ready\n"))
        await #expect(throws: CancellationError.self) { try await command.value }
    }
}

private final class CapturedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var lines: [String] {
        lock.withLock { storage }
    }

    func append(_ line: String) {
        lock.withLock { storage.append(line) }
    }
}

private struct FixtureDebugAdapter: SwiftPMDebugAdapterServing {
    let stops: CapturedLines
    func start() async throws -> SwiftPMDebugEndpoint {
        SwiftPMDebugEndpoint(uri: "tcp://127.0.0.1:12345") { stops.append("stopped") }
    }
}

private actor WaitingDebugAdapter: SwiftPMDebugAdapterServing {
    let stops: CapturedLines
    let returnsEndpointAfterCancellation: Bool
    private(set) var started = false
    private(set) var cancelled = false

    init(stops: CapturedLines, returnsEndpointAfterCancellation: Bool) {
        self.stops = stops
        self.returnsEndpointAfterCancellation = returnsEndpointAfterCancellation
    }

    func start() async throws -> SwiftPMDebugEndpoint {
        started = true
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            cancelled = true
            if !returnsEndpointAfterCancellation { throw error }
        }
        return SwiftPMDebugEndpoint(uri: "tcp://127.0.0.1:12345") { [stops] in stops.append("stopped") }
    }
}

private actor ActionRecorder: SwiftPMCommandExecuting {
    struct Call: Sendable {
        let executable: URL
        let arguments: [String]
        let directory: URL
        let environment: [String: String]
    }

    let metadata: Data
    let binDirectory: URL
    private(set) var calls: [Call] = []
    private var exitCode: Int32 = 0
    private var waitsDuringBuild = false

    init(fixture: TemporarySwiftPMPackage) throws {
        metadata = try fixture.describe(
            targets: [describedTarget("Core"), describedTarget("App", type: "executable")],
            products: [["name": "app-tool", "targets": ["App"]]]
        )
        binDirectory = fixture.root.appendingPathComponent("bin")
        try fixture.write("#!/bin/sh\nexit 0\n", to: "bin/app-tool")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binDirectory.appendingPathComponent("app-tool").path
        )
    }

    func setExitCode(_ code: Int32) {
        exitCode = code
    }

    func waitDuringBuild() {
        waitsDuringBuild = true
    }

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
        calls.append(Call(
            executable: executable,
            arguments: arguments,
            directory: workingDirectory,
            environment: environment
        ))
        if arguments.contains("describe") { return .init(standardOutput: metadata, standardError: Data(), exitCode: 0) }
        if arguments.contains("--show-bin-path") {
            return .init(standardOutput: Data(binDirectory.path.utf8), standardError: Data(), exitCode: 0)
        }
        if waitsDuringBuild { try await Task.sleep(for: .seconds(60)) }
        outputHandler?("  build output\n")
        return .init(standardOutput: Data(), standardError: Data(), exitCode: exitCode)
    }
}
