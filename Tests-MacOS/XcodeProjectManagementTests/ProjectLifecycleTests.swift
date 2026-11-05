import Foundation
import Testing
import XcodeProj
@testable import XcodeProjectManagement

struct ProjectLifecycleTests {
    private func copyProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BSP Lifecycle \(UUID())")
        let fixture = try #require(Bundle.module.resourceURL?.appendingPathComponent("DemoProjects/HelloProject"))
        try FileManager.default.copyItem(at: fixture, to: root)
        return root.resolvingSymlinksInPath()
    }

    private func manager(at root: URL) async throws -> XcodeProjectManager {
        let toolchain = XcodeToolchain(workingDirectory: root)
        let manager = XcodeProjectManager(
            rootURL: root,
            toolchain: toolchain,
            projectLocator: XcodeProjectLocator(),
            settingsLoader: XcodeSettingsLoader(commandBuilder: XcodeBuildCommandBuilder(), toolchain: toolchain)
        )
        try await manager.initialize()
        return manager
    }

    @Test
    func generatedSchemeWritesPreserveUnchangedFiles() async throws {
        let root = try copyProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try await manager(at: root)
        let snapshot = try #require(await manager.projectSnapshot)
        let target = try #require(snapshot.xcodeTargets.first { $0.name == "Hello" })
        let scheme = try await manager.findOrCreateScheme(for: target, in: [])
        let original = try Data(contentsOf: scheme.path)
        let timestamp = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: scheme.path.path)

        let repeated = try await manager.findOrCreateScheme(for: target, in: [])
        #expect(repeated.path == scheme.path)
        #expect(try Data(contentsOf: scheme.path) == original)
        let attributes = try FileManager.default.attributesOfItem(atPath: scheme.path.path)
        #expect(attributes[.modificationDate] as? Date == timestamp)

        _ = try await manager.findOrCreateScheme(for: target, in: [], buildConfiguration: "Release")
        let changed = try XCScheme(pathString: scheme.path.path)
        #expect(changed.launchAction?.buildConfiguration == "Release")
        #expect(try Data(contentsOf: scheme.path) != original)
    }

    @Test
    func reloadsSourcesSettingsAndTargetsAndPreservesStateAfterInvalidSave() async throws {
        let root = try copyProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try await manager(at: root)
        let projectURL = root.appendingPathComponent("Hello.xcodeproj")
        let pbx = projectURL.appendingPathComponent("project.pbxproj")
        let base = try #require(await manager.projectSnapshot)
        let identifier = try #require(base.xcodeTargets.first { $0.name == "Hello" }).targetIdentifier
        let initialSources = await manager.getSourcesItems(targetIdentifiers: [identifier])
        #expect(initialSources.first?.sources.isEmpty == false)
        let added = root.appendingPathComponent("Hello/NewFile.swift")
        try "struct NewFile {}".write(to: added, atomically: true, encoding: .utf8)
        let cachedOptions = try await manager.getCompileArguments(
            targetIdentifier: identifier, sourceFileURL: root.appendingPathComponent("Hello/ContentView.swift")
        )
        #expect(!cachedOptions.contains { $0.hasSuffix("/Hello/NewFile.swift") })
        try await manager.reloadProject()
        let sources = await manager.getSourcesItems(targetIdentifiers: [identifier])
        #expect(sources.first?.sources.contains { $0.path.lastPathComponent == "NewFile.swift" } == true)
        let addedOptions = try await manager.getCompileArguments(
            targetIdentifier: identifier, sourceFileURL: root.appendingPathComponent("Hello/ContentView.swift")
        )
        #expect(addedOptions.contains { $0.hasSuffix("/Hello/NewFile.swift") })
        try FileManager.default.removeItem(at: added)

        let config = root.appendingPathComponent(".sourcekit-bsp/project.json")
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(XcodeProjectReference(project: "Hello.xcodeproj", configuration: "Release"))
            .write(to: config)
        let project = try XcodeProj(pathString: projectURL.path)
        let target = try #require(project.pbxproj.nativeTargets.first { $0.name == "HelloTests" })
        target.name = "RenamedTests"
        try project.pbxproj.write(path: .init(pbx.path), override: true, outputSettings: .init())
        try await manager.reloadProject()
        let reloaded = try #require(await manager.projectSnapshot)
        #expect(reloaded.configuration == "Release")
        #expect(reloaded.xcodeTargets.contains { $0.name == "RenamedTests" })
        let afterDelete = await manager.getSourcesItems(targetIdentifiers: [identifier])
        #expect(afterDelete.first?.sources.isEmpty == false)
        #expect(afterDelete.first?.sources.contains { $0.path.lastPathComponent == "NewFile.swift" } == false)
        let options = try await manager.getCompileArguments(
            targetIdentifier: identifier, sourceFileURL: root.appendingPathComponent("Hello/ContentView.swift")
        )
        #expect(!options.isEmpty)
        #expect(!options.contains { $0.hasSuffix("/Hello/NewFile.swift") })

        let saved = try Data(contentsOf: pbx)
        try Data("incomplete project".utf8).write(to: pbx)
        try "struct NewFile {}".write(to: added, atomically: true, encoding: .utf8)
        await #expect(throws: (any Error).self) { try await manager.reloadProject() }
        let retained = try #require(await manager.projectSnapshot)
        #expect(retained.xcodeTargets.map(\.name) == reloaded.xcodeTargets.map(\.name))
        let retainedOptions = try await manager.getCompileArguments(
            targetIdentifier: identifier, sourceFileURL: root.appendingPathComponent("Hello/ContentView.swift")
        )
        #expect(retainedOptions == options)
        let retainedSources = await manager.getSourcesItems(targetIdentifiers: [identifier])
        #expect(retainedSources == afterDelete)
        try saved.write(to: pbx)
        try FileManager.default.removeItem(at: config)
        try await manager.reloadProject()
        #expect(await manager.projectSnapshot?.configuration == "Debug")
    }

    @Test
    func loadsSourcesOnDemandAndReusesThemForCompilerArguments() async throws {
        let root = try copyProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try await manager(at: root)
        let base = try #require(await manager.projectSnapshot)
        let app = try #require(base.xcodeTargets.first { $0.name == "Hello" }).targetIdentifier
        let tests = try #require(base.xcodeTargets.first { $0.name == "HelloTests" }).targetIdentifier
        let missing = XcodeTargetIdentifier(projectFilePath: app.projectFilePath, targetName: "Missing")
        let initial = await manager.getSourcesItems(targetIdentifiers: [app, missing, app])
        #expect(initial.count == 3)
        #expect(initial[0] == initial[2])
        #expect(initial[1].sources.isEmpty)

        let added = root.appendingPathComponent("Hello/AddedAfterQuery.swift")
        try "struct AddedAfterQuery {}".write(to: added, atomically: true, encoding: .utf8)
        let cached = await manager.getSourcesItems(targetIdentifiers: [app])
        #expect(cached.first == initial.first)
        let options = try await manager.getCompileArguments(
            targetIdentifier: app, sourceFileURL: root.appendingPathComponent("Hello/ContentView.swift")
        )
        #expect(!options.contains { $0.hasSuffix("/Hello/AddedAfterQuery.swift") })

        let testSource = root.appendingPathComponent("HelloTests/AddedBeforeQuery.swift")
        try "struct AddedBeforeQuery {}".write(to: testSource, atomically: true, encoding: .utf8)
        let firstTestSources = await manager.getSourcesItems(targetIdentifiers: [tests])
        #expect(firstTestSources.first?.sources
            .contains { $0.path.resolvingSymlinksInPath() == testSource.resolvingSymlinksInPath() } == true)

        await manager.invalidateSourceFileCache()
        let refreshedOptions = try await manager.getCompileArguments(
            targetIdentifier: app, sourceFileURL: root.appendingPathComponent("Hello/ContentView.swift")
        )
        #expect(refreshedOptions.contains { $0.hasSuffix("/Hello/AddedAfterQuery.swift") })
    }

    @Test
    func cachesEmptyTargetsUntilSourcesAreInvalidated() async throws {
        let root = try copyProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("HelloTests")
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where file.pathExtension == "swift" {
            try FileManager.default.removeItem(at: file)
        }
        let manager = try await manager(at: root)
        let base = try #require(await manager.projectSnapshot)
        let target = try #require(base.xcodeTargets.first { $0.name == "HelloTests" }).targetIdentifier
        let initial = await manager.getSourcesItems(targetIdentifiers: [target])
        #expect(initial.first?.sources.isEmpty == true)
        let added = folder.appendingPathComponent("Generated.swift")
        try "struct Generated {}".write(to: added, atomically: true, encoding: .utf8)
        let cached = await manager.getSourcesItems(targetIdentifiers: [target])
        #expect(cached == initial)
        await manager.invalidateSourceFileCache()
        let refreshed = await manager.getSourcesItems(targetIdentifiers: [target])
        #expect(refreshed.first?.sources.map { $0.path.resolvingSymlinksInPath() } == [added.resolvingSymlinksInPath()])
    }

    @Test
    func validatesAllTestTargetsAndUsesValidSchemesAndRunnableDestinations() async throws {
        let root = try copyProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try await manager(at: root)
        let base = try #require(await manager.projectSnapshot)
        let tests = base.xcodeTargets.filter(\.xcodeProductType.isTestBundle)
        #expect(tests.count == 2)
        let arguments = [
            "-destination",
            "id=SIM",
            "-configuration",
            "Release",
            "-derivedDataPath",
            "/tmp/BSPTestOutput"
        ]
        let commands = try await manager.testCommands(for: tests.map(\.targetIdentifier), arguments: arguments)
        #expect(commands.count == 2)
        for (target, command) in zip(tests, commands) {
            #expect(command.contains("test"))
            #expect(!command.contains("test-without-building"))
            #expect(command.contains("-only-testing:\(target.name)"))
            #expect(command.contains("Release"))
            #expect(command.contains("/tmp/BSPTestOutput"))
            let schemeIndex = try #require(command.firstIndex(of: "-scheme"))
            let scheme = try XCScheme(pathString: target.projectURL
                .appendingPathComponent("xcshareddata/xcschemes/\(command[schemeIndex + 1]).xcscheme").path)
            let project = try XcodeProj(pathString: target.projectURL.path)
            let native = try #require(project.pbxproj.nativeTargets.first { $0.name == target.name })
            #expect(scheme.testAction?.testables.contains {
                $0.buildableReference.blueprintIdentifier == native.uuid
            } == true)
        }
        let first = try #require(tests.first)
        let filtered = try await manager.testCommands(
            for: tests.map(\.targetIdentifier), arguments: arguments + ["-only-testing:\(first.name)/Example/test"]
        )
        #expect(filtered.count == 1)
        #expect(filtered[0].contains("-only-testing:\(first.name)/Example/test"))
        #expect(!filtered[0].contains("-only-testing:\(first.name)"))
        let invalid = XcodeTargetIdentifier(projectFilePath: first.projectURL.path, targetName: "Missing")
        await #expect(throws: XcodeProjectError.self) {
            try await manager.testCommands(for: [first.targetIdentifier, invalid], arguments: arguments)
        }
        await #expect(throws: XcodeProjectError.self) {
            try await manager.testCommands(
                for: [first.targetIdentifier],
                arguments: ["-destination", "generic/platform=iOS Simulator"]
            )
        }
        await #expect(throws: XcodeProjectError.self) {
            try await manager.testCommands(
                for: [first.targetIdentifier],
                arguments: arguments + ["-only-testing:Unknown"]
            )
        }
        let deduplicated = try await manager.testCommands(
            for: [first.targetIdentifier, first.targetIdentifier], arguments: arguments
        )
        #expect(deduplicated.count == 1)
    }
}
