import BuildServerProtocol
import Foundation
import XcodeProjectManagement

public extension XcodeBSPProjectManager {
    var supportsBuildContexts: Bool {
        true
    }

    func contextOptions(_ params: BuildContextOptionsParams) async throws -> BuildContextOptionsResult {
        try await backend.contextOptions(params)
    }

    func resolveContext(_ params: BuildContextParams) async throws -> BuildContext {
        try await backend.resolveContext(params)
    }

    func startBuild(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        logHandler: (@Sendable (String) -> Void)?,
        context: BuildContext
    ) async throws -> StatusCode {
        try checkContextScope(context, operation: .compile, targets: targetIdentifiers)
        let result = try await backend.compileContext(
            context, arguments: arguments, outputHandler: logHandler.map { ClosureOutputHandler(onLine: $0) }
        )
        return result == 0 ? .ok : .error
    }

    // swiftlint:disable:next function_parameter_count
    func run(
        targetIdentifier: BSPBuildTargetIdentifier,
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        progressHandler: (@Sendable (String) async -> Void)?,
        context: BuildContext
    ) async throws -> StatusCode {
        try checkContextScope(context, operation: .run, targets: [targetIdentifier])
        try checkContextRuntimeArguments(
            arguments,
            environmentVariables: environmentVariables,
            workingDirectory: workingDirectory
        )
        let flags = try await backend.contextArguments(context, arguments: nil)
        await progressHandler?("Building the selected scheme before launch")
        guard try await backend.compileContext(context, arguments: nil) == 0 else { return .error }
        return try await run(
            targetIdentifier: targetIdentifier,
            arguments: flags,
            environmentVariables: nil,
            workingDirectory: nil,
            progressHandler: progressHandler
        )
    }

    // swiftlint:disable:next function_parameter_count
    func test(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        logHandler: (@Sendable (String) -> Void)?,
        testEventHandler: (@Sendable (TestExecutionEvent) async -> Void)?,
        context: BuildContext
    ) async throws -> StatusCode {
        try checkContextScope(context, operation: .test, targets: targetIdentifiers)
        let flags = try await backend.contextArguments(context, arguments: arguments)
        return try await test(
            targetIdentifiers: targetIdentifiers,
            arguments: flags,
            environmentVariables: environmentVariables,
            workingDirectory: workingDirectory,
            logHandler: logHandler,
            testEventHandler: testEventHandler
        )
    }

    func startDebugSession(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        logHandler: (@Sendable (String) -> Void)?,
        progressHandler: (@Sendable (String) async -> Void)?,
        context: BuildContext
    ) async throws -> DebugSessionConnection {
        try checkContextScope(context, operation: .debug, targets: targetIdentifiers)
        try checkContextRuntimeArguments(arguments, environmentVariables: nil, workingDirectory: nil)
        let flags = try await backend.contextArguments(context, arguments: nil)
        await progressHandler?("Building the selected scheme before debugging")
        guard try await backend.compileContext(
            context, arguments: nil, outputHandler: logHandler.map { ClosureOutputHandler(onLine: $0) }
        ) == 0 else { throw DebugSessionError.buildFailed }
        return try await startDebugSession(
            targetIdentifiers: targetIdentifiers,
            arguments: flags,
            logHandler: logHandler,
            progressHandler: progressHandler
        )
    }

    private func checkContextScope(
        _ context: BuildContext, operation: BuildContextOperation, targets: [BSPBuildTargetIdentifier]
    ) throws {
        guard context.operation == operation, !targets.isEmpty, Set(targets) == Set(context.targets),
              targets.count == context.targets.count else {
            throw BuildContextError.invalid("The operation or target scope does not match the context")
        }
    }

    private func checkContextRuntimeArguments(
        _ arguments: [String]?, environmentVariables: [String: String]?, workingDirectory: URI?
    ) throws {
        guard arguments?.isEmpty != false, environmentVariables?.isEmpty != false, workingDirectory == nil else {
            throw BuildContextError
                .invalid(
                    "Xcode context run/debug does not support runtime arguments, environment overrides, "
                        + "or working-directory overrides yet"
                )
        }
    }
}
