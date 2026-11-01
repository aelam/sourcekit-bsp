//
//  BuildShutdownRequest.swift
//  sourcekit-bsp
//
//  Created by ST22956 on 2024/11/09.
//

import JSONRPCConnection

public final class BuildShutdownRequest: ContextualRequestType, Sendable {
    public typealias RequiredContext = BSPServerService

    public static func method() -> String {
        "build/shutdown"
    }

    public func handle<Handler: ContextualMessageHandler>(
        contextualHandler: Handler,
        id: RequestID
    ) async -> ResponseType? where Handler.Context == BSPServerService {
        await contextualHandler.withContext { context in
            await context.shutdownProject()
            return BuildShutdownResponse(
                jsonrpc: "2.0",
                id: id,
                result: .null
            )
        }
    }
}

struct BuildShutdownResponse: ResponseType {
    let jsonrpc: String
    let id: JSONRPCID?

    let result: JSONValue
}
