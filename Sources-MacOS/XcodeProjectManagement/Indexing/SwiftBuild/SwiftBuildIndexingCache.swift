import Foundation
import SwiftBuild

struct SwiftBuildIndexingPlan: Sendable {
    /// All plans from one operation share its single native retain.
    final class BuildDescription: Sendable {
        let id: SWBBuildDescriptionID
        let version = UUID()
        let wasLoadedOrCreated: Bool
        private let session: SWBBuildServiceSession

        init(id: SWBBuildDescriptionID, session: SWBBuildServiceSession, wasLoadedOrCreated: Bool) {
            self.id = id
            self.wasLoadedOrCreated = wasLoadedOrCreated
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

struct SwiftBuildIndexingDescription: Sendable {
    let request: SWBBuildRequest
    let description: SwiftBuildIndexingPlan.BuildDescription
    let targetGUIDs: Set<String>
}

/// Retains descriptions by identity. All targets in a description share its lifetime.
struct SwiftBuildIndexingPlanCache: Sendable {
    private struct SourcePaths: Sendable {
        let descriptionVersion: UUID
        let paths: [URL: AbsolutePath]
    }

    private var descriptions: [SWBBuildDescriptionID: SwiftBuildIndexingDescription] = [:]
    private var accessOrder: [SWBBuildDescriptionID] = []
    private var primaryID: SWBBuildDescriptionID?
    private var plans: [XcodeTargetIdentifier: SwiftBuildIndexingPlan] = [:]
    private var sourcePaths: [XcodeTargetIdentifier: SourcePaths] = [:]

    var hasPrimaryDescription: Bool {
        primaryID != nil
    }

    mutating func description(covering guids: Set<String>) -> SwiftBuildIndexingDescription? {
        let candidates = primaryID.map { [$0] + accessOrder.reversed() } ?? Array(accessOrder.reversed())
        guard let id = candidates.first(where: {
            descriptions[$0].map { guids.isSubset(of: $0.targetGUIDs) } == true
        }), let description = descriptions[id] else { return nil }
        touch(id)
        return description
    }

    mutating func insert(_ entry: SwiftBuildIndexingDescription, primary: Bool) {
        let id = entry.description.id
        descriptions[id] = entry
        if primary { primaryID = id }
        touch(id)
        // A batch with hundreds of targets still occupies one description slot.
        while accessOrder.count > 4 {
            guard let evicted = accessOrder.first(where: { $0 != primaryID }) else { break }
            remove(evicted)
        }
    }

    mutating func plan(for target: XcodeTargetIdentifier) -> SwiftBuildIndexingPlan? {
        guard let plan = plans[target] else { return nil }
        touch(plan.descriptionID)
        return plan
    }

    mutating func insert(_ plan: SwiftBuildIndexingPlan, for target: XcodeTargetIdentifier) {
        // A query can finish after its description was replaced or evicted.
        guard descriptions[plan.descriptionID]?.description === plan.description else { return }
        if plans[target]?.description !== plan.description { sourcePaths[target] = nil }
        plans[target] = plan
        touch(plan.descriptionID)
    }

    /// Discard overlapping graphs when preparation changes their inputs.
    mutating func replace(
        _ previous: SwiftBuildIndexingDescription, with updated: SwiftBuildIndexingDescription
    ) -> Set<String> {
        let primary = primaryID == previous.description.id
        var affected = previous.targetGUIDs.union(updated.targetGUIDs)
        let removed = descriptions.filter {
            !$0.value.targetGUIDs.isDisjoint(with: affected)
        }
        for (id, entry) in removed {
            affected.formUnion(entry.targetGUIDs)
            remove(id)
        }
        insert(updated, primary: primary)
        return affected
    }

    private mutating func remove(_ id: SWBBuildDescriptionID) {
        accessOrder.removeAll { $0 == id }
        descriptions[id] = nil
        if primaryID == id { primaryID = nil }
        for target in Array(plans.keys) where plans[target]?.descriptionID == id {
            plans[target] = nil
            sourcePaths[target] = nil
        }
    }

    func paths(for target: XcodeTargetIdentifier, descriptionVersion: UUID) -> [URL: AbsolutePath]? {
        guard let sources = sourcePaths[target], sources.descriptionVersion == descriptionVersion else { return nil }
        return sources.paths
    }

    mutating func storePaths(
        _ paths: [URL: AbsolutePath], for target: XcodeTargetIdentifier, descriptionVersion: UUID
    ) {
        guard plans[target]?.description.version == descriptionVersion else { return }
        sourcePaths[target] = SourcePaths(descriptionVersion: descriptionVersion, paths: paths)
    }

    private mutating func touch(_ id: SWBBuildDescriptionID) {
        accessOrder.removeAll { $0 == id }
        accessOrder.append(id)
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

    var targets: Set<XcodeTargetIdentifier> {
        Set(published.keys.map(\.target))
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

    mutating func invalidate(targets: Set<XcodeTargetIdentifier>) {
        // Also reject queries for files that have not published arguments yet.
        version = UUID()
        valid = valid.filter { !targets.contains($0.target) }
    }

    mutating func invalidate() {
        version = UUID()
        valid.removeAll()
    }
}
