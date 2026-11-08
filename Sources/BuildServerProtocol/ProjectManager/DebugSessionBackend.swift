import Foundation

/// Owns one native endpoint. These values are never encoded in BSP messages.
public struct DebugSessionBackend: Sendable {
    public let connection: DebugSessionConnection
    public let validate: @Sendable () async throws -> Void
    public let didStart: @Sendable () async -> Void
    public let stop: @Sendable () async -> Void

    public init(
        connection: DebugSessionConnection,
        validate: @escaping @Sendable () async throws -> Void = {},
        didStart: @escaping @Sendable () async -> Void = {},
        stop: @escaping @Sendable () async -> Void
    ) {
        self.connection = connection
        self.validate = validate
        self.didStart = didStart
        self.stop = stop
    }
}

public extension ProjectManager {
    func prepareDebugAttach(context: BuildContext, pid: Int?) async throws -> DebugSessionBackend {
        throw BuildContextError.invalid("Attach is not supported by this provider.")
    }

    func stopDebugSession(uri: String) async {}

    func debugSessionDidStart(uri: String) async {}
}
