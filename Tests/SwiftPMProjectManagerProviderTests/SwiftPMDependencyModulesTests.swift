import BuildServerProtocol
import Foundation
import Testing
@testable import SwiftPMProjectManagerProvider

struct SwiftPMDependencyModulesTests {
    @Test
    func includesTransitiveAndBinaryProductsWithoutUnrelatedPackages() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let library = fixture.directory.appendingPathComponent("Library")
        let binary = fixture.directory.appendingPathComponent("Binary")
        for directory in [library, binary] {
            try fixture.write("// Fixture", to: "Package.swift", in: directory)
        }
        let executor = try FixtureCommandExecutor(fixture.describe(
            targets: [
                describedTarget("Core", products: ["LibraryProduct"]),
                describedTarget("App", dependencies: ["Core"]),
                describedTarget("Unused")
            ],
            dependencies: [["identity": "library", "type": "fileSystem", "path": library.path]]
        ))
        try await executor.set(
            manifest(target: "Core", product: "LibraryProduct", package: "library"),
            key: fixture.root.path + ":dump"
        )
        try await executor.set(fixture.describe(
            name: "Library",
            at: library,
            targets: [describedTarget("Core", products: ["BinaryProduct"])],
            products: [["name": "LibraryProduct", "targets": ["Core"]]],
            dependencies: [["identity": "binary", "type": "fileSystem", "path": binary.path]]
        ), key: library.path + ":describe")
        try await executor.set(
            manifest(target: "Core", product: "BinaryProduct", package: "binary"),
            key: library.path + ":dump"
        )
        try await executor.set(fixture.describe(
            name: "Binary",
            at: binary,
            targets: [describedTarget("Native", type: "binary")],
            products: [["name": "BinaryProduct", "targets": ["Native"]]]
        ), key: binary.path + ":describe")
        let manager = fixture.manager(executor: executor)
        await #expect(throws: DependencyModulesError.self) {
            try await manager.getDependencyModules(targetIdentifiers: [])
        }
        try await manager.initialize()
        let targets = await manager.getTargetList()
        let app = try #require(targets.first { $0.displayName == "App" })
        let unused = try #require(targets.first { $0.displayName == "Unused" })
        let dependency = try #require(targets.first { $0.tags.contains(.dependency) })
        let callCount = await executor.calls.count
        let items = try await manager.getDependencyModules(targetIdentifiers: [app.id, unused.id, dependency.id])
        #expect(items.map(\.target) == [app.id, unused.id, dependency.id])
        #expect(items[0].modules.map(\.name) == ["LibraryProduct", "BinaryProduct"])
        // swiftformat:disable:next preferKeyPath
        #expect(items[0].modules.allSatisfy { $0.version.isEmpty })
        #expect(items[1].modules.isEmpty)
        #expect(items[2].modules.map(\.name) == ["BinaryProduct"])
        #expect(!targets.contains { $0.displayName == "Native" })
        #expect(await executor.calls.count == callCount)
        #expect(try await manager.getDependencyModules(targetIdentifiers: []).isEmpty)

        await executor.set(Data(), key: fixture.root.path + ":describe", code: 1)
        await #expect(throws: SwiftPMProjectError.self) { try await manager.updateBuildGraph() }
        #expect(try await manager.getDependencyModules(targetIdentifiers: [app.id]).first == items.first)
        try await executor.set(
            fixture.describe(targets: [describedTarget("App")]),
            key: fixture.root.path + ":describe"
        )
        try await manager.updateBuildGraph()
        #expect(try await manager.getDependencyModules(targetIdentifiers: [app.id]).first?.modules.isEmpty == true)
        await manager.shutdown()
        await #expect(throws: DependencyModulesError.self) {
            try await manager.getDependencyModules(targetIdentifiers: [app.id])
        }
    }

    private func manifest(target: String, product: String, package: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "targets": [["name": target, "dependencies": [["product": [product, package, NSNull(), NSNull()]]]]],
            "dependencies": [["fileSystem": [["identity": package]]]]
        ])
    }
}
