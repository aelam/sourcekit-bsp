import Foundation
import Support
import Testing
@testable import XcodeProjectManagement

struct SwiftBuildIndexingCacheTests {
    @Test(
        .timeLimit(.minutes(2)),
        arguments: [false, true]
    )
    func handlesEvictedDescriptions(prepareAfterEachTarget: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Index Cache \(UUID())")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try makeProject(in: root)
        let derivedData = root.appendingPathComponent("DerivedData")
        _ = try XcodeIndexingSelection(platform: "macosx", configuration: "Debug").save(in: derivedData)
        let toolchain = XcodeToolchain(workingDirectory: root)
        try await toolchain.initialize()
        let installation = try #require(await toolchain.getSelectedInstallation())
        let snapshot = XcodeProjectSnapshot(
            rootURL: root,
            projectLocation: .standaloneProject(project),
            xcodeGlobalSettings: .init(derivedDataPath: derivedData),
            xcodeTargets: [],
            schemes: [],
            configuration: "Debug",
            xcodeInstallation: installation
        )
        let service = Bundle(for: IndexCacheBundleLocator.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("SWBBuildServiceBundle")
        let backend = try #require(await XcodeIndexingConfiguration(enableBuildTargetPrepare: true).makeBackend(
            snapshot: snapshot,
            serviceExecutable: service
        ))
        let engine = try #require(backend as? SwiftBuildIndexingBackend)
        do {
            // Swift Build keeps four descriptions by default. Seven targets force eviction.
            let targets = (0 ..< 7).map {
                XcodeTargetIdentifier(projectFilePath: project.path, targetName: "Library\($0)")
            }
            // Library0 -> Library1 -> Library2: prepare the dependency before its consumer.
            let logs = CrossPlatformLock(initialState: [String]())
            #expect(try await backend.prepare(targets: [targets[1], targets[2]]) { message in
                logs.withLock { $0.append(message) }
            }.isEmpty)
            #expect(logs.withLock { $0.count(where: { $0 == "Index preparation build started" }) } == 1)
            #expect(try await backend.prepare(targets: [targets[0]], log: nil).isEmpty)
            var initialOptions: [[String]] = []
            for target in targets {
                let options = try await backend.compilerArguments(
                    for: target, file: root.appendingPathComponent("\(target.targetName).swift")
                )
                #expect(options.contains(target.targetName))
                initialOptions.append(options)
                if prepareAfterEachTarget {
                    #expect(try await backend.prepare(targets: [target], log: nil).isEmpty)
                }
            }
            // Query the oldest description before prepare has a chance to recreate it.
            let before = await engine.statistics
            let first = try await backend.compilerArguments(
                for: targets[0], file: root.appendingPathComponent("Library0.swift")
            )
            #expect(first == initialOptions[0])
            if !prepareAfterEachTarget {
                #expect(await engine.statistics.buildDescriptions == before.buildDescriptions)
                #expect(await engine.statistics.compilerArgumentQueries == before.compilerArgumentQueries)
                #expect(await engine.statistics.compilerArgumentCacheHits == before.compilerArgumentCacheHits + 1)
            }
            logs.withLock { $0.removeAll() }
            // Duplicate targets must still produce one native operation.
            #expect(try await backend.prepare(targets: targets + [targets[0]]) { message in
                logs.withLock { $0.append(message) }
            }.isEmpty)
            #expect(logs.withLock { $0.count(where: { $0 == "Index preparation build started" }) } == 1)
            // Both an evicted target and a surviving plan can still read the batch description.
            for index in [0, 6] {
                #expect(try await backend.compilerArguments(
                    for: targets[index], file: root.appendingPathComponent("Library\(index).swift")
                ) == initialOptions[index])
            }
            for (target, expected) in zip(targets, initialOptions) {
                let options = try await backend.compilerArguments(
                    for: target, file: root.appendingPathComponent("\(target.targetName).swift")
                )
                #expect(options == expected)
            }
            let missing = XcodeTargetIdentifier(projectFilePath: project.path, targetName: "Missing")
            logs.withLock { $0.removeAll() }
            await #expect(throws: (any Error).self) {
                try await backend.prepare(targets: [targets[0], missing]) { message in
                    logs.withLock { $0.append(message) }
                }
            }
            #expect(logs.withLock { $0.isEmpty })
            #expect(try await backend.prepare(targets: [targets[0], targets[1]], log: nil).isEmpty)
            await backend.shutdown()
        } catch {
            await backend.shutdown()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func cachesArgumentsAcrossContextReadsAndReusesTheSessionWhenSelectionChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Index Selection \(UUID())")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try makeProject(in: root)
        let derivedData = root.appendingPathComponent("DerivedData")
        let debug = XcodeIndexingSelection(platform: "macosx", configuration: "Debug")
        _ = try debug.save(in: derivedData)
        let toolchain = XcodeToolchain(workingDirectory: root)
        try await toolchain.initialize()
        let installation = try #require(await toolchain.getSelectedInstallation())
        let snapshot = XcodeProjectSnapshot(
            rootURL: root,
            projectLocation: .standaloneProject(project),
            xcodeGlobalSettings: .init(derivedDataPath: derivedData),
            xcodeTargets: [],
            schemes: [],
            configuration: "Debug",
            xcodeInstallation: installation
        )
        let service = Bundle(for: IndexCacheBundleLocator.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("SWBBuildServiceBundle")
        let engine = try SwiftBuildIndexingBackend(snapshot: snapshot, serviceExecutable: service)
        let target = XcodeTargetIdentifier(projectFilePath: project.path, targetName: "Library0")
        let file = root.appendingPathComponent("Library0.swift")
        do {
            let initial = try await engine.compilerArguments(for: target, file: file)
            #expect(initial.contains { $0.contains("INDEX_DEBUG") })
            let cold = await engine.statistics
            for _ in 0 ..< 10 {
                try await engine.updateSelection(debug)
                #expect(try await engine.compilerArguments(for: target, file: file) == initial)
            }
            #expect(await engine.statistics.workspaceLoads == 1)
            #expect(await engine.statistics.buildDescriptions == cold.buildDescriptions)
            #expect(await engine.statistics.compilerArgumentQueries == cold.compilerArgumentQueries)
            #expect(await engine.statistics.compilerArgumentCacheHits == 10)

            try Data("public struct EditedValue {}\n".utf8).write(to: file)
            await engine.invalidateInputs(preservingArguments: true)
            #expect(try await engine.compilerArguments(for: target, file: file) == initial)
            #expect(await engine.statistics.compilerArgumentQueries == cold.compilerArgumentQueries)

            await engine.invalidateInputs()
            #expect(try await engine.compilerArguments(for: target, file: file) == initial)
            #expect(await engine.statistics.compilerArgumentQueries == cold.compilerArgumentQueries + 1)

            // Preparing unchanged dependencies preserves the cached compiler arguments.
            let dependency = XcodeTargetIdentifier(projectFilePath: project.path, targetName: "Library1")
            #expect(try await engine.prepare(targets: [dependency], log: nil).isEmpty)
            #expect(try await engine.compilerArguments(for: target, file: file) == initial)
            #expect(await engine.statistics.compilerArgumentQueries == cold.compilerArgumentQueries + 1)

            try await engine.updateSelection(.init(platform: "macosx", configuration: "Release"))
            let release = try await engine.compilerArguments(for: target, file: file)
            #expect(release.contains { $0.contains("INDEX_RELEASE") })
            #expect(!release.contains { $0.contains("INDEX_DEBUG") })
            #expect(await engine.statistics.workspaceLoads == 1)
            #expect(await engine.statistics.buildDescriptions == cold.buildDescriptions + 1)

            try await engine.updateSelection(.init(platform: "macosx"))
            #expect(try await engine.compilerArguments(for: target, file: file) == initial)
            #expect(await engine.statistics.workspaceLoads == 1)
            await engine.shutdown()
            await #expect(throws: CancellationError.self) {
                try await engine.compilerArguments(for: target, file: file)
            }
        } catch {
            await engine.shutdown()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func sharesArgumentAndSourceQueriesAcrossConcurrentRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Index Queries \(UUID())")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try makeProject(in: root, extraSource: true)
        let derivedData = root.appendingPathComponent("DerivedData")
        _ = try XcodeIndexingSelection(platform: "macosx", configuration: "Debug").save(in: derivedData)
        let toolchain = XcodeToolchain(workingDirectory: root)
        try await toolchain.initialize()
        let installation = try #require(await toolchain.getSelectedInstallation())
        let snapshot = XcodeProjectSnapshot(
            rootURL: root,
            projectLocation: .standaloneProject(project),
            xcodeGlobalSettings: .init(derivedDataPath: derivedData),
            xcodeTargets: [],
            schemes: [],
            configuration: "Debug",
            xcodeInstallation: installation
        )
        let service = Bundle(for: IndexCacheBundleLocator.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("SWBBuildServiceBundle")
        let engine = try SwiftBuildIndexingBackend(snapshot: snapshot, serviceExecutable: service)
        let target = XcodeTargetIdentifier(projectFilePath: project.path, targetName: "Library0")
        let files = ["Library0.swift", "Library0Extra.swift"].map { root.appendingPathComponent($0) }
        do {
            for pass in 1 ... 2 {
                try await withThrowingTaskGroup(of: [String].self) { group in
                    for index in 0 ..< 40 {
                        let file = files[index % files.count]
                        group.addTask { try await engine.compilerArguments(for: target, file: file) }
                    }
                    for try await arguments in group {
                        #expect(arguments.contains("Library0"))
                        #expect(arguments.contains { $0.contains("INDEX_DEBUG") })
                    }
                }
                let statistics = await engine.statistics
                #expect(statistics.workspaceLoads == 1)
                #expect(statistics.buildDescriptions == 1)
                #expect(statistics.sourceQueries == 1)
                #expect(statistics.compilerArgumentQueries == pass * files.count)
                await engine.invalidateInputs()
            }
            await engine.shutdown()
        } catch {
            await engine.shutdown()
            throw error
        }
    }

    @Test
    func invalidatedArgumentsCannotBePublishedByAnOlderQuery() {
        let target = XcodeTargetIdentifier(projectFilePath: "/tmp/Cache.xcodeproj", targetName: "Library0")
        let key = SwiftBuildIndexingArgumentsCache.Key(target: target, file: URL(fileURLWithPath: "/tmp/File.swift"))
        var cache = SwiftBuildIndexingArgumentsCache()
        let oldVersion = cache.version
        let initial = cache.publish(["old"], for: key, version: oldVersion)
        #expect(initial)
        cache.invalidate()
        #expect(cache.cached(for: key) == nil)
        #expect(cache.published(for: target)[key] == ["old"])
        let current = cache.publish(["new"], for: key, version: cache.version)
        let stale = cache.publish(["stale"], for: key, version: oldVersion)
        #expect(current)
        #expect(!stale)
        #expect(cache.cached(for: key) == ["new"])
    }
}

extension SwiftBuildIndexingCacheTests {
    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func sharesSelectedDescriptionAcrossTargets(selectAllTargets: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Shared Index \(UUID())")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try makeProject(in: root, extraSource: true)
        let targets = (0 ..< 7).map {
            XcodeTargetIdentifier(projectFilePath: project.path, targetName: "Library\($0)")
        }
        let roots = selectAllTargets ? targets : [targets[0]]
        let covered = selectAllTargets ? targets : Array(targets.prefix(3))
        let engine = try await makeEngine(root: root, project: project, roots: roots)
        do {
            // The first request is for a dependency, before its selected root.
            if !selectAllTargets {
                _ = try await engine.compilerArguments(
                    for: targets[2],
                    file: root.appendingPathComponent("Library2.swift")
                )
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for target in covered {
                    group.addTask {
                        let arguments = try await engine.compilerArguments(
                            for: target, file: root.appendingPathComponent("\(target.targetName).swift")
                        )
                        #expect(arguments.contains(target.targetName))
                    }
                }
                try await group.waitForAll()
            }
            let before = await engine.statistics
            #expect(before.buildDescriptions == 1)
            #expect(before.compilerArgumentQueries == covered.count)
            #expect(before.workspaceLoads == 1)
            // New files in covered targets can be queried while a build owns the lock.
            try await XcodeBuildScheduler.shared.withBuild(in: root.appendingPathComponent("DerivedData")) {
                for target in covered {
                    let arguments = try await engine.compilerArguments(
                        for: target, file: root.appendingPathComponent("\(target.targetName)Extra.swift")
                    )
                    #expect(arguments.contains(target.targetName))
                }
            }
            #expect(await engine.statistics.buildDescriptions == 1)
            #expect(await engine.statistics.sourceQueries == covered.count)
            #expect(try await engine.prepare(targets: [targets[1], targets[2]], log: nil).isEmpty)
            #expect(try await engine.prepare(targets: [targets[0]], log: nil).isEmpty)
            #expect(await engine.statistics.compilerArgumentQueries == covered.count * 2)
            #expect(await engine.statistics.buildDescriptions == 1)
            for target in covered {
                _ = try await engine.compilerArguments(
                    for: target, file: root.appendingPathComponent("\(target.targetName).swift")
                )
            }
            #expect(await engine.statistics.compilerArgumentQueries == covered.count * 2)
            // Changing the selected roots keeps the workspace session.
            try await engine.updateSelection(.init(
                platform: "macosx",
                configuration: "Debug",
                rootTargets: [targets[6]]
            ))
            _ = try await engine.compilerArguments(for: targets[6], file: root.appendingPathComponent("Library6.swift"))
            #expect(await engine.statistics.buildDescriptions == 2)
            #expect(await engine.statistics.workspaceLoads == 1)
            await engine.shutdown()
        } catch {
            await engine.shutdown()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func retainsSelectedDescriptionWhenSupplementalDescriptionsAreEvicted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pinned Index \(UUID())")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try makeProject(in: root, extraSource: true)
        let targets = (0 ..< 7).map {
            XcodeTargetIdentifier(projectFilePath: project.path, targetName: "Library\($0)")
        }
        let engine = try await makeEngine(root: root, project: project, roots: [targets[2]])
        do {
            // Several concurrent targets also share initial planning of the selected scope.
            try await withThrowingTaskGroup(of: Void.self) { group in
                for target in targets {
                    group.addTask {
                        _ = try await engine.compilerArguments(
                            for: target, file: root.appendingPathComponent("\(target.targetName).swift")
                        )
                    }
                }
                try await group.waitForAll()
            }
            let before = await engine.statistics
            #expect(before.buildDescriptions > 4)
            _ = try await engine.compilerArguments(
                for: targets[2],
                file: root.appendingPathComponent("Library2Extra.swift")
            )
            #expect(await engine.statistics.buildDescriptions == before.buildDescriptions)
            #expect(await engine.statistics.sourceQueries == before.sourceQueries)
            #expect(await engine.statistics.workspaceLoads == 1)
            await engine.shutdown()
        } catch {
            await engine.shutdown()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func refreshesChangedSettingsWithoutRefreshingEveryFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Changed Index \(UUID())")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try makeProject(in: root, externalSettings: true)
        let target = XcodeTargetIdentifier(projectFilePath: project.path, targetName: "Library0")
        let other = XcodeTargetIdentifier(projectFilePath: project.path, targetName: "Library6")
        let engine = try await makeEngine(root: root, project: project, roots: [target])
        do {
            let file = root.appendingPathComponent("Library0.swift")
            let initial = try await engine.compilerArguments(for: target, file: file)
            let otherFile = root.appendingPathComponent("Library6.swift")
            let otherArguments = try await engine.compilerArguments(for: other, file: otherFile)
            let before = await engine.statistics
            try Data("OTHER_SWIFT_FLAGS = -DINDEX_CHANGED\n".utf8)
                .write(to: root.appendingPathComponent("Index.xcconfig"))
            #expect(try await engine.prepare(targets: [target], log: nil) == [target])
            #expect(await engine.statistics.compilerArgumentQueries == before.compilerArgumentQueries)
            #expect(try await engine.compilerArguments(for: other, file: otherFile) == otherArguments)
            #expect(await engine.statistics.compilerArgumentQueries == before.compilerArgumentQueries)
            let updated = try await engine.compilerArguments(for: target, file: file)
            #expect(initial.contains("-DINDEX_INITIAL"))
            #expect(updated.contains("-DINDEX_CHANGED"))
            #expect(!updated.contains("-DINDEX_INITIAL"))
            #expect(await engine.statistics.compilerArgumentQueries == before.compilerArgumentQueries + 1)
            #expect(try await engine.prepare(targets: [target], log: nil).isEmpty)
            #expect(await engine.statistics.compilerArgumentQueries == before.compilerArgumentQueries + 1)
            #expect(await engine.statistics.buildDescriptions == before.buildDescriptions)
            await engine.shutdown()
        } catch {
            await engine.shutdown()
            throw error
        }
    }

    @Test
    func scopedInvalidationRejectsUnpublishedQueriesAndPreservesOtherTargets() {
        let target = XcodeTargetIdentifier(projectFilePath: "/tmp/Cache.xcodeproj", targetName: "Library0")
        let other = XcodeTargetIdentifier(projectFilePath: "/tmp/Cache.xcodeproj", targetName: "Library1")
        let key = SwiftBuildIndexingArgumentsCache.Key(target: target, file: URL(fileURLWithPath: "/tmp/File.swift"))
        let otherKey = SwiftBuildIndexingArgumentsCache.Key(
            target: other,
            file: URL(fileURLWithPath: "/tmp/Other.swift")
        )
        var cache = SwiftBuildIndexingArgumentsCache()
        let previous = cache.version
        cache.publish(["other"], for: otherKey, version: previous)
        cache.invalidate(targets: [target])
        let stale = cache.publish(["stale"], for: key, version: previous)
        #expect(!stale)
        #expect(cache.cached(for: otherKey) == ["other"])
        let empty = cache.version
        cache.invalidate(targets: [])
        let unpublished = cache.publish(["stale"], for: key, version: empty)
        #expect(!unpublished)
    }
}

private extension SwiftBuildIndexingCacheTests {
    func makeEngine(
        root: URL, project: URL, roots: [XcodeTargetIdentifier]
    ) async throws -> SwiftBuildIndexingBackend {
        let derivedData = root.appendingPathComponent("DerivedData")
        _ = try XcodeIndexingSelection(platform: "macosx", configuration: "Debug", rootTargets: roots)
            .save(in: derivedData)
        let toolchain = XcodeToolchain(workingDirectory: root)
        try await toolchain.initialize()
        let installation = try #require(await toolchain.getSelectedInstallation())
        let snapshot = XcodeProjectSnapshot(
            rootURL: root,
            projectLocation: .standaloneProject(project),
            xcodeGlobalSettings: .init(derivedDataPath: derivedData),
            xcodeTargets: [],
            schemes: [],
            configuration: "Debug",
            xcodeInstallation: installation
        )
        let service = Bundle(for: IndexCacheBundleLocator.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("SWBBuildServiceBundle")
        return try SwiftBuildIndexingBackend(snapshot: snapshot, serviceExecutable: service)
    }

    func makeProject(in root: URL, extraSource: Bool = false, externalSettings: Bool = false) throws -> URL {
        let project = root.appendingPathComponent("Cache.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var objects: [String: [String: Any]] = [:]
        func add(_ object: [String: Any]) -> String {
            let id = String(format: "%024X", objects.count + 1)
            objects[id] = object
            return id
        }
        func configuration(_ settings: [String: Any]) -> String {
            let configs = ["Debug", "Release"].map { name in
                var settings = settings
                settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) INDEX_\(name.uppercased())"
                return add(["isa": "XCBuildConfiguration", "name": name, "buildSettings": settings])
            }
            return add([
                "isa": "XCConfigurationList", "buildConfigurations": configs,
                "defaultConfigurationIsVisible": 0, "defaultConfigurationName": "Debug"
            ])
        }
        let projectConfig = configuration([
            "SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx",
            "MACOSX_DEPLOYMENT_TARGET": "15.0", "SWIFT_VERSION": "6.0",
            "CODE_SIGNING_ALLOWED": "NO"
        ])
        var targets: [String] = []
        var sources: [String] = []
        var products: [String] = []
        for index in 0 ..< 7 {
            let name = "Library\(index)"
            let dependencyImport = index < 2 ? "import Library\(index + 1)\n" : ""
            try Data("\(dependencyImport)public struct Value\(index) {}\n".utf8)
                .write(to: root.appendingPathComponent("\(name).swift"))
            let source = add([
                "isa": "PBXFileReference", "path": "\(name).swift", "sourceTree": "<group>",
                "lastKnownFileType": "sourcecode.swift"
            ])
            sources.append(source)
            let buildFile = add(["isa": "PBXBuildFile", "fileRef": source])
            var buildFiles = [buildFile]
            if extraSource {
                try Data("public struct ExtraValue\(index) {}\n".utf8)
                    .write(to: root.appendingPathComponent("\(name)Extra.swift"))
                let extra = add([
                    "isa": "PBXFileReference", "path": "\(name)Extra.swift", "sourceTree": "<group>",
                    "lastKnownFileType": "sourcecode.swift"
                ])
                sources.append(extra)
                buildFiles.append(add(["isa": "PBXBuildFile", "fileRef": extra]))
            }
            let phase = add([
                "isa": "PBXSourcesBuildPhase", "files": buildFiles,
                "buildActionMask": 2_147_483_647, "runOnlyForDeploymentPostprocessing": 0
            ])
            let product = add([
                "isa": "PBXFileReference", "path": "lib\(name).a", "sourceTree": "BUILT_PRODUCTS_DIR",
                "explicitFileType": "archive.ar"
            ])
            products.append(product)
            let config = configuration(["PRODUCT_NAME": "$(TARGET_NAME)"])
            if externalSettings, index == 0 {
                try Data("OTHER_SWIFT_FLAGS = -DINDEX_INITIAL\n".utf8)
                    .write(to: root.appendingPathComponent("Index.xcconfig"))
                let settings = add([
                    "isa": "PBXFileReference", "path": "Index.xcconfig", "sourceTree": "<group>",
                    "lastKnownFileType": "text.xcconfig"
                ])
                sources.append(settings)
                for id in objects[config]?["buildConfigurations"] as? [String] ?? [] {
                    objects[id]?["baseConfigurationReference"] = settings
                }
            }
            targets.append(add([
                "isa": "PBXNativeTarget", "name": name, "productName": name,
                "productType": "com.apple.product-type.library.static", "productReference": product,
                "buildConfigurationList": config, "buildPhases": [phase],
                "dependencies": [], "buildRules": []
            ]))
        }
        for index in 0 ..< 2 {
            let dependency = add(["isa": "PBXTargetDependency", "target": targets[index + 1]])
            objects[targets[index]]?["dependencies"] = [dependency]
        }
        let productsGroup = add([
            "isa": "PBXGroup", "name": "Products", "sourceTree": "<group>", "children": products
        ])
        let group = add(["isa": "PBXGroup", "sourceTree": "<group>", "children": sources + [productsGroup]])
        let projectID = add([
            "isa": "PBXProject", "buildConfigurationList": projectConfig,
            "compatibilityVersion": "Xcode 14.0", "developmentRegion": "en", "knownRegions": ["en"],
            "mainGroup": group, "productRefGroup": productsGroup, "projectDirPath": "",
            "projectRoot": "", "targets": targets
        ])
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "archiveVersion": "1", "objectVersion": "56", "classes": [:],
            "objects": objects, "rootObject": projectID
        ], format: .xml, options: 0)
        try data.write(to: project.appendingPathComponent("project.pbxproj"))
        return project
    }
}

private final class IndexCacheBundleLocator: NSObject {}
