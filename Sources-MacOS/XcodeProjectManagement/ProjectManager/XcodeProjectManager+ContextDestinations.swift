import Foundation

public extension XcodeProjectManager {
    func refreshContextDestinations() async throws {
        try Task.checkCancellation()
        guard !destinationDiscoveryStopped else { throw CancellationError() }
        if let task = destinationRefreshTask {
            try await task.value
            try Task.checkCancellation()
            guard !destinationDiscoveryStopped else { throw CancellationError() }
            return
        }
        let loader = destinationLoader
        let task = Task { try await loader.loadDestinations(reload: true) }
        destinationRefreshTask = task
        defer { destinationRefreshTask = nil }
        try await task.value
        try Task.checkCancellation()
        guard !destinationDiscoveryStopped else { throw CancellationError() }
    }

    func stopContextDestinationDiscovery() async {
        destinationDiscoveryStopped = true
        destinationRefreshTask?.cancel()
        if let task = destinationRefreshTask { _ = await task.result }
        destinationRefreshTask = nil
    }
}
