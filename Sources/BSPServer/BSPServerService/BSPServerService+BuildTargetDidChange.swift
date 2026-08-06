//
//  BSPServerService+BuildTargetDidChange.swift
//
//  Copyright © 2024 Wang Lun.
//

import BuildServerProtocol
import Foundation
import JSONRPCConnection
import Logger

extension BSPServerService {
    /// React to watched-file changes reported by the client: invalidate any
    /// cached project data so the next query re-reads from disk, then tell the
    /// client to re-query build targets, sources and compiler options.
    func handleWatchedFilesDidChange() async {
        await projectManager?.updateBuildGraph()
        await notifyBuildTargetsChanged()
    }

    /// Emit a `buildTarget/didChange` notification. A `nil` change list means
    /// "targets may have changed" — the client should re-query everything.
    func notifyBuildTargetsChanged(_ changes: [BuildTargetEvent]? = nil) async {
        do {
            try await sendNotification(ServerJSONRPCNotification(
                method: BuildTargetDidChangeNotification.method(),
                params: BuildTargetDidChangeNotification.Params(changes: changes)
            ))
        } catch {
            logger.warning("Failed to send buildTarget/didChange: \(String(describing: error))")
        }
    }
}
