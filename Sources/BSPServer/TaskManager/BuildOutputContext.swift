import Foundation
import SourceKitBSPProtocol

struct BuildOutputContext: Sendable {
    var rootURL: URL = FileManager.default.temporaryDirectory
    var logDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("sourcekit-bsp-logs")
    var targets: [BSPBuildTarget] = []
    var sources: [SourcesItem] = []
    var affectedTargets: [BSPBuildTargetIdentifier] = []

    static func load(using manager: any ProjectManager, targets requested: [BSPBuildTargetIdentifier]) async -> Self {
        let project = await manager.project
        let targets = project?.targets ?? []
        let affected = project?.dependencyClosure(for: requested) ?? requested
        let root = await manager.rootURL
        let directory = project?.buildRootURL ?? root.appendingPathComponent(".sourcekit-bsp")
        return await Self(
            rootURL: root,
            logDirectory: directory.appendingPathComponent("Logs/sourcekit-bsp"),
            targets: targets,
            sources: (try? manager.getSourceFileList(targetIdentifiers: affected)) ?? [],
            affectedTargets: affected
        )
    }
}
