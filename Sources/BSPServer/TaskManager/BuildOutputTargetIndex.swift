import BuildServerProtocol
import Foundation

/// Resolves diagnostic ownership from one build context snapshot.
struct BuildOutputTargetIndex: Sendable {
    private struct NamedTarget: Sendable {
        let id: BSPBuildTargetIdentifier
        let project: String?
    }

    private let sourceTargets: [BSPBuildTargetIdentifier]
    private let files: [URL: Set<Int>]
    private let directories: [String: Set<Int>]
    private let names: [String: [NamedTarget]]

    init(context: BuildOutputContext) {
        self.sourceTargets = context.sources.map(\.target)
        var files: [URL: Set<Int>] = [:]
        var directories: [String: Set<Int>] = [:]
        // Overlapping entries in one source item must count as one owner.
        for (index, item) in context.sources.enumerated() {
            for source in item.sources {
                guard let url = source.uri.fileURL?.standardizedFileURL else { continue }
                files[url, default: []].insert(index)
                if source.kind == .directory {
                    directories[url.path + "/", default: []].insert(index)
                }
            }
        }
        self.files = files
        self.directories = directories

        let affected = Set(context.affectedTargets)
        var names: [String: [NamedTarget]] = [:]
        for target in context.targets where affected.contains(target.id) {
            guard let name = target.displayName else { continue }
            let project = target.id.uri.scheme == "xcode"
                ? target.id.uri.arbitrarySchemeURL.deletingLastPathComponent().deletingPathExtension().lastPathComponent
                : nil
            names[name, default: []].append(NamedTarget(id: target.id, project: project))
        }
        self.names = names
    }

    func target(for file: URL, named name: String?, project: String?) -> BSPBuildTargetIdentifier? {
        if let name {
            let matches = (names[name] ?? []).filter {
                project == nil || $0.project == nil || $0.project == project
            }.map(\.id)
            if matches.count == 1 { return matches.first }
            guard !matches.isEmpty else { return nil }
            let owners = Set(sourceOwners(of: file).map { sourceTargets[$0] })
            let common = matches.filter { owners.contains($0) }
            return common.count == 1 ? common.first : nil
        }
        // Parallel compiler jobs can interleave. Only an unambiguous source owner is safe.
        let owners = sourceOwners(of: file)
        guard owners.count == 1, let owner = owners.first else { return nil }
        return sourceTargets[owner]
    }

    private func sourceOwners(of file: URL) -> Set<Int> {
        var owners = files[file] ?? []
        guard !directories.isEmpty else { return owners }
        let path = file.path
        for slash in path.indices where path[slash] == "/" {
            if let matches = directories[String(path[...slash])] {
                owners.formUnion(matches)
            }
        }
        return owners
    }
}
