import Foundation
import Testing
@testable import XcodeProjectManagement

struct XcodeContainerDiscoveryTests {
    @Test
    func ignoresGeneratedSwiftPMWorkspacesIncludingSymlinkAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GeneratedWorkspace-\(UUID())")
        let generated = root.appendingPathComponent(".swiftpm/xcode/package.xcworkspace")
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"<?xml version="1.0"?><Workspace version="1.0"><FileRef location="self:"></FileRef></Workspace>"#.write(
            to: generated.appendingPathComponent("contents.xcworkspacedata"), atomically: true, encoding: .utf8
        )
        let alias = root.appendingPathComponent("Package.xcworkspace")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: generated)
        for url in [generated, alias] {
            #expect(XcodeContainerDiscovery.isSwiftPMPackageWorkspace(url))
            #expect(!XcodeContainerDiscovery.isBuildContainer(url))
            do {
                _ = try XcodeProjectLocator().resolveProjectType(
                    rootURL: root, xcodeProjectReference: .init(workspace: url.path)
                )
                Issue.record("Expected generated package workspace selection to fail")
            } catch {
                #expect(error.localizedDescription.contains("--package"))
            }
        }
        #expect(throws: XcodeProjectError.projectNotFound) {
            try XcodeProjectLocator().resolveProjectType(rootURL: root)
        }
        let fake = root.appendingPathComponent("Fake.xcodeproj")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        #expect(!XcodeContainerDiscovery.isBuildContainer(fake))
        try "".write(to: fake.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        #expect(XcodeContainerDiscovery.isBuildContainer(fake))
    }
}
