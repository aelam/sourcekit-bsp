//
//  ProjectInfo+XcodeProjectInfo.swift
//  sourcekit-bsp
//
//  Created by wang.lun on 2025/08/21.
//

import BuildServerProtocol
import Foundation
import XcodeProjectManagement

extension XcodeProjectBaseInfo {
    func asProjectInfo() -> ProjectInfo {
        ProjectInfo(
            rootURL: rootURL,
            name: "",
            targets: xcodeTargets.map { $0.asProjectTarget() },
            derivedDataPath: xcodeGlobalSettings.derivedDataPath,
            indexStoreURL: xcodeGlobalSettings.indexStoreURL,
            indexDatabaseURL: xcodeGlobalSettings.indexDatabaseURL
        )
    }
}

extension XcodeTarget {
    func asProjectTarget() -> ProjectTarget {
        ProjectTarget(
            targetIndentifier: targetIdentifier.rawValue,
            name: name,
            isSourcesResolved: false,
            isDependenciesResolved: false,
            sourceFiles: [],
            dependencies: [],
            productType: xcodeProductType.asProductType
        )
    }
}
