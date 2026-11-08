import BuildServerProtocol
import Foundation

public extension XcodeBSPProjectManager {
    func shouldReloadProject(for changes: [ProjectFileChange]) -> Bool {
        guard let project else { return false }
        return XcodeFileChangeClassifier(rootURL: project.rootURL, buildRootURL: project.buildRootURL)
            .requiresReload(for: changes)
    }
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
            guard path != derivedData, !path.hasPrefix(derivedData + "/"),
                  !file.pathComponents.contains(".build") else { return false }
            if Self.configurationExtensions.contains(file.pathExtension)
                || file.lastPathComponent == "contents.xcworkspacedata"
                || file.lastPathComponent == "Package.resolved"
                || file == configuration {
                return true
            }
            return change.kind != .changed && Self.sourceExtensions.contains(file.pathExtension)
        }
    }
}
