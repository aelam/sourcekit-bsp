import Foundation
import Testing
import XcodeProj
@testable import XcodeProjectManagement

struct XcodeProjectStoreTests {
    private func copyProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BSP Sources \(UUID())")
        let fixture = try #require(Bundle.module.resourceURL?.appendingPathComponent("DemoProjects/HelloProject"))
        try FileManager.default.copyItem(at: fixture, to: root)
        return root.resolvingSymlinksInPath()
    }

    @Test
    func loadsOnlyRequestedTargetsAndReusesTheirSourceLists() throws {
        let root = try copyProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Hello.xcodeproj")
        let app = XcodeTargetIdentifier(projectFilePath: project.path, targetName: "Hello")
        let tests = XcodeTargetIdentifier(projectFilePath: project.path, targetName: "HelloTests")
        var store = XcodeProjectStore()
        let loaded = store.project(at: project)
        let parsed = try #require(loaded)
        #expect(store.project(at: project) === parsed)
        let initial = store.sources(for: [app])
        #expect(initial.first?.sources.isEmpty == false)

        let addedApp = root.appendingPathComponent("Hello/Later.swift")
        let addedTest = root.appendingPathComponent("HelloTests/LaterTest.swift")
        try Data("struct Later {}".utf8).write(to: addedApp)
        try Data("struct LaterTest {}".utf8).write(to: addedTest)
        let missing = XcodeTargetIdentifier(projectFilePath: project.path, targetName: "Missing")
        let result = store.sources(for: [tests, app, missing, app])
        #expect(result.map(\.target) == [tests, app, missing, app])
        #expect(result[0].sources.contains { $0.path.resolvingSymlinksInPath() == addedTest.resolvingSymlinksInPath() })
        #expect(result[1].sources == initial[0].sources)
        #expect(result[2].sources.isEmpty)
        #expect(result[3].sources == initial[0].sources)
        #expect(store.sources(for: []).isEmpty)
    }

    @Test
    func keepsTargetsWithTheSameNameInDifferentProjectsSeparate() throws {
        let firstRoot = try copyProject()
        defer { try? FileManager.default.removeItem(at: firstRoot) }
        let secondRoot = try copyProject()
        defer { try? FileManager.default.removeItem(at: secondRoot) }
        let firstProject = firstRoot.appendingPathComponent("Hello.xcodeproj")
        let secondProject = secondRoot.appendingPathComponent("Hello.xcodeproj")
        let first = XcodeTargetIdentifier(projectFilePath: firstProject.path, targetName: "Hello")
        let second = XcodeTargetIdentifier(projectFilePath: secondProject.path, targetName: "Hello")
        var store = XcodeProjectStore()
        let loadedFirst = store.project(at: firstProject)
        _ = try #require(loadedFirst)
        #expect(store.sources(for: [second])[0].sources.isEmpty)
        let loadedSecond = store.project(at: secondProject)
        _ = try #require(loadedSecond)
        let firstSources = store.sources(for: [first])[0].sources
        let added = secondRoot.appendingPathComponent("Hello/Second.swift")
        try Data("struct Second {}".utf8).write(to: added)
        let result = store.sources(for: [second, first])
        #expect(result[0].sources.contains { $0.path.resolvingSymlinksInPath() == added.resolvingSymlinksInPath() })
        #expect(result[0].sources
            .allSatisfy { $0.path.resolvingSymlinksInPath().path.hasPrefix(secondRoot.path + "/") })
        #expect(result[1].sources == firstSources)
        #expect(result[1].sources.allSatisfy { $0.path.resolvingSymlinksInPath().path.hasPrefix(firstRoot.path + "/") })
    }

    @Test
    func sharesSourcesAcrossProjectPathAliasesAndPreservesRequestedIdentifiers() throws {
        let root = try copyProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let project = root.appendingPathComponent("Hello.xcodeproj")
        let aliasProject = alias.appendingPathComponent("Hello.xcodeproj")
        let target = XcodeTargetIdentifier(projectFilePath: project.path, targetName: "Hello")
        let aliasTarget = XcodeTargetIdentifier(projectFilePath: aliasProject.path, targetName: "Hello")
        var store = XcodeProjectStore()
        let loaded = store.project(at: project)
        let parsed = try #require(loaded)
        #expect(store.project(at: aliasProject) === parsed)
        let initial = store.sources(for: [target])[0].sources
        #expect(!initial.isEmpty)
        let added = root.appendingPathComponent("Hello/Later.swift")
        try Data("struct Later {}".utf8).write(to: added)
        let cached = store.sources(for: [aliasTarget, target])
        #expect(cached.map(\.target) == [aliasTarget, target])
        #expect(cached.allSatisfy { $0.sources == initial })
        store.invalidateSources()
        let refreshed = store.sources(for: [aliasTarget, target])
        #expect(refreshed[0].sources == refreshed[1].sources)
        #expect(refreshed[0].sources.contains { $0.path.lastPathComponent == "Later.swift" })
    }

    @Test
    func invalidatesEmptySourceListsWithoutReparsingProjects() throws {
        let root = try copyProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("HelloTests")
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
        let project = root.appendingPathComponent("Hello.xcodeproj")
        let tests = XcodeTargetIdentifier(projectFilePath: project.path, targetName: "HelloTests")
        var store = XcodeProjectStore()
        let loaded = store.project(at: project)
        let parsed = try #require(loaded)
        #expect(store.sources(for: [tests])[0].sources.isEmpty)
        let added = directory.appendingPathComponent("Added.swift")
        try Data("struct Added {}".utf8).write(to: added)
        #expect(store.sources(for: [tests])[0].sources.isEmpty)

        store.invalidateSources()
        #expect(store.project(at: project) === parsed)
        #expect(store.sources(for: [tests])[0].sources
            .map { $0.path.resolvingSymlinksInPath() } == [added.resolvingSymlinksInPath()])
    }

    @Test(arguments: [true, false])
    func resolvesDirectSharedGroupsRegardlessOfOrder(rootFirst: Bool) throws {
        let root = try copyProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Hello.xcodeproj")
        let fixture = try XcodeProj(pathString: projectURL.path)
        let mainGroup = try #require(try fixture.pbxproj.rootGroup())
        let app = try #require(fixture.pbxproj.nativeTargets.first { $0.name == "Hello" })
        let input = PBXFileReference(sourceTree: .group, path: "Input.swift")
        let config = PBXFileReference(sourceTree: .group, path: "Settings.xcconfig")
        let rooted = PBXFileReference(sourceTree: .sourceRoot, path: "Rooted.swift")
        let absoluteURL = root.appendingPathComponent("Absolute.swift")
        let absolute = PBXFileReference(sourceTree: .absolute, path: absoluteURL.path)
        let shared = PBXGroup(children: [input, config, rooted, absolute], sourceTree: .group, path: "Module/Sources")
        let nestedInput = PBXFileReference(sourceTree: .group, path: "Input.swift")
        let nestedGroup = PBXGroup(children: [nestedInput], sourceTree: .group, path: "Module/Sources")
        let wrapper = PBXGroup(children: [shared, nestedGroup], sourceTree: .group, path: "Module")
        let files = [input, nestedInput, rooted, absolute].map { PBXBuildFile(file: $0) }
        let phase = PBXSourcesBuildPhase(files: files)
        for object in [
            input,
            nestedInput,
            config,
            rooted,
            absolute,
            shared,
            nestedGroup,
            wrapper,
            phase
        ] as [PBXObject] {
            fixture.pbxproj.add(object: object)
        }
        for file in files {
            fixture.pbxproj.add(object: file)
        }
        mainGroup.children = rootFirst ? [shared, wrapper] : [wrapper, shared]
        app.buildPhases = [phase]
        app.fileSystemSynchronizedGroups = nil
        let debug = try #require(app.buildConfigurationList?.buildConfigurations.first { $0.name == "Debug" })
        debug.baseConfiguration = config
        try fixture.write(path: #require(fixture.path))
        let projectFile = projectURL.appendingPathComponent("project.pbxproj")
        let original = try Data(contentsOf: projectFile)

        var store = XcodeProjectStore()
        let loaded = store.project(at: projectURL)
        let project = try #require(loaded)
        let target = XcodeTargetIdentifier(projectFilePath: projectURL.path, targetName: "Hello")
        let expectedFolder = root.appendingPathComponent("Module/Sources")
        let expectedInput = expectedFolder.appendingPathComponent("Input.swift")
        // Generated inputs must keep their declared paths before the files exist.
        #expect(!FileManager.default.fileExists(atPath: expectedInput.path))
        #expect(Set(store.sources(for: [target])[0].sources.map(\.path)) == [
            expectedInput, root.appendingPathComponent("Module/Module/Sources/Input.swift"),
            root.appendingPathComponent("Rooted.swift"), absoluteURL
        ])
        let loadedConfig = try #require(project.pbxproj.fileReferences.first { $0.path == "Settings.xcconfig" })
        #expect(try loadedConfig.fullPath(sourceRoot: root.path) == expectedFolder
            .appendingPathComponent("Settings.xcconfig").path)
        store.invalidateSources()
        #expect(store.sources(for: [target])[0].sources.contains { $0.path == expectedInput })
        #expect(try Data(contentsOf: projectFile) == original)
    }

    @Test
    func resolvesSharedSynchronizedGroups() throws {
        let root = try copyProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Hello.xcodeproj")
        let fixture = try XcodeProj(pathString: projectURL.path)
        let mainGroup = try #require(try fixture.pbxproj.rootGroup())
        let app = try #require(fixture.pbxproj.nativeTargets.first { $0.name == "Hello" })
        let group = try #require(app.fileSystemSynchronizedGroups?.first)
        let wrapper = PBXGroup(children: [group], sourceTree: .group, path: "Extra")
        fixture.pbxproj.add(object: wrapper)
        mainGroup.children.append(wrapper)
        try fixture.write(path: #require(fixture.path))

        var store = XcodeProjectStore()
        let loaded = store.project(at: projectURL)
        _ = try #require(loaded)
        let target = XcodeTargetIdentifier(projectFilePath: projectURL.path, targetName: "Hello")
        let sources = store.sources(for: [target])[0].sources
        #expect(Set(sources.map(\.path.lastPathComponent)) == ["ContentView.swift", "HelloApp.swift"])
        #expect(Set(sources.map { $0.path.resolvingSymlinksInPath().deletingLastPathComponent().path }) == [
            root.appendingPathComponent("Hello").path
        ])
    }

    @Test(arguments: [true, false])
    func resolvesSharedGroupsUnderSiblingParents(reverseOrder: Bool) throws {
        let root = try copyProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Hello.xcodeproj")
        let fixture = try XcodeProj(pathString: projectURL.path)
        let mainGroup = try #require(try fixture.pbxproj.rootGroup())
        let app = try #require(fixture.pbxproj.nativeTargets.first { $0.name == "Hello" })
        let input = PBXFileReference(sourceTree: .group, path: "Input.swift")
        let shared = PBXGroup(children: [input], sourceTree: .group, path: "Sources")
        let first = PBXGroup(children: [shared], sourceTree: .group, path: "First")
        let second = PBXGroup(children: [shared], sourceTree: .group, path: "Second")
        let buildFile = PBXBuildFile(file: input)
        let phase = PBXSourcesBuildPhase(files: [buildFile])
        for object in [input, shared, first, second, buildFile, phase] as [PBXObject] {
            fixture.pbxproj.add(object: object)
        }
        mainGroup.children = reverseOrder ? [second, first] : [first, second]
        app.buildPhases = [phase]
        app.fileSystemSynchronizedGroups = nil
        try fixture.write(path: #require(fixture.path))

        var store = XcodeProjectStore()
        let loaded = store.project(at: projectURL)
        _ = try #require(loaded)
        let target = XcodeTargetIdentifier(projectFilePath: projectURL.path, targetName: "Hello")
        let expected = root
            .appendingPathComponent(reverseOrder ? "First/Sources/Input.swift" : "Second/Sources/Input.swift")
        #expect(store.sources(for: [target])[0].sources.map(\.path) == [expected])
    }
}
