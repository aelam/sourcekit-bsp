import Foundation
import SourceKitBSPProtocol
import XcodeProjectManagement

public extension XcodeBSPProjectManager {
    func shouldReloadProject(for changes: [ProjectFileChange]) async -> Bool {
        guard let project else { return false }
        let selectionFile = XcodeIndexingSelection.file(in: project.buildRootURL).standardizedFileURL
        let selectionChanges = changes.filter { $0.uri.fileURL?.standardizedFileURL == selectionFile }
        let projectChanges = changes.filter { $0.uri.fileURL?.standardizedFileURL != selectionFile }
        var reasons: XcodeProjectUpdateReasons = []
        if !selectionChanges.isEmpty { reasons.insert(.indexBuildContext) }
        if XcodeFileChangeClassifier(rootURL: project.rootURL, buildRootURL: project.buildRootURL)
            .requiresReload(for: projectChanges) {
            reasons.insert(.projectStructure)
        }
        reload.pendingReasons.formUnion(reasons)
        return !reasons.isEmpty
    }
}

/// File events that require an update; the stored values might still be unchanged.
struct XcodeProjectUpdateReasons: OptionSet, Sendable {
    let rawValue: UInt8

    static let indexBuildContext = Self(rawValue: 1 << 0)
    static let projectStructure = Self(rawValue: 1 << 1)
}

struct XcodeFileChangeClassifier {
    let rootURL: URL
    let buildRootURL: URL

    private static let sourceExtensions: Set = ["swift", "c", "cc", "cpp", "cxx", "m", "mm", "h", "hpp", "hxx"]
    private static let configurationExtensions: Set = [
        "pbxproj", "xcworkspace", "xcconfig", "xcscheme", "xctestplan", "xcfilelist"
    ]

    func requiresReload(for changes: [ProjectFileChange]) -> Bool {
        let derivedData = buildRootURL.standardizedFileURL.path
        let configuration = rootURL.appendingPathComponent(".sourcekit-bsp/project.json").standardizedFileURL
        return changes.contains { change in
            guard let file = change.uri.fileURL?.standardizedFileURL else { return false }
            let path = file.path
            if file == XcodeIndexingSelection.file(in: buildRootURL).standardizedFileURL { return true }
            guard path != derivedData, !path.hasPrefix(derivedData + "/"),
                  !file.pathComponents.contains(".build") else { return false }
            if Self.configurationExtensions.contains(file.pathExtension)
                || file.lastPathComponent == "contents.xcworkspacedata"
                || file.lastPathComponent == "Package.resolved"
                || file.lastPathComponent == "Package.swift"
                || file == configuration {
                return true
            }
            return change.kind != .changed && Self.sourceExtensions.contains(file.pathExtension)
        }
    }
}
