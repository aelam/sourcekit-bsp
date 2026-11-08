import Foundation

extension SwiftPMProjectManagerProvider {
    static func discoverPackageRoot(_ url: URL) throws -> URL? {
        guard url.isFileURL else { return nil }
        if let root = try? packageRoot(url) { return root }
        if url.lastPathComponent == "Package.swift" { return nil }
        let workspace = url.standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspace.path, isDirectory: &directory),
              directory.boolValue else { return nil }
        var candidates: [URL] = []
        var pending = [workspace]
        let excluded: Set = ["node_modules", "Pods", "Carthage", "DerivedData", "build", "out", "target", "vendor"]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        while let parent = pending.popLast() {
            try Task.checkCancellation()
            for child in try FileManager.default.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
            ) {
                let values = try child.resourceValues(forKeys: keys)
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      !excluded.contains(child.lastPathComponent),
                      !["xcodeproj", "xcworkspace"].contains(child.pathExtension) else { continue }
                if let package = try? packageRoot(child) {
                    candidates.append(package)
                } else {
                    pending.append(child)
                }
            }
        }
        let matches = Array(Set(candidates)).sorted { $0.path < $1.path }
        guard matches.count <= 1 else {
            let prefix = workspace.path.hasSuffix("/") ? workspace.path : workspace.path + "/"
            let paths = matches.map { String($0.path.dropFirst(prefix.count)) }
            throw SwiftPMProjectError.ambiguousPackages(paths)
        }
        return matches.first
    }
}
