//
//  BuildTargetCompileRequest.swift
//
//  Copyright © 2024 Wang Lun.
//

import Foundation
import JSONRPCConnection
import SourceKitBSPProtocol

/// https://build-server-protocol.github.io/docs/specification.html
/// https://github.com/microsoft/build-server-for-gradle
public struct BuildTargetCompileRequest: ContextualRequestType, Sendable {
    public typealias RequiredContext = BSPServerService

    public static func method() -> String {
        "buildTarget/compile"
    }

    public struct Params: Codable, Sendable {
        /// The build targets to prepare for background indexing
        public let targets: [BSPBuildTargetIdentifier]
        public let originId: String?
        public let arguments: [String]?
        public var executionContext: BuildContextReference?

        public init(targets: [BSPBuildTargetIdentifier], originId: String? = nil, arguments: [String]? = nil) {
            self.targets = targets
            self.originId = originId
            self.arguments = arguments
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
            logger.debug("Compile targets: \(params.targets)")

            do {
                // 直接使用 BSPServerService.compileTargets，它会自动处理任务进度
                let status = try await context.compileTargets(
                    params.targets,
                    originId: params.originId,
                    arguments: params.arguments,
                    executionContext: params.executionContext
                )

                return BuildTargetCompileResponse(
                    jsonrpc: jsonrpc,
                    id: id,
                    result: BuildTargetCompileResult(originId: params.originId, statusCode: status)
                )

            } catch let error as BuildContextError {
                return JSONRPCErrorResponse(
                    id: id,
                    error: JSONRPCError(code: -32602, message: error.localizedDescription)
                )
            } catch {
                logger.error("Failed to compile targets: \(error)")
                return BuildTargetCompileResponse(
                    jsonrpc: jsonrpc,
                    id: id,
                    result: BuildTargetCompileResult(originId: params.originId, statusCode: .error)
                )
            }
        }
    }
}

public struct BuildTargetCompileResponse: ResponseType, Hashable {
    public let jsonrpc: String
    public let id: JSONRPCID?
    public let result: BuildTargetCompileResult

    public init(jsonrpc: String = "2.0", id: JSONRPCID? = nil, result: BuildTargetCompileResult) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
    }
}

public struct BuildTargetCompileResult: Codable, Hashable, Sendable {
    /** An optional request id to know the origin of this report. */
    public let originId: String?
    /** A status code for the execution. */
    public let statusCode: StatusCode?

    // Kind of data to expect in the `data` field. If this field is not set, the kind of data is not specified.
    // public let dataKind: CompileResultDataKind?

    // A field containing language-specific information, like products
    // of compilation or compiler-specific metadata the client needs to know.
    // data?: CompileResultData

    public init(originId: String? = nil, statusCode: StatusCode? = nil) {
        self.originId = originId
        self.statusCode = statusCode
    }
}
