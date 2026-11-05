//
//  ProjectManager.swift
//  Core Module
//
//  Copyright © 2024 Wang Lun.
//

import Foundation

public protocol ProjectManager: AnyObject, Sendable {
    var rootURL: URL { get async }

    var project: BSPProject? { get async }

    func getProjectState() async -> ProjectState

    var projectType: String { get }

    func initialize() async throws

    func shutdown() async

    /// Mark active index preparation inputs as changed without reloading the graph.
    func invalidateIndexInputs() async

    /// workspace/buildTargets
    func getTargetList() async -> [BSPBuildTarget]

    /// buildTarget/sources
    func getSourceFileList(targetIdentifiers: [BSPBuildTargetIdentifier]) async throws
        -> [SourcesItem]

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
        buildBeforeLaunch: Bool,
        logHandler: (@Sendable (String) -> Void)?,
        progressHandler: (@Sendable (String) async -> Void)?
    ) async throws -> DebugSessionConnection
}

public extension ProjectManager {
    /// Reload for every nonempty batch unless the provider can safely filter it.
    func shouldReloadProject(for changes: [ProjectFileChange]) async -> Bool {
        !changes.isEmpty
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
