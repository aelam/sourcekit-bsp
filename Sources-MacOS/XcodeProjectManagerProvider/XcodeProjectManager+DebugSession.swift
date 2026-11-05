import BuildServerProtocol
import Foundation
import XcodeProjectManagement

public extension XcodeProjectManager {
    /// BSP entry point: convert the BSP target identifier to the Xcode domain
    /// and delegate to the debug orchestration in `XcodeProjectManagement`.
    func startDebugSession(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        buildBeforeLaunch: Bool = true,
        logHandler: (@Sendable (String) -> Void)? = nil,
        progressHandler: (@Sendable (String) async -> Void)? = nil
    ) async throws -> DebugSessionConnection {
        guard let bspIdentifier = targetIdentifiers.first else {
            throw DebugSessionError.buildFailed
        }
        return try await startDebugSession(
            xcodeTargetIdentifier: XcodeTargetIdentifier(bspIdentifier),
            arguments: arguments,
            buildBeforeLaunch: buildBeforeLaunch,
            outputHandler: logHandler.map { ClosureOutputHandler(onLine: $0) },
            progressHandler: progressHandler
        )
    }
}
