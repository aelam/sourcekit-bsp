import Foundation
import JSONRPCConnection
import SourceKitBSPProtocol

public struct WorkspaceContextOptionsRequest: ContextualRequestType, Sendable {
    public typealias RequiredContext = BSPServerService
    public static func method() -> String {
        "workspace/contextOptions"
    }

    public let params: BuildContextOptionsParams

    public func handle<Handler: ContextualMessageHandler>(
        contextualHandler: Handler,
        id: RequestID
    ) async -> ResponseType?
        where Handler.Context == BSPServerService {
        await contextualHandler.withContext { context in
            do {
                return try await ContextOptionsResponse(id: id, result: context.contextOptions(params))
            } catch {
                return JSONRPCErrorResponse(
                    id: id,
                    error: JSONRPCError(code: -32602, message: error.localizedDescription)
                )
            }
        }
    }
}

public struct WorkspaceResolveContextRequest: ContextualRequestType, Sendable {
    public typealias RequiredContext = BSPServerService
    public static func method() -> String {
        "workspace/resolveContext"
    }

    public let params: BuildContextParams

    public func handle<Handler: ContextualMessageHandler>(
        contextualHandler: Handler,
        id: RequestID
    ) async -> ResponseType?
        where Handler.Context == BSPServerService {
        await contextualHandler.withContext { context in
            do {
                return try await ResolveContextResponse(id: id, result: context.resolveContext(params))
            } catch {
                return JSONRPCErrorResponse(
                    id: id,
                    error: JSONRPCError(code: -32602, message: error.localizedDescription)
                )
            }
        }
    }
}

private struct ContextOptionsResponse: ResponseType {
    let jsonrpc = "2.0"
    let id: JSONRPCID?
    let result: BuildContextOptionsResult
}

private struct ResolveContextResponse: ResponseType {
    let jsonrpc = "2.0"
    let id: JSONRPCID?
    let result: BuildContextResolution
}
