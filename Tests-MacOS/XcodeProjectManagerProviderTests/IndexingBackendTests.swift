import Foundation
import SourceKitBSPProtocol
import Support
import Testing
@testable import XcodeProjectManagement
@testable import XcodeProjectManagerProvider

struct IndexingBackendTests {
    @Test
    func indexingBackendCreationDoesNotLoadWorkspace() async throws {
        let root = try configurationRoot(nil)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = XcodeProjectSnapshot(
            rootURL: root,
            projectLocation: .standaloneProject(root.appendingPathComponent("NotLoaded.xcodeproj")),
            xcodeGlobalSettings: .init(derivedDataPath: root.appendingPathComponent("DerivedData")),
            xcodeTargets: [],
            schemes: [],
            configuration: "Debug",
            xcodeInstallation: .init(
                path: root.appendingPathComponent("NotLoaded.xcode"),
                version: "27.0", buildVersion: "test",
                isXcodeVersionFileVersion: false, isDeveloperDirVersion: false, isXcodeSelectedVersion: false
            )
        )
        // Missing workspace and toolchain paths must not block the BSP connection.
        let index = try #require(await XcodeIndexingConfiguration(enableBuildTargetPrepare: true)
            .makeBackend(snapshot: snapshot))
        #expect(index.indexStoreURL == snapshot.xcodeGlobalSettings.indexStoreURL)
        #expect(index.indexDatabaseURL == snapshot.xcodeGlobalSettings.indexDatabaseURL)
        await index.shutdown()
        await #expect(throws: CancellationError.self) {
            try await index.compilerArguments(
                for: XcodeTargetIdentifier(
                    projectFilePath: root.appendingPathComponent("NotLoaded.xcodeproj").path,
                    targetName: "App"
                ),
                file: root.appendingPathComponent("App.swift")
            )
        }
    }

    @Test
    func routesIndexingWithoutChangingExecutionTargetsOrProducts() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = RecordingIndexingBackend(root: root)
        let toolchain = XcodeToolchain(workingDirectory: root)
        let backend = XcodeProjectManager(
            rootURL: root, toolchain: toolchain, projectLocator: XcodeProjectLocator(),
            settingsLoader: XcodeSettingsLoader(commandBuilder: XcodeBuildCommandBuilder(), toolchain: toolchain)
        )
        let manager = XcodeBSPProjectManager(backend: backend, indexingFactory: { _ in index })
        try await manager.initialize()
        let project = try #require(await manager.project)
        let target = try #require(project.targets.first { $0.displayName == "Hello" })
        #expect(target.capabilities.canCompile == true)
        #expect(target.capabilities.canRun == true)
        #expect(target.capabilities.canDebug == true)
        #expect(project.indexStoreURL == index.indexStoreURL)
        #expect(project.indexDatabaseURL == index.indexDatabaseURL)
        #expect(await manager.preparesIndexingOnRequest)
        #expect(await !manager.capabilities.contains(.cleanCache))
        #expect(project.buildRootURL != index.indexStoreURL)
        let products = try await manager.outputPaths(for: [target.id])
        #expect(products.first?.outputPaths.first?.uri.fileURL?.path
            == project.buildRootURL.appendingPathComponent("Build/Products").path)
        let sources = try await manager.getSourceFileList(targetIdentifiers: [target.id])
        let file = try #require(sources.first?.sources.first?.uri.fileURL)
        let arguments = try await manager.getCompileArguments(
            targetIdentifier: target.id.uri.stringValue,
            sourceFileURL: file
        )
        #expect(arguments == ["-module-name", "EngineModule", file.path])
        #expect(await index.requestedTarget?.targetName == "Hello")
        #expect(try await manager.buildIndex(for: [target.id]) == [])
        #expect(await index.preparedTargets.map(\.targetName) == ["Hello"])
        await manager.invalidateIndexInputs()
        #expect(await index.invalidated)
        await index.failNextPreparation()
        await #expect(throws: RecordingIndexingBackend.Failure.self) {
            try await manager.buildIndex(for: [target.id])
        }
        await manager.shutdown()
        #expect(await index.stopped)
    }

    @Test(arguments: [false, true])
    func providerUsesLaunchSettingAcrossReloads(enabled: Bool) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(".sourcekit-bsp")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A legacy project setting must not override the process's launch option.
        try Data("{\"prepareForIndexing\":\(!enabled)}".utf8)
            .write(to: directory.appendingPathComponent("project.json"))
        let provider = XcodeProjectManagerProvider(enableBuildTargetPrepare: enabled)
        let manager = try await provider.createProjectManager(rootURL: root, config: nil)
        do {
            try await manager.initialize()
            #expect(await manager.preparesIndexingOnRequest == enabled)
            try await manager.updateBuildGraph()
            #expect(await manager.preparesIndexingOnRequest == enabled)
            await manager.shutdown()
        } catch {
            await manager.shutdown()
            throw error
        }
    }

    @Test
    func selectionChangesKeepTheBackendAndProjectModel() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = CrossPlatformLock(initialState: [RecordingIndexingBackend]())
        let toolchain = XcodeToolchain(workingDirectory: root)
        let backend = XcodeProjectManager(
            rootURL: root, toolchain: toolchain, projectLocator: XcodeProjectLocator(),
            settingsLoader: XcodeSettingsLoader(commandBuilder: XcodeBuildCommandBuilder(), toolchain: toolchain)
        )
        let manager = XcodeBSPProjectManager(backend: backend, indexingFactory: { _ in
            let index = RecordingIndexingBackend(root: root)
            created.withLock { $0.append(index) }
            return index
        })
        do {
            try await manager.initialize()
            let project = try #require(await manager.project)
            let index = try #require(created.withLock { $0.first })
            let graph = await backend.buildGraphVersion
            let file = XcodeIndexingSelection.file(in: project.buildRootURL)
            let release = XcodeIndexingSelection(platform: "iphonesimulator", configuration: "Release")
            _ = try release.save(in: project.buildRootURL)
            #expect(await manager.shouldReloadProject(for: [.init(uri: URI(file), kind: .changed)]))
            try await manager.updateBuildGraph()
            #expect(created.withLock { $0.count } == 1)
            #expect(await backend.buildGraphVersion == graph)
            #expect(await index.selectionUpdates == [release])
            #expect(await !index.stopped)

            try FileManager.default.removeItem(at: file)
            #expect(await manager.shouldReloadProject(for: [.init(uri: URI(file), kind: .deleted)]))
            try await manager.updateBuildGraph()
            #expect(created.withLock { $0.count } == 1)
            #expect(await index.selectionUpdates == [release, nil])
            #expect(await backend.buildGraphVersion == graph)

            // A project edit must take precedence over a selection update in the same batch.
            _ = try release.save(in: project.buildRootURL)
            #expect(await manager.shouldReloadProject(for: [
                .init(uri: URI(file), kind: .changed),
                .init(uri: URI(root.appendingPathComponent("Hello.xcodeproj/project.pbxproj")), kind: .changed)
            ]))
            try await manager.updateBuildGraph()
            #expect(created.withLock { $0.count } == 2)
            #expect(await backend.buildGraphVersion != graph)
            #expect(await index.stopped)
            await manager.shutdown()
        } catch {
            await manager.shutdown()
            throw error
        }
    }

    private func configurationRoot(_ contents: String?) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".sourcekit-bsp"),
            withIntermediateDirectories: true
        )
        if let contents {
            try Data(contents.utf8).write(to: root.appendingPathComponent(".sourcekit-bsp/project.json"))
        }
        return root
    }

    private func fixture() throws -> URL {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("XcodeProjectManagementTests/Resources/DemoProjects/HelloProject")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Index Backend \(UUID())")
        try FileManager.default.copyItem(at: source, to: root)
        return root
    }
}

private actor RecordingIndexingBackend: XcodeIndexingBackend {
    enum Failure: Error { case preparation }
    nonisolated let indexStoreURL: URL
    nonisolated let indexDatabaseURL: URL
    var requestedTarget: XcodeTargetIdentifier?
    var preparedTargets: [XcodeTargetIdentifier] = []
    var stopped = false
    var invalidated = false
    var fail = false
    var selectionUpdates: [XcodeIndexingSelection?] = []

    init(root: URL) {
        self.indexStoreURL = root.appendingPathComponent("Index/Store")
        self.indexDatabaseURL = root.appendingPathComponent("Index/Database")
    }

    func compilerArguments(for target: XcodeTargetIdentifier, file: URL) -> [String] {
        requestedTarget = target
        return ["-module-name", "EngineModule", file.path]
    }

    func prepare(
        targets: [XcodeTargetIdentifier],
        log: (@Sendable (String) -> Void)?
    ) throws -> [XcodeTargetIdentifier] {
        if fail { throw Failure.preparation }
        preparedTargets = targets
        return []
    }

    func invalidateInputs() {
        invalidated = true
    }

    func updateSelection(_ selection: XcodeIndexingSelection?) {
        selectionUpdates.append(selection)
    }

    func failNextPreparation() {
        fail = true
    }

    func shutdown() {
        stopped = true
    }
}
