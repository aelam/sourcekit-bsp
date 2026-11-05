import BuildServerProtocol
import Foundation
import Testing
import XcodeProj
@testable import XcodeProjectManagement
@testable import XcodeProjectManagerProvider

struct XcodeBSPProjectTests {
    @Test
    func convertsWorkspaceTargetsWithoutMergingEqualNames() throws {
        let root = URL(fileURLWithPath: "/tmp/Workspace With Spaces")
        let appURL = root.appendingPathComponent("App.xcodeproj")
        let libraryURL = root.appendingPathComponent("Library.xcodeproj")
        let app = XcodeTarget(
            targetIdentifier: .init(projectFilePath: appURL.path, targetName: "Shared Name"),
            name: "Shared Name",
            projectURL: appURL,
            productName: "App",
            xcodeProductType: .application
        )
        let library = XcodeTarget(
            targetIdentifier: .init(projectFilePath: libraryURL.path, targetName: "Shared Name"),
            name: "Shared Name",
            projectURL: libraryURL,
            productName: "Library",
            xcodeProductType: .framework
        )
        let snapshot = XcodeProjectSnapshot(
            rootURL: root,
            projectLocation: .explicitWorkspace(root.appendingPathComponent("Example.xcworkspace")),
            xcodeGlobalSettings: .init(derivedDataPath: root.appendingPathComponent("Build")),
            xcodeTargets: [app, library],
            schemes: [],
            configuration: "Debug",
            xcodeInstallation: .init(
                path: URL(fileURLWithPath: "/Applications/Xcode.app"),
                version: "26.0",
                buildVersion: "17A",
                isXcodeVersionFileVersion: false,
                isDeveloperDirVersion: false,
                isXcodeSelectedVersion: true
            )
        )
        let project = snapshot.asBSPProject(dependencies: [app.targetIdentifier: [library.targetIdentifier]])
        #expect(project.name == "Example.xcworkspace")
        #expect(project.rootURL == root)
        #expect(project.targets.count == 2)
        let mapped = try #require(project.target(for: app.targetIdentifier.bspIdentifier))
        #expect(mapped.dependencies == [library.targetIdentifier.bspIdentifier])
        #expect(mapped.capabilities.canRun == true)
        #expect(project.target(for: library.targetIdentifier.bspIdentifier)?.capabilities.canRun == false)
        #expect(XcodeTargetIdentifier(mapped.id) == app.targetIdentifier)
        #expect(project.indexStoreURL == snapshot.xcodeGlobalSettings.indexStoreURL)
        #expect(project.buildRootURL == snapshot.xcodeGlobalSettings.derivedDataPath)
    }

    @Test
    func publishesReloadedModelAndKeepsPreviousModelAfterFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BSP Model \(UUID())")
            .resolvingSymlinksInPath()
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("XcodeProjectManagementTests/Resources/DemoProjects/HelloProject")
        try FileManager.default.copyItem(at: fixture, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let toolchain = XcodeToolchain(workingDirectory: root)
        let backend = XcodeProjectManager(
            rootURL: root,
            toolchain: toolchain,
            projectLocator: XcodeProjectLocator(),
            settingsLoader: XcodeSettingsLoader(commandBuilder: XcodeBuildCommandBuilder(), toolchain: toolchain)
        )
        let manager = XcodeBSPProjectManager(backend: backend)
        #expect(await manager.project == nil)
        await #expect(throws: XcodeProjectError.self) {
            try await manager.getSourceFileList(targetIdentifiers: [])
        }
        try await manager.initialize()
        let initial = try #require(await manager.project)
        #expect(await manager.getTargetList() == initial.targets)
        #expect(initial.name == "Hello.xcodeproj")
        let app = try #require(initial.targets.first { $0.displayName == "Hello" })
        let tests = try #require(initial.targets.first { $0.displayName == "HelloTests" })
        #expect(tests.dependencies.contains(app.id))
        #expect(tests.capabilities.canTest == true)

        // Conversion must not populate the source cache for every target.
        let added = root.appendingPathComponent("Hello/AfterInitialize.swift")
        try Data("struct AfterInitialize {}".utf8).write(to: added)
        let sources = try await manager.getSourceFileList(targetIdentifiers: [app.id])
        #expect(sources.first?.sources
            .contains { $0.uri.fileURL?.lastPathComponent == "AfterInitialize.swift" } == true)

        let compilerArguments = try await manager.getCompileArguments(
            targetIdentifier: app.id.uri.stringValue,
            sourceFileURL: added
        )
        #expect(compilerArguments.contains(added.path))

        let projectURL = root.appendingPathComponent("Hello.xcodeproj")
        let project = try XcodeProj(pathString: projectURL.path)
        let target = try #require(project.pbxproj.nativeTargets.first { $0.name == "HelloTests" })
        target.name = "RenamedTests"
        let pbx = projectURL.appendingPathComponent("project.pbxproj")
        try project.pbxproj.write(path: .init(pbx.path), override: true, outputSettings: .init())
        #expect(await manager.getTargetList() == initial.targets)
        try FileManager.default.removeItem(at: added)
        try await manager.updateBuildGraph()
        let reloaded = try #require(await manager.project)
        #expect(reloaded.target(for: tests.id) == nil)
        let renamed = try #require(reloaded.targets.first { $0.displayName == "RenamedTests" })
        #expect(renamed.dependencies.contains(app.id))
        #expect(await manager.getTargetList() == reloaded.targets)
        let refreshedSources = try await manager.getSourceFileList(targetIdentifiers: [app.id])
        #expect(refreshedSources.first?.sources.isEmpty == false)
        #expect(refreshedSources.first?.sources.contains {
            $0.uri.fileURL?.lastPathComponent == "AfterInitialize.swift"
        } == false)
        await #expect(throws: XcodeProjectError.self) {
            try await manager.getSourceFileList(targetIdentifiers: [tests.id])
        }

        try Data("incomplete project".utf8).write(to: pbx)
        await #expect(throws: (any Error).self) { try await manager.updateBuildGraph() }
        #expect(await manager.getTargetList() == reloaded.targets)
        #expect(try await manager.getSourceFileList(targetIdentifiers: [app.id]) == refreshedSources)
        if case let .loaded(project) = await manager.getProjectState().projectLoadState {
            #expect(project.targets == reloaded.targets)
        } else {
            Issue.record("The last loaded BSP project must remain available after a failed reload")
        }
        await manager.shutdown()
    }
}
