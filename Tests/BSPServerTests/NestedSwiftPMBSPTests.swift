import BuildServerProtocol
import Foundation
import Testing
@testable import BSPServer

struct NestedSwiftPMBSPTests {
    @Test(arguments: [false, true])
    func initializesTheParentWorkspaceAndResolvesItsScope(explicit: Bool) async throws {
        let fixture = try NestedWorkspace()
        let package = fixture.root.appendingPathComponent("p3", isDirectory: true)
        try fixture.write("""
        // swift-tools-version: 6.1
        import PackageDescription
        let package = Package(name: "Nested", targets: [.target(name: "Core")])
        """, to: "p3/Package.swift")
        try fixture.write("public let value = 1", to: "p3/Sources/Core/Core.swift")
        try fixture.write(
            #"<Workspace version="1.0"><FileRef location="self:"/></Workspace>"#,
            to: "p3/.swiftpm/xcode/package.xcworkspace/contents.xcworkspacedata"
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("Package.xcworkspace"),
            withDestinationURL: package.appendingPathComponent(".swiftpm/xcode/package.xcworkspace")
        )
        if explicit {
            try fixture.write(#"{"package":"p3"}"#, to: ".sourcekit-bsp/project.json")
            try fixture.write("invalid root manifest", to: "Package.swift")
            try fixture.write("", to: "p2/Package.swift")
            try fixture.write("", to: "App.xcodeproj/project.pbxproj")
        }
        let factory = await ProjectManagerProviderRegistry.createFactory()
        let service = BSPServerService.createStdioService(projectManagerProvider: factory)
        let handler = BSPMessageHandler()
        handler.setBSPServerService(service)
        let initializationURI = URL(fileURLWithPath: fixture.root.path, isDirectory: false).absoluteString
        let payload: [String: Any] = [
            "id": 1,
            "params": [
                "rootUri": initializationURI,
                "capabilities": ["languageIds": ["swift"]],
                "data": ["bspExtensions": [BuildContextExtension.name: ["version": "0.1"]]]
            ]
        ]
        let request = try JSONDecoder().decode(
            BuildInitializeRequest.self, from: JSONSerialization.data(withJSONObject: payload)
        )
        let response = try #require(await request.handle(
            contextualHandler: handler, id: .int(1)
        ) as? BuildInitializeResponse)
        #expect(response.result.rootUri == initializationURI)
        let manager = try #require(await service.getCurrentProjectManager())
        #expect(manager.projectType == "swiftpm")
        #expect(await manager.rootURL == package)
        #expect(await manager.workspaceRootURL.path == fixture.root.path)
        let target = try #require(await manager.getTargetList().first)
        let sources = try await manager.getSourceFileList(targetIdentifiers: [target.id])
        #expect(sources.flatMap(\.sources)
            .map(\.uri) == [URI(package.appendingPathComponent("Sources/Core/Core.swift"))])
        for isDirectory in [false, true] {
            let scope = BuildContextScope(workspaceUri: URI(filePath: fixture.root.path, isDirectory: isDirectory))
            let options = try await service.contextOptions(.init(scope: scope))
            let context = try await service.resolveContext(.init(
                scope: scope,
                operation: .compile,
                selection: options.selection
            ))
            #expect(context.targets == [target.id])
            #expect(try await service.executionContext(
                .init(id: context.id), operation: .compile, targets: [target.id]
            )?.targets == [target.id])
        }
        for invalid in [package, fixture.root.appendingPathComponent("Other")] {
            await #expect(throws: BuildContextError.self) {
                try await service.contextOptions(.init(scope: .init(workspaceUri: URI(invalid))))
            }
        }
        await service.shutdownProject()
    }

    @Test(arguments: ["project", "workspace"])
    func preservesExplicitXcodeSelectionInsteadOfDiscoveringASwiftPackage(key: String) async throws {
        let fixture = try NestedWorkspace()
        try fixture.write("", to: "p3/Package.swift")
        let content = key == "project" ? #"{"project":"Missing/App.xcodeproj"}"#
            : #"{"workspace":"Missing/App.xcworkspace"}"#
        try fixture.write(content, to: ".sourcekit-bsp/project.json")
        let configuration = try #require(try WorkspaceProjectConfiguration.load(at: fixture.root))
        #expect(configuration.preferredProvider == "XcodeProjectManagerProvider")
        let factory = await ProjectManagerProviderRegistry.createFactory()
        let service = BSPServerService.createStdioService(projectManagerProvider: factory)
        await #expect(throws: (any Error).self) {
            try await service.initializeProject(rootURL: fixture.root)
        }
        #expect(await service.getCurrentProjectManager() == nil)
    }

    @Test
    func rejectsConflictingMalformedAndMissingExplicitPackages() async throws {
        let fixture = try NestedWorkspace()
        for content in [
            #"{"package":"p3","project":"App.xcodeproj"}"#,
            #"{"package":"p3","workspace":"App.xcworkspace"}"#,
            #"{"package":" "}"#,
            #"{"package":42}"#,
            "{"
        ] {
            try fixture.write(content, to: ".sourcekit-bsp/project.json")
            #expect(throws: (any Error).self) { try WorkspaceProjectConfiguration.load(at: fixture.root) }
        }
        try fixture.write(#"{"package":"missing"}"#, to: ".sourcekit-bsp/project.json")
        try fixture.write("a root manifest must not hide the bad selection", to: "Package.swift")
        try fixture.write("", to: "App.xcodeproj/project.pbxproj")
        let factory = await ProjectManagerProviderRegistry.createFactory()
        let service = BSPServerService.createStdioService(projectManagerProvider: factory)
        do {
            try await service.initializeProject(rootURL: fixture.root)
            Issue.record("Expected the invalid explicit package to fail")
        } catch {
            #expect(error.localizedDescription.contains("missing"))
            #expect(error.localizedDescription.contains("Package.swift"))
        }
        #expect(await service.getCurrentProjectManager() == nil)
    }
}

private final class NestedWorkspace {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Nested BSP \(UUID())", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ content: String, to path: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
    }
}
