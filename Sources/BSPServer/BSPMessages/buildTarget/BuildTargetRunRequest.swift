import BuildServerProtocol
import Foundation
import JSONRPCConnection
import Logger

/// https://build-server-protocol.github.io/docs/specification.html
/// https://github.com/microsoft/build-server-for-gradle
public struct BuildTargetRunRequest: ContextualRequestType, Sendable {
    public typealias RequiredContext = BSPServerService
    public typealias RunParamsDataKind = String
    public struct RunParamsData: Codable, Sendable {}

    public static func method() -> String {
        "buildTarget/run"
    }

    public struct RunParams: Codable, Sendable {
        /// The build targets to prepare for background indexing
        public let target: BSPBuildTargetIdentifier
        public let arguments: [String]?
        public let environmentVariables: [String: String]?
        public let workingDirectory: URI?

        public init(
            target: BSPBuildTargetIdentifier,
            arguments: [String]? = nil,
            environmentVariables: [String: String]? = nil,
            workingDirectory: URI? = nil
        ) {
            self.target = target
            self.arguments = arguments
            self.environmentVariables = environmentVariables
            self.workingDirectory = workingDirectory
        }
    }

    public let id: JSONRPCID
    public let jsonrpc: String
    public let params: RunParams

    public func handle<Handler: ContextualMessageHandler>(
        contextualHandler: Handler,
        id: RequestID
    ) async -> ResponseType? where Handler.Context == BSPServerService {
        await contextualHandler.withContext { context in
            logger.debug("run target: \(params.target)")

            do {
                let statusCode = try await context.run(
                    targetIdentifier: params.target,
                    arguments: params.arguments,
                    environmentVariables: params.environmentVariables,
                    workingDirectory: params.workingDirectory
                )

                return BuildTargetRunResponse(
                    id: id,
                    result: .init(originId: nil, statusCode: statusCode)
                )
            } catch is CancellationError {
                return BuildTargetRunResponse(
                    id: id,
                    result: .init(originId: nil, statusCode: .cancelled)
                )
            } catch {
                logger.error("Failed to run target: \(params.target), error: \(error)")
                try? await context.sendNotification(ServerJSONRPCNotification(
                    method: "build/logMessage",
                    params: BuildLogMessageParams(type: 1, message: "Run failed: \(error.localizedDescription)")
                ))
                return BuildTargetRunResponse(
                    id: id,
                    result: .init(originId: nil, statusCode: .error)
                )
            }
        }
    }
}

public struct BuildTargetRunResponse: ResponseType, Codable, Sendable {
    public struct RunResult: Codable, Sendable {
        let originId: String?
        let statusCode: StatusCode
    }

    public let id: JSONRPCID?
    public let jsonrpc: String
    public let result: RunResult

    public init(id: JSONRPCID? = nil, jsonrpc: String = "2.0", result: RunResult) {
        self.id = id
        self.jsonrpc = jsonrpc
        self.result = result
    }
}
