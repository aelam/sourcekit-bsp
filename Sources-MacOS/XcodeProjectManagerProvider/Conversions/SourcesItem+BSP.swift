//
//  SourcesItem+BSP.swift
//  sourcekit-bsp
//
//  Created by wang.lun on 2025/08/29.
//

import BuildServerProtocol
import XcodeProjectManagement

extension XcodeProjectManagement.SourcesItem {
    func asBSPSourcesItems() -> BuildServerProtocol.SourcesItem {
        BuildServerProtocol.SourcesItem(
            target: self.target.bspIdentifier,
            sources: sources.map { $0.asBSPSourceItem() },
            roots: roots?.map { URI($0) }
        )
    }
}

extension XcodeProjectManagement.SourceItem {
    func asBSPSourceItem() -> BuildServerProtocol.SourceItem {
        BuildServerProtocol.SourceItem(
            uri: URI(path),
            kind: itemKind.asBSPSourceItemKind(),
            generated: false
        )
    }
}

extension XcodeProjectManagement.SourceItem.SourceItemKind {
    func asBSPSourceItemKind() -> BuildServerProtocol.SourceItemKind {
        switch self {
        case .directory:
            .directory
        case .file:
            .file
        }
    }
}
