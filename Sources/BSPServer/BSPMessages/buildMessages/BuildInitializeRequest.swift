//
//  BuildInitializeRequest.swift
//  Created by ST22956 on 2024/11/17.
//

import BuildServerProtocol
import Foundation
import JSONRPCConnection
import Logger

/// Languages supported by sourcekit-bsp for Xcode projects
public let buildServerSupportedLanguages: Set<Language> = [.swift, .objective_c, .objective_cpp, .c, .cpp]

public struct BuildInitializeRequest: ContextualRequestType, Sendable {
    public typealias RequiredContext = BSPServerService

    public static func method() -> String {
        "build/initialize"
    }

    struct Params: Codable, Sendable {
        struct BuildClientCapabilities: Codable, Sendable {
            let languageIds: [Language]
        }

        let rootUri: String
        let capabilities: BuildClientCapabilities // clientCapabilities
        let displayName: String?
        let version: String?
        let bspVersion: String?
    }

    let id: JSONRPCID
    let params: Params

    // MARK: - ContextualRequestType Implementation

    public func handle<Handler: ContextualMessageHandler>(
        contextualHandler: Handler,
        id: RequestID
    ) async -> ResponseType? where Handler.Context == BSPServerService {
        logger.debug("BuildInitializeRequest params - rootUri: \(params.rootUri)")

        return await contextualHandler.withContext { service -> ResponseType in
            // 从请求参数中获取项目根路径
            guard let rootURL = URL(string: self.params.rootUri) else {
                logger.error("BuildInitializeRequest: failed to create rootURL from: \(self.params.rootUri)")
                return JSONRPCErrorResponse(
                    id: id,
                    error: JSONRPCError(
                        code: -32603,
                        message: "Failed to initialize build server: invalid root URI"
                    )
                )
            }

            logger.debug("BuildInitializeRequest: initializing project...")
            do {
                try await service.initializeProject(rootURL: rootURL)
                logger.debug("BuildInitializeRequest: project initialized successfully")
            } catch {
                logger.error("Failed to initialize project: \(error)")
                return JSONRPCErrorResponse(
                    id: id,
                    error: JSONRPCError(
                        code: -32603,
                        message: "Failed to initialize project: \(error.localizedDescription)"
                    )
                )
            }

            // 获取项目信息
            guard
                let projectManager = await service.getCurrentProjectManager(),
                let projectInfo = await projectManager.projectInfo
            else {
                logger
                    .error(
                        "BuildInitializeRequest: project manager or project info not available after initialization"
                    )
                return JSONRPCErrorResponse(
                    id: id,
                    error: JSONRPCError(
                        code: -32603,
                        message: "Project initialization succeeded but project info not available"
                    )
                )
            }

            let response = createResponseForBuildInitializeRequest(
                rootURL: rootURL,
                indexStoreURL: projectInfo.indexStoreURL,
                indexDatabaseURL: projectInfo.indexDatabaseURL,
                clientCapabilities: self.params.capabilities
            )

            logger.debug("BuildInitializeRequest: response created successfully, returning")
            return response
        }
    }

    private func createResponseForBuildInitializeRequest(
        rootURL: URL,
        indexStoreURL: URL,
        indexDatabaseURL: URL,
        clientCapabilities: Params.BuildClientCapabilities
    ) -> BuildInitializeResponse {
        // Create server capabilities based on client capabilities
        let serverCapabilities = createServerCapabilities(
            clientCapabilities: clientCapabilities
        )
        let fileWatchers = createFileSystemWatchers(
            rootURL: rootURL
        )
        logger.debug("BuildInitializeRequest: creating response")
        return BuildInitializeResponse(
            jsonrpc: "2.0",
            id: id,
            result: .init(
                capabilities: serverCapabilities,
                dataKind: "sourceKit",
                data: .init(
                    indexStorePath: indexStoreURL.path,
                    indexDatabasePath: indexDatabaseURL.path,
                    prepareProvider: true,
                    sourceKitOptionsProvider: true,
                    debugWithoutBuildingProvider: true,
                    watchers: fileWatchers
                ),
                rootUri: self.params.rootUri,
                bspVersion: "2.2.0",
                version: "1.0",
                displayName: "sourcekit-bsp"
            )
        )
    }

    private func createFileSystemWatchers(
        rootURL: URL
    ) -> [FileSystemWatcher] {
        let patterns = [
            "**/*.{swift,c,cc,cpp,cxx,m,mm,h,hpp,hxx}",
            "**/*.{pbxproj,xcconfig,xcscheme,xcfilelist}",
            "**/contents.xcworkspacedata", "**/Package.resolved", ".sourcekit-bsp/project.json"
        ]
        return patterns.map { FileSystemWatcher(globPattern: rootURL.path + "/" + $0) }
    }

    /// Create server capabilities based on client capabilities
    private func createServerCapabilities(
        clientCapabilities: Params.BuildClientCapabilities
    ) -> BuildServerCapabilities {
        logger.debug("createServerCapabilities: client languages: \(clientCapabilities.languageIds)")
        let clientLanguages = Set(clientCapabilities.languageIds)
        let supportedLanguages = Array(buildServerSupportedLanguages.intersection(clientLanguages))
        logger.debug("createServerCapabilities: supported languages: \(supportedLanguages)")

        // Create capabilities based on supported languages
        let hasLanguages = !supportedLanguages.isEmpty
        logger.debug("createServerCapabilities: hasLanguages: \(hasLanguages)")

        let capabilities = BuildServerCapabilities(
            compileProvider: hasLanguages ? CompileProvider(languageIds: supportedLanguages) : nil,
            testProvider: hasLanguages ? TestProvider(languageIds: supportedLanguages) : nil,
            runProvider: hasLanguages ? RunProvider(languageIds: supportedLanguages) : nil,
            debugProvider: hasLanguages ? DebugProvider(languageIds: supportedLanguages) : nil,
            inverseSourcesProvider: false,
            dependencySourcesProvider: false,
            resourcesProvider: false,
            outputPathsProvider: true,
            buildTargetChangedProvider: true,
            canReload: true
        )
        logger.debug("createServerCapabilities: capabilities created successfully")
        return capabilities
    }
}

struct BuildInitializeResponse: ResponseType {
    struct Result: Codable {
        struct Data: Codable {
            let indexStorePath: String
            let indexDatabasePath: String
            let prepareProvider: Bool?
            let sourceKitOptionsProvider: Bool?
            let debugWithoutBuildingProvider: Bool?
            let watchers: [FileSystemWatcher]
        }

        let capabilities: BuildServerCapabilities
        let dataKind: String
        let data: Data
        let rootUri: String
        let bspVersion: String
        let version: String
        let displayName: String
    }

    let jsonrpc: String
    let id: JSONRPCID?
    let result: Result
}

public struct FileSystemWatcher: Codable, Hashable, Sendable {
    /// The glob pattern to watch.
    public var globPattern: String

    /// The kind of events of interest. If omitted it defaults to
    /// WatchKind.create | WatchKind.change | WatchKind.delete.
    public var kind: WatchKind?

    public init(globPattern: String, kind: WatchKind? = nil) {
        self.globPattern = globPattern
        self.kind = kind
    }
}

public struct WatchKind: OptionSet, Codable, Hashable, Sendable {
    public var rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let create: WatchKind = .init(rawValue: 1)
    public static let change: WatchKind = .init(rawValue: 2)
    public static let delete: WatchKind = .init(rawValue: 4)
}

public struct BuildServerCapabilities: Codable, Hashable, Sendable {
    /// The languages the server supports compilation via method buildTarget/compile.
    public var compileProvider: CompileProvider?

    /// The languages the server supports test execution via method buildTarget/test
    public var testProvider: TestProvider?

    /// The languages the server supports run via method buildTarget/run
    public var runProvider: RunProvider?

    /// The languages the server supports debugging via method debugSession/start.
    public var debugProvider: DebugProvider?

    /// The server can provide a list of targets that contain a
    /// single text document via the method buildTarget/inverseSources
    public var inverseSourcesProvider: Bool?

    /// The server provides sources for library dependencies
    /// via method buildTarget/dependencySources
    public var dependencySourcesProvider: Bool?

    /// The server provides all the resource dependencies
    /// via method buildTarget/resources
    public var resourcesProvider: Bool?

    /// The server provides all output paths
    /// via method buildTarget/outputPaths
    public var outputPathsProvider: Bool?

    /// The server sends notifications to the client on build
    /// target change events via `buildTarget/didChange`
    public var buildTargetChangedProvider: Bool?

    /// The server can respond to `buildTarget/jvmRunEnvironment` requests with the
    /// necessary information required to launch a Java process to run a main class.
    public var jvmRunEnvironmentProvider: Bool?

    /// The server can respond to `buildTarget/jvmTestEnvironment` requests with the
    /// necessary information required to launch a Java process for testing or
    /// debugging.
    public var jvmTestEnvironmentProvider: Bool?

    /// The server can respond to `workspace/cargoFeaturesState` and
    /// `setCargoFeatures` requests. In other words, supports Cargo Features extension.
    public var cargoFeaturesProvider: Bool?

    /// Reloading the build state through workspace/reload is supported
    public var canReload: Bool?

    /// The server can respond to `buildTarget/jvmCompileClasspath` requests with the
    /// necessary information about the target's classpath.
    public var jvmCompileClasspathProvider: Bool?

    public init(
        compileProvider: CompileProvider? = nil,
        testProvider: TestProvider? = nil,
        runProvider: RunProvider? = nil,
        debugProvider: DebugProvider? = nil,
        inverseSourcesProvider: Bool? = nil,
        dependencySourcesProvider: Bool? = nil,
        resourcesProvider: Bool? = nil,
        outputPathsProvider: Bool? = nil,
        buildTargetChangedProvider: Bool? = nil,
        jvmRunEnvironmentProvider: Bool? = nil,
        jvmTestEnvironmentProvider: Bool? = nil,
        cargoFeaturesProvider: Bool? = nil,
        canReload: Bool? = nil,
        jvmCompileClasspathProvider: Bool? = nil
    ) {
        self.compileProvider = compileProvider
        self.testProvider = testProvider
        self.runProvider = runProvider
        self.debugProvider = debugProvider
        self.inverseSourcesProvider = inverseSourcesProvider
        self.dependencySourcesProvider = dependencySourcesProvider
        self.resourcesProvider = resourcesProvider
        self.outputPathsProvider = outputPathsProvider
        self.buildTargetChangedProvider = buildTargetChangedProvider
        self.jvmRunEnvironmentProvider = jvmRunEnvironmentProvider
        self.jvmTestEnvironmentProvider = jvmTestEnvironmentProvider
        self.cargoFeaturesProvider = cargoFeaturesProvider
        self.canReload = canReload
        self.jvmCompileClasspathProvider = jvmCompileClasspathProvider
    }
}

public struct CompileProvider: Codable, Hashable, Sendable {
    public var languageIds: [Language]

    public init(languageIds: [Language]) {
        self.languageIds = languageIds
    }
}

public struct TestProvider: Codable, Hashable, Sendable {
    public var languageIds: [Language]

    public init(languageIds: [Language]) {
        self.languageIds = languageIds
    }
}

public struct RunProvider: Codable, Hashable, Sendable {
    public var languageIds: [Language]

    public init(languageIds: [Language]) {
        self.languageIds = languageIds
    }
}

public struct DebugProvider: Codable, Hashable, Sendable {
    public var languageIds: [Language]

    public init(languageIds: [Language]) {
        self.languageIds = languageIds
    }
}
