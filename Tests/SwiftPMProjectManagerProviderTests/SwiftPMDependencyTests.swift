import BuildServerProtocol
import Foundation
import Testing
@testable import SwiftPMProjectManagerProvider

struct SwiftPMDependencyTests {
    @Test
    func loadsLocalProductsAndWatchesPackagesOutsideTheRoot() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let dependency = fixture.directory.appendingPathComponent("Dependency", isDirectory: true)
        try fixture.write("// Fixture", to: "Package.swift", in: dependency)
        let executor = try FixtureCommandExecutor(
            fixture.describe(
                targets: [
                    describedTarget("Core", products: ["LibraryProduct"]),
                    describedTarget("App", type: "executable", dependencies: ["Core"]),
                ],
                dependencies: [["identity": "dependency", "type": "fileSystem", "path": dependency.path]]
            )
        )
        try await executor.set(
            fixture.describe(
                name: "Dependency",
                at: dependency,
                targets: [
                    describedTarget("Core", dependencies: ["Internal"]), describedTarget("Internal"),
                ],
                products: [["name": "LibraryProduct", "targets": ["Core"]]]
            ),
            key: dependency.path + ":describe"
        )
        try await executor.set(
            manifest(product: "LibraryProduct", package: "Dependency", dependency: "dependency"),
            key: fixture.root.path + ":dump"
        )
        let manager = fixture.manager(executor: executor)
        #expect(await manager.watchedFileRoots == [fixture.root])
        try await manager.initialize()
        let targets = await manager.getTargetList()
        let core = try #require(targets.first { $0.displayName == "Core" && !$0.tags.contains(.dependency) })
        let library = try #require(targets.first { $0.displayName == "Core" && $0.tags.contains(.dependency) })
        let internalTarget = try #require(targets.first { $0.displayName == "Internal" })
        #expect(core.id != library.id)
        #expect(core.dependencies == [library.id])
        #expect(library.dependencies == [internalTarget.id])
        #expect(await manager.watchedFileRoots == [fixture.root, dependency].sorted { $0.path < $1.path })
        #expect(
            await manager.shouldReloadProject(for: [
                .init(uri: URI(dependency.appendingPathComponent("Package.swift")), kind: .changed)
            ])
        )
        #expect(await manager.diagnostics.isEmpty)
        #expect(await !(executor.calls.contains { $0.arguments.contains("show-dependencies") }))
        #expect(await executor.calls.count == 3)
    }

    @Test
    func resolvesRemoteProductsUsingReturnedPathsAndPackageIdentity() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let remote = fixture.directory.appendingPathComponent("Downloaded/unexpected checkout 名", isDirectory: true)
        let other = fixture.directory.appendingPathComponent("Local", isDirectory: true)
        for path in [remote, other] {
            try fixture.write("// Fixture", to: "Package.swift", in: path)
        }
        let executor = try FixtureCommandExecutor(
            fixture.describe(
                targets: [describedTarget("Core", products: ["SharedProduct"])],
                dependencies: [
                    ["identity": "remote-identity", "type": "sourceControl"],
                    ["identity": "local", "type": "fileSystem", "path": other.path],
                ]
            )
        )
        try await executor.set(
            fixture.describe(
                name: "UnrelatedDisplayName",
                at: remote,
                targets: [describedTarget("RemoteCore")],
                products: [
                    ["name": "SharedProduct", "targets": ["RemoteCore"]]
                ]
            ),
            key: remote.path + ":describe"
        )
        try await executor.set(
            fixture.describe(
                name: "Local",
                at: other,
                targets: [describedTarget("LocalCore")],
                products: [
                    ["name": "SharedProduct", "targets": ["LocalCore"]]
                ]
            ),
            key: other.path + ":describe"
        )
        try await executor.set(
            manifest(
                product: "SharedProduct",
                package: "remote-identity",
                dependency: "remote-identity",
                type: "sourceControl"
            ),
            key: fixture.root.path + ":dump"
        )
        try await executor.set(
            resolvedGraph(
                root: fixture.root,
                nodes: [
                    ["identity": "remote-identity", "path": remote.path, "dependencies": []],
                    ["identity": "local", "path": other.path, "dependencies": []],
                ]
            ),
            key: fixture.root.path + ":resolve"
        )
        let manager = fixture.manager(executor: executor)
        try await manager.initialize()
        let targets = await manager.getTargetList()
        let core = try #require(targets.first { $0.displayName == "Core" })
        let remoteCore = try #require(targets.first { $0.displayName == "RemoteCore" })
        #expect(core.dependencies == [remoteCore.id])
        #expect(await manager.diagnostics.isEmpty)
        let resolutionCount = await executor.calls.count { $0.arguments.contains("show-dependencies") }
        #expect(resolutionCount == 1)
        #expect(await manager.watchedFileRoots.contains(remote))
        #expect(await executor.calls.contains { $0.root == remote })
    }

    @Test
    func missingResolvedMappingAndResolutionFailureAreReadable() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let executor = try FixtureCommandExecutor(
            fixture.describe(dependencies: [["identity": "missing", "type": "sourceControl"]])
        )
        try await executor.set(resolvedGraph(root: fixture.root, nodes: []), key: fixture.root.path + ":resolve")
        let manager = fixture.manager(executor: executor)
        do {
            try await manager.initialize()
            Issue.record("Expected a missing checkout error")
        } catch {
            #expect(error.localizedDescription.contains("missing"))
            #expect(error.localizedDescription.contains("checkout path"))
        }
        await executor.set(
            Data(),
            key: fixture.root.path + ":resolve",
            stderr: "dependency resolution failed: repository unavailable",
            code: 1
        )
        do {
            try await manager.updateBuildGraph()
            Issue.record("Expected a resolution error")
        } catch {
            #expect(error.localizedDescription.contains("repository unavailable"))
            #expect(error.localizedDescription.contains("show-dependencies"))
        }
        #expect(await manager.project == nil)
    }

    @Test
    func unknownProductAndUnsupportedTargetsDoNotInventEdges() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let executor = try FixtureCommandExecutor(
            fixture.describe(targets: [
                describedTarget("Core", dependencies: ["Plugin"], products: ["UnknownProduct"]),
                describedTarget("Plugin", type: "plugin"),
            ])
        )
        try await executor.set(
            manifest(product: "UnknownProduct", package: "unknown", dependency: "unknown"),
            key: fixture.root.path + ":dump"
        )
        let manager = fixture.manager(executor: executor)
        try await manager.initialize()
        #expect(await manager.getTargetList().count == 1)
        #expect(await manager.getTargetList().first?.dependencies.isEmpty == true)
        #expect(await manager.diagnostics.contains { $0.contains("UnknownProduct") && $0.contains("omitted") })
        #expect(await manager.diagnostics.contains { $0.contains("unsupported type 'plugin'") })
    }

    private func manifest(product: String, package: String, dependency: String, type: String = "fileSystem") throws
        -> Data {
        try JSONSerialization.data(withJSONObject: [
            "targets": [["name": "Core", "dependencies": [["product": [product, package, NSNull(), NSNull()]]]]],
            "dependencies": [[type: [["identity": dependency]]]],
        ])
    }

    private func resolvedGraph(root: URL, nodes: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["identity": "root", "path": root.path, "dependencies": nodes])
    }
}
