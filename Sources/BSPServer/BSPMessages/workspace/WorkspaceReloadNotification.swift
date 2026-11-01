import BuildServerProtocol
import JSONRPCConnection

public struct WorkspaceReloadNotification: ContextualNotificationType, Sendable {
    public typealias RequiredContext = BSPServerService

    public static func method() -> String {
        "workspace/reload"
    }

    public struct Params: Codable, Sendable {}

    public let jsonrpc: String
    public let params: Params?

    // MARK: - ContextualRequestType Implementation

    public func handle<Handler: ContextualMessageHandler>(
        contextualHandler: Handler
    ) async where Handler.Context == BSPServerService {
        await contextualHandler.withContext { context in
            do {
                try await context.reloadProject()
            } catch {
                logger.error("Failed to reload project: \(error)")
            }
        }
    }
}
