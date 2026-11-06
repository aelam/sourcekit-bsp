import BuildServerProtocol
import Foundation

struct SwiftPMGraphLoader: Sendable {
    let root: URL
    let executable: URL
    let executor: any SwiftPMCommandExecuting
    var supportsDebug = false
    var discoveryToolchain: URL?

    func load() async throws -> SwiftPMGraphSnapshot {
        var packages: [SwiftPMLoadedPackage] = []
        var pending = [root]
        var visited = Set<URL>()
        var diagnostics: [String] = []
        var resolvedPaths: [String: URL]?
        while !pending.isEmpty {
            try Task.checkCancellation()
            let packageRoot = try SwiftPMProjectManagerProvider.packageRoot(pending.removeFirst())
            guard visited.insert(packageRoot).inserted else { continue }
            let (description, warnings): (SwiftPMPackageDescription, String) = try await metadata(
                at: packageRoot,
                arguments: ["describe", "--type", "json"]
            )
            if !warnings.isEmpty { diagnostics.append(warnings) }
            guard
                URL(fileURLWithPath: description.path).standardizedFileURL.resolvingSymlinksInPath().path
                == packageRoot.path
            else {
                throw SwiftPMProjectError.invalidMetadata(
                    package: packageRoot.path,
                    details: "The package path differs."
                )
            }
            var manifest: SwiftPMManifest?
            if description.targets.contains(where: { !($0.productDependencies ?? []).isEmpty }) {
                let (value, warnings): (SwiftPMManifest, String) = try await metadata(
                    at: packageRoot,
                    arguments: ["dump-package"]
                )
                manifest = value
                if !warnings.isEmpty { diagnostics.append(warnings) }
            }
            packages.append(.init(root: packageRoot, description: description, manifest: manifest))
            if description.dependencies.contains(where: { $0.type != "fileSystem" }), resolvedPaths == nil {
                let (graph, warnings): (SwiftPMResolvedDependency, String) = try await metadata(
                    at: root,
                    arguments: ["show-dependencies", "--format", "json"]
                )
                resolvedPaths = try graph.packagePaths()
                if !warnings.isEmpty { diagnostics.append(warnings) }
            }
            for dependency in description.dependencies {
                try pending.append(dependencyRoot(dependency, in: packageRoot, resolvedPaths: resolvedPaths ?? [:]))
            }
        }
        return try makeSnapshot(packages: packages, resolvedPaths: resolvedPaths ?? [:], diagnostics: diagnostics)
    }

    private func diagnosticText(_ data: Data) -> String {
        // Preserve partial diagnostics when a tool writes invalid UTF-8.
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: data, as: UTF8.self)
    }

    private func metadata<Value: Decodable>(at root: URL, arguments: [String]) async throws -> (Value, String) {
        let arguments = ["package", "--package-path", root.path] + arguments
        let result = try await executor.execute(executable: executable, arguments: arguments, workingDirectory: root)
        try Task.checkCancellation()
        let stderr = diagnosticText(result.standardError).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard result.exitCode == 0 else {
            throw SwiftPMProjectError.commandFailed(
                command: ([executable.path] + arguments).joined(separator: " "),
                status: result.exitCode,
                output: stderr.isEmpty ? diagnosticText(result.standardOutput) : stderr
            )
        }
        do {
            return try (JSONDecoder().decode(Value.self, from: result.standardOutput), stderr)
        } catch {
            throw SwiftPMProjectError.invalidMetadata(
                package: root.path,
                details: "\(error)\(stderr.isEmpty ? "" : "\n" + stderr)"
            )
        }
    }

    private func makeSnapshot(
        packages: [SwiftPMLoadedPackage],
        resolvedPaths: [String: URL],
        diagnostics: [String]
    ) throws -> SwiftPMGraphSnapshot {
        var diagnostics = diagnostics
        var targets: [BSPBuildTarget] = []
        var sources: [BSPBuildTargetIdentifier: SourcesItem] = [:]
        var executableTargets: [BSPBuildTargetIdentifier: String] = [:]
        var testModules: [BSPBuildTargetIdentifier: String] = [:]
        for package in packages {
            var names = Set<String>()
            for target in package.description.targets {
                guard names.insert(target.name).inserted else {
                    throw SwiftPMProjectError.invalidMetadata(
                        package: package.root.path,
                        details: "Duplicate target \(target.name)."
                    )
                }
                guard target.isSupported else {
                    diagnostics.append(
                        "SwiftPM target '\(target.name)' has unsupported type '\(target.type)' and is omitted."
                    )
                    continue
                }
                guard let path = target.path, let files = target.sources else {
                    throw SwiftPMProjectError.invalidMetadata(
                        package: package.root.path,
                        details: "Target '\(target.name)' has no source path or source list."
                    )
                }
                let directory = URL(fileURLWithPath: path, isDirectory: true, relativeTo: package.root)
                    .standardizedFileURL
                let sourceURLs = files.map { URL(fileURLWithPath: $0, relativeTo: directory).standardizedFileURL }
                let id = try Self.identifier(package: package.root, target: target.name)
                let edges = try dependencies(
                    of: target,
                    in: package,
                    packages: packages,
                    resolvedPaths: resolvedPaths,
                    diagnostics: &diagnostics
                )
                var tags: [BuildTargetTag] =
                    switch target.type {
                    case "executable": [.application]
                    case "test": [.test]
                    default: [.library]
                    }
                if package.root != root { tags.append(.dependency) }
                let isRoot = package.root == root
                executableTargets[id] = executableProduct(for: target, in: package)
                testModules[id] = try testModule(for: target, in: package)
                var languages = Set(sourceURLs.compactMap(Self.language))
                if target.moduleType == "SwiftTarget" { languages.insert(.swift) }
                let discovery = discoveryData(module: testModules[id])
                targets.append(
                    BSPBuildTarget(
                        id: id,
                        displayName: target.name,
                        baseDirectory: URI(directory),
                        tags: tags,
                        languageIds: languages.sorted { $0.rawValue < $1.rawValue },
                        dependencies: edges,
                        capabilities: .init(
                            canCompile: isRoot,
                            canTest: testModules[id] != nil,
                            canRun: executableTargets[id] != nil,
                            canDebug: (executableTargets[id] != nil || testModules[id] != nil) && supportsDebug
                        ),
                        dataKind: discovery == nil ? nil : .sourceKit,
                        data: discovery
                    )
                )
                sources[id] = SourcesItem(
                    target: id,
                    sources: sourceURLs.map { SourceItem(uri: URI($0), kind: .file, generated: false) },
                    roots: [URI(directory)]
                )
            }
        }
        let buildRoot = root.appendingPathComponent(".build", isDirectory: true)
        // BSPProject requires cache URLs. Loading does not create or prepare these directories.
        let project = BSPProject(
            rootURL: root,
            name: packages[0].description.name,
            targets: targets.sorted { $0.id.uri.stringValue < $1.id.uri.stringValue },
            buildRootURL: buildRoot,
            indexStoreURL: buildRoot.appendingPathComponent("index/store", isDirectory: true),
            indexDatabaseURL: buildRoot.appendingPathComponent("index/db", isDirectory: true)
        )
        return SwiftPMGraphSnapshot(
            project: project,
            sources: sources,
            packageRoots: Set(packages.map(\.root)),
            diagnostics: Array(Set(diagnostics)).sorted(),
            executableTargets: executableTargets,
            testModules: testModules
        )
    }

    private func discoveryData(module: String?) -> LSPAny? {
        guard let discoveryToolchain, let module else { return nil }
        return .dictionary([
            "toolchain": .string(discoveryToolchain.absoluteString),
            "testDiscovery": .dictionary([
                "provider": .string("sourcekit-lsp"),
                "version": .int(1),
                "selectionDataKind": .string("sourcekit-test-selection"),
                "moduleName": .string(module)
            ])
        ])
    }

    private func testModule(
        for target: SwiftPMPackageDescription.Target,
        in package: SwiftPMLoadedPackage
    ) throws -> String? {
        guard package.root == root, target.type == "test" else { return nil }
        guard let module = target.c99name, !module.isEmpty else {
            throw SwiftPMProjectError.invalidMetadata(
                package: package.root.path,
                details: "Test target '\(target.name)' has no module name."
            )
        }
        return module
    }

    private func executableProduct(
        for target: SwiftPMPackageDescription.Target,
        in package: SwiftPMLoadedPackage
    ) -> String? {
        guard package.root == root, target.type == "executable" else { return nil }
        let products = package.description.products.filter { $0.targets.contains(target.name) }
        return products.count == 1 ? products[0].name : nil
    }

    private func dependencies(
        of target: SwiftPMPackageDescription.Target,
        in package: SwiftPMLoadedPackage,
        packages: [SwiftPMLoadedPackage],
        resolvedPaths: [String: URL],
        diagnostics: inout [String]
    ) throws -> [BSPBuildTargetIdentifier] {
        var result: [BSPBuildTargetIdentifier] = []
        for name in target.targetDependencies ?? [] {
            if let dependency = package.description.targets.first(where: { $0.name == name }), dependency.isSupported {
                try result.append(Self.identifier(package: package.root, target: name))
            } else {
                diagnostics.append("Dependency '\(name)' of target '\(target.name)' is not a loaded source target.")
            }
        }
        for name in target.productDependencies ?? [] {
            let reference = package.manifest?.packageReference(target: target.name, product: name)
            var candidates: [(SwiftPMLoadedPackage, SwiftPMPackageDescription.Product)] = []
            for dependency in package.description.dependencies {
                let aliases = package.manifest?.aliases(for: dependency.identity) ?? [dependency.identity.lowercased()]
                if let reference, !aliases.contains(reference) { continue }
                let url = try dependencyRoot(dependency, in: package.root, resolvedPaths: resolvedPaths)
                if let loaded = packages.first(where: { $0.root.path == url.path }),
                   let product = loaded.description.products.first(where: { $0.name == name }) {
                    candidates.append((loaded, product))
                }
            }
            guard candidates.count == 1, let (dependency, product) = candidates.first else {
                diagnostics.append(
                    "Product dependency '\(name)' of target '\(target.name)' could not be resolved uniquely "
                        + "within loaded packages. Its dependency edge is omitted."
                )
                continue
            }
            for name in product.targets {
                if dependency.description.targets.contains(where: { $0.name == name && $0.isSupported }) {
                    try result.append(Self.identifier(package: dependency.root, target: name))
                } else {
                    diagnostics.append(
                        "Product '\(product.name)' includes unloaded target '\(name)'; its edge is omitted."
                    )
                }
            }
        }
        return Array(Set(result)).sorted { $0.uri.stringValue < $1.uri.stringValue }
    }

    private func dependencyRoot(
        _ dependency: SwiftPMPackageDescription.Dependency,
        in package: URL,
        resolvedPaths: [String: URL]
    ) throws -> URL {
        if dependency.type == "fileSystem", let path = dependency.path {
            return URL(fileURLWithPath: path, isDirectory: true, relativeTo: package)
                .standardizedFileURL.resolvingSymlinksInPath()
        }
        guard let path = resolvedPaths[dependency.identity.lowercased()] else {
            throw SwiftPMProjectError.invalidMetadata(
                package: package.path,
                details: "SwiftPM did not return a checkout path for dependency '\(dependency.identity)'."
            )
        }
        return path
    }

    static func identifier(package: URL, target: String) throws -> BSPBuildTargetIdentifier {
        var components = URLComponents()
        components.scheme = "swiftpm"
        components.path = package.path
        components.queryItems = [URLQueryItem(name: "target", value: target)]
        guard let url = components.url else {
            throw SwiftPMProjectError.invalidMetadata(
                package: package.path,
                details: "Invalid target name '\(target)'."
            )
        }
        return BSPBuildTargetIdentifier(uri: URI(url))
    }

    static func language(_ file: URL) -> Language? {
        switch file.pathExtension {
        case "swift": .swift
        case "c": .c
        case "cc", "cpp", "cxx", "c++", "C": .cpp
        case "m": .objective_c
        case "mm": .objective_cpp
        default: nil
        }
    }
}
