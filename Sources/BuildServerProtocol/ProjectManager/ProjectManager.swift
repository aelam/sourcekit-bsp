//
//  ProjectManager.swift
//  Core Module
//
//  Copyright © 2024 Wang Lun.
//

import Foundation

public protocol ProjectManager: AnyObject, Sendable {
    var rootURL: URL { get async }
    var workspaceRootURL: URL { get async }

    var project: BSPProject? { get async }

    func getProjectState() async -> ProjectState

    var projectType: String { get }

    var capabilities: ProjectManagerCapabilities { get async }

    /// Execute background preparation only when the provider explicitly enables it.
    var preparesIndexingOnRequest: Bool { get async }
    var watchedConfigurationFiles: [URL] { get async }

    var watchedFileRoots: [URL] { get async }

    var supportsBuildContexts: Bool { get async }
    var supportedBuildPolicies: [BuildContextBuildPolicy] { get async }
    func contextOptions(_ params: BuildContextOptionsParams) async throws -> BuildContextOptionsResult
    func resolveContext(_ params: BuildContextParams) async throws -> BuildContext
    func startBuild(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        logHandler: (@Sendable (String) -> Void)?,
        context: BuildContext
    ) async throws -> StatusCode
    // swiftlint:disable:next function_parameter_count
    func run(
        targetIdentifier: BSPBuildTargetIdentifier,
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        progressHandler: (@Sendable (String) async -> Void)?,
        context: BuildContext
    ) async throws -> StatusCode
    // swiftlint:disable:next function_parameter_count
    func run(
        targetIdentifier: BSPBuildTargetIdentifier,
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        progressHandler: (@Sendable (String) async -> Void)?,
        buildOutput: RunBuildOutput?,
        context: BuildContext
    ) async throws -> StatusCode
    // swiftlint:disable:next function_parameter_count
    func test(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        logHandler: (@Sendable (String) -> Void)?,
        testEventHandler: (@Sendable (TestExecutionEvent) async -> Void)?,
        context: BuildContext
    ) async throws -> StatusCode
    func startDebugSession(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        logHandler: (@Sendable (String) -> Void)?,
        progressHandler: (@Sendable (String) async -> Void)?,
        context: BuildContext
    ) async throws -> DebugSessionConnection

    /// Prepares an existing process for DAP attach without running a build.
    func prepareDebugAttach(context: BuildContext, pid: Int?) async throws -> DebugSessionBackend
    func stopDebugSession(uri: String) async
    func debugSessionDidStart(uri: String) async

    func initialize() async throws

    func shutdown() async

    /// Mark active index preparation inputs as changed without reloading the graph.
    func invalidateIndexInputs() async

    /// workspace/buildTargets
    func getTargetList() async -> [BSPBuildTarget]

    /// buildTarget/sources
    func getSourceFileList(targetIdentifiers: [BSPBuildTargetIdentifier]) async throws
        -> [SourcesItem]

    /// buildTarget/dependencyModules
    func getDependencyModules(targetIdentifiers: [BSPBuildTargetIdentifier]) async throws -> [DependencyModulesItem]

    func outputPaths(for targets: [BSPBuildTargetIdentifier]) async throws
        -> [BuildTargetOutputPathsResult.OutputPathsItem]

    func getCompileArguments(
        targetIdentifier: String,
        sourceFileURL: URL
    ) async throws -> [String]

    func updateBuildGraph() async throws

    /// Decide whether file changes require a build graph reload.
    func shouldReloadProject(for changes: [ProjectFileChange]) async -> Bool

    /// Prepare dependencies and return targets whose compiler options changed.
    func buildIndex(for targetIdentifiers: [BSPBuildTargetIdentifier]) async throws -> [BSPBuildTargetIdentifier]

    func buildIndex(
        for targetIdentifiers: [BSPBuildTargetIdentifier],
        logHandler: (@Sendable (String) -> Void)?
    ) async throws -> [BSPBuildTargetIdentifier]

    func startBuild(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        logHandler: (@Sendable (String) -> Void)?
    ) async throws -> StatusCode

    func run(
        targetIdentifier: BSPBuildTargetIdentifier,
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?
    ) async throws -> StatusCode

    func run(
        targetIdentifier: BSPBuildTargetIdentifier,
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        progressHandler: (@Sendable (String) async -> Void)?
    ) async throws -> StatusCode

    func test(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        logHandler: (@Sendable (String) -> Void)?
    ) async throws -> StatusCode

    // swiftlint:disable:next function_parameter_count
    func test(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        logHandler: (@Sendable (String) -> Void)?,
        testEventHandler: (@Sendable (TestExecutionEvent) async -> Void)?
    ) async throws -> StatusCode

    func testArguments(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        dataKind: String?,
        data: LSPAny?
    ) async throws -> [String]?

    func startDebugSession(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        logHandler: (@Sendable (String) -> Void)?,
        progressHandler: (@Sendable (String) async -> Void)?
    ) async throws -> DebugSessionConnection
}

public extension ProjectManager {
    var preparesIndexingOnRequest: Bool {
        false
    }

    var watchedConfigurationFiles: [URL] {
        []
    }

    var workspaceRootURL: URL {
        get async { await rootURL }
    }

    func getDependencyModules(targetIdentifiers: [BSPBuildTargetIdentifier]) async throws -> [DependencyModulesItem] {
        guard await capabilities.contains(.dependencyModules) else { throw DependencyModulesError.unsupported }
        guard let project = await project else { throw DependencyModulesError.notInitialized }
        return try project.dependencyModules(for: targetIdentifiers)
    }

    var watchedFileRoots: [URL] {
        get async { await [rootURL] }
    }

    /// Preserve the capabilities of existing providers.
    var capabilities: ProjectManagerCapabilities {
        [.compile, .test, .run, .debug, .prepare, .sourceKitOptions, .outputPaths, .cleanCache]
    }

    /// Reload for every nonempty batch unless the provider can safely filter it.
    func shouldReloadProject(for changes: [ProjectFileChange]) async -> Bool {
        !changes.isEmpty
    }

    func outputPaths(for targets: [BSPBuildTargetIdentifier]) async throws
        -> [BuildTargetOutputPathsResult.OutputPathsItem] {
        targets.map { .init(target: $0, outputPaths: []) }
    }

    func getTargetList() async -> [BSPBuildTarget] {
        await project?.targets ?? []
    }

    func testArguments(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        dataKind: String?,
        data: LSPAny?
    ) async throws -> [String]? {
        guard dataKind == nil, data == nil else {
            throw TestSelectionError.unsupported
        }
        return arguments
    }

    // swiftlint:disable:next function_parameter_count
    func test(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        logHandler: (@Sendable (String) -> Void)?,
        testEventHandler: (@Sendable (TestExecutionEvent) async -> Void)?
    ) async throws -> StatusCode {
        try await test(
            targetIdentifiers: targetIdentifiers,
            arguments: arguments,
            environmentVariables: environmentVariables,
            workingDirectory: workingDirectory,
            logHandler: logHandler
        )
    }

    func shutdown() async {}

    func invalidateIndexInputs() async {}

    func run(
        targetIdentifier: BSPBuildTargetIdentifier,
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        progressHandler: (@Sendable (String) async -> Void)?
    ) async throws -> StatusCode {
        try await run(
            targetIdentifier: targetIdentifier,
            arguments: arguments,
            environmentVariables: environmentVariables,
            workingDirectory: workingDirectory
        )
    }

    func buildIndex(
        for targetIdentifiers: [BSPBuildTargetIdentifier],
        logHandler: (@Sendable (String) -> Void)?
    ) async throws -> [BSPBuildTargetIdentifier] {
        try await buildIndex(for: targetIdentifiers)
    }
}
