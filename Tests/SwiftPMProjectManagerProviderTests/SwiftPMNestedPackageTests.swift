import BuildServerProtocol
import Foundation
import Testing
@testable import SwiftPMProjectManagerProvider

struct SwiftPMNestedPackageTests {
    @Test
    func selectsRootBeforeNestedPackagesAndStopsAtPackageBoundaries() throws {
        let fixture = try TemporarySwiftPMPackage()
        try fixture.write("", to: "Nested/Package.swift")
        #expect(try SwiftPMProjectManagerProvider.discoverPackageRoot(fixture.directory) == fixture.root)
        #expect(try SwiftPMProjectManagerProvider.discoverPackageRoot(fixture.root) == fixture.root)
        try fixture.write("", to: "Package.swift", in: fixture.directory)
        #expect(try SwiftPMProjectManagerProvider.discoverPackageRoot(fixture.directory)?.path == fixture.directory
            .path)
    }

    @Test
    func ignoresCachesAndSymlinksDuringAutomaticDiscovery() throws {
        let fixture = try TemporarySwiftPMPackage()
        for path in [".build/checkouts", ".git", ".swiftpm", "node_modules/module", "Pods/Dependency", "DerivedData"] {
            try fixture.write("", to: path + "/Package.swift", in: fixture.directory)
        }
        try FileManager.default.createSymbolicLink(
            at: fixture.directory.appendingPathComponent("cycle"), withDestinationURL: fixture.directory
        )
        #expect(try SwiftPMProjectManagerProvider.discoverPackageRoot(fixture.directory) == fixture.root)
    }

    @Test
    func factoryReportsAmbiguousPackagesInsteadOfDroppingTheProvider() async throws {
        let fixture = try TemporarySwiftPMPackage()
        try fixture.write("", to: "Other/Package.swift", in: fixture.directory)
        let factory = ProjectManagerFactory()
        await factory.registerProvider(SwiftPMProjectManagerProvider())
        do {
            _ = try await factory.createProjectManager(rootURL: fixture.directory)
            Issue.record("Expected ambiguous package discovery")
        } catch let SwiftPMProjectError.ambiguousPackages(paths) {
            #expect(paths == ["Other", fixture.root.lastPathComponent])
        }
    }

    @Test
    func explicitPathsOverrideRootDiscoveryAndInvalidPathsDoNotFallBack() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let executor = try NestedCommandRecorder(fixture: fixture)
        let provider = SwiftPMProjectManagerProvider(executor: executor, environment: [:])
        try fixture.write("", to: "Package.swift", in: fixture.directory)
        try fixture.write("", to: "swift")
        let swift = fixture.root.appendingPathComponent("swift")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
        for path in [
            fixture.root.lastPathComponent,
            fixture.root.path,
            fixture.root.lastPathComponent + "/Package.swift"
        ] {
            let manager = try await provider.createProjectManager(
                rootURL: URL(fileURLWithPath: fixture.directory.path),
                config: .init(customSettings: ["swiftExecutable": swift.path], packagePath: path)
            )
            #expect(await manager.rootURL == fixture.root)
            #expect(await manager.workspaceRootURL.path == fixture.directory.path)
        }
        await #expect(throws: SwiftPMProjectError.self) {
            try await provider.createProjectManager(rootURL: fixture.directory, config: .init(packagePath: "missing"))
        }
    }

    @Test
    func parentWorkspaceScopesKeepAllCommandsInsideTheSelectedPackage() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let executor = try NestedCommandRecorder(fixture: fixture)
        try fixture.write("", to: "bin/app-tool")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fixture.root.appendingPathComponent("bin/app-tool").path
        )
        let manager = SwiftPMProjectManager(
            rootURL: fixture.root,
            executable: fixture.root.appendingPathComponent("swift"),
            executor: executor,
            workspaceRootURL: fixture.directory
        )
        try await manager.initialize()
        let scope = BuildContextScope(workspaceUri: URI(fixture.directory))
        #expect(try await manager.contextOptions(.init(scope: scope)).dimensions.count == 3)
        let compile = try await manager.resolveContext(.init(scope: scope, operation: .compile))
        #expect(try await manager.startBuild(
            targetIdentifiers: compile.targets, arguments: nil, logHandler: nil, context: compile
        ) == .ok)
        let run = try await manager.resolveContext(.init(scope: scope, operation: .run, buildPolicy: .reuse))
        _ = try await manager.run(
            targetIdentifier: #require(run.targets.first),
            arguments: nil,
            environmentVariables: nil,
            workingDirectory: nil,
            progressHandler: nil,
            context: run
        )
        let test = try await manager.resolveContext(.init(scope: scope, operation: .test, buildPolicy: .reuse))
        _ = try await manager.test(
            targetIdentifiers: test.targets,
            arguments: nil,
            environmentVariables: nil,
            workingDirectory: nil,
            logHandler: nil,
            testEventHandler: nil,
            context: test
        )
        let calls = await executor.calls
        #expect(calls.allSatisfy { $0.directory == fixture.root })
        #expect(calls.contains { $0.executable.lastPathComponent == "app-tool" })
        #expect(calls.contains { $0.arguments.first == "test" && $0.arguments.contains("--skip-build") })
        for call in calls {
            if let path = call.arguments.firstIndex(of: "--package-path") {
                #expect(call.arguments[path + 1] == fixture.root.path)
            }
        }
        for invalid in [fixture.root, fixture.directory.appendingPathComponent("Other")] {
            await #expect(throws: BuildContextError.self) {
                try await manager.resolveContext(.init(scope: .init(workspaceUri: URI(invalid)), operation: .compile))
            }
        }
        #expect(await manager.watchedFileRoots == [fixture.root])
        await manager.shutdown()
    }
}

private actor NestedCommandRecorder: SwiftPMCommandExecuting {
    struct Call: Sendable {
        let executable: URL
        let arguments: [String]
        let directory: URL
    }

    let root: URL
    let metadata: Data
    var calls: [Call] = []

    init(fixture: TemporarySwiftPMPackage) throws {
        root = fixture.root
        metadata = try fixture.describe(
            targets: [describedTarget("App", type: "executable"), describedTarget("AppTests", type: "test")],
            products: [["name": "app-tool", "targets": ["App"]]]
        )
    }

    func execute(executable: URL, arguments: [String], workingDirectory: URL) async throws -> SwiftPMCommandResult {
        calls.append(.init(executable: executable, arguments: arguments, directory: workingDirectory))
        let output: Data = if arguments.contains("describe") {
            metadata
        } else if arguments == ["-print-target-info"] {
            Data(#"{"target":{"triple":"arm64-apple-macosx26.0"}}"#.utf8)
        } else if arguments.contains("--show-bin-path") {
            Data(root.appendingPathComponent("bin").path.utf8)
        } else {
            Data()
        }
        return .init(standardOutput: output, standardError: Data(), exitCode: 0)
    }
}
