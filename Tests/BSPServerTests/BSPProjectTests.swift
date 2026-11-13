import Foundation
import SourceKitBSPProtocol
import Testing

struct BSPProjectTests {
    private let root = URL(fileURLWithPath: "/tmp/BSPProject")

    private func identifier(_ name: String) -> BSPBuildTargetIdentifier {
        BSPBuildTargetIdentifier(uri: URI(root.appendingPathComponent(name)))
    }

    @Test
    func indexesTargetsByIdentityAndTraversesCyclesAndSharedDependencies() {
        let first = BSPBuildTarget(
            id: identifier("first"),
            displayName: "Same name",
            dependencies: [
                identifier("second"),
                identifier("shared")
            ],
            capabilities: .init(canCompile: true)
        )
        let second = BSPBuildTarget(
            id: identifier("second"),
            displayName: "Same name",
            dependencies: [
                identifier("first"),
                identifier("shared")
            ],
            capabilities: .init(canTest: true)
        )
        let shared = BSPBuildTarget(id: identifier("shared"), capabilities: .init())
        let project = BSPProject(
            rootURL: root,
            name: "Example",
            targets: [first, second, shared, first],
            buildRootURL: root,
            indexStoreURL: root,
            indexDatabaseURL: root
        )
        #expect(project.targets == [first, second, shared])
        #expect(project.target(for: first.id) == first)
        #expect(project.target(for: second.id) == second)
        #expect(project.target(for: identifier("missing")) == nil)
        #expect(project.dependencyClosure(for: [first.id, second.id]) == [first.id, second.id, shared.id])
        #expect(project.dependencyClosure(for: []).isEmpty)
        #expect(project.dependencyClosure(for: [identifier("missing")]) == [identifier("missing")])
    }

    @Test
    func dependencyModulesFollowTargetEdgesAndKeepDistinctLibraries() throws {
        let app = identifier("app")
        let library = identifier("library")
        let unrelated = identifier("unrelated")
        let module = DependencyModule(name: "Shared", version: "1.2.3", data: ["uri": "file:///one"])
        let other = DependencyModule(name: "Shared", version: "1.2.3", data: ["uri": "file:///two"])
        let project = BSPProject(
            rootURL: root,
            name: "Example",
            targets: [
                .init(id: app, dependencies: [library], capabilities: .init()),
                .init(id: library, dependencies: [app], capabilities: .init()),
                .init(id: unrelated, capabilities: .init())
            ],
            buildRootURL: root,
            indexStoreURL: root,
            indexDatabaseURL: root,
            dependencyModules: [
                app: [module],
                library: [module, other],
                unrelated: [.init(name: "Unused", version: "")]
            ]
        )
        let items = try project.dependencyModules(for: [app, library])
        #expect(items.map(\.target) == [app, library])
        #expect(items.allSatisfy { $0.modules == [module, other] })
        #expect(try project.dependencyModules(for: []).isEmpty)
        #expect(throws: DependencyModulesError.self) {
            try project.dependencyModules(for: [app, identifier("missing")])
        }
    }
}
