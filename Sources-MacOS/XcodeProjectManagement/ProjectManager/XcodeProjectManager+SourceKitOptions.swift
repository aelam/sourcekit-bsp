//
//  XcodeProjectManager+SourceKitOptions.swift
//  sourcekit-bsp
//
//  Created by wang.lun on 2025/09/01.
//

import Foundation

public extension XcodeProjectManager {
    func getCompileArguments(targetIdentifier: XcodeTargetIdentifier, sourceFileURL: URL) async throws -> [String] {
        let projectFilePath = targetIdentifier.projectFilePath
        let targetName = targetIdentifier.targetName

        let projectURL = URL(fileURLWithPath: projectFilePath)
        guard
            let projectSnapshot,
            let xcodeProj = loadXcodeProjCache(projectURL: projectURL)
        else {
            return []
        }

        let sourceItems = getSourcesItems(targetIdentifiers: [targetIdentifier]).first?.sources ?? []

        let generator = try CompileArgGenerator.create(
            xcodeInstallation: projectSnapshot.xcodeInstallation,
            xcodeGlobalSettings: projectSnapshot.xcodeGlobalSettings,
            xcodeProj: xcodeProj,
            target: targetName,
            configurationName: projectSnapshot.configuration,
            fileURL: sourceFileURL,
            sourceItems: sourceItems
        )

        return generator.compileArguments()
    }
}
