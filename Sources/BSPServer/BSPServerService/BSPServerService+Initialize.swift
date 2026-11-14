//
//  BSPServerService+Initialize.swift
//  sourcekit-bsp
//
//  Created by wang.lun on 2025/08/21.
//

import Foundation
import JSONRPCConnection
import SourceKitBSPProtocol

public extension BSPServerService {
    func shutdownProject() async {
        invalidateBuildContexts()
        graphUpdateTask?.cancel()
        await stopDebugSessions()
        await projectManager?.shutdown()
        _ = await graphUpdateTask?.result
    }

    func initializeProject(rootURL: URL) async throws {
        if projectManager != nil {
            return
        }

        logger.debug("Initializing project at \(rootURL.path)")

        let config = try launchConfiguration ?? WorkspaceProjectConfiguration.load(at: rootURL)
        let projectManager = try await projectManagerProvider.createProjectManager(rootURL: rootURL, config: config)
        try await projectManager.initialize()
        logger.info("Project ready: \(rootURL.path)")
        self.projectManager = projectManager
    }

    func reloadProject() async throws {
        invalidateBuildContexts()
        let previous = graphUpdateTask
        let task = Task {
            _ = await previous?.result
            try Task.checkCancellation()
            try await self.refreshProjectAndNotify()
        }
        graphUpdateTask = task
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func waitForBuildSystemUpdates() async throws {
        try await graphUpdateTask?.value
    }

    func filesDidChange(_ changes: [WorkspaceDidChangeWatchedFilesNotification.FileEvent]) async throws {
        guard let projectManager else { return }
        let events = changes.map { change in
            let kind: ProjectFileChange.Kind = switch change.type {
            case .created: .created
            case .changed: .changed
            case .deleted: .deleted
            }
            return ProjectFileChange(uri: change.uri, kind: kind)
        }
        await projectManager.invalidateIndexInputs(for: events)
        guard await projectManager.shouldReloadProject(for: events) else { return }
        do {
            try await reloadProject()
        } catch {
            try? await sendNotification(ServerJSONRPCNotification(
                method: "build/logMessage",
                params: BuildLogMessageParams(type: 1, message: "Project reload failed: \(error.localizedDescription)")
            ))
            throw error
        }
    }

    private func refreshProjectAndNotify() async throws {
        guard let projectManager else {
            throw BuildServerError.invalidConfiguration("Project manager not initialized")
        }

        logger.info("Reloading project...")
        let before = await Set(projectManager.getTargetList()
            .map(\.id))
        try await projectManager.updateBuildGraph()
        invalidateBuildContexts()
        let after = await Set(projectManager.getTargetList()
            .map(\.id))
        let changes = before.union(after).sorted { $0.uri.stringValue < $1.uri.stringValue }.map { target in
            BuildTargetEvent(
                target: target,
                kind: !after.contains(target) ? .deleted : (before.contains(target) ? .changed : .created),
                dataKind: nil,
                data: nil
            )
        }
        try await sendNotification(ServerJSONRPCNotification(
            method: BuildTargetDidChangeNotification.method(),
            params: BuildTargetDidChangeNotification.Params(changes: changes)
        ))
        logger.info("Project reloaded")
    }
}
