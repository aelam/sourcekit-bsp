//
//  XcodeTargetIdentifier+BSP.swift
//  sourcekit-bsp
//
//  The single bridge between the Xcode-domain target identifier
//  (`XcodeTargetIdentifier`) and the BSP-domain identifier
//  (`BSPBuildTargetIdentifier`). All conversions between the two models must go
//  through here so the mapping stays consistent and correct.
//

import BuildServerProtocol
import Foundation
import XcodeProjectManagement

extension XcodeTargetIdentifier {
    /// The target's URI. Built from components (rather than parsing the raw
    /// string) so project/target paths containing spaces or other characters
    /// that `URL(string:)` rejects are percent-encoded correctly.
    ///
    /// Shape: `xcode://<projectFilePath>/<targetName>`.
    var uri: URI {
        var components = URLComponents()
        components.scheme = "xcode"
        components.host = ""
        components.path = "\(projectFilePath)/\(targetName)"
        if let url = components.url {
            return URI(url)
        }
        // Best-effort fallback; should not happen for a well-formed identifier.
        return (try? URI(string: rawValue)) ?? URI(filePath: projectFilePath, isDirectory: false)
    }

    /// The BSP identifier for this Xcode target.
    var bspIdentifier: BSPBuildTargetIdentifier {
        BSPBuildTargetIdentifier(uri: uri)
    }

    /// Reconstruct an Xcode target identifier from a BSP identifier.
    /// Uses the percent-decoded URL path so paths round-trip exactly.
    init(_ bspIdentifier: BSPBuildTargetIdentifier) {
        let url = bspIdentifier.uri.arbitrarySchemeURL
        if url.scheme == "xcode" {
            // `url.path` is percent-decoded. Format: "<projectFilePath>/<targetName>".
            let fullPath = url.path as NSString
            self.init(
                projectFilePath: fullPath.deletingLastPathComponent,
                targetName: fullPath.lastPathComponent
            )
        } else {
            self.init(rawValue: bspIdentifier.uri.stringValue)
        }
    }
}
