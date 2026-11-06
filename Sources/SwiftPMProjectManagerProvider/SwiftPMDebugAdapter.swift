import Foundation

/// Starts a DAP endpoint for a host executable.
public protocol SwiftPMDebugAdapterServing: Sendable {
    func start() async throws -> SwiftPMDebugEndpoint
}

public struct SwiftPMDebugEndpoint: Sendable {
    public let uri: String
    public let terminate: @Sendable () -> Void

    public init(uri: String, terminate: @escaping @Sendable () -> Void) {
        self.uri = uri
        self.terminate = terminate
    }
}
