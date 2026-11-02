//
//  BuildTargetTestRequest.swift
//
//  Copyright © 2024 Wang Lun.
//

import BuildServerProtocol
import Foundation
import JSONRPCConnection

/// https://build-server-protocol.github.io/docs/specification.html
/// https://github.com/microsoft/build-server-for-gradle
public struct BuildTargetTestRequest: ContextualRequestType, Sendable {
    public typealias RequiredContext = BSPServerService

    public static func method() -> String {
        "buildTarget/test"
    }

    public struct TestParams: Codable, Sendable {
        public let targets: [BSPBuildTargetIdentifier]
        public let originId: String?
        public let arguments: [String]?
        public let environmentVariables: [String: String]?
        public let workingDirectory: URI?
        public let dataKind: TestParamsDataKind?
        public let data: TestParamsData?

        public init(
            targets: [BSPBuildTargetIdentifier],
            originId: String? = nil,
            arguments: [String]? = nil,
            environmentVariables: [String: String]? = nil,
            workingDirectory: URI? = nil,
            dataKind: TestParamsDataKind? = nil,
            data: TestParamsData? = nil
        ) {
            self.targets = targets
            self.originId = originId
            self.arguments = arguments
            self.environmentVariables = environmentVariables
            self.workingDirectory = workingDirectory
            self.dataKind = dataKind
            self.data = data
        }
    }

    public let id: JSONRPCID
    public let jsonrpc: String
    public let params: TestParams

    public func handle<Handler: ContextualMessageHandler>(
        contextualHandler: Handler,
        id: RequestID
    ) async -> ResponseType? where Handler.Context == BSPServerService {
        await contextualHandler.withContext { context in
            logger.debug("Test targets: \(params.targets)")

            do {
                let statusCode = try await context.test(
                    targetIdentifiers: params.targets,
                    originId: params.originId,
                    arguments: params.arguments,
                    environmentVariables: params.environmentVariables,
                    workingDirectory: params.workingDirectory,
                    dataKind: params.dataKind,
                    data: params.data
                )
                return BuildTargetTestResponse(
                    jsonrpc: jsonrpc,
                    id: id,
                    result: BuildTargetTestResult(originId: params.originId, statusCode: statusCode)
                )

            } catch {
                logger.error("Failed to test targets: \(error)")
                return BuildTargetTestResponse(
                    jsonrpc: jsonrpc,
                    id: id,
                    result: BuildTargetTestResult(
                        originId: params.originId, statusCode: error is CancellationError ? .cancelled : .error
                    )
                )
            }
        }
    }
}

public struct BuildTargetTestResponse: ResponseType, Hashable {
    public let jsonrpc: String
    public let id: JSONRPCID?
    public let result: BuildTargetTestResult

    public init(jsonrpc: String = "2.0", id: JSONRPCID? = nil, result: BuildTargetTestResult) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
    }
}

public struct BuildTargetTestResult: Codable, Hashable, Sendable {
    /** An optional request id to know the origin of this report. */
    public let originId: String?
    /** A status code for the execution. */
    public let statusCode: StatusCode?

    public let dataKind: TestParamsDataKind?
    public let data: TestResultData?

    public init(
        originId: String? = nil,
        statusCode: StatusCode? = nil,
        dataKind: TestParamsDataKind? = nil,
        data: TestResultData? = nil
    ) {
        self.originId = originId
        self.statusCode = statusCode
        self.dataKind = dataKind
        self.data = data
    }
}

public typealias TestParamsDataKind = String

public extension TestParamsDataKind {
    static let sourceKit: TestParamsDataKind = "sourceKit"
}

public typealias TestParamsData = LSPAny

public typealias TestResultDataKind = String
public typealias TestResultData = LSPAny
