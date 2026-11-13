import Foundation
import SourceKitBSPProtocol
import Testing
@testable import XcodeProjectManagement

struct XcodeLaunchSelectionTests {
    @Test
    func separateProjectsKeepTheirTargetsContextsAndProductsAfterReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("XcodeLaunch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try #require(Bundle.module.resourceURL?.appendingPathComponent("DemoProjects/HelloProject"))
        for name in ["A", "B"] {
            try FileManager.default.copyItem(at: source, to: root.appendingPathComponent(name))
        }
        let settings = root.appendingPathComponent(".sourcekit-bsp")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        let config = settings.appendingPathComponent("project.json")
        try "{".write(to: config, atomically: true, encoding: .utf8)
        let first = try await manager(root: root, project: "A/Hello.xcodeproj")
        let second = try await manager(root: root, project: "B/Hello.xcodeproj")
        let firstBase = try #require(await first.projectSnapshot)
        let secondBase = try #require(await second.projectSnapshot)
        #expect(firstBase.xcodeTargets.map(\.name).sorted() == secondBase.xcodeTargets.map(\.name).sorted())
        #expect(Set(firstBase.xcodeTargets.map(\.targetIdentifier)).isDisjoint(
            with: secondBase.xcodeTargets.map(\.targetIdentifier)
        ))
        #expect(firstBase.xcodeGlobalSettings.derivedDataPath != secondBase.xcodeGlobalSettings.derivedDataPath)
        let firstContext = try await context(first, root: root, project: "A")
        let secondContext = try await context(second, root: root, project: "B")
        #expect(Set(firstContext.targets).isDisjoint(with: secondContext.targets))
        await #expect(throws: BuildContextError.self) { try await first.validateContext(secondContext) }
        for (manager, context, name) in [(first, firstContext, "A"), (second, secondContext, "B")] {
            let command = try await manager.contextBuildCommand(context, arguments: nil)
            let projectIndex = try #require(command.firstIndex(of: "-project"))
            #expect(command[projectIndex + 1] == root.appendingPathComponent("\(name)/Hello.xcodeproj").path)
            let dataIndex = try #require(command.firstIndex(of: "-derivedDataPath"))
            let base = try #require(await manager.projectSnapshot)
            #expect(command[dataIndex + 1] == base.xcodeGlobalSettings.derivedDataPath.path)
        }
        try #"{"project":"Missing.xcodeproj"}"#.write(to: config, atomically: true, encoding: .utf8)
        try await first.reloadProject()
        try await second.reloadProject()
        #expect(try await context(first, root: root, project: "A") == firstContext)
        #expect(try await context(second, root: root, project: "B") == secondContext)
        await first.stopContextDestinationDiscovery()
        await second.stopContextDestinationDiscovery()
    }

    @Test
    func explicitProjectDoesNotRequireAnImplicitWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Standalone-\(UUID())")
        let project = root.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = try XcodeProjectLocator().resolveProjectType(
            rootURL: root, xcodeProjectReference: .init(project: "App.xcodeproj")
        )
        guard case let .standaloneProject(resolved) = location else {
            Issue.record("Expected an explicitly selected standalone project")
            return
        }
        #expect(resolved.path == project.path)
    }

    private func manager(root: URL, project: String) async throws -> XcodeProjectManager {
        let toolchain = XcodeToolchain(workingDirectory: root)
        let discover: @Sendable () async throws -> String = { ContextInventory.connected }
        let manager = XcodeProjectManager(
            rootURL: root,
            xcodeProjectReference: .init(project: project),
            toolchain: toolchain,
            projectLocator: XcodeProjectLocator(),
            settingsLoader: XcodeSettingsLoader(commandBuilder: XcodeBuildCommandBuilder(), toolchain: toolchain),
            destinationDiscovery: discover
        )
        try await manager.initialize()
        return manager
    }

    private func context(_ manager: XcodeProjectManager, root: URL, project: String) async throws -> BuildContext {
        try await manager.resolveContext(.init(
            scope: .init(workspaceUri: URI(filePath: root.path, isDirectory: true)),
            operation: .compile,
            selection: [
                "xcode.scheme": root.appendingPathComponent(
                    "\(project)/Hello.xcodeproj/xcshareddata/xcschemes/Hello.xcscheme"
                ).absoluteString,
                "xcode.configuration": "Debug",
                "xcode.destination": "BSP-SIMULATOR"
            ]
        ))
    }
}
