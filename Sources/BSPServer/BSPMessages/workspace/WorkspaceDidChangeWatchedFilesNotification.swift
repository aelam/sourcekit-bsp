//

//  WorkspaceDidChangeWatchedFilesNotification.swift
//
//  Copyright © 2024 Wang Lun.
//

import JSONRPCConnection
import Logger
import SourceKitBSPProtocol

public struct WorkspaceDidChangeWatchedFilesNotification: ContextualNotificationType, Sendable {
    public typealias RequiredContext = BSPServerService

    public static func method() -> String {
        "workspace/didChangeWatchedFiles"
    }

    public struct Params: Codable, Sendable {
        public let changes: [FileEvent]
    }

    public struct FileEvent: Codable, Sendable {
        public enum Kind: Int, Codable, Sendable {
            case created = 1
            case changed = 2
            case deleted = 3
        }

        public let uri: URI
        public let type: Kind
    }

    public let params: Params

    public func handle<Handler: ContextualMessageHandler>(
        contextualHandler: Handler
    ) async throws where Handler.Context == BSPServerService {
        try await contextualHandler.withContext { service in
            try await service.filesDidChange(params.changes)
        }
    }
}
