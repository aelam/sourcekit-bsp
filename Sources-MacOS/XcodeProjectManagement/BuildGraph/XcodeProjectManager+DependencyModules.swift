import Foundation
import SourceKitBSPProtocol
import Support
import XcodeProj

public extension XcodeProjectManager {
    /// Read external package products and linked libraries from the loaded projects.
    func resolveDependencyModules() throws -> [XcodeTargetIdentifier: [DependencyModule]] {
        guard let snapshot = projectSnapshot else { return [:] }
        let workspace = snapshot.projectLocation.workspaceOrProjectFileURL
        let workspacePins = try SwiftPackageResolvedFile(
            url: workspace.appendingPathComponent("xcshareddata/swiftpm/Package.resolved")
        )
        var modules: [XcodeTargetIdentifier: [DependencyModule]] = [:]
        let grouped = Dictionary(grouping: snapshot.xcodeTargets, by: \.projectURL)
        for (url, targets) in grouped {
            guard let project = loadXcodeProjCache(projectURL: url) else { continue }
            let projectPins = try SwiftPackageResolvedFile(
                url: url.appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
            )
            for target in targets {
                guard let native = project.pbxproj.nativeTargets.first(where: { $0.name == target.name }) else {
                    continue
                }
                modules[target.targetIdentifier] = XcodeDependencyModules.read(
                    target: native, project: project, pins: [workspacePins, projectPins]
                )
            }
        }
        return modules
    }
}

enum XcodeDependencyModules {
    static func read(
        target: PBXNativeTarget,
        project: XcodeProj,
        pins: [SwiftPackageResolvedFile]
    ) -> [DependencyModule] {
        let linkedFiles = target.buildPhases.compactMap { $0 as? PBXFrameworksBuildPhase }
            .flatMap { $0.files ?? [] }
        let products = (target.packageProductDependencies ?? []) + linkedFiles.compactMap(\.product)
        var modules = products.map { product in
            let repository = product.package?.repositoryURL
            let pin = repository.flatMap { repository in pins.lazy.compactMap { $0.pin(repository: repository) }.first }
            var data: [String: LSPAny] = [:]
            if let repository {
                data["repository"] = .string(repository)
                data["identity"] = .string(SwiftPackageResolvedFile.identity(for: repository))
            }
            return DependencyModule(
                name: product.productName, version: pin?.version ?? "", dataKind: "swiftpm", data: .dictionary(data)
            )
        }
        let workspaceProducts = Set(project.pbxproj.nativeTargets.compactMap { $0.product?.uuid })
        for buildFile in linkedFiles {
            guard let file = buildFile.file as? PBXFileReference,
                  !workspaceProducts.contains(file.uuid),
                  file.sourceTree != .buildProductsDir,
                  file.sourceTree != .sdkRoot,
                  file.sourceTree != .developerDir,
                  let path = file.path ?? file.name,
                  ["framework", "xcframework", "a", "dylib", "tbd"].contains((path as NSString).pathExtension)
            else { continue }
            var data: [String: LSPAny] = ["path": .string(path)]
            if let sourceRoot = project.path?.parent().string,
               let fullPath = try? file.fullPath(sourceRoot: sourceRoot), !fullPath.contains("$") {
                data["uri"] = .string(URI(URL(fileURLWithPath: fullPath)).stringValue)
            }
            if let tree = file.sourceTree { data["sourceTree"] = .string(tree.description) }
            modules.append(DependencyModule(
                name: ((file.name ?? path) as NSString).lastPathComponent,
                version: "",
                dataKind: "xcode",
                data: .dictionary(data)
            ))
        }
        var seen = Set<DependencyModule>()
        return modules.filter { seen.insert($0).inserted }
    }
}
