import BuildServerProtocol
import XcodeProjectManagement

extension XcodeProjectSnapshot {
    func asBSPProject(dependencies: [XcodeTargetIdentifier: [XcodeTargetIdentifier]]) -> BSPProject {
        BSPProject(
            rootURL: rootURL,
            name: name,
            targets: xcodeTargets.map { target in
                target.asBSPBuildTarget(
                    dependencies: (dependencies[target.targetIdentifier] ?? []).map(\.bspIdentifier),
                    toolchain: xcodeInstallation.toolchainDir
                )
            },
            buildRootURL: xcodeGlobalSettings.derivedDataPath,
            indexStoreURL: xcodeGlobalSettings.indexStoreURL,
            indexDatabaseURL: xcodeGlobalSettings.indexDatabaseURL
        )
    }
}

extension XcodeProjectManager {
    /// Read the snapshot and its dependency graph in one actor turn.
    func makeBSPProject() -> BSPProject? {
        projectSnapshot?.asBSPProject(dependencies: resolveDirectDependencies())
    }
}
