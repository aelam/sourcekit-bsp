//
//  XcodeProjectManager+Dependencies.swift
//  sourcekit-bsp
//
//  Resolves the direct build-target dependency graph for the loaded project(s).
//

import Foundation
import XcodeProj

public extension XcodeProjectManager {
    /// Direct (immediate) build dependencies for every target in the project,
    /// keyed by target identifier. Combines explicit target dependencies and
    /// implicit framework links, resolved across all projects in the workspace.
    ///
    /// Returns an empty map before `initialize()` has populated the base info.
    func resolveDirectDependencies() -> [XcodeTargetIdentifier: [XcodeTargetIdentifier]] {
        guard let baseInfo = xcodeProjectBaseInfo else { return [:] }

        let targets = baseInfo.xcodeTargets
        guard !targets.isEmpty else { return [:] }

        // Load the (cached) XcodeProj for every project the targets belong to.
        let projects = Set(targets.map(\.projectURL)).compactMap { loadXcodeProjCache(projectURL: $0) }
        guard let primary = projects.first else { return [:] }

        let resolver = XcodeBuildGraphResolver(
            primaryXcodeProj: primary,
            additionalXcodeProjs: Array(projects.dropFirst()),
            mode: .full
        )

        var dependenciesByTarget: [XcodeTargetIdentifier: [XcodeTargetIdentifier]] = [:]
        for target in targets {
            dependenciesByTarget[target.targetIdentifier] =
                resolver.directDependencies(for: target.targetIdentifier)
        }
        return dependenciesByTarget
    }
}
