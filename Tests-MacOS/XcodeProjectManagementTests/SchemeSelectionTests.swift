import BuildServerProtocol
import Foundation
import Testing
import XcodeProj
@testable import XcodeProjectManagement

struct SchemeSelectionTests {
    @Test
    func missingSchemesDoNotCreateFilesDuringDiscoveryOrExecution() async throws {
        let fixture = try await ContextFixture.make()
        defer { fixture.remove() }
        #expect(try fixture.schemeFiles() == ["Hello.xcscheme"])
        let directory = fixture.schemeURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: directory)
        try await fixture.manager.reloadProject()
        let base = try #require(await fixture.manager.projectSnapshot)
        #expect(base.schemes.isEmpty)
        let app = try #require(base.xcodeTargets.first { $0.name == "Hello" })
        let tests = try #require(base.xcodeTargets.first { $0.name == "HelloTests" })
        let options = try await fixture.manager.contextOptions(.init())
        #expect(options.dimensions.first?.options.isEmpty == true)
        let sources = await fixture.manager.getSourcesItems(targetIdentifiers: [app.targetIdentifier])
        #expect(sources.first?.sources.isEmpty == false)

        for target in [app, tests] {
            do {
                _ = try await fixture.manager.buildConfiguration(for: target)
                Issue.record("A missing scheme must produce an error")
            } catch {
                #expect(error.localizedDescription.contains("No existing scheme supports target '\(target.name)'"))
            }
            await #expect(throws: XcodeProjectError.self) {
                try await fixture.manager.compileTarget(targetIdentifier: target.targetIdentifier, configuration: nil)
            }
            await #expect(throws: XcodeProjectError.self) {
                try await fixture.manager.resolvedBuildSettings(for: target, arguments: nil)
            }
            await #expect(throws: XcodeProjectError.self) {
                try await fixture.manager.startDebugSession(
                    xcodeTargetIdentifier: target.targetIdentifier,
                    arguments: nil
                )
            }
        }
        await #expect(throws: XcodeProjectError.self) {
            try await fixture.manager.testCommands(
                for: [tests.targetIdentifier], arguments: ["-destination", "id=BSP-SIMULATOR"]
            )
        }
        let run = await fixture.manager.run(
            xcodeTargetIdentifier: app.targetIdentifier,
            arguments: nil,
            environmentVariables: nil,
            workingDirectory: nil
        )
        #expect(run.statusCode == .error)
        #expect(run.message?.contains("No existing scheme supports target 'Hello'") == true)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let entries = try #require(FileManager.default.enumerator(at: fixture.root, includingPropertiesForKeys: nil))
        #expect(entries.compactMap { $0 as? URL }.allSatisfy { $0.pathExtension != "xcscheme" })
    }

    @Test
    func reusesAnExistingSchemeWithADifferentName() async throws {
        let fixture = try await ContextFixture.make()
        defer { fixture.remove() }
        let base = try #require(await fixture.manager.projectSnapshot)
        let target = try #require(base.xcodeTargets.first { $0.name == "HelloTests" })
        let before = try Data(contentsOf: fixture.schemeURL)
        let selected = try await fixture.manager.findExistingScheme(for: target, in: base.schemes)
        #expect(selected.name == "Hello")
        let commands = try await fixture.manager.testCommands(
            for: [target.targetIdentifier], arguments: ["-destination", "id=BSP-SIMULATOR"]
        )
        let command = try #require(commands.first)
        let index = try #require(command.firstIndex(of: "-scheme"))
        #expect(command[index + 1] == "Hello")
        #expect(try fixture.schemeFiles() == ["Hello.xcscheme"])
        #expect(try Data(contentsOf: fixture.schemeURL) == before)
    }
}
