//
//  BSPServerService+Initialize.swift
//  sourcekit-bsp
//
//  Created by wang.lun on 2025/08/21.
//

import Foundation

public extension BSPServerService {
    func shutdownProject() async {
        await projectManager?.shutdown()
    }

    func initializeProject(rootURL: URL) async throws {
        if projectManager != nil {
            return
        }

        logger.info("Initializing project...")

        let projectManager = try await Task.detached {
            let projectManager = try await ProjectManagerProviderRegistry
                .createFactory().createProjectManager(
                    rootURL: rootURL
                )

            try await projectManager.initialize()
            return projectManager
        }.value
        logger.info("!!projectManager created: \(projectManager)")
        self.projectManager = projectManager
    }

    func reloadProject() async throws {
        guard let projectManager else {
            throw BuildServerError.invalidConfiguration("Project manager not initialized")
        }

        logger.info("Reloading project...")
        try await projectManager.initialize()
        await projectManager.updateBuildGraph()
        logger.info("Project reloaded")
    }
}
