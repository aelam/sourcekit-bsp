import Foundation
import SourceKitBSPProtocol

struct SwiftPMPackageDescription: Decodable, Sendable {
    let name: String
    let path: String
    let targets: [Target]
    let products: [Product]
    let dependencies: [Dependency]

    struct Target: Decodable, Sendable {
        let name: String
        let type: String
        let path: String?
        let sources: [String]?
        let c99name: String?
        let moduleType: String?
        let targetDependencies: [String]?
        let productDependencies: [String]?

        enum CodingKeys: String, CodingKey {
            case name, type, path, sources, c99name
            case moduleType = "module_type"
            case targetDependencies = "target_dependencies"
            case productDependencies = "product_dependencies"
        }

        var isSupported: Bool {
            ["library", "executable", "test"].contains(type)
        }
    }

    struct Product: Decodable, Sendable {
        let name: String
        let targets: [String]
    }

    struct Dependency: Decodable, Sendable {
        let identity: String
        let type: String
        let path: String?
    }
}

struct SwiftPMManifest: Decodable, Sendable {
    let targets: [Target]
    let dependencies: [[String: [Dependency]]]

    struct Dependency: Decodable, Sendable {
        let identity: String
        let nameForTargetDependencyResolution: String?
    }

    struct Target: Decodable, Sendable {
        let name: String
        let dependencies: [[String: [LSPAny]]]
    }

    func packageReference(target: String, product: String) -> String? {
        guard let target = targets.first(where: { $0.name == target }) else { return nil }
        for dependency in target.dependencies {
            if let values = dependency["product"], values.count > 1,
               values[0] == .string(product), case let .string(package) = values[1] {
                return package.lowercased()
            }
        }
        return nil
    }

    func aliases(for identity: String) -> Set<String> {
        var names: Set<String> = [identity.lowercased()]
        for dependency in dependencies.flatMap({ $0.values.flatMap(\.self) }) where dependency.identity == identity {
            if let name = dependency.nameForTargetDependencyResolution { names.insert(name.lowercased()) }
        }
        return names
    }
}

struct SwiftPMLoadedPackage: Sendable {
    let root: URL
    let description: SwiftPMPackageDescription
    let manifest: SwiftPMManifest?
}

struct SwiftPMGraphSnapshot: Sendable {
    let project: BSPProject
    let sources: [BSPBuildTargetIdentifier: SourcesItem]
    let packageRoots: Set<URL>
    let diagnostics: [String]
    let executableTargets: [BSPBuildTargetIdentifier: String]
    let testModules: [BSPBuildTargetIdentifier: String]
}

struct SwiftPMResolvedDependency: Decodable, Sendable {
    let identity: String
    let path: String
    let dependencies: [SwiftPMResolvedDependency]

    func packagePaths() throws -> [String: URL] {
        var paths: [String: URL] = [:]
        var pending = [self]
        while let node = pending.popLast() {
            guard !node.identity.isEmpty, !node.path.isEmpty, (node.path as NSString).isAbsolutePath else {
                throw SwiftPMProjectError.invalidMetadata(
                    package: path,
                    details: "A resolved dependency has no identity or absolute checkout path."
                )
            }
            let url = URL(fileURLWithPath: node.path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            let identity = node.identity.lowercased()
            if let existing = paths[identity], existing != url {
                throw SwiftPMProjectError.invalidMetadata(
                    package: path,
                    details: "Resolved dependency '\(identity)' has conflicting checkout paths."
                )
            }
            paths[identity] = url
            pending.append(contentsOf: node.dependencies)
        }
        return paths
    }
}
