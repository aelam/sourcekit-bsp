import Foundation
import Testing
@testable import XcodeProjectManagement

struct SwiftBuildIndexingCacheTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["SOURCEKIT_BSP_SWIFT_BUILD"] == "1"),
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
            rootURL: root, projectLocation: .standaloneProject(project),
            xcodeGlobalSettings: .init(derivedDataPath: derivedData),
            xcodeTargets: [], schemes: [], configuration: "Debug", xcodeInstallation: installation
        )
        let service = Bundle(for: IndexCacheBundleLocator.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("SWBBuildServiceBundle")
        let backend = try #require(await XcodeIndexingConfiguration(enableBuildTargetPrepare: true).makeBackend(
            snapshot: snapshot,
            serviceExecutable: service
        ))
        do {
            // Swift Build keeps four descriptions by default. Seven targets force eviction.
            let targets = (0 ..< 7).map {
                XcodeTargetIdentifier(projectFilePath: project.path, targetName: "Library\($0)")
            }
            // Library0 -> Library1 -> Library2: prepare the dependency before its consumer.
            #expect(try await backend.prepare(targets: [targets[1]], log: nil).isEmpty)
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
            let first = try await backend.compilerArguments(
                for: targets[0], file: root.appendingPathComponent("Library0.swift")
            )
            #expect(first == initialOptions[0])
            #expect(try await backend.prepare(targets: targets, log: nil).isEmpty)
            for (target, expected) in zip(targets, initialOptions) {
                let options = try await backend.compilerArguments(
                    for: target, file: root.appendingPathComponent("\(target.targetName).swift")
                )
                #expect(options == expected)
            }
            await backend.shutdown()
        } catch {
            await backend.shutdown()
            throw error
        }
    }

    private func makeProject(in root: URL) throws -> URL {
        let project = root.appendingPathComponent("Cache.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var objects: [String: [String: Any]] = [:]
        func add(_ object: [String: Any]) -> String {
            let id = String(format: "%024X", objects.count + 1)
            objects[id] = object
            return id
        }
        func configuration(_ settings: [String: Any]) -> String {
            let config = add(["isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": settings])
            return add([
                "isa": "XCConfigurationList", "buildConfigurations": [config],
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
            let phase = add([
                "isa": "PBXSourcesBuildPhase", "files": [buildFile],
                "buildActionMask": 2_147_483_647, "runOnlyForDeploymentPostprocessing": 0
            ])
            let product = add([
                "isa": "PBXFileReference", "path": "lib\(name).a", "sourceTree": "BUILT_PRODUCTS_DIR",
                "explicitFileType": "archive.ar"
            ])
            products.append(product)
            let config = configuration(["PRODUCT_NAME": "$(TARGET_NAME)"])
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
