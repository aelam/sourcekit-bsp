//
//  WorkspaceBuildTargetsRequest.swift
//
//  Copyright © 2024 Wang Lun.
//

//
//
//   {
//     "method":"workspace/buildTargets",
//     "id":2,
//     "jsonrpc":"2.0",
//     "params":{}
//   }
//

import BuildServerProtocol
import JSONRPCConnection

public struct WorkspaceBuildTargetsRequest: ContextualRequestType, Sendable {
    public typealias RequiredContext = BSPServerService

    public static func method() -> String {
        "workspace/buildTargets"
    }

    public struct Params: Codable, Sendable {}

    public let id: JSONRPCID
    public let jsonrpc: String
    public let params: Params?

    // MARK: - ContextualRequestType Implementation

    public func handle<Handler: ContextualMessageHandler>(
        contextualHandler: Handler,
        id: RequestID
    ) async -> ResponseType? where Handler.Context == BSPServerService {
        await contextualHandler.withContext { service in
            do {
                let allBuildTargets = try await service.createBuildTargets()
                return WorkspaceBuildTargetsResponse(
                    id: id,
                    jsonrpc: "2.0",
                    targets: allBuildTargets
                )
            } catch {
                logger.error("Failed to get build targets: \(error)")

                let errorMessage = if error.localizedDescription.contains("BuildServerContext not loaded") {
                    "Build server not initialized. Please send 'build/initialize' request first."
                } else {
                    "Failed to get build targets: \(error.localizedDescription)"
                }

                return JSONRPCErrorResponse(
                    id: id,
                    error: JSONRPCError(
                        code: -32002, // LSP ServerNotInitialized error code
                        message: errorMessage
                    )
                )
            }
        }
    }
}

public struct WorkspaceBuildTargetsResponse: ResponseType, Sendable {
    public let id: JSONRPCID?
    public let jsonrpc: String
    public let result: WorkspaceBuildTargetsResult

    public init(id: JSONRPCID?, jsonrpc: String = "2.0", targets: [BSPBuildTarget]) {
        self.id = id
        self.jsonrpc = jsonrpc
        self.result = WorkspaceBuildTargetsResult(targets: targets)
    }
}

public struct WorkspaceBuildTargetsResult: Codable, Sendable {
    public let targets: [BSPBuildTarget]

    public init(targets: [BSPBuildTarget]) {
        self.targets = targets
    }
}
