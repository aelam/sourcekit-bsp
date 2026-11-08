import BuildServerProtocol
import Foundation
import Testing
import XcodeProj
@testable import XcodeProjectManagement

struct ContextDiscoveryPerformanceTests {
    @Test
    func workspaceDoesNotParseUnselectedSchemes() async throws {
        let fixture = try await ContextFixture.make { _, directory in
            let other = try XCScheme(pathString: directory.appendingPathComponent("Hello.xcscheme").path)
            other.name = "Other"
            other.testAction?.testables = []
            other.testAction?.testPlans = [.init(reference: "container:Missing.xctestplan", default: true)]
            try other.write(path: .init(directory.appendingPathComponent("Other.xcscheme").path), override: true)
        }
        defer { fixture.remove() }
        let otherURL = fixture.schemeURL.deletingLastPathComponent().appendingPathComponent("Other.xcscheme")
        try Data("invalid scheme XML".utf8).write(to: otherURL)
        let otherID = otherURL.resolvingSymlinksInPath().standardizedFileURL.absoluteString
        let initial = try await fixture.manager.contextOptions(.init())
        #expect(initial.dimensions[0].options.first { $0.id == otherID }?.availability == true)
        #expect(initial.operations?.isEmpty == true)
        let selected = try await fixture.manager.contextOptions(.init(selection: ["xcode.scheme": fixture.schemeID]))
        #expect(selected.dimensions[0].options.first { $0.id == otherID }?.availability == true)
        #expect(selected.operations == BuildContextOperation.allCases)
        let invalid = try await fixture.manager.contextOptions(.init(selection: ["xcode.scheme": otherID]))
        #expect(invalid.dimensions[0].options.first { $0.id == otherID }?.availability == false)
        #expect(invalid.dimensions.dropFirst().allSatisfy { $0.enabled == false })
        #expect(invalid.operations?.isEmpty == true)
    }

    @Test
    func selectedSchemeEditsAndDeletionAreVisibleWithoutReloading() async throws {
        let fixture = try await ContextFixture.make()
        defer { fixture.remove() }
        let selection = ["xcode.scheme": fixture.schemeID]
        let initial = try await fixture.manager.contextOptions(.init(selection: selection))
        #expect(initial.operations == BuildContextOperation.allCases)
        let scheme = try XCScheme(pathString: fixture.schemeURL.path)
        scheme.launchAction = nil
        scheme.testAction?.testables = []
        try scheme.write(path: .init(fixture.schemeURL.path), override: true)
        let edited = try await fixture.manager.contextOptions(.init(selection: selection))
        #expect(edited.operations == [.compile])
        try FileManager.default.removeItem(at: fixture.schemeURL)
        let deleted = try await fixture.manager.contextOptions(.init())
        #expect(deleted.dimensions[0].options.first?.availability == false)
        #expect(deleted.dimensions[0].options.first?.reason != nil)
    }

    @Test
    func targetScopeStillFiltersSchemesByTheirCurrentTargets() async throws {
        let fixture = try await ContextFixture.make { _, directory in
            let other = try XCScheme(pathString: directory.appendingPathComponent("Hello.xcscheme").path)
            other.name = "TestsOnly"
            other.buildAction?.buildActionEntries = []
            other.launchAction = nil
            try other.write(path: .init(directory.appendingPathComponent("TestsOnly.xcscheme").path), override: true)
        }
        defer { fixture.remove() }
        let base = try #require(await fixture.manager.projectSnapshot)
        let app = try #require(base.xcodeTargets.first { $0.name == "Hello" })
        let id = try BSPBuildTargetIdentifier(uri: URI(string: app.targetIdentifier.rawValue))
        let options = try await fixture.manager.contextOptions(.init(scope: .init(targets: [id])))
        #expect(options.dimensions[0].options.first { $0.label == "Hello" }?.availability == true)
        #expect(options.dimensions[0].options.first { $0.label == "TestsOnly" }?.availability == false)
        #expect(options.selection["xcode.scheme"] == fixture.schemeID)
        #expect(options.operations == [.compile, .run, .debug])
    }
}
