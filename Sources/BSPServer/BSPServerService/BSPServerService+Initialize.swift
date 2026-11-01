//
//  BSPServerService+Initialize.swift
//  sourcekit-bsp
//
//  Created by wang.lun on 2025/08/21.
//

import BuildServerProtocol
import Foundation
import JSONRPCConnection

public extension BSPServerService {
    func shutdownProject() async {
        _ = await graphUpdateTask?.result
        await projectManager?.shutdown()
    }

    func initializeProject(rootURL: URL) async throws {
        if projectManager != nil {
            return
        }

        logger.info("Initializing project...")

        let projectManager = try await projectManagerProvider.createProjectManager(rootURL: rootURL)
        try await projectManager.initialize()
        logger.info("!!projectManager created: \(projectManager)")
        self.projectManager = projectManager
    }

    func reloadProject() async throws {
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
        guard let info = await projectManager?.projectInfo else { return }
        let sourceExtensions: Set = ["swift", "c", "cc", "cpp", "cxx", "m", "mm", "h", "hpp", "hxx"]
        let configurationExtensions: Set = ["pbxproj", "xcworkspace", "xcconfig", "xcscheme", "xcfilelist"]
        let relevant = changes.contains { change in
            guard let file = change.uri.fileURL else { return false }
            let path = file.standardizedFileURL.path
            let derivedData = info.derivedDataPath.standardizedFileURL.path
            guard path != derivedData, !path.hasPrefix(derivedData + "/"),
                  !file.pathComponents.contains(".build") else { return false }
            if configurationExtensions.contains(file.pathExtension)
                || file.lastPathComponent == "contents.xcworkspacedata"
                || file.lastPathComponent == "Package.resolved"
                || file == info.rootURL.appendingPathComponent(".sourcekit-bsp/project.json") {
                return true
            }
            return change.type != .changed && sourceExtensions.contains(file.pathExtension)
        }
        guard relevant else { return }
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
        let before = await Set(projectManager.getTargetList(resolveSourceFiles: false, resolveDependencies: false)
            .map(\.id))
        try await projectManager.updateBuildGraph()
        let after = await Set(projectManager.getTargetList(resolveSourceFiles: false, resolveDependencies: false)
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
