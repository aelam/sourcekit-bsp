import Foundation

/// Owns one native endpoint. These values are never encoded in BSP messages.
public struct DebugSessionBackend: Sendable {
    public let connection: DebugSessionConnection
    public let validate: @Sendable () async throws -> Void
    public let didStart: @Sendable () async -> Void
    /// Measures native initialize and launch/attach requests. Nil success means no response arrived.
    public let recordRequestTiming: @Sendable (String, Duration, Bool?) -> Void
    public let stop: @Sendable () async -> Void

    public init(
        connection: DebugSessionConnection,
        validate: @escaping @Sendable () async throws -> Void = {},
        didStart: @escaping @Sendable () async -> Void = {},
        recordRequestTiming: @escaping @Sendable (String, Duration, Bool?) -> Void = { _, _, _ in },
        stop: @escaping @Sendable () async -> Void
    ) {
        self.connection = connection
        self.validate = validate
        self.didStart = didStart
        self.recordRequestTiming = recordRequestTiming
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
