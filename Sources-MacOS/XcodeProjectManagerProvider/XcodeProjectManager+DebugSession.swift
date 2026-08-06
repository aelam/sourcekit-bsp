import BuildServerProtocol
import Foundation
import XcodeProjectManagement

public extension XcodeProjectManager {
    /// Stub — real implementation added in a later task. Present now so the
    /// package keeps building on macOS while the protocol requirement lands.
    func startDebugSession(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?
    ) async throws -> DebugSessionConnection {
        throw XcodeProjectError.toolchainError("debugSession/start not yet implemented")
    }
}
