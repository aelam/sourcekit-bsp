import BuildServerProtocol
import Foundation
import Testing
@testable import SwiftPMProjectManagerProvider

struct SwiftPMProjectProviderTests {
    @Test
    func detectsDirectoriesAndManifestsAndNormalizesSymlinks() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let provider = SwiftPMProjectManagerProvider()
        #expect(await provider.canHandle(projectURL: fixture.root))
        #expect(await provider.canHandle(projectURL: fixture.root.appendingPathComponent("Package.swift")))
        #expect(await !(provider.canHandle(projectURL: fixture.directory)))
        #expect(try await !(provider.canHandle(projectURL: #require(URL(string: "https://example.com/Package.swift")))))
        #expect(
            try SwiftPMProjectManagerProvider.packageRoot(fixture.root.appendingPathComponent("Package.swift"))
                == fixture.root
        )
        let alias = fixture.directory.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        #expect(try SwiftPMProjectManagerProvider.packageRoot(alias) == fixture.root)
        let fake = fixture.directory.appendingPathComponent("Fake", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fake.appendingPathComponent("Package.swift"),
            withIntermediateDirectories: true
        )
        #expect(await !(provider.canHandle(projectURL: fake)))
    }

    @Test
    func resolvesConfiguredExecutableThenEnvironmentThenPath() throws {
        let fixture = try TemporarySwiftPMPackage()
        for name in ["configured", "environment", "swift", "swift.exe"] {
            try fixture.write("", to: "bin/\(name)")
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: fixture.root.appendingPathComponent("bin/\(name)").path
            )
        }
        let bin = fixture.root.appendingPathComponent("bin", isDirectory: true)
        let environment = ["SWIFT_EXEC": bin.appendingPathComponent("environment").path, "PATH": bin.path]
        #expect(
            try SwiftPMExecutableResolver.resolve(
                configured: "bin/configured",
                environment: environment,
                root: fixture.root
            ).lastPathComponent == "configured"
        )
        #expect(
            try SwiftPMExecutableResolver.resolve(configured: nil, environment: environment, root: fixture.root)
                .lastPathComponent == "environment"
        )
        #expect(
            try SwiftPMExecutableResolver.resolve(configured: nil, environment: ["PATH": bin.path], root: fixture.root)
                .lastPathComponent == "swift"
        )
        #expect(
            try SwiftPMExecutableResolver.resolve(
                configured: nil,
                environment: ["SWIFT_EXEC": bin.appendingPathComponent("swiftc").path],
                root: fixture.root
            ).lastPathComponent == "swift"
        )
        #expect(
            try SwiftPMExecutableResolver.resolve(
                configured: nil,
                environment: ["SWIFT_EXEC": bin.appendingPathComponent("swiftc.exe").path],
                root: fixture.root,
                windows: true
            ).lastPathComponent == "swift.exe"
        )
        #expect(throws: SwiftPMProjectError.self) {
            try SwiftPMExecutableResolver.resolve(configured: "missing", environment: environment, root: fixture.root)
        }
        #expect(throws: SwiftPMProjectError.self) {
            try SwiftPMExecutableResolver.resolve(
                configured: nil,
                environment: ["PATH": "/does-not-exist"],
                root: fixture.root
            )
        }
        #expect(
            try SwiftPMExecutableResolver.resolve(
                configured: nil,
                environment: ["Path": "\"\(bin.path)\";/missing"],
                root: fixture.root,
                windows: true
            ).lastPathComponent == "swift.exe"
        )
    }

    @Test
    func mapsMetadataWithoutScanningOrBuilding() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let data = try fixture.describe(targets: [
            describedTarget("Core", path: "custom 空 格", sources: ["nested/Unicode 日本.swift"]),
            describedTarget("App", type: "executable", dependencies: ["Core"]),
            describedTarget("CoreTests", type: "test", dependencies: ["Core"]),
            describedTarget("Native", sources: ["x.c", "x.cpp", "x.m", "x.mm"]),
        ], products: [["name": "app-tool", "targets": ["App"]]])
        let executor = FixtureCommandExecutor(data)
        let manager = fixture.manager(executor: executor)
        if case .uninitialized = await manager.getProjectState().projectLoadState {
        } else {
            Issue.record("Expected uninitialized state")
        }
        try await manager.initialize()
        let targets = await manager.getTargetList()
        #expect(targets.count == 4)
        let core = try #require(targets.first { $0.displayName == "Core" })
        let app = try #require(targets.first { $0.displayName == "App" })
        let tests = try #require(targets.first { $0.displayName == "CoreTests" })
        #expect(app.dependencies == [core.id])
        #expect(tests.dependencies == [core.id])
        #expect(core.id != app.id)
        #expect(core.tags == [.library])
        #expect(app.tags == [.application])
        #expect(tests.tags == [.test])
        #expect(core.languageIds == [.swift])
        #expect(
            try Set(#require(targets.first { $0.displayName == "Native" }?.languageIds)) == [
                .c,
                .cpp,
                .objective_c,
                .objective_cpp
            ]
        )
        #expect(targets.allSatisfy { $0.capabilities.canCompile == true })
        #expect(targets.filter { $0.capabilities.canTest == true }.map(\.id) == [tests.id])
        #expect(targets.allSatisfy { $0.capabilities.canDebug == false })
        #expect(targets.filter { $0.capabilities.canRun == true }.map(\.id) == [app.id])
        #expect(await manager.capabilities == [.compile, .run, .test, .outputPaths])
        #expect(await manager.project?.name == "Root")
        let source = try await manager.getSourceFileList(targetIdentifiers: [core.id])
        #expect(
            source[0].sources.map(\.uri) == [
                URI(fixture.root.appendingPathComponent("custom 空 格/nested/Unicode 日本.swift"))
            ]
        )
        #expect(source[0].sources.allSatisfy { $0.kind == .file && !$0.generated })
        #expect(
            await executor.calls.map(\.arguments) == [
                ["package", "--package-path", fixture.root.path, "describe", "--type", "json"]
            ]
        )
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".bsp").path))
        let identifiers = targets.map(\.id)
        try await manager.updateBuildGraph()
        #expect(await manager.getTargetList().map(\.id) == identifiers)
        if case .loaded = await manager.getProjectState().projectLoadState {
        } else {
            Issue.record("Expected loaded state")
        }
        await manager.shutdown()
        #expect(await manager.getTargetList().isEmpty)
        await #expect(throws: SwiftPMProjectError.self) { try await manager.initialize() }
    }

    @Test
    func reportsFailureAndPreservesLastSuccessfulGraph() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let executor = try FixtureCommandExecutor(fixture.describe(targets: [describedTarget("Core")]))
        let manager = fixture.manager(executor: executor)
        try await manager.initialize()
        let before = await manager.getTargetList()
        await executor.set(Data(), stderr: "Package.swift:12: error: invalid manifest", code: 1)
        do {
            try await manager.updateBuildGraph()
            Issue.record("Expected a command failure")
        } catch {
            #expect(error.localizedDescription.contains("invalid manifest"))
            #expect(error.localizedDescription.contains("exit 1"))
            #expect(error.localizedDescription.contains("describe"))
        }
        #expect(await manager.getTargetList() == before)
        if case .failed = await manager.getProjectState().projectLoadState {
        } else {
            Issue.record("Expected failed state")
        }
        await executor.set(Data("not json".utf8), stderr: "metadata warning")
        do {
            try await manager.updateBuildGraph()
            Issue.record("Expected invalid metadata")
        } catch { #expect(error.localizedDescription.contains("metadata warning")) }
        try await executor.set(fixture.describe(targets: [describedTarget("Replacement")]))
        try await manager.updateBuildGraph()
        #expect(await manager.getTargetList().map(\.displayName) == ["Replacement"])
    }

    @Test
    func rejectsUnknownTargetsAndUnsupportedOperations() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let manager = try fixture.manager(executor: FixtureCommandExecutor(fixture.describe()))
        let id = BSPBuildTargetIdentifier(uri: URI(fixture.root))
        await #expect(throws: SwiftPMProjectError.self) { try await manager.getSourceFileList(targetIdentifiers: []) }
        try await manager.initialize()
        #expect(try await manager.getSourceFileList(targetIdentifiers: []).isEmpty)
        await #expect(throws: SwiftPMProjectError.self) { try await manager.getSourceFileList(targetIdentifiers: [id]) }
        let actions: [@Sendable () async throws -> Void] = [
            {
                _ = try await manager.getCompileArguments(
                    targetIdentifier: id.uri.stringValue,
                    sourceFileURL: fixture.root
                )
            },
            { _ = try await manager.buildIndex(for: [id]) },
            {
                _ = try await manager.startDebugSession(
                    targetIdentifiers: [id],
                    arguments: nil,
                    logHandler: nil,
                    progressHandler: nil
                )
            },
        ]
        for action in actions {
            do {
                try await action()
                Issue.record("Expected unsupported operation")
            } catch let SwiftPMProjectError.unsupported(operation) { #expect(!operation.isEmpty) }
        }
        await #expect(throws: SwiftPMProjectError.self) {
            try await manager.startBuild(targetIdentifiers: [id], arguments: nil, logHandler: nil)
        }
        await #expect(throws: SwiftPMProjectError.self) {
            try await manager.run(
                targetIdentifier: id,
                arguments: nil,
                environmentVariables: nil,
                workingDirectory: nil
            )
        }
    }

    @Test
    func filtersChangesAndCoalescesReloads() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let executor = try FixtureCommandExecutor(fixture.describe(), delay: .milliseconds(100))
        let manager = fixture.manager(executor: executor)
        async let first: Void = manager.initialize()
        async let second: Void = manager.updateBuildGraph()
        _ = try await (first, second)
        #expect(await executor.calls.count == 1)
        for name in ["Package.swift", "Package@swift-6.1.swift", "Package.resolved"] {
            #expect(
                await manager.shouldReloadProject(for: [
                    .init(uri: URI(fixture.root.appendingPathComponent(name)), kind: .changed)
                ])
            )
        }
        for kind in [ProjectFileChange.Kind.created, .deleted] {
            #expect(
                await manager.shouldReloadProject(for: [
                    .init(uri: URI(fixture.root.appendingPathComponent("Sources/New.swift")), kind: kind)
                ])
            )
            #expect(
                await !(manager.shouldReloadProject(for: [
                    .init(uri: URI(fixture.root.appendingPathComponent(".build/generated.swift")), kind: kind)
                ]))
            )
        }
        #expect(
            await !(manager.shouldReloadProject(for: [
                .init(uri: URI(fixture.root.appendingPathComponent("Sources/File.swift")), kind: .changed)
            ]))
        )
        #expect(
            await !(manager.shouldReloadProject(for: [
                .init(uri: URI(fixture.directory.appendingPathComponent("Unrelated.swift")), kind: .created)
            ]))
        )
        #expect(await !(manager.shouldReloadProject(for: [])))
    }

    @Test
    func shutdownCancelsLoadingAndPreventsLatePublication() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let executor = try FixtureCommandExecutor(fixture.describe(), delay: .seconds(60))
        let manager = fixture.manager(executor: executor)
        let loading = Task { try await manager.initialize() }
        for _ in 0 ..< 200 {
            if await !executor.calls.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await executor.calls.count == 1)
        if case .loading = await manager.getProjectState().projectLoadState {
        } else {
            Issue.record("Expected loading state")
        }
        await manager.shutdown()
        do {
            try await loading.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        #expect(await manager.project == nil)
        if case .uninitialized = await manager.getProjectState().projectLoadState {
        } else {
            Issue.record("Expected reset state")
        }
    }
}
