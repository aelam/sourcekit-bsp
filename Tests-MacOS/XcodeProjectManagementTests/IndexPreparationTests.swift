import Foundation
import Testing
@testable import XcodeProjectManagement

struct IndexPreparationTests {
    @Test
    func buildsIndexInputsAndRetriesAfterSourceChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BSP Index \(UUID().uuidString)")
        let fixture = try #require(Bundle.module.resourceURL?.appendingPathComponent("DemoProjects/HelloProject"))
        try FileManager.default.copyItem(at: fixture, to: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let toolchain = XcodeToolchain(workingDirectory: root)
        let manager = XcodeProjectManager(
            rootURL: root,
            toolchain: toolchain,
            projectLocator: XcodeProjectLocator(),
            settingsLoader: XcodeSettingsLoader(commandBuilder: XcodeBuildCommandBuilder(), toolchain: toolchain)
        )
        try await manager.initialize()
        let base = try #require(await manager.projectSnapshot)
        let appTarget = base.xcodeTargets.first { $0.name == "Hello" }
        let app = try #require(appTarget)
        let derivedData = base.xcodeGlobalSettings.derivedDataPath
        defer { try? FileManager.default.removeItem(at: derivedData) }

        let initialKey = await manager.indexPreparationKey(for: app.targetIdentifier)
        #expect(await manager.indexPreparationKey(for: app.targetIdentifier) == initialKey)
        await manager.invalidateIndexInputs()
        #expect(await manager.indexPreparationKey(for: app.targetIdentifier) != initialKey)

        let arguments = await manager.indexBuildArguments(for: app)
        #expect(arguments.contains("generic/platform=iOS Simulator"))
        #expect(arguments.contains("CODE_SIGNING_ALLOWED=NO"))
        #expect(arguments.contains("INDEX_DATA_STORE_DIR=\(base.xcodeGlobalSettings.indexStoreURL.path)"))
        #expect(arguments.contains(derivedData.path))
        let empty = try await manager.prepareForIndexing(targetIdentifiers: [])
        #expect(empty.isEmpty)
        let missing = XcodeTargetIdentifier(projectFilePath: app.projectURL.path, targetName: "Missing")
        await #expect(throws: IndexPreparationError.self) {
            try await manager.prepareForIndexing(targetIdentifiers: [app.targetIdentifier, missing])
        }
        #expect(!FileManager.default.fileExists(atPath: derivedData.path))

        // Concurrent requests must share the build database without lock errors.
        async let first = manager.prepareForIndexing(targetIdentifiers: [app.targetIdentifier, app.targetIdentifier])
        async let second = manager.prepareForIndexing(targetIdentifiers: [app.targetIdentifier])
        async let compile = manager.compileTarget(
            targetIdentifier: app.targetIdentifier, configuration: nil, arguments: ["CODE_SIGNING_ALLOWED=NO"]
        )
        let (_, _, compileStatus) = try await (first, second, compile)
        #expect(await manager.indexPreparationCoordinator.operationCount == 0)
        #expect(compileStatus == 0)
        let units = base.xcodeGlobalSettings.indexStoreURL.appendingPathComponent("v5/units")
        #expect(try !FileManager.default.contentsOfDirectory(atPath: units.path).isEmpty)
        let settings = try await manager.resolvedBuildSettings(for: app, arguments: arguments)
        #expect(settings["CONFIGURATION"] == base.configuration)
        #expect(settings["PLATFORM_NAME"] == "iphonesimulator")
        #expect(settings["INDEX_DATA_STORE_DIR"] == base.xcodeGlobalSettings.indexStoreURL.path)
        let options = try await manager.getCompileArguments(
            targetIdentifier: app.targetIdentifier, sourceFileURL: root.appendingPathComponent("Hello/HelloApp.swift")
        )
        let indexFlag = try #require(options.firstIndex(of: "-index-store-path"))
        #expect(options[indexFlag + 1] == base.xcodeGlobalSettings.indexStoreURL.path)

        // A successful request must not hide a later source error.
        let source = root.appendingPathComponent("Hello/ContentView.swift")
        let original = try String(contentsOf: source, encoding: .utf8)
        try (original + "\nlet brokenIndexInput: MissingIndexType = 0\n").write(
            to: source, atomically: true, encoding: .utf8
        )
        do {
            _ = try await manager.prepareForIndexing(targetIdentifiers: [app.targetIdentifier])
            Issue.record("Preparation accepted invalid Swift source")
        } catch {
            #expect(error.localizedDescription.contains("MissingIndexType"))
        }
        try original.write(to: source, atomically: true, encoding: .utf8)
        _ = try await manager.prepareForIndexing(targetIdentifiers: [app.targetIdentifier])
        let unchanged = try await manager.prepareForIndexing(targetIdentifiers: [app.targetIdentifier])
        #expect(unchanged.isEmpty)

        let interrupted = Task {
            try await manager.prepareForIndexing(targetIdentifiers: [app.targetIdentifier])
        }
        try await Task.sleep(for: .milliseconds(100))
        interrupted.cancel()
        await #expect(throws: CancellationError.self) {
            try await interrupted.value
        }
        _ = try await manager.prepareForIndexing(targetIdentifiers: [app.targetIdentifier])
        await manager.stopIndexPreparation()
    }
}
