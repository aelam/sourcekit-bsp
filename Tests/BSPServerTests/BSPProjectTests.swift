import BuildServerProtocol
import Foundation
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
}
