import BuildServerProtocol
import JSONRPCConnection

public struct WorkspaceReloadRequest: ContextualRequestType, Sendable {
    public typealias RequiredContext = BSPServerService

    public static func method() -> String {
        "workspace/reload"
    }

    public struct Params: Codable, Sendable {}

    public let jsonrpc: String
    public let id: RequestID
    public let params: Params?

    // MARK: - ContextualRequestType Implementation

    public func handle<Handler: ContextualMessageHandler>(
        contextualHandler: Handler,
        id: RequestID
    ) async -> ResponseType? where Handler.Context == BSPServerService {
        await contextualHandler.withContext { context in
            do {
                try await context.reloadProject()
                return VoidResponse(jsonrpc: "2.0", id: id)
            } catch {
                logger.error("Failed to reload project: \(error)")
                return JSONRPCErrorResponse(
                    id: id,
                    error: JSONRPCError(code: -32603, message: String(describing: error))
                )
            }
        }
    }
}
