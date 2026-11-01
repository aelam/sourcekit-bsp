//
//  BuildTargetOutputPathsRequest.swift
//
//  Copyright © 2024 Wang Lun.
//

import BuildServerProtocol
import Foundation
import JSONRPCConnection

/// https://build-server-protocol.github.io/docs/specification.html
/// https://github.com/microsoft/build-server-for-gradle
public struct BuildTargetOutputPathsRequest: ContextualRequestType, Sendable {
    public typealias RequiredContext = BSPServerService

    public static func method() -> String {
        "buildTarget/outputPaths"
    }

    public struct Params: Codable, Sendable {
        /// The build targets to prepare for background indexing
        public let targets: [BSPBuildTargetIdentifier]
        public let originId: String?

        public init(targets: [BSPBuildTargetIdentifier], originId: String? = nil) {
            self.targets = targets
            self.originId = originId
        }
    }

    public let id: JSONRPCID
    public let jsonrpc: String
    public let params: Params

    public func handle<Handler: ContextualMessageHandler>(
        contextualHandler: Handler,
        id: RequestID
    ) async -> ResponseType? where Handler.Context == BSPServerService {
        await contextualHandler.withContext { context in
            logger.debug("get outputs of targets: \(params.targets)")
            do {
                let items = try await context.outputPaths(for: params.targets)
                return BuildTargetOutputPathsResponse(
                    jsonrpc: jsonrpc,
                    id: id,
                    result: BuildTargetOutputPathsResult(items: items)
                )
            } catch {
                return JSONRPCErrorResponse(
                    id: id,
                    error: JSONRPCError(
                        code: -32603,
                        message: "failed to get output paths: \(error)"
                    )
                )
            }
        }
    }
}

public struct BuildTargetOutputPathsResponse: ResponseType, Hashable {
    public let jsonrpc: String
    public let id: JSONRPCID?
    public let result: BuildTargetOutputPathsResult

    public init(jsonrpc: String = "2.0", id: JSONRPCID? = nil, result: BuildTargetOutputPathsResult) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
    }
}

public struct BuildTargetOutputPathsResult: Codable, Hashable, Sendable {
    public let items: [OutputPathsItem]

    public init(items: [OutputPathsItem] = []) {
        self.items = items
    }

    public struct OutputPathsItem: Codable, Hashable, Sendable {
        public enum OutputPathItemKind: Int, Codable, Hashable, Sendable {
            case file = 1
            case directory = 2
        }

        public struct OutputPathItem: Codable, Hashable, Sendable {
            public let uri: URI
            public let kind: OutputPathItemKind

            public init(uri: URI, kind: OutputPathItemKind) {
                self.uri = uri
                self.kind = kind
            }
        }

        public let target: BSPBuildTargetIdentifier
        public let outputPaths: [OutputPathItem]

        public init(target: BSPBuildTargetIdentifier, outputPaths: [OutputPathItem]) {
            self.target = target
            self.outputPaths = outputPaths
        }
    }
}
