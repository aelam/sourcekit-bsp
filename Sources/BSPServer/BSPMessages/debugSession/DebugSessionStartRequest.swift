import BuildServerProtocol
import Foundation
import JSONRPCConnection
import Logger

/// https://build-server-protocol.github.io/docs/specification.html
public struct DebugSessionStartRequest: ContextualRequestType, Sendable {
    public typealias RequiredContext = BSPServerService

    public static func method() -> String {
        "debugSession/start"
    }

    public struct Params: Codable, Sendable {
        public let targets: [BSPBuildTargetIdentifier]
        public let originId: String?
        public let arguments: [String]?
    }

    public let params: Params

    public func handle<Handler: ContextualMessageHandler>(
        contextualHandler: Handler,
        id: RequestID
    ) async -> ResponseType? where Handler.Context == BSPServerService {
        await contextualHandler.withContext { context in
            do {
                let connection = try await context.startDebugSession(
                    targets: params.targets,
                    arguments: params.arguments
                )
                return DebugSessionStartResponse(id: id, connection: connection)
            } catch {
                logger.error("debugSession/start failed: \(String(describing: error))")
                return JSONRPCErrorResponse(
                    id: id,
                    error: JSONRPCError(
                        code: -32603,
                        message: "debugSession/start failed: \(error.localizedDescription)"
                    )
                )
            }
        }
    }
}

public struct DebugSessionStartResponse: ResponseType, Hashable {
    public let id: JSONRPCID?
    public let jsonrpc: String
    public let result: Result

    public struct Result: Codable, Hashable, Sendable {
        public let uri: String
        public let dataKind: String
        public let data: DebugData

        public struct DebugData: Codable, Hashable, Sendable {
            public let request: String
            public let program: String?
            public let pid: Int?
            public let bundleId: String?
        }
    }

    public init(id: JSONRPCID? = nil, jsonrpc: String = "2.0", connection: DebugSessionConnection) {
        self.id = id
        self.jsonrpc = jsonrpc
        self.result = Result(
            uri: connection.uri,
            dataKind: "lldb",
            data: .init(
                request: connection.request.rawValue,
                program: connection.program,
                pid: connection.pid,
                bundleId: connection.bundleId
            )
        )
    }
}
