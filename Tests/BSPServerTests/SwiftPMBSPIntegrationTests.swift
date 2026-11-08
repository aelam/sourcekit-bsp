import BuildServerProtocol
import Foundation
import JSONRPCConnection
import Testing
@testable import BSPServer

struct SwiftPMBSPIntegrationTests {
    @Test
    func initializesPackageThroughRegisteredProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BSP Package \(UUID())")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/Core"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        // swift-tools-version: 6.1
        import PackageDescription
        let package = Package(name: "Probe", targets: [.target(name: "Core")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let source = root.appendingPathComponent("Sources/Core/Core.swift")
        try "public let value = 1".write(to: source, atomically: true, encoding: .utf8)
        let generated = root.appendingPathComponent(".swiftpm/xcode/package.xcworkspace")
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        try #"<Workspace version="1.0"><FileRef location="self:"/></Workspace>"#.write(
            to: generated.appendingPathComponent("contents.xcworkspacedata"), atomically: true, encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Package.xcworkspace"), withDestinationURL: generated
        )
        let factory = await ProjectManagerProviderRegistry.createFactory()
        let service = BSPServerService.createStdioService(projectManagerProvider: factory)
        let handler = BSPMessageHandler()
        handler.setBSPServerService(service)
        let payload: [String: Any] = [
            "id": 1, "params": ["rootUri": root.absoluteString, "capabilities": ["languageIds": ["swift"]]]
        ]
        let request = try JSONDecoder().decode(
            BuildInitializeRequest.self, from: JSONSerialization.data(withJSONObject: payload)
        )
        let response = try #require(await request.handle(
            contextualHandler: handler, id: .int(1)
        ) as? BuildInitializeResponse)
        #expect(response.result.capabilities.compileProvider != nil)
        #expect(response.result.capabilities.testProvider != nil)
        #expect(response.result.capabilities.runProvider != nil)
        #expect(response.result.capabilities.outputPathsProvider == true)
        #if os(macOS)
        #expect(response.result.capabilities.debugProvider != nil)
        #else
        #expect(response.result.capabilities.debugProvider == nil)
        #endif
        #expect(response.result.data.prepareProvider == false)
        #expect(response.result.data.sourceKitOptionsProvider == false)
        #expect(response.result.capabilities.dependencyModulesProvider == true)
        let manager = try #require(await service.getCurrentProjectManager())
        #expect(manager.projectType == "swiftpm")
        let project = try #require(await manager.project)
        #expect(response.result.data.indexStorePath == project.indexStoreURL.path)
        #expect(response.result.data.indexDatabasePath == project.indexDatabaseURL.path)
        let targets = await manager.getTargetList()
        let target = try #require(targets.first)
        #expect(targets.count == 1)
        #expect(target.displayName == "Core")
        #expect(target.capabilities.canCompile == true)
        #expect(target.capabilities.canRun == false)
        #expect(target.capabilities.canDebug == false)
        let sources = try await manager.getSourceFileList(targetIdentifiers: [target.id])
        #expect(sources.flatMap(\.sources).map(\.uri) == [URI(source.resolvingSymlinksInPath())])
        let outputs = try await service.outputPaths(for: [target.id])
        let output = try #require(outputs.first?.outputPaths.first)
        #expect(outputs.first?.target == target.id)
        #expect(output.kind == .directory)
        let outputURL = try #require(output.uri.fileURL)
        #expect(outputURL.path.contains("/\(root.lastPathComponent)/.build/"))
        #expect(outputURL.lastPathComponent.lowercased() == "debug")
        let modulesRequest = BuildTargetDependencyModulesRequest(params: .init(targets: [target.id]))
        let modulesResponse = try #require(await modulesRequest.handle(contextualHandler: handler, id: .int(2))
            as? BuildTargetDependencyModulesResponse)
        #expect(modulesResponse.result.items == [.init(target: target.id, modules: [])])
        await service.shutdownProject()
    }

    @Test
    func requiresExplicitSelectionInMixedProjectFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BSP Mixed \(UUID())")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("Package.swift"))
        try Data().write(to: root.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        let providers = ProjectManagerProviderRegistry.getAllProviders()
        var matches: [String] = []
        for provider in providers where await provider.canHandle(projectURL: root) {
            matches.append(provider.name)
        }
        #if os(macOS)
        #expect(matches == ["XcodeProjectManagerProvider", "SwiftPMProjectManagerProvider"])
        let factory = await ProjectManagerProviderRegistry.createFactory()
        do {
            _ = try await factory.createProjectManager(rootURL: root)
            Issue.record("Expected an explicit build-system selection")
        } catch {
            #expect(error.localizedDescription.contains("--package"))
            #expect(error.localizedDescription.contains("--project"))
        }
        #else
        #expect(matches == ["SwiftPMProjectManagerProvider"])
        #endif
    }
}
