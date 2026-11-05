import Foundation
import XcodeProj

/// Parsed projects and source lists owned by one XcodeProjectManager.
struct XcodeProjectStore {
    private var projects: [URL: XcodeProj] = [:]
    private var sourceFiles: [XcodeTargetIdentifier: [SourceItem]] = [:]
    var compilerSettings = CompilerSettingsCache()

    mutating func project(at url: URL) -> XcodeProj? {
        let key = url.resolvingSymlinksInPath().standardizedFileURL
        if let project = projects[key] { return project }
        guard let project = try? XcodeProj(pathString: url.path) else { return nil }
        assignFileParents(in: project)
        projects[key] = project
        return project
    }

    private func assignFileParents(in project: XcodeProj) {
        guard let root = try? project.pbxproj.rootGroup() else { return }
        // Resolve child groups before assigning their parent links, as Xcode does.
        // Direct references then take precedence over references in nested groups.
        var visited: Set<ObjectIdentifier> = []
        func visit(_ group: PBXGroup) {
            guard visited.insert(ObjectIdentifier(group)).inserted else { return }
            let children = group.children
            for case let childGroup as PBXGroup in children {
                visit(childGroup)
            }
            for child in children {
                child.parent = group
            }
        }
        visit(root)
        root.parent = nil
    }

    mutating func invalidateSources() {
        sourceFiles.removeAll()
        compilerSettings.invalidate()
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
