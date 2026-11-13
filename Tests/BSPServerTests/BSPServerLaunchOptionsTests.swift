import Foundation
import JSONRPCConnection
import SourceKitBSPProtocol
import Testing
@testable import BSPServer

struct BSPServerLaunchOptionsTests {
    @Test
    func parsesSelectorsAndPreservesDebugOnlyStartup() throws {
        #expect(try BSPServerLaunchOptions(arguments: []).configuration == nil)
        #expect(try BSPServerLaunchOptions(arguments: ["--debug"]).configuration == nil)
        for selector in ["--package", "--project", "--workspace"] {
            let options = try BSPServerLaunchOptions(arguments: ["--debug", selector, "relative path", "--debug"])
            let config = try #require(options.configuration)
            if selector == "--package" {
                #expect(config.packagePath == "relative path")
                #expect(config.preferredProvider == "SwiftPMProjectManagerProvider")
            } else {
                #expect(config.customSettings[String(selector.dropFirst(2))] == "relative path")
                #expect(config.preferredProvider == "XcodeProjectManagerProvider")
            }
        }
    }

    @Test(arguments: [
        ["--package"], ["--project", ""], ["--workspace", " "], ["--unknown"],
        ["--package", "--debug"], ["--package", "A", "--package", "A"],
        ["--package", "A", "--project", "B"], ["--workspace", "A", "--project", "B"]
    ])
    func rejectsMalformedOrConflictingSelectors(arguments: [String]) {
        #expect(throws: (any Error).self) { try BSPServerLaunchOptions(arguments: arguments) }
    }

    @Test
    func twoPackagesKeepIndependentTargetsContextsAndOutputsAcrossReloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Launch BSP \(UUID())",
            isDirectory: true
        )
        .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["A", "B"] {
            let package = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: package.appendingPathComponent("Sources/Core"), withIntermediateDirectories: true
            )
            try """
            // swift-tools-version: 6.1
            import PackageDescription
            let package = Package(name: "\(name)", targets: [.target(name: "Core")])
            """.write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            try "public let value = 1".write(
                to: package.appendingPathComponent("Sources/Core/Core.swift"), atomically: true, encoding: .utf8
            )
        }
        let configDirectory = root.appendingPathComponent(".sourcekit-bsp")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let configFile = configDirectory.appendingPathComponent("project.json")
        try "{".write(to: configFile, atomically: true, encoding: .utf8)
        let first = try await service(package: "A", root: root)
        let second = try await service(package: "B", root: root)
        let firstManager = try #require(await first.getCurrentProjectManager())
        let secondManager = try #require(await second.getCurrentProjectManager())
        #expect(await firstManager.workspaceRootURL.path == root.path)
        #expect(await secondManager.workspaceRootURL.path == root.path)
        #expect(await firstManager.rootURL.path == root.appendingPathComponent("A").path)
        #expect(await secondManager.rootURL.path == root.appendingPathComponent("B").path)
        let scope = BuildContextScope(workspaceUri: URI(root))
        let firstContext = try await first.resolveContext(.init(scope: scope, operation: .compile))
        let secondContext = try await second.resolveContext(.init(scope: scope, operation: .compile))
        #expect(Set(firstContext.targets).isDisjoint(with: secondContext.targets))
        #expect(await firstManager.project?.buildRootURL != secondManager.project?.buildRootURL)
        await #expect(throws: BuildContextError.self) {
            try await second.executionContext(
                .init(id: firstContext.id),
                operation: .compile,
                targets: firstContext.targets
            )
        }
        await #expect(throws: BuildContextError.self) {
            try await first.resolveContext(.init(scope: .init(targets: secondContext.targets), operation: .compile))
        }
        try #"{"package":"missing"}"#.write(to: configFile, atomically: true, encoding: .utf8)
        try await first.reloadProject()
        try await second.reloadProject()
        #expect(await firstManager.getTargetList().map(\.id) == firstContext.targets)
        #expect(await secondManager.getTargetList().map(\.id) == secondContext.targets)
        await first.shutdownProject()
        await second.shutdownProject()
    }

    private func service(package: String, root: URL) async throws -> BSPServerService {
        let factory = await ProjectManagerProviderRegistry.createFactory()
        let handler = BSPMessageHandler()
        let connection = JSONRPCConnection(
            transport: MemoryTransport(),
            messageRegistry: bspRegistry,
            messageHandler: handler
        )
        let options = try BSPServerLaunchOptions(arguments: ["--package", package])
        let service = BSPServerService(
            projectManagerProvider: factory, jsonrpcConnection: connection, launchConfiguration: options.configuration
        )
        handler.setBSPServerService(service)
        try await service.initializeProject(rootURL: root)
        _ = await service.negotiateBuildContext([
            "bspExtensions": [BuildContextExtension.name: ["version": "0.1"]]
        ])
        return service
    }
}
