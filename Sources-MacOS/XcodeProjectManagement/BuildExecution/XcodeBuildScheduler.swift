import Foundation

/// Coordinates builds that use the same DerivedData directory within this server.
actor XcodeBuildScheduler {
    static let shared = XcodeBuildScheduler()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var activeDirectories: Set<URL> = []
    private var waiters: [URL: [Waiter]] = [:]

    func withBuild(
        in directory: URL,
        operation: @Sendable () async throws -> XcodeBuildExitCode
    ) async throws -> XcodeBuildExitCode {
        let key = canonicalDirectory(directory)
        try await acquire(key)
        defer { release(key) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func canonicalDirectory(_ directory: URL) -> URL {
        // Resolve the existing ancestor because DerivedData may not exist before the first build.
        var ancestor = directory
        var components: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            components.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        return components.reversed().reduce(ancestor.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1, isDirectory: true)
        }.standardizedFileURL
    }

    private func acquire(_ directory: URL) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if activeDirectories.insert(directory).inserted {
                    continuation.resume()
                } else {
                    waiters[directory, default: []].append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id, in: directory) }
        }
    }

    private func cancel(_ id: UUID, in directory: URL) {
        guard let index = waiters[directory]?.firstIndex(where: { $0.id == id }),
              let waiter = waiters[directory]?.remove(at: index) else { return }
        if waiters[directory]?.isEmpty == true { waiters[directory] = nil }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ directory: URL) {
        guard var queue = waiters.removeValue(forKey: directory), !queue.isEmpty else {
            activeDirectories.remove(directory)
            return
        }
        let next = queue.removeFirst()
        if !queue.isEmpty { waiters[directory] = queue }
        next.continuation.resume()
    }
}
