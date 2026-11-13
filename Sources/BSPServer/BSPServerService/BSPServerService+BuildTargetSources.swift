//
//  BSPServerService+BuildTargetSources.swift
//  sourcekit-bsp
//
//  Created by wang.lun on 2025/08/21.
//

import Foundation
import SourceKitBSPProtocol

extension BSPServerService {
    func getSourcesItems(targetIds: [BSPBuildTargetIdentifier]) async throws -> [SourcesItem] {
        guard let projectManager else {
            throw BuildServerError.invalidConfiguration("Project manager not initialized")
        }
        return try await projectManager.getSourceFileList(targetIdentifiers: targetIds)
    }
}
