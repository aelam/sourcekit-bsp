import Foundation
import Testing
import XcodeProj
@testable import XcodeProjectManagement

struct SourceFileListerTests {
    @Test
    func expandsFoldersAndAppliesTargetExclusions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BSP Sources \(UUID())")
        let fixture = try #require(Bundle.module.resourceURL?.appendingPathComponent("DemoProjects/HelloProject"))
        try FileManager.default.copyItem(at: fixture, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Hello.xcodeproj")
        let project = try XcodeProj(pathString: projectURL.path)
        let app = try #require(project.pbxproj.nativeTargets.first { $0.name == "Hello" })
        let tests = try #require(project.pbxproj.nativeTargets.first { $0.name == "HelloTests" })
        let group = try #require(app.fileSystemSynchronizedGroups?.first)
        let excluded = PBXFileSystemSynchronizedBuildFileExceptionSet(
            target: app, membershipExceptions: ["Excluded.swift", "ExcludedFolder"],
            publicHeaders: nil, privateHeaders: nil,
            additionalCompilerFlagsByRelativePath: nil, attributesByRelativePath: nil
        )
        let otherTarget = PBXFileSystemSynchronizedBuildFileExceptionSet(
            target: tests, membershipExceptions: ["ContentView.swift"],
            publicHeaders: nil, privateHeaders: nil,
            additionalCompilerFlagsByRelativePath: nil, attributesByRelativePath: nil
        )
        project.pbxproj.add(object: excluded)
        project.pbxproj.add(object: otherTarget)
        group.exceptions = [excluded, otherTarget]
        group.explicitFolders = ["ResourceFolder"]
        for path in [
            "Nested/Extra.swift",
            "Excluded.swift",
            "ExcludedFolder/Other.swift",
            "ResourceFolder/Data.swift"
        ] {
            let file = root.appendingPathComponent("Hello/\(path)")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "".write(to: file, atomically: true, encoding: .utf8)
        }
        let identifier = XcodeTargetIdentifier(projectFilePath: projectURL.path, targetName: "Hello")
        let item = try #require(SourceFileLister
            .loadSourcesItems(for: project, targets: ["Hello"])[identifier.rawValue])
        let sources = item.sources
        #expect(sources.allSatisfy { $0.itemKind == .file })
        #expect(sources.map(\.path.lastPathComponent) == ["ContentView.swift", "HelloApp.swift", "Extra.swift"])
        #expect(item.roots?.map(\.path) == [root.appendingPathComponent("Hello").path])
        excluded.membershipExceptions = [
            "ContentView.swift",
            "HelloApp.swift",
            "Nested",
            "Excluded.swift",
            "ExcludedFolder"
        ]
        let empty = try #require(SourceFileLister
            .loadSourcesItems(for: project, targets: ["Hello"])[identifier.rawValue])
        #expect(empty.sources.isEmpty)
        #expect(empty.roots == [])
    }
}
