import BuildServerProtocol
import Foundation
import Testing
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
@testable import SwiftPMProjectManagerProvider

struct SwiftPMIntegrationTests {
    @Test(.timeLimit(.minutes(2)))
    func loadsRealLocalPackageWithCustomSourcesAndReloads() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let dependency = fixture.directory.appendingPathComponent("Dependency 空", isDirectory: true)
        try fixture.write(
            """
            // swift-tools-version: 6.1
            import PackageDescription
            let package = Package(name: "Dependency", products: [.library(name: "DepProduct", targets: ["DepCore"])],
                targets: [.target(name: "DepCore", dependencies: ["Internal"]), .target(name: "Internal")])
            """,
            to: "Package.swift",
            in: dependency
        )
        try fixture.write(
            "This source is not compiled during loading.",
            to: "Sources/DepCore/Dep.swift",
            in: dependency
        )
        try fixture.write("struct Internal {}", to: "Sources/Internal/Internal.swift", in: dependency)
        let manifest = """
        // swift-tools-version: 6.1
        import PackageDescription
        let package = Package(name: "SamplePackage", products: [.library(name: "Core", targets: ["Core"])],
            dependencies: [.package(path: "../Dependency 空")], targets: [
                .target(name: "Core", dependencies: [.product(name: "DepProduct", package: "dependency 空")],
                    path: "custom 源 码", exclude: ["Excluded.swift", "Ignored"]),
                .executableTarget(name: "App", dependencies: ["Core"]),
                .testTarget(name: "CoreTests", dependencies: ["Core"])
            ])
        """
        try fixture.write(manifest, to: "Package.swift")
        try fixture.write("This is deliberately not valid Swift.", to: "custom 源 码/Nested/日本 語.swift")
        try fixture.write("excluded", to: "custom 源 码/Excluded.swift")
        try fixture.write("excluded", to: "custom 源 码/Ignored/Hidden.swift")
        try fixture.write("print(1)", to: "Sources/App/main.swift")
        try fixture.write("import Testing", to: "Tests/CoreTests/Tests.swift")
        let recorder = RecordingProcessExecutor()
        let provider = SwiftPMProjectManagerProvider(
            executor: recorder,
            environment: ProcessInfo.processInfo.environment
        )
        let manager = try await provider.createProjectManager(
            rootURL: fixture.root.appendingPathComponent("Package.swift"),
            config: nil
        )
        try await manager.initialize()
        #expect(await manager.rootURL == fixture.root)
        #expect(await manager.project?.name == "SamplePackage")
        let targets = await manager.getTargetList()
        #expect(targets.count == 5)
        let core = try #require(targets.first { $0.displayName == "Core" })
        let depCore = try #require(targets.first { $0.displayName == "DepCore" })
        let internalTarget = try #require(targets.first { $0.displayName == "Internal" })
        #expect(core.dependencies == [depCore.id])
        #expect(depCore.dependencies == [internalTarget.id])
        #expect(targets.first { $0.displayName == "App" }?.dependencies == [core.id])
        #expect(targets.first { $0.displayName == "CoreTests" }?.dependencies == [core.id])
        let sources = try await manager.getSourceFileList(targetIdentifiers: [core.id])
        #expect(
            sources[0].sources.map(\.uri) == [URI(fixture.root.appendingPathComponent("custom 源 码/Nested/日本 語.swift"))]
        )
        #expect(
            try String(contentsOf: fixture.root.appendingPathComponent("Package.swift"), encoding: .utf8) == manifest
        )
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".bsp").path))
        #expect(await manager.watchedFileRoots.contains(dependency))
        try fixture.write("struct Added {}", to: "custom 源 码/Added.swift")
        try await manager.updateBuildGraph()
        #expect(await manager.getTargetList().map(\.id) == targets.map(\.id))
        #expect(try await manager.getSourceFileList(targetIdentifiers: [core.id])[0].sources.count == 2)
        let calls = await recorder.calls
        #expect(calls.allSatisfy {
            $0.contains("describe") || $0.contains("dump-package") || $0 == ["-print-target-info"]
        })
        let discoveryCalls = calls.count { $0 == ["-print-target-info"] }
        #expect(discoveryCalls == 1)
        #expect(!calls.contains { $0.contains("build") || $0.contains("show-dependencies") })
        await manager.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func invalidManifestReportsSwiftPMError() async throws {
        let fixture = try TemporarySwiftPMPackage()
        try fixture.write(
            "// swift-tools-version: 6.1\nimport PackageDescription\ninvalid manifest syntax",
            to: "Package.swift"
        )
        let manager = try await SwiftPMProjectManagerProvider().createProjectManager(rootURL: fixture.root, config: nil)
        do {
            try await manager.initialize()
            Issue.record("Expected invalid manifest")
        } catch {
            #expect(error.localizedDescription.contains("Package.swift"))
            #expect(error.localizedDescription.contains("exit"))
            #expect(error.localizedDescription.contains("error:"))
        }
        if case .failed = await manager.getProjectState().projectLoadState {
        } else {
            Issue.record("Expected failed state")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func processCapturesLargeOutputsAndExitStatus() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let result = try await SwiftPMProcessExecutor().execute(
            executable: swiftExecutable(root: fixture.root),
            arguments: [
                "-e",
                """
                import Foundation
                FileHandle.standardOutput.write(Data(repeating: 65, count: 262144))
                FileHandle.standardError.write(Data(repeating: 66, count: 262144))
                exit(7)
                """,
            ],
            workingDirectory: fixture.root
        )
        #expect(result.exitCode == 7)
        #expect(result.standardOutput == Data(repeating: 65, count: 262_144))
        #expect(result.standardError == Data(repeating: 66, count: 262_144))
    }

    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func cancellationTerminatesTheRunningProcess(packageCommand: Bool) async throws {
        let fixture = try TemporarySwiftPMPackage()
        let ready = fixture.root.appendingPathComponent("ready")
        let naturalExit = fixture.root.appendingPathComponent("natural-exit")
        let executable = try swiftExecutable(root: fixture.root)
        let body = """
        import Foundation
        try Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(
            to: URL(fileURLWithPath: \(String(reflecting: ready.path))))
        Thread.sleep(forTimeInterval: 60)
        try Data("natural exit".utf8).write(to: URL(fileURLWithPath: \(String(reflecting: naturalExit.path))))
        """
        let arguments: [String]
        if packageCommand {
            try fixture.write(
                "// swift-tools-version: 6.1\nimport PackageDescription\n" + body
                    + "\nlet package = Package(name: \"CancellationFixture\", targets: [])",
                to: "Package.swift"
            )
            // This test manifest writes lifecycle markers; normal loading keeps the SwiftPM sandbox enabled.
            arguments = [
                "package", "--disable-sandbox", "--package-path", fixture.root.path, "describe", "--type", "json"
            ]
        } else {
            try fixture.write(body, to: "wait.swift")
            arguments = [fixture.root.appendingPathComponent("wait.swift").path]
        }
        let task = Task {
            try await SwiftPMProcessExecutor().execute(
                executable: executable,
                arguments: arguments,
                workingDirectory: fixture.root
            )
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = (try? String(contentsOf: ready, encoding: .utf8)).flatMap(Int32.init)
        task.cancel()
        do {
            let result = try await task.value
            let stderr = String(bytes: result.standardError, encoding: .utf8) ?? "Non-UTF-8 stderr"
            Issue.record("Expected cancellation, received exit \(result.exitCode): \(stderr)")
        } catch is CancellationError {}
        let processID = try #require(pid)
        #expect(!FileManager.default.fileExists(atPath: naturalExit.path))
        #if !os(Windows)
        // Allow the system reaper to collect a terminated manifest process.
        let reapDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while kill(processID, 0) == 0, ContinuousClock.now < reapDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let processStatus = kill(processID, 0)
        let processError = errno
        #expect(processStatus == -1)
        #expect(processError == ESRCH)
        #endif
    }
}

private actor RecordingProcessExecutor: SwiftPMCommandExecuting {
    private(set) var calls: [[String]] = []

    func execute(executable: URL, arguments: [String], workingDirectory: URL) async throws -> SwiftPMCommandResult {
        calls.append(arguments)
        return try await SwiftPMProcessExecutor().execute(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory
        )
    }
}
