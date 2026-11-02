//
//  ProjectManager.swift
//  Core Module
//
//  Copyright © 2024 Wang Lun.
//

import Foundation

public protocol ProjectManager: AnyObject, Sendable {
    var rootURL: URL { get async }

    var projectInfo: ProjectInfo? { get async }

    func getProjectState() async -> ProjectState

    var projectType: String { get }

    func initialize() async throws

    func shutdown() async

    /// workspace/buildTargets
    func getTargetList(
        resolveSourceFiles: Bool,
        resolveDependencies: Bool
    ) async -> [BSPBuildTarget]

    /// buildTarget/sources
    func getSourceFileList(targetIdentifiers: [BSPBuildTargetIdentifier]) async throws
        -> [SourcesItem]

    func getCompileArguments(
        targetIdentifier: String,
        sourceFileURL: URL
    ) async throws -> [String]

    func updateBuildGraph() async throws

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
        arguments: [String]?
    ) async throws -> DebugSessionConnection

    func startDebugSession(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        progressHandler: (@Sendable (String) async -> Void)?
    ) async throws -> DebugSessionConnection
}

public extension ProjectManager {
    func startDebugSession(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        progressHandler: (@Sendable (String) async -> Void)?
    ) async throws -> DebugSessionConnection {
        try await startDebugSession(targetIdentifiers: targetIdentifiers, arguments: arguments)
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

public struct ProjectInfo: Sendable {
    public let rootURL: URL
    public let name: String?
    public let targets: [ProjectTarget]
    public let derivedDataPath: URL
    public let indexStoreURL: URL
    public let indexDatabaseURL: URL

    public init(
        rootURL: URL,
        name: String?,
        targets: [ProjectTarget],
        derivedDataPath: URL,
        indexStoreURL: URL,
        indexDatabaseURL: URL
    ) {
        self.rootURL = rootURL
        self.name = name
        self.targets = targets
        self.derivedDataPath = derivedDataPath
        self.indexStoreURL = indexStoreURL
        self.indexDatabaseURL = indexDatabaseURL
    }
}

public struct ProjectTarget: Sendable {
    public let targetIndentifier: String
    public let name: String

    public let isSourcesResolved: Bool
    public let isDependenciesResolved: Bool

    public let sourceFiles: [URL]
    public let dependencies: [ProjectTarget]

    public let productType: ProductType

    public init(
        targetIndentifier: String,
        name: String,
        isSourcesResolved: Bool,
        isDependenciesResolved: Bool,
        sourceFiles: [URL],
        dependencies: [ProjectTarget],
        productType: ProductType
    ) {
        self.targetIndentifier = targetIndentifier
        self.name = name
        self.isSourcesResolved = isSourcesResolved
        self.isDependenciesResolved = isDependenciesResolved
        self.sourceFiles = sourceFiles
        self.dependencies = dependencies
        self.productType = productType
    }
}
