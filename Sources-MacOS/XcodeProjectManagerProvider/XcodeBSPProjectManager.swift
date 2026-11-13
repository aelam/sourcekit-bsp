import Foundation
import SourceKitBSPProtocol
import XcodeProjectManagement

/// Owns the BSP model and delegates execution to the Xcode backend.
public actor XcodeBSPProjectManager: ProjectManager {
    public var capabilities: ProjectManagerCapabilities {
        var capabilities: ProjectManagerCapabilities =
            [.compile, .test, .run, .debug, .prepare, .sourceKitOptions, .outputPaths, .cleanCache, .dependencyModules]
        // Removing active index data requires a separate lifecycle from ordinary cache cleaning.
        if indexing != nil { capabilities.remove(.cleanCache) }
        return capabilities
    }

    public var preparesIndexingOnRequest: Bool {
        indexing != nil
    }

    let backend: XcodeProjectManager
    public var rootURL: URL {
        get async { await backend.rootURL }
    }

    public nonisolated let projectType = "xcodeproj"
    public private(set) var project: BSPProject?
    private var reloadTask: Task<Void, Error>?
    var indexing: (any XcodeIndexingBackend)?
    private let indexingFactory: @Sendable (XcodeProjectSnapshot) async throws -> (any XcodeIndexingBackend)?

    public init(
        backend: XcodeProjectManager,
        indexingFactory: @escaping @Sendable (XcodeProjectSnapshot) async throws -> (any XcodeIndexingBackend)? = {
            try await XcodeIndexingConfiguration.makeBackend(snapshot: $0)
        }
    ) {
        self.backend = backend
        self.indexingFactory = indexingFactory
    }

    public func initialize() async throws {
        try await updateBuildGraph()
    }

    public func updateBuildGraph() async throws {
        if let reloadTask {
            try await reloadTask.value
            return
        }
        let task = Task {
            try await backend.reloadProject()
            guard let project = try await backend.makeBSPProject() else {
                throw XcodeProjectError.invalidConfig("Project not initialized")
            }
            guard let snapshot = await backend.projectSnapshot else {
                throw XcodeProjectError.invalidConfig("Project not initialized")
            }
            let nextIndexing = try await indexingFactory(snapshot)
            let previousIndexing = indexing
            indexing = nextIndexing
            // Publish before any waiter returns from the shared reload task.
            if let nextIndexing {
                self.project = project.withIndexPaths(
                    store: nextIndexing.indexStoreURL, database: nextIndexing.indexDatabaseURL
                )
            } else {
                self.project = project
            }
            await previousIndexing?.shutdown()
        }
        reloadTask = task
        defer { reloadTask = nil }
        // A failed reload leaves the previous model available.
        try await task.value
    }

    public func getProjectState() -> ProjectState {
        var state = ProjectState()
        if let project { state.projectLoadState = .loaded(projectInfo: project) }
        return state
    }

    public func shutdown() async {
        reloadTask?.cancel()
        if let reloadTask { _ = await reloadTask.result }
        await backend.stopContextDestinationDiscovery()
        await backend.shutdownBuilds()
        await backend.stopIndexPreparation()
        await indexing?.shutdown()
        await backend.stopDebugSessions()
    }

    public func getSourceFileList(targetIdentifiers: [BSPBuildTargetIdentifier]) async throws
        -> [SourceKitBSPProtocol.SourcesItem] {
        try validateTargets(targetIdentifiers)
        let sources = await backend
            .getSourcesItems(targetIdentifiers: targetIdentifiers.map(XcodeTargetIdentifier.init))
        return sources.map { $0.asBSPSourcesItems() }
    }

    public func outputPaths(for targets: [BSPBuildTargetIdentifier]) async throws
        -> [BuildTargetOutputPathsResult.OutputPathsItem] {
        try validateTargets(targets)
        guard let project else { throw XcodeProjectError.invalidConfig("Project not initialized") }
        let directory = project.buildRootURL.appendingPathComponent("Build/Products", isDirectory: true)
        return targets.map { .init(target: $0, outputPaths: [.init(uri: URI(directory), kind: .directory)]) }
    }

    public func getCompileArguments(targetIdentifier: String, sourceFileURL: URL) async throws -> [String] {
        let identifier = try BSPBuildTargetIdentifier(uri: URI(string: targetIdentifier))
        try validateTargets([identifier])
        if let indexing {
            return try await indexing.compilerArguments(for: XcodeTargetIdentifier(identifier), file: sourceFileURL)
        }
        return try await backend.getCompileArguments(
            targetIdentifier: XcodeTargetIdentifier(identifier), sourceFileURL: sourceFileURL
        )
    }

    public func buildIndex(for targets: [BSPBuildTargetIdentifier]) async throws -> [BSPBuildTargetIdentifier] {
        try await buildIndex(for: targets, logHandler: nil)
    }

    public func buildIndex(
        for targets: [BSPBuildTargetIdentifier], logHandler: (@Sendable (String) -> Void)?
    ) async throws -> [BSPBuildTargetIdentifier] {
        try validateTargets(targets)
        if let indexing {
            return try await indexing.prepare(targets: targets.map(XcodeTargetIdentifier.init), log: logHandler)
                .map(\.bspIdentifier)
        }
        return try await backend.prepareForIndexing(
            targetIdentifiers: targets.map(XcodeTargetIdentifier.init), logHandler: logHandler
        )
        .map(\.bspIdentifier)
    }

    private func validateTargets(_ identifiers: [BSPBuildTargetIdentifier]) throws {
        guard let project else { throw XcodeProjectError.invalidConfig("Project not initialized") }
        for identifier in identifiers where project.target(for: identifier) == nil {
            throw XcodeProjectError.invalidConfig("Unknown build target: \(identifier.uri.stringValue)")
        }
    }
}
