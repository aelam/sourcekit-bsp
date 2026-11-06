import BuildServerProtocol
import Foundation
import Logger

public actor SwiftPMProjectManager: ProjectManager {
    public let rootURL: URL
    public nonisolated let projectType = "swiftpm"
    public var capabilities: ProjectManagerCapabilities {
        var result: ProjectManagerCapabilities = [.compile, .run, .test, .outputPaths]
        if debugAdapter != nil { result.insert(.debug) }
        return result
    }

    public var watchedFileRoots: [URL] {
        packageRoots.sorted { $0.path < $1.path }
    }

    public private(set) var project: BSPProject?
    public private(set) var diagnostics: [String] = []
    private let loader: SwiftPMGraphLoader
    private var state = ProjectState()
    private var sources: [BSPBuildTargetIdentifier: SourcesItem] = [:]
    private var packageRoots: Set<URL>
    private var reloadTask: Task<Void, Error>?
    var isShutDown = false
    var buildContextHost: BuildContextOption?
    let commandExecutable: URL
    let commandExecutor: any SwiftPMCommandExecuting
    let debugAdapter: (any SwiftPMDebugAdapterServing)?
    var outputBuildArguments: [BSPBuildTargetIdentifier: [String]] = [:]
    var executableTargets: [BSPBuildTargetIdentifier: String] = [:]
    var testModules: [BSPBuildTargetIdentifier: String] = [:]
    var executionTasks: [UUID: Task<SwiftPMCommandResult, Error>] = [:]
    var debugStartupTasks: [UUID: Task<DebugSessionConnection, Error>] = [:]
    var debugEndpoints: [UUID: SwiftPMDebugEndpoint] = [:]

    init(
        rootURL: URL,
        executable: URL,
        executor: any SwiftPMCommandExecuting,
        debugAdapter: (any SwiftPMDebugAdapterServing)? = nil,
        discoveryToolchain: URL? = nil
    ) {
        self.rootURL = rootURL
        self.commandExecutable = executable
        self.commandExecutor = executor
        self.debugAdapter = debugAdapter
        self.packageRoots = [rootURL]
        self.loader = SwiftPMGraphLoader(
            root: rootURL,
            executable: executable,
            executor: executor,
            supportsDebug: debugAdapter != nil,
            discoveryToolchain: discoveryToolchain
        )
    }

    public func initialize() async throws {
        try await updateBuildGraph()
    }

    public func getProjectState() -> ProjectState {
        state
    }

    public func updateBuildGraph() async throws {
        guard !isShutDown else { throw SwiftPMProjectError.shutDown }
        try Task.checkCancellation()
        let task: Task<Void, Error>
        if let reloadTask {
            task = reloadTask
        } else {
            state.projectLoadState = .loading(projectPath: rootURL.path)
            task = Task {
                defer { reloadTask = nil }
                do {
                    let snapshot = try await loader.load()
                    try Task.checkCancellation()
                    guard !isShutDown else { throw SwiftPMProjectError.shutDown }
                    buildContextHost = nil
                    project = snapshot.project
                    executableTargets = snapshot.executableTargets
                    testModules = snapshot.testModules
                    sources = snapshot.sources
                    packageRoots = snapshot.packageRoots
                    diagnostics = snapshot.diagnostics
                    for diagnostic in diagnostics {
                        logger.warning(diagnostic)
                    }
                    state.projectLoadState = .loaded(projectInfo: snapshot.project)
                } catch {
                    if !isShutDown { state.projectLoadState = .failed(error) }
                    throw error
                }
            }
            reloadTask = task
        }
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
        } onCancel: {
            task.cancel()
        }
    }

    public func getSourceFileList(targetIdentifiers: [BSPBuildTargetIdentifier]) throws -> [SourcesItem] {
        guard !isShutDown else { throw SwiftPMProjectError.shutDown }
        guard project != nil else { throw SwiftPMProjectError.notInitialized }
        return try targetIdentifiers.map { identifier in
            guard let item = sources[identifier] else {
                throw SwiftPMProjectError.unknownTarget(identifier.uri.stringValue)
            }
            return item
        }
    }

    public func shouldReloadProject(for changes: [ProjectFileChange]) async -> Bool {
        changes.contains { change in
            guard let url = change.uri.fileURL else { return false }
            let file = url.standardizedFileURL.resolvingSymlinksInPath()
            for root in packageRoots {
                let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
                guard file.path == root.path || file.path.hasPrefix(prefix) else { continue }
                let relative = String(file.path.dropFirst(prefix.count))
                let components = relative.split(separator: "/")
                if let first = components.first, [".build", ".git", ".bsp"].contains(String(first)) { continue }
                let name = file.lastPathComponent
                if name == "Package.resolved" || name == "Package.swift"
                    || (name.hasPrefix("Package@swift-") && name.hasSuffix(".swift")) {
                    return true
                }
                if change.kind != .changed { return true }
            }
            return false
        }
    }

    public func shutdown() async {
        isShutDown = true
        reloadTask?.cancel()
        let tasks = Array(executionTasks.values)
        let debugTasks = Array(debugStartupTasks.values)
        for task in tasks {
            task.cancel()
        }
        for task in debugTasks {
            task.cancel()
        }
        for task in tasks {
            _ = await task.result
        }
        for task in debugTasks {
            _ = await task.result
        }
        for endpoint in debugEndpoints.values {
            endpoint.terminate()
        }
        debugEndpoints.removeAll()
        if let reloadTask { _ = await reloadTask.result }
        project = nil
        outputBuildArguments = [:]
        executableTargets = [:]
        testModules = [:]
        sources = [:]
        diagnostics = []
        state = ProjectState()
    }

    public func getCompileArguments(targetIdentifier: String, sourceFileURL: URL) throws -> [String] {
        throw SwiftPMProjectError.unsupported("compiler arguments")
    }

    public func buildIndex(for targetIdentifiers: [BSPBuildTargetIdentifier]) throws -> [BSPBuildTargetIdentifier] {
        throw SwiftPMProjectError.unsupported("index preparation")
    }
}
