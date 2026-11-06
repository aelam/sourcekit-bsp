//
//  BSPServerService+BuildTargets.swift
//
//  Copyright © 2024 Wang Lun.
//

import BuildServerProtocol
import Foundation
import JSONRPCConnection
import Logger

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

    /// 为索引构建目标（BSP 协议适配）
    func buildTargetForIndex(targets: [BSPBuildTargetIdentifier]) async throws {
        guard let projectManager else {
            throw BuildServerError.invalidConfiguration("Project not initialized")
        }

        let context = await BuildOutputContext.load(using: projectManager, targets: targets)
        let changedTargets = try await getTaskManager().executeTask(
            originId: nil, message: "Prepare indexing", context: context
        ) { _, log in
            try await (projectManager.buildIndex(for: targets, logHandler: log), StatusCode.ok)
        }
        if !changedTargets.isEmpty {
            try await sendNotification(ServerJSONRPCNotification(
                method: BuildTargetDidChangeNotification.method(),
                params: BuildTargetDidChangeNotification.Params(changes: changedTargets.map {
                    BuildTargetEvent(target: $0, kind: .changed, dataKind: nil, data: nil)
                })
            ))
        }
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
