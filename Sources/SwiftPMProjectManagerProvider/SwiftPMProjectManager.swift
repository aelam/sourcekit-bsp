import BuildServerProtocol
import Foundation
import Logger

public actor SwiftPMProjectManager: ProjectManager {
    public let rootURL: URL
    public nonisolated let projectType = "swiftpm"
    public var capabilities: ProjectManagerCapabilities {
        .init()
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
    private var isShutDown = false

    init(rootURL: URL, executable: URL, executor: any SwiftPMCommandExecuting) {
        self.rootURL = rootURL
        self.packageRoots = [rootURL]
        self.loader = SwiftPMGraphLoader(root: rootURL, executable: executable, executor: executor)
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
                    project = snapshot.project
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
        if let reloadTask { _ = await reloadTask.result }
        project = nil
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

    public func startBuild(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        logHandler: (@Sendable (String) -> Void)?
    ) throws -> StatusCode {
        throw SwiftPMProjectError.unsupported("compilation")
    }

    public func run(
        targetIdentifier: BSPBuildTargetIdentifier,
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?
    ) throws -> StatusCode {
        throw SwiftPMProjectError.unsupported("running targets")
    }

    public func test(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        logHandler: (@Sendable (String) -> Void)?
    ) throws -> StatusCode {
        throw SwiftPMProjectError.unsupported("testing targets")
    }

    public func testArguments(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        dataKind: String?,
        data: LSPAny?
    ) async throws -> [String]? {
        throw SwiftPMProjectError.unsupported("test arguments")
    }

    public func startDebugSession(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        buildBeforeLaunch: Bool,
        logHandler: (@Sendable (String) -> Void)?,
        progressHandler: (@Sendable (String) async -> Void)?
    ) throws -> DebugSessionConnection {
        throw SwiftPMProjectError.unsupported("debug sessions")
    }
}
