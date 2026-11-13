import Foundation
import SourceKitBSPProtocol
import Testing
@testable import XcodeProjectManagement
@testable import XcodeProjectManagerProvider

struct IndexingBackendTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SOURCEKIT_BSP_SWIFT_BUILD"] == "1"))
    func indexingBackendCreationDoesNotLoadWorkspace() async throws {
        let root = try configurationRoot(#"{"prepareForIndexing":true}"#)
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
        let index = try #require(await XcodeIndexingConfiguration.makeBackend(snapshot: snapshot))
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

    @Test(arguments: [nil, "{}", #"{"project":"Hello.xcodeproj"}"#, #"{"prepareForIndexing":false}"#])
    func preparationIsDisabledUnlessEnabled(contents: String?) throws {
        let root = try configurationRoot(contents)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try !XcodeIndexingConfiguration.load(root: root, environment: [:]).prepareForIndexing)
    }

    @Test
    func projectSettingEnablesPreparation() throws {
        let root = try configurationRoot(#"{"prepareForIndexing":true}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try XcodeIndexingConfiguration.load(root: root, environment: [:]).prepareForIndexing)
    }

    @Test(arguments: ["1", "true", "0", "false"])
    func environmentOverridesProjectSetting(value: String) throws {
        let enabled = value == "1" || value == "true"
        let root = try configurationRoot("{\"prepareForIndexing\":\(!enabled)}")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try XcodeIndexingConfiguration.load(
            root: root, environment: ["SOURCEKIT_BSP_PREPARE_FOR_INDEXING": value]
        )
        #expect(configuration.prepareForIndexing == enabled)
    }

    @Test
    func rejectsInvalidPreparationSettings() throws {
        let root = try configurationRoot(#"{"prepareForIndexing":"true"}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: DecodingError.self) {
            try XcodeIndexingConfiguration.load(root: root, environment: [:])
        }
        try Data("{}".utf8).write(to: root.appendingPathComponent(".sourcekit-bsp/project.json"))
        #expect(throws: XcodeProjectError.self) {
            try XcodeIndexingConfiguration.load(
                root: root, environment: ["SOURCEKIT_BSP_PREPARE_FOR_INDEXING": "typo"]
            )
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

    func failNextPreparation() {
        fail = true
    }

    func shutdown() {
        stopped = true
    }
}
