//
//  BSPServerService+BuildTargets.swift
//
//  Copyright © 2024 Wang Lun.
//

import Foundation
import JSONRPCConnection
import Logger
import SourceKitBSPProtocol

extension BSPServerService {
    func getWorkingDirectory() async throws -> String? {
        await projectManager?.rootURL.path
    }

    func createBuildTargets() async throws -> [BSPBuildTarget] {
        guard let projectManager else {
            throw BuildServerError.invalidConfiguration("Project manager not initialized")
        }

        return await projectManager.getTargetList()
    }

    func buildTargetForIndex(targets: [BSPBuildTargetIdentifier]) async throws {
        guard let projectManager else {
            throw BuildServerError.invalidConfiguration("Project not initialized")
        }
        guard await projectManager.preparesIndexingOnRequest else { return }
        let changed = try await projectManager.buildIndex(for: targets) { message in
            logger.debug("Index preparation: \(message)")
        }
        guard !changed.isEmpty else { return }
        try await sendNotification(ServerJSONRPCNotification(
            method: BuildTargetDidChangeNotification.method(),
            params: BuildTargetDidChangeNotification.Params(changes: changed.map {
                BuildTargetEvent(target: $0, kind: .changed, dataKind: nil, data: nil)
            })
        ))
    }

    func outputPaths(
        for targets: [BSPBuildTargetIdentifier]
    ) async throws -> [BuildTargetOutputPathsResult.OutputPathsItem] {
        guard let projectManager else {
            throw BuildServerError.invalidConfiguration("Project not initialized")
        }
        guard await projectManager.capabilities.contains(.outputPaths) else {
            throw BuildServerError.invalidConfiguration("Output paths are not supported by this project provider")
        }
        return try await projectManager.outputPaths(for: targets)
    }

    func cleanBuildTargetCaches(
        targets _: [BSPBuildTargetIdentifier]
    ) async throws -> BuildTargetCleanCacheResult {
        guard let projectManager else {
            throw BuildServerError.invalidConfiguration("Project not initialized")
        }
        guard await projectManager.capabilities.contains(.cleanCache) else {
            throw BuildServerError.invalidConfiguration("Cache cleaning is not supported by this project provider")
        }
        guard let projectInfo = await projectManager.project else {
            throw BuildServerError.invalidConfiguration("Project info not initialized")
        }

        let paths = [
            projectInfo.indexStoreURL,
            projectInfo.indexDatabaseURL,
            projectInfo.buildRootURL.appendingPathComponent(
                "Build/Intermediates.noindex",
                isDirectory: true
            ),
            projectInfo.buildRootURL.deletingLastPathComponent().appendingPathComponent(
                "ModuleCache.noindex",
                isDirectory: true
            ),
        ]

        let fileManager = FileManager.default
        var removedCount = 0
        for path in paths where fileManager.fileExists(atPath: path.path) {
            try fileManager.removeItem(at: path)
            removedCount += 1
        }

        return BuildTargetCleanCacheResult(
            message: "Removed \(removedCount) cache path(s)",
            cleaned: true
        )
    }
}
