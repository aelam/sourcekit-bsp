import SourceKitBSPProtocol
import XcodeProjectManagement

extension XcodeProjectSnapshot {
    func asBSPProject(
        dependencies: [XcodeTargetIdentifier: [XcodeTargetIdentifier]],
        dependencyModules: [XcodeTargetIdentifier: [DependencyModule]] = [:]
    ) -> BSPProject {
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
            indexDatabaseURL: xcodeGlobalSettings.indexDatabaseURL,
            dependencyModules: Dictionary(uniqueKeysWithValues: dependencyModules
                .map { ($0.key.bspIdentifier, $0.value) })
        )
    }
}

extension XcodeProjectManager {
    /// Read the snapshot and its dependency graph in one actor turn.
    func makeBSPProject() throws -> BSPProject? {
        try projectSnapshot?.asBSPProject(
            dependencies: resolveDirectDependencies(), dependencyModules: resolveDependencyModules()
        )
    }
}
