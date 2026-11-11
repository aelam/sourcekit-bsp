import Foundation

public struct RunBuildOutput: Sendable {
    public let onLine: @Sendable (String) -> Void
    public let finish: @Sendable () async -> Void

    public init(
        onLine: @escaping @Sendable (String) -> Void,
        finish: @escaping @Sendable () async -> Void
    ) {
        self.onLine = onLine
        self.finish = finish
    }
}

public extension ProjectManager {
    var supportsBuildContexts: Bool {
        get async { false }
    }

    var supportedBuildPolicies: [BuildContextBuildPolicy] {
        get async { [.build] }
    }

    func contextOptions(_ params: BuildContextOptionsParams) async throws -> BuildContextOptionsResult {
        throw BuildContextError.invalid("This provider does not support execution contexts.")
    }

    func resolveContext(_ params: BuildContextParams) async throws -> BuildContext {
        throw BuildContextError.invalid("This provider does not support execution contexts.")
    }

    func startBuild(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        logHandler: (@Sendable (String) -> Void)?,
        context: BuildContext
    ) async throws -> StatusCode {
        throw BuildContextError.invalid("This provider does not support compile contexts.")
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
        throw BuildContextError.invalid("This provider does not support run contexts.")
    }

    // swiftlint:disable:next function_parameter_count
    func run(
        targetIdentifier: BSPBuildTargetIdentifier,
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        progressHandler: (@Sendable (String) async -> Void)?,
        buildOutput: RunBuildOutput?,
        context: BuildContext
    ) async throws -> StatusCode {
        try await run(
            targetIdentifier: targetIdentifier,
            arguments: arguments,
            environmentVariables: environmentVariables,
            workingDirectory: workingDirectory,
            progressHandler: progressHandler,
            context: context
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
        throw BuildContextError.invalid("This provider does not support test contexts.")
    }

    func startDebugSession(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        logHandler: (@Sendable (String) -> Void)?,
        progressHandler: (@Sendable (String) async -> Void)?,
        context: BuildContext
    ) async throws -> DebugSessionConnection {
        throw BuildContextError.invalid("This provider does not support debug contexts.")
    }
}
