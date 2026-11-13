//
//  SourcesItem+BSP.swift
//  sourcekit-bsp
//
//  Created by wang.lun on 2025/08/29.
//

import SourceKitBSPProtocol
import XcodeProjectManagement

extension XcodeProjectManagement.SourcesItem {
    func asBSPSourcesItems() -> SourceKitBSPProtocol.SourcesItem {
        SourceKitBSPProtocol.SourcesItem(
            target: self.target.bspIdentifier,
            sources: sources.map { $0.asBSPSourceItem() },
            roots: roots?.map { URI($0) }
        )
    }
}

extension XcodeProjectManagement.SourceItem {
    func asBSPSourceItem() -> SourceKitBSPProtocol.SourceItem {
        SourceKitBSPProtocol.SourceItem(
            uri: URI(path),
            kind: itemKind.asBSPSourceItemKind(),
            generated: false
        )
    }
}

extension XcodeProjectManagement.SourceItem.SourceItemKind {
    func asBSPSourceItemKind() -> SourceKitBSPProtocol.SourceItemKind {
        switch self {
        case .directory:
            .directory
        case .file:
            .file
        }
    }
}
