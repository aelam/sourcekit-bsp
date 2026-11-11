import Foundation
import Testing
import XcodeProj
@testable import XcodeProjectManagement

struct SourceRootsTests {
    private func copyProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BSP Source Roots \(UUID())")
        let fixture = try #require(Bundle.module.resourceURL?.appendingPathComponent("DemoProjects/HelloProject"))
        try FileManager.default.copyItem(at: fixture, to: root)
        return root.resolvingSymlinksInPath()
    }

    @Test
    func derivesPhysicalGroupRootsWithoutTreatingVirtualGroupsAsDirectories() throws {
        let root = try copyProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Hello.xcodeproj")
        let project = try XcodeProj(pathString: projectURL.path)
        let main = try #require(try project.pbxproj.rootGroup())
        let app = try #require(project.pbxproj.nativeTargets.first { $0.name == "Hello" })
        let model = PBXFileReference(sourceTree: .group, path: "Model.swift")
        let view = PBXFileReference(sourceTree: .group, path: "View.swift")
        let loose = PBXFileReference(sourceTree: .sourceRoot, path: "Loose/Extra.swift")
        let shared = PBXFileReference(sourceTree: .group, path: "Shared.swift")
        let unused = PBXFileReference(sourceTree: .group, path: "Unused.swift")
        let models = PBXGroup(children: [model], sourceTree: .group, path: "Models")
        let views = PBXGroup(children: [view], sourceTree: .group, path: "Views")
        let virtual = PBXGroup(children: [loose], sourceTree: .group, name: "Display Only")
        let feature = PBXGroup(children: [models, views, virtual], sourceTree: .group, path: "Feature 空格%20")
        let external = root.deletingLastPathComponent().appendingPathComponent("Shared \(UUID())", isDirectory: true)
        let sharedGroup = PBXGroup(children: [shared], sourceTree: .absolute, path: external.path)
        let unrelated = PBXGroup(children: [unused], sourceTree: .group, path: "OtherTarget")
        let buildFiles = [model, view, loose, shared, model].map { PBXBuildFile(file: $0) }
        let phase = PBXSourcesBuildPhase(files: buildFiles)
        for object in [
            model,
            view,
            loose,
            shared,
            unused,
            models,
            views,
            virtual,
            feature,
            sharedGroup,
            unrelated,
            phase
        ] as [PBXObject] {
            project.pbxproj.add(object: object)
        }
        for file in buildFiles {
            project.pbxproj.add(object: file)
        }
        main.children = [feature, sharedGroup, unrelated]
        app.buildPhases = [phase]
        app.fileSystemSynchronizedGroups = nil
        try project.write(path: #require(project.path))

        var store = XcodeProjectStore()
        let loaded = store.project(at: projectURL)
        _ = try #require(loaded)
        let target = XcodeTargetIdentifier(projectFilePath: projectURL.path, targetName: "Hello")
        let items = store.sources(for: [target])
        let item = try #require(items.first)
        #expect(item.roots?.map(\.path) == [
            root.appendingPathComponent("Feature 空格%20").path,
            root.appendingPathComponent("Loose").path,
            external.path
        ].sorted())
        #expect(item.sources.count == 4)
        #expect(item.sources.allSatisfy { $0.itemKind == .file })
        #expect(Set(item.sources.map(\.path.path)) == [
            root.appendingPathComponent("Feature 空格%20/Models/Model.swift").path,
            root.appendingPathComponent("Feature 空格%20/Views/View.swift").path,
            root.appendingPathComponent("Loose/Extra.swift").path,
            external.appendingPathComponent("Shared.swift").path
        ])
    }

    @Test
    func cachesRootsWithSourcesAndPreservesIdentifiersForProjectAliases() throws {
        let root = try copyProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Hello.xcodeproj")
        let app = XcodeTargetIdentifier(projectFilePath: projectURL.path, targetName: "Hello")
        let tests = XcodeTargetIdentifier(projectFilePath: projectURL.path, targetName: "HelloTests")
        let missing = XcodeTargetIdentifier(projectFilePath: projectURL.path, targetName: "Missing")
        var store = XcodeProjectStore()
        let loaded = store.project(at: projectURL)
        let project = try #require(loaded)
        let initial = store.sources(for: [app, tests, missing])
        #expect(initial[0].roots?.map(\.path) == [root.appendingPathComponent("Hello").path])
        #expect(initial[1].roots?.map(\.path) == [root.appendingPathComponent("HelloTests").path])
        #expect(initial[2].roots == nil)

        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let aliasTarget = XcodeTargetIdentifier(
            projectFilePath: alias.appendingPathComponent("Hello.xcodeproj").path,
            targetName: "Hello"
        )
        let target = try #require(project.pbxproj.nativeTargets.first { $0.name == "Hello" })
        let group = try #require(target.fileSystemSynchronizedGroups?.first)
        group.path = "Moved"
        let moved = root.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        try Data("struct Moved {}".utf8).write(to: moved.appendingPathComponent("Moved.swift"))
        let cached = store.sources(for: [app, aliasTarget])
        #expect(cached.map(\.target) == [app, aliasTarget])
        #expect(cached.allSatisfy { $0.roots == initial[0].roots && $0.sources == initial[0].sources })
        store.invalidateSources()
        let refreshed = store.sources(for: [aliasTarget, app])
        #expect(refreshed.map(\.target) == [aliasTarget, app])
        #expect(refreshed.allSatisfy { $0.roots?.map(\.path) == [moved.path] })
        #expect(refreshed.allSatisfy { $0.sources.map(\.path.lastPathComponent) == ["Moved.swift"] })
    }

    @Test
    func keepsSharedFilesAndRootsSeparateAcrossProjectsWithTheSameTargetName() throws {
        let first = try copyProject(), second = try copyProject()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let shared = first.appendingPathComponent("Shared", isDirectory: true)
        var identifiers: [XcodeTargetIdentifier] = []
        var store = XcodeProjectStore()
        for root in [first, second] {
            let projectURL = root.appendingPathComponent("Hello.xcodeproj")
            let project = try XcodeProj(pathString: projectURL.path)
            let main = try #require(try project.pbxproj.rootGroup())
            let app = try #require(project.pbxproj.nativeTargets.first { $0.name == "Hello" })
            let reference = PBXFileReference(sourceTree: .group, path: "Utility.swift")
            let group = PBXGroup(children: [reference], sourceTree: .absolute, path: shared.path)
            let file = PBXBuildFile(file: reference)
            let phase = PBXSourcesBuildPhase(files: [file])
            for object in [reference, group, file, phase] as [PBXObject] {
                project.pbxproj.add(object: object)
            }
            main.children.append(group)
            app.buildPhases = [phase]
            app.fileSystemSynchronizedGroups = nil
            try project.write(path: #require(project.path))
            let loaded = store.project(at: projectURL)
            _ = try #require(loaded)
            identifiers.append(XcodeTargetIdentifier(projectFilePath: projectURL.path, targetName: "Hello"))
        }
        let items = store.sources(for: identifiers)
        #expect(items.map(\.target) == identifiers)
        #expect(items[0].target != items[1].target)
        #expect(items.allSatisfy { $0.roots?.map(\.path) == [shared.path] })
        #expect(items
            .allSatisfy { $0.sources.map(\.path.path) == [shared.appendingPathComponent("Utility.swift").path] })
    }
}
