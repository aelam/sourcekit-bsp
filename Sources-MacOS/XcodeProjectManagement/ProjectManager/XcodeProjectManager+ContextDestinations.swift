import Foundation

public extension XcodeProjectManager {
    func refreshContextDestinations(allowCached: Bool = false) async throws {
        try Task.checkCancellation()
        guard !destinationDiscoveryStopped else { throw CancellationError() }
        let now = contextDiscoveryClock()
        if let task = destinationRefreshTask {
            try await task.value
            try Task.checkCancellation()
            guard !destinationDiscoveryStopped else { throw CancellationError() }
            return
        }
        if allowCached, let refreshed = destinationRefreshInstant,
           refreshed.duration(to: now) < .seconds(2) {
            return
        }
        destinationRefreshInstant = nil
        let loader = destinationLoader
        let task = Task { try await loader.loadDestinations(reload: true) }
        destinationRefreshTask = task
        defer { destinationRefreshTask = nil }
        try await task.value
        try Task.checkCancellation()
        guard !destinationDiscoveryStopped else { throw CancellationError() }
        destinationRefreshInstant = contextDiscoveryClock()
    }

    func stopContextDestinationDiscovery() async {
        destinationDiscoveryStopped = true
        destinationRefreshInstant = nil
        destinationRefreshTask?.cancel()
        if let task = destinationRefreshTask { _ = await task.result }
        destinationRefreshTask = nil
    }
}
