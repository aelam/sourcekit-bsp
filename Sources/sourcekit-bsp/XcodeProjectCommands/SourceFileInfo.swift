#if os(macOS)
//
//  SourceFileInfo.swift
//  sourcekit-bsp
//
//  Created by wang.lun on 2025/09/04.
//

import Foundation
import XcodeProjectManagement

struct TargetInfo: Sendable {
    let projectFolder: URL
    let projectFilePath: String // relative to projectFolder
    let targetName: String
    var configurationName: String = "Debug"
    var derivedDataPath: URL {
        PathHash.derivedDataFullPath(for: projectFolder.appendingPathComponent(projectFilePath).path)
    }

    var projectFileFullPath: URL {
        if projectFilePath.isRelativePath {
            return projectFolder.appendingPathComponent(projectFilePath)
        }
        return URL(fileURLWithPath: projectFilePath)
    }
}

struct SourceFileInfo: Sendable {
    let targetInfo: TargetInfo
    let filePath: String // relative to projectFolder

    var fileFullPath: URL {
        if filePath.isRelativePath {
            return targetInfo.projectFolder.appendingPathComponent(filePath)
        }
        return URL(fileURLWithPath: filePath)
    }
}

extension TargetInfo {
    init(sharedOptions: SharedOptions) {
        self.init(
            projectFolder: URL(fileURLWithPath: sharedOptions.workspaceFolder.absolutePath),
            projectFilePath: sharedOptions.xcodeproj,
            targetName: sharedOptions.target,
            configurationName: sharedOptions.configuration
        )
    }
}
#endif
