import Foundation
import XcodeProj

/// Parsed projects and source lists owned by one XcodeProjectManager.
struct XcodeProjectStore {
    private var projects: [URL: XcodeProj] = [:]
    private var sourceFiles: [XcodeTargetIdentifier: [SourceItem]] = [:]

    mutating func project(at url: URL) -> XcodeProj? {
        let key = url.resolvingSymlinksInPath().standardizedFileURL
        if let project = projects[key] { return project }
        guard let project = try? XcodeProj(pathString: url.path) else { return nil }
        projects[key] = project
        return project
    }

    mutating func invalidateSources() {
        sourceFiles.removeAll()
    }

    mutating func sources(for identifiers: [XcodeTargetIdentifier]) -> [SourcesItem] {
        let keys = identifiers.map { identifier in
            let url = URL(fileURLWithPath: identifier.projectFilePath).resolvingSymlinksInPath().standardizedFileURL
            return XcodeTargetIdentifier(projectFilePath: url.path, targetName: identifier.targetName)
        }
        let missing = Set(keys).filter { sourceFiles[$0] == nil }
        let grouped = Dictionary(grouping: missing) { URL(fileURLWithPath: $0.projectFilePath) }
        for (url, targets) in grouped {
            // Only projects loaded into this workspace can supply source files.
            guard let project = projects[url], let projectPath = project.path?.string else { continue }
            let loaded = SourceFileLister.loadSourceFiles(for: project, targets: Set(targets.map(\.targetName)))
            for target in targets {
                let parsedIdentifier = XcodeTargetIdentifier(
                    projectFilePath: projectPath,
                    targetName: target.targetName
                )
                sourceFiles[target] = loaded[parsedIdentifier.rawValue]
            }
        }
        return zip(identifiers, keys).map { SourcesItem(target: $0, sources: sourceFiles[$1] ?? []) }
    }
}
