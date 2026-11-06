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
        #expect(response.result.capabilities.compileProvider == nil)
        #expect(response.result.capabilities.testProvider == nil)
        #expect(response.result.capabilities.runProvider == nil)
        #expect(response.result.capabilities.debugProvider == nil)
        #expect(response.result.data.prepareProvider == false)
        #expect(response.result.data.sourceKitOptionsProvider == false)
        let manager = try #require(await service.getCurrentProjectManager())
        #expect(manager.projectType == "swiftpm")
        let project = try #require(await manager.project)
        #expect(response.result.data.indexStorePath == project.indexStoreURL.path)
        #expect(response.result.data.indexDatabasePath == project.indexDatabaseURL.path)
        let targets = await manager.getTargetList()
        let target = try #require(targets.first)
        #expect(targets.count == 1)
        #expect(target.displayName == "Core")
        #expect(target.capabilities.canCompile == false)
        let sources = try await manager.getSourceFileList(targetIdentifiers: [target.id])
        #expect(sources.flatMap(\.sources).map(\.uri) == [URI(source.resolvingSymlinksInPath())])
        await service.shutdownProject()
    }

    @Test
    func keepsXcodePriorityInMixedProjectFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BSP Mixed \(UUID())")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("Package.swift"))
        let providers = ProjectManagerProviderRegistry.getAllProviders()
        var matches: [String] = []
        for provider in providers where await provider.canHandle(projectURL: root) {
            matches.append(provider.name)
        }
        #if os(macOS)
        #expect(matches == ["XcodeProjectManagerProvider", "SwiftPMProjectManagerProvider"])
        #else
        #expect(matches == ["SwiftPMProjectManagerProvider"])
        #endif
    }
}
