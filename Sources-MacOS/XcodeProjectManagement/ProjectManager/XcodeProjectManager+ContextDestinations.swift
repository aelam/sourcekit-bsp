import Foundation

public extension XcodeProjectManager {
    func refreshContextDestinations(allowCached: Bool = false) async throws {
        try Task.checkCancellation()
        guard !destinationDiscoveryStopped else { throw CancellationError() }
        let now = contextDiscoveryClock()
        if allowCached, let refreshed = destinationRefreshInstant {
            if refreshed.duration(to: now) >= .seconds(2) {
                _ = startContextDestinationRefresh()
            }
            return
        }
        let task = startContextDestinationRefresh()
        try await task.value
        try Task.checkCancellation()
        guard !destinationDiscoveryStopped else { throw CancellationError() }
    }

    func stopContextDestinationDiscovery() async {
        destinationDiscoveryStopped = true
        let task = destinationRefreshTask
        invalidateContextDestinationDiscovery()
        if let task { _ = await task.result }
    }
}

extension XcodeProjectManager {
    func invalidateContextDestinationDiscovery() {
        destinationRefreshID = nil
        destinationRefreshInstant = nil
        destinationRefreshTask?.cancel()
        destinationRefreshTask = nil
    }

    private func startContextDestinationRefresh() -> Task<Void, Error> {
        if let task = destinationRefreshTask { return task }
        let id = UUID()
        destinationRefreshID = id
        let task = Task { try await performContextDestinationRefresh(id: id) }
        destinationRefreshTask = task
        return task
    }

    private func performContextDestinationRefresh(id: UUID) async throws {
        do {
            let snapshot = try await destinationLoader.discoverDestinations()
            try Task.checkCancellation()
            guard destinationRefreshID == id, !destinationDiscoveryStopped else { throw CancellationError() }
            destinationLoader.publishDestinations(snapshot)
            destinationRefreshInstant = contextDiscoveryClock()
            destinationRefreshTask = nil
            destinationRefreshID = nil
        } catch {
            if destinationRefreshID == id {
                destinationRefreshInstant = nil
                destinationRefreshTask = nil
                destinationRefreshID = nil
            }
            throw error
        }
    }
}
