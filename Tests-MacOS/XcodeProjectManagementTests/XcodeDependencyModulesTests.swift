import BuildServerProtocol
import Foundation
import Support
import Testing
import XcodeProj
@testable import XcodeProjectManagement

struct XcodeDependencyModulesTests {
    @Test
    func readsOnlyTargetProductsAndExternalLibraries() throws {
        let fixture = try #require(Bundle.module.resourceURL?.appendingPathComponent("DemoProjects/HelloProject"))
        let project = try XcodeProj(pathString: fixture.appendingPathComponent("Hello.xcodeproj").path)
        let target = try #require(project.pbxproj.nativeTargets.first { $0.name == "Hello" })
        let repository = XCRemoteSwiftPackageReference(
            repositoryURL: "https://example.com/dependency.git", versionRequirement: .upToNextMajorVersion("1.0.0")
        )
        let product = XCSwiftPackageProductDependency(productName: "Library", package: repository)
        let local = XCSwiftPackageProductDependency(productName: "LocalLibrary")
        let vendor = PBXFileReference(sourceTree: .sourceRoot, path: "Vendor/Library.xcframework")
        let sdk = PBXFileReference(sourceTree: .sdkRoot, path: "System/Library/Frameworks/UIKit.framework")
        let built = PBXFileReference(sourceTree: .buildProductsDir, path: "Internal.framework")
        let internalProduct = try #require(target.product)
        let files = [
            PBXBuildFile(product: product), PBXBuildFile(file: vendor), PBXBuildFile(file: vendor),
            PBXBuildFile(file: sdk), PBXBuildFile(file: built), PBXBuildFile(file: internalProduct)
        ]
        let phase = PBXFrameworksBuildPhase(files: files)
        for object: PBXObject in [repository, product, local, vendor, sdk, built, phase] + files {
            project.pbxproj.add(object: object)
        }
        target.packageProductDependencies = [product, local]
        target.buildPhases = [phase]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockfile = directory.appendingPathComponent("Package.resolved")
        let lockData = """
        {"version":2,"pins":[
          {"identity":"dependency","location":"https://example.com/dependency",
           "state":{"version":"1.8.3","revision":"abcdef"}},
          {"identity":"unused","location":"https://example.com/unused","state":{"version":"9.0.0"}}
        ]}
        """
        try Data(lockData.utf8).write(to: lockfile)
        let pins = try SwiftPackageResolvedFile(url: lockfile)
        let modules = XcodeDependencyModules.read(target: target, project: project, pins: [pins])
        #expect(modules.map(\.name) == ["Library", "LocalLibrary", "Library.xcframework"])
        #expect(modules.map(\.version) == ["1.8.3", "", ""])
        #expect(modules.map(\.dataKind) == ["swiftpm", "swiftpm", "xcode"])
        let framework = try #require(modules.first { $0.name == "Library.xcframework" })
        guard case let .dictionary(data) = framework.data else {
            Issue.record("Expected library metadata")
            return
        }
        #expect(data["uri"] == .string(URI(fixture.appendingPathComponent("Vendor/Library.xcframework")).stringValue))
        let unresolved = XcodeDependencyModules.read(target: target, project: project, pins: [])
        #expect(unresolved.first?.version.isEmpty == true)
    }
}
