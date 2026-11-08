import Foundation
import Testing
import XcodeProj
@testable import XcodeProjectManagement

struct ContextTargetLookupTests {
    @Test
    func resolvesProjectAliasesWithoutChangingTheTargetIdentifier() async throws {
        let fixture = try await ContextFixture.make()
        defer { fixture.remove() }
        let base = try #require(await fixture.manager.projectSnapshot)
        let scheme = try #require(base.schemes.first { $0.name == "Hello" })
        let target = try await fixture.manager.lookupSchemeLaunchTarget(scheme)
        let alias = fixture.root.appendingPathComponent("Alias.xcodeproj")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target.projectURL)
        let resolved = try await fixture.manager.lookupSchemeLaunchTarget(
            scheme,
            container: "container:Alias.xcodeproj"
        )
        #expect(resolved.targetIdentifier == target.targetIdentifier)
    }

    @Test
    func projectReloadRebuildsTheReferenceLookup() async throws {
        let fixture = try await ContextFixture.make()
        defer { fixture.remove() }
        let base = try #require(await fixture.manager.projectSnapshot)
        let scheme = try #require(base.schemes.first { $0.name == "Hello" })
        let target = try await fixture.manager.lookupSchemeLaunchTarget(scheme)
        let project = try XcodeProj(pathString: target.projectURL.path)
        let native = try #require(project.pbxproj.nativeTargets.first { $0.name == target.name })
        native.name = "RenamedApp"
        try project.write(path: .init(target.projectURL.path))
        try await fixture.manager.reloadProject()
        let resolved = try await fixture.manager.lookupSchemeLaunchTarget(scheme)
        #expect(resolved.name == "RenamedApp")
        #expect(resolved.targetIdentifier != target.targetIdentifier)
    }
}

private extension XcodeProjectManager {
    func lookupSchemeLaunchTarget(_ scheme: XcodeScheme, container: String? = nil) throws -> XcodeTarget {
        let parsed = try XCScheme(pathString: scheme.path.path)
        let original = try #require(parsed.launchAction?.runnable?.buildableReference)
        let reference = XCScheme.BuildableReference(
            referencedContainer: container ?? original.referencedContainer,
            blueprintIdentifier: original.blueprintIdentifier,
            buildableName: original.buildableName,
            blueprintName: original.blueprintName
        )
        return try contextTarget(for: reference, scheme: scheme)
    }
}
