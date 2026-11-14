import Foundation
import SwiftBuild

/// Tracks shared requests and pending operations until shutdown.
struct SwiftBuildIndexingOperations {
    struct PlanningKey: Hashable, Sendable {
        let target: XcodeTargetIdentifier
        let contextVersion: UUID
    }

    struct PreparationKey: Hashable, Sendable {
        let targets: [XcodeTargetIdentifier]
        let generation: UUID
    }

    struct ArgumentsKey: Hashable, Sendable {
        let entry: SwiftBuildIndexingArgumentsCache.Key
        let contextVersion: UUID
        let inputsVersion: UUID
    }

    struct SourcesKey: Hashable, Sendable {
        let target: XcodeTargetIdentifier
        let contextVersion: UUID
        let descriptionID: SWBBuildDescriptionID
    }

    private struct Pending {
        let cancel: @Sendable () -> Void
        let completion: Task<Void, Never>
    }

    let initialization = IndexPreparationCoordinator<String>()
    let planning = SharedIndexPreparationCoordinator<PlanningKey, SwiftBuildIndexingPlan>()
    let preparation = SharedIndexPreparationCoordinator<PreparationKey, IndexPreparationChanges>()
    let arguments = SharedIndexPreparationCoordinator<ArgumentsKey, [String]?>()
    let sources = SharedIndexPreparationCoordinator<SourcesKey, [URL: AbsolutePath]>()
    private var pending: [UUID: Pending] = [:]
    private(set) var isStopped = false

    mutating func track(_ task: Task<some Sendable, Error>, id: UUID) {
        pending[id] = Pending(cancel: { task.cancel() }, completion: Task { _ = await task.result })
    }

    mutating func remove(_ id: UUID) {
        pending[id] = nil
    }

    mutating func stopAcceptingWork() {
        isStopped = true
    }

    func cancelPending() -> [Task<Void, Never>] {
        let operations = Array(pending.values)
        for operation in operations {
            operation.cancel()
        }
        return operations.map(\.completion)
    }
}
