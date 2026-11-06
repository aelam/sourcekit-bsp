import BuildServerProtocol
import Foundation

public struct SwiftPMProjectManagerProvider: ProjectManagerProvider {
    public let name = "SwiftPMProjectManagerProvider"
    private let executor: any SwiftPMCommandExecuting
    private let environment: [String: String]
    private let debugAdapter: (any SwiftPMDebugAdapterServing)?

    public init(debugAdapter: (any SwiftPMDebugAdapterServing)? = nil) {
        self.init(
            executor: SwiftPMProcessExecutor(),
            environment: ProcessInfo.processInfo.environment,
            debugAdapter: debugAdapter
        )
    }

    init(
        executor: any SwiftPMCommandExecuting,
        environment: [String: String],
        debugAdapter: (any SwiftPMDebugAdapterServing)? = nil
    ) {
        self.executor = executor
        self.environment = environment
        self.debugAdapter = debugAdapter
    }

    public func canHandle(projectURL: URL) async -> Bool {
        (try? Self.packageRoot(projectURL)) != nil
    }

    public func createProjectManager(
        rootURL: URL,
        config: ProjectConfiguration?
    ) async throws -> any ProjectManager {
        let root = try Self.packageRoot(rootURL)
        let executable = try SwiftPMExecutableResolver.resolve(
            configured: config?.customSettings["swiftExecutable"],
            environment: environment,
            root: root
        )
        return SwiftPMProjectManager(
            rootURL: root,
            executable: executable,
            executor: executor,
            debugAdapter: debugAdapter
        )
    }

    static func packageRoot(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw SwiftPMProjectError.invalidPackage(url.absoluteString) }
        let root = (url.lastPathComponent == "Package.swift" ? url.deletingLastPathComponent() : url)
            .standardizedFileURL.resolvingSymlinksInPath()
        let manifest = root.appendingPathComponent("Package.swift")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: manifest.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw SwiftPMProjectError.invalidPackage(root.path)
        }
        return URL(fileURLWithPath: root.path, isDirectory: true)
    }
}
