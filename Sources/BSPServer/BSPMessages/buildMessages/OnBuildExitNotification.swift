//
//  OnBuildExitNotification.swift
//  sourcekit-bsp
//
//  Created by ST22956 on 2024/11/09.
//

import Foundation
import JSONRPCConnection
import Logger

/// Like the language server protocol, a notification to ask the
/// server to exit its process. The server should exit with success
/// code 0 if the shutdown request has been received before;
/// otherwise with error code 1.
public struct OnBuildExitNotification: ContextualNotificationType, Sendable {
    public typealias RequiredContext = BSPServerService

    public static func method() -> String {
        "build/exit"
    }

    public func handle(
        contextualHandler: some ContextualMessageHandler
    ) async throws {
        logger.flush()
        exit(0)
    }
}
