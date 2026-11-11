import BuildServerProtocol
import Foundation
import Testing
@testable import BSPServer

struct BuildOutputTargetIndexTests {
    private let root = URL(fileURLWithPath: "/workspace", isDirectory: true)

    private func target(_ name: String, project: String? = nil) throws -> BSPBuildTarget {
        let uri = try URI(string: project.map { "xcode:///workspace/\($0).xcodeproj/\(name)" }
            ?? "swiftpm:///workspace/\(name)")
        return BSPBuildTarget(id: .init(uri: uri), displayName: name, capabilities: .init())
    }

    private func source(_ path: String, kind: SourceItemKind = .file) -> SourceItem {
        SourceItem(uri: URI(filePath: path, isDirectory: kind == .directory), kind: kind, generated: false)
    }

    @Test
    func normalizesSourcesAndParsesRelativeAndFileURIDiagnostics() throws {
        let app = try target("App")
        let file = root.appendingPathComponent("Sources/A file 文.swift")
        let context = BuildOutputContext(
            rootURL: root,
            targets: [app],
            sources: [.init(target: app.id, sources: [source("/workspace/Sources/../Sources/A file 文.swift")])],
            affectedTargets: [app.id]
        )
        var parser = XcodeBuildOutputParser(context: context)
        let relative = parser.parse("Sources/../Sources/A file 文.swift:1:2: warning: unused")
        let absolute = parser.parse("\(file.absoluteString):1:2: warning: unused")
        #expect(relative.diagnostic?.target == app.id)
        #expect(relative.diagnostic?.file == file)
        #expect(absolute.diagnostic?.target == app.id)
        #expect(absolute.diagnostic?.file == file)
        #expect(parser.parse("Other.swift:1:2: warning: unknown file").diagnostic == nil)
    }

    @Test
    func directoriesMatchDescendantsWithoutDuplicateOwnersOrSiblingPrefixes() throws {
        let app = try target("App")
        let folder = root.appendingPathComponent("Sources", isDirectory: true)
        let file = folder.appendingPathComponent("Nested/A.swift")
        let sources = [
            source(folder.path, kind: .directory),
            source(file.path),
            source(file.path),
            source(folder.appendingPathComponent("Nested").path, kind: .directory),
        ]
        let context = BuildOutputContext(
            sources: [.init(target: app.id, sources: sources)]
        )
        let index = BuildOutputTargetIndex(context: context)
        #expect(index.target(for: file, named: nil, project: nil) == app.id)
        #expect(index.target(for: folder, named: nil, project: nil) == app.id)
        #expect(index.target(for: folder.appendingPathComponent("Other.swift"), named: nil, project: nil) == app.id)
        #expect(index.target(for: root.appendingPathComponent("SourcesExtra/A.swift"), named: nil, project: nil) == nil)
    }

    @Test
    func sharedFilesAndNestedDirectoriesRequireAnUnambiguousOwner() throws {
        let app = try target("App")
        let tests = try target("Tests")
        let file = root.appendingPathComponent("Sources/Nested/A.swift")
        let context = BuildOutputContext(
            targets: [app, tests],
            sources: [
                .init(target: app.id, sources: [source("/workspace/Sources", kind: .directory)]),
                .init(target: tests.id, sources: [source(file.path)]),
            ],
            affectedTargets: [app.id, tests.id]
        )
        let index = BuildOutputTargetIndex(context: context)
        #expect(index.target(for: file, named: nil, project: nil) == nil)
        #expect(index.target(for: file, named: "App", project: nil) == app.id)
        #expect(index.target(for: file, named: "Tests", project: nil) == tests.id)
        #expect(index.target(for: file, named: "Missing", project: nil) == nil)
    }

    @Test
    func namesUseProjectAndSourceOwnershipToResolveAmbiguity() throws {
        let first = try target("App", project: "First")
        let second = try target("App", project: "Second")
        let file = root.appendingPathComponent("First.swift")
        let shared = root.appendingPathComponent("Shared.swift")
        let context = BuildOutputContext(
            targets: [first, second],
            sources: [
                .init(target: first.id, sources: [source(file.path), source(shared.path)]),
                .init(target: second.id, sources: [source(shared.path)]),
            ],
            affectedTargets: [first.id, second.id]
        )
        let index = BuildOutputTargetIndex(context: context)
        #expect(index.target(for: file, named: "App", project: nil) == first.id)
        #expect(index.target(for: shared, named: "App", project: nil) == nil)
        #expect(index.target(for: shared, named: "App", project: "First") == first.id)
        #expect(index.target(for: shared, named: "App", project: "Second") == second.id)
        #expect(index.target(for: file, named: "App", project: "Missing") == nil)
        #expect(index.target(for: root.appendingPathComponent("Generated.swift"), named: "App", project: "Second")
            == second.id)
    }

    @Test
    func namedTargetsRespectAffectedTargetsAndNonXcodeProjects() throws {
        let xcode = try target("App", project: "Xcode")
        let package = try target("App")
        let excluded = try target("Excluded", project: "Xcode")
        let file = root.appendingPathComponent("A.swift")
        let context = BuildOutputContext(
            targets: [xcode, package, excluded],
            sources: [.init(target: package.id, sources: [source(file.path)])],
            affectedTargets: [xcode.id, package.id]
        )
        let index = BuildOutputTargetIndex(context: context)
        #expect(index.target(for: file, named: "App", project: "Other") == package.id)
        #expect(index.target(for: file, named: "App", project: "Xcode") == package.id)
        #expect(index.target(for: file, named: "Excluded", project: "Xcode") == nil)
    }

    @Test
    func ignoresNonFileSourcesAndPreservesAmbiguityAcrossSourceItems() throws {
        let app = try target("App")
        let file = root.appendingPathComponent("A.swift")
        let remote = try SourceItem(
            uri: URI(string: "https://example.test/workspace/A.swift"), kind: .file, generated: false
        )
        let context = BuildOutputContext(sources: [
            .init(target: app.id, sources: [remote]),
            .init(target: app.id, sources: [source(file.path)]),
            .init(target: app.id, sources: [source(file.path)]),
        ])
        let index = BuildOutputTargetIndex(context: context)
        #expect(index.target(for: file, named: nil, project: nil) == nil)
        #expect(index.target(for: root.appendingPathComponent("Other.swift"), named: nil, project: nil) == nil)
    }

    @Test
    func eachParserIndexesItsOwnContextSnapshot() throws {
        let first = try target("App", project: "First")
        let second = try target("App", project: "Second")
        var context = BuildOutputContext(
            rootURL: root,
            targets: [first],
            sources: [.init(target: first.id, sources: [source("/workspace/A.swift")])],
            affectedTargets: [first.id]
        )
        var original = XcodeBuildOutputParser(context: context)
        context.targets = [second]
        context.sources = [.init(target: second.id, sources: [source("/workspace/B.swift")])]
        context.affectedTargets = [second.id]
        var updated = XcodeBuildOutputParser(context: context)
        #expect(original.parse("A.swift:1:2: warning: unused").diagnostic?.target == first.id)
        #expect(original.parse("B.swift:1:2: warning: unused").diagnostic == nil)
        #expect(updated.parse("A.swift:1:2: warning: unused").diagnostic == nil)
        #expect(updated.parse("B.swift:1:2: warning: unused").diagnostic?.target == second.id)
        #expect(original.parse("Generated.swift:1:2: warning: unused (in target 'App' from project 'First')")
            .diagnostic?.target == first.id)
        #expect(updated.parse("Generated.swift:1:2: warning: unused (in target 'App' from project 'First')")
            .diagnostic == nil)
    }
}
