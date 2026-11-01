import BuildServerProtocol
import Foundation
import XcodeProjectManagement

public extension XcodeProjectManager {
    /// BSP entry point: convert the BSP target identifier to the Xcode domain
    /// and delegate to the debug orchestration in `XcodeProjectManagement`.
    func startDebugSession(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?
    ) async throws -> DebugSessionConnection {
        guard let bspIdentifier = targetIdentifiers.first else {
            throw DebugSessionError.buildFailed
        }
        return try await startDebugSession(
            xcodeTargetIdentifier: XcodeTargetIdentifier(bspIdentifier),
            arguments: arguments
        )
    }
}
