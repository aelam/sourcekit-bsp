import BuildServerProtocol
import Foundation

struct BuildOutputContext: Sendable {
    var rootURL: URL = FileManager.default.temporaryDirectory
    var logDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("sourcekit-bsp-logs")
    var targets: [BSPBuildTarget] = []
    var sources: [SourcesItem] = []
    var affectedTargets: [BSPBuildTargetIdentifier] = []

    static func load(using manager: any ProjectManager, targets requested: [BSPBuildTargetIdentifier]) async -> Self {
        let targets = await manager.getTargetList(resolveSourceFiles: true, resolveDependencies: true)
        var affected = Set(requested)
        var pending = requested
        while let id = pending.popLast() {
            for dependency in targets.first(where: { $0.id == id })?.dependencies ?? []
                where affected.insert(dependency).inserted {
                pending.append(dependency)
            }
        }
        let root = await manager.rootURL
        let directory = await manager.projectInfo?.derivedDataPath ?? root.appendingPathComponent(".sourcekit-bsp")
        return await Self(
            rootURL: root,
            logDirectory: directory.appendingPathComponent("Logs/sourcekit-bsp"),
            targets: targets,
            sources: (try? manager.getSourceFileList(targetIdentifiers: Array(affected))) ?? [],
            affectedTargets: Array(affected)
        )
    }

    func target(for file: URL, named name: String?, project: String?) -> BSPBuildTargetIdentifier? {
        let owners = sources.filter { item in
            item.sources.contains { source in
                guard let url = source.uri.fileURL?.standardizedFileURL else { return false }
                return url == file || (source.kind == .directory && file.path.hasPrefix(url.path + "/"))
            }
        }
        .map(\.target)
        if let name {
            let matches = targets.filter { target in
                guard affectedTargets.contains(target.id), target.displayName == name else { return false }
                guard let project, target.id.uri.scheme == "xcode" else { return true }
                let url = target.id.uri.arbitrarySchemeURL.deletingLastPathComponent()
                return url.deletingPathExtension().lastPathComponent == project
            }
            .map(\.id)
            if matches.count == 1 { return matches.first }
            let common = matches.filter { owners.contains($0) }
            return common.count == 1 ? common.first : nil
        }
        // Parallel compiler jobs can interleave. Do not infer ownership from the previous log line.
        return owners.count == 1 ? owners.first : nil
    }
}
