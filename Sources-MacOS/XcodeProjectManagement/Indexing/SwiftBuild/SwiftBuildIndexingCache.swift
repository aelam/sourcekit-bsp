import Foundation
import SwiftBuild

struct SwiftBuildIndexingPlan: Sendable {
    /// All plans from one operation share its single native retain.
    final class BuildDescription: Sendable {
        let id: SWBBuildDescriptionID
        private let session: SWBBuildServiceSession

        init(id: SWBBuildDescriptionID, session: SWBBuildServiceSession) {
            self.id = id
            self.session = session
        }

        deinit {
            let session = session
            let descriptionID = id
            Task { await session.releaseBuildDescription(id: descriptionID) }
        }
    }

    let request: SWBBuildRequest
    let description: BuildDescription
    let target: SWBConfiguredTargetIdentifier

    var descriptionID: SWBBuildDescriptionID {
        description.id
    }
}

/// Limits retained build descriptions and keeps source paths with their corresponding plan.
struct SwiftBuildIndexingPlanCache: Sendable {
    private struct SourcePaths: Sendable {
        let descriptionID: SWBBuildDescriptionID
        let paths: [URL: AbsolutePath]
    }

    private var plans: [XcodeTargetIdentifier: SwiftBuildIndexingPlan] = [:]
    private var accessOrder: [XcodeTargetIdentifier] = []
    private var sourcePaths: [XcodeTargetIdentifier: SourcePaths] = [:]

    mutating func plan(for target: XcodeTargetIdentifier) -> SwiftBuildIndexingPlan? {
        guard let plan = plans[target] else { return nil }
        accessOrder.removeAll { $0 == target }
        accessOrder.append(target)
        return plan
    }

    mutating func insert(_ plan: SwiftBuildIndexingPlan, for target: XcodeTargetIdentifier) {
        plans[target] = plan
        sourcePaths[target] = nil
        accessOrder.removeAll { $0 == target }
        accessOrder.append(target)
        // Match the engine's default cache count without retaining every target in a large workspace.
        while accessOrder.count > 4 {
            let evicted = accessOrder.removeFirst()
            plans[evicted] = nil
            sourcePaths[evicted] = nil
        }
    }

    func paths(for target: XcodeTargetIdentifier, descriptionID: SWBBuildDescriptionID) -> [URL: AbsolutePath]? {
        guard let sources = sourcePaths[target], sources.descriptionID == descriptionID else { return nil }
        return sources.paths
    }

    mutating func storePaths(
        _ paths: [URL: AbsolutePath], for target: XcodeTargetIdentifier, descriptionID: SWBBuildDescriptionID
    ) {
        sourcePaths[target] = SourcePaths(descriptionID: descriptionID, paths: paths)
    }
}

/// Keeps published arguments for change detection and tracks which entries can be reused.
struct SwiftBuildIndexingArgumentsCache: Sendable {
    struct Key: Hashable, Sendable {
        let target: XcodeTargetIdentifier
        let file: URL
    }

    private var published: [Key: [String]] = [:]
    private var valid: Set<Key> = []
    private(set) var version = UUID()

    func cached(for key: Key) -> [String]? {
        valid.contains(key) ? published[key] : nil
    }

    func published(for target: XcodeTargetIdentifier) -> [Key: [String]] {
        published.filter { $0.key.target == target }
    }

    @discardableResult
    mutating func publish(_ arguments: [String], for key: Key, version: UUID) -> Bool {
        guard self.version == version else { return false }
        published[key] = arguments
        valid.insert(key)
        return true
    }

    mutating func invalidate() {
        version = UUID()
        valid.removeAll()
    }
}
