//
//  BuildSourceKitOptionsChangedNotification.swift
//
//  Copyright © 2024 Wang Lun.
//

// The `TextDocumentSourceKitOptionsRequest` request is sent from the client to the server to query for the list of
// compiler options necessary to compile this file in the given target.
//
// The build settings are considered up-to-date and can be cached by SourceKit-LSP until a
// `DidChangeBuildTargetNotification` is sent for the requested target.
//
// The request may return `nil` if it doesn't have any build settings for this file in the given target.
// server --> client
// Deprecated
//

import BuildServerProtocol
import JSONRPCConnection

public struct BuildSourceKitOptionsChangedNotification: ContextualNotificationType, Sendable {
    public typealias RequiredContext = BSPServerService

    public static func method() -> String {
        "build/sourceKitOptionsChanged"
    }

    public struct Params: Codable, Sendable {
        public struct UpdateOptions: Codable, Sendable {
            public let options: [String]
            public let workingDirectory: String?
        }

        /// The URI of the document to get options for
        public var textDocument: TextDocumentIdentifier

        /// The target for which the build setting should be returned.
        ///
        /// A source file might be part of multiple targets and might have different compiler arguments in those two
        /// targets,
        /// thus the target is necessary in this request.
        public var target: BuildServerProtocol.BSPBuildTargetIdentifier

        /// The language with which the document was opened in the editor.
        public var language: BuildServerProtocol.Language
    }

    public let id: JSONRPCID
    public let jsonrpc: String
    public let params: Params

    public func handle(
        contextualHandler: some ContextualMessageHandler
    ) async throws {}
}
