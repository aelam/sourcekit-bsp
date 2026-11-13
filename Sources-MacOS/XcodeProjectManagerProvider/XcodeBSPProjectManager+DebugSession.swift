import Foundation
import SourceKitBSPProtocol
import XcodeProjectManagement

public extension XcodeBSPProjectManager {
    func prepareDebugAttach(context: BuildContext, pid: Int?) async throws -> DebugSessionBackend {
        try await backend.prepareDebugAttach(context: context, pid: pid)
    }

    func debugSessionDidStart(uri: String) async {
        await backend.debugSessionDidStart(uri: uri)
    }

    func stopDebugSession(uri: String) async {
        await backend.stopDebugSession(uri: uri)
    }

    /// BSP entry point: convert the BSP target identifier to the Xcode domain
    /// and delegate to the debug orchestration in `XcodeProjectManagement`.
    func startDebugSession(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        logHandler: (@Sendable (String) -> Void)? = nil,
        progressHandler: (@Sendable (String) async -> Void)? = nil
    ) async throws -> DebugSessionConnection {
        guard let bspIdentifier = targetIdentifiers.first else {
            throw DebugSessionError.buildFailed
        }
        return try await backend.startDebugSession(
            xcodeTargetIdentifier: XcodeTargetIdentifier(bspIdentifier),
            arguments: arguments,
            outputHandler: logHandler.map { ClosureOutputHandler(onLine: $0) },
            progressHandler: progressHandler
        )
    }
}
