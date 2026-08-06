//
//  WorkspaceDidChangeWatchedFilesNotification.swift
//
//  Copyright © 2024 Wang Lun.
//

import JSONRPCConnection
import Logger

/// Sent by the client (e.g. SourceKit-LSP) when files matching the watchers
/// declared in the `build/initialize` response change on disk. The server
/// reacts by invalidating cached project data and emitting
/// `buildTarget/didChange` so the client re-queries sources and options.
public struct WorkspaceDidChangeWatchedFilesNotification: ContextualNotificationType, Sendable {
    public typealias RequiredContext = BSPServerService

    public static func method() -> String {
        "workspace/didChangeWatchedFiles"
    }

    /// A single file-system change event, mirroring the LSP `FileEvent`.
    public struct FileEvent: Codable, Sendable {
        /// The file's URI.
        public let uri: String
        /// The change type: 1 = created, 2 = changed, 3 = deleted.
        public let type: Int?
    }

    public struct Params: Codable, Sendable {
        public let changes: [FileEvent]?
    }

    public let params: Params

    public func handle<Handler: ContextualMessageHandler>(
        contextualHandler: Handler
    ) async throws where Handler.Context == BSPServerService {
        await contextualHandler.withContext { service in
            let changeCount = params.changes?.count ?? 0
            logger.debug("workspace/didChangeWatchedFiles: \(changeCount) change(s)")
            await service.handleWatchedFilesDidChange()
        }
    }
}
