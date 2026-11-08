import Foundation

/// Coordinates access to a DerivedData directory across server processes.
actor XcodeBuildScheduler {
    static let shared = XcodeBuildScheduler()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lockDirectory: URL
    private var activeDirectories: Set<URL> = []
    private var waiters: [URL: [Waiter]] = [:]

    init(lockDirectory: URL = XcodeBuildFileLock.defaultDirectory) {
        self.lockDirectory = lockDirectory
    }

    func withBuild<Result: Sendable>(
        in directory: URL,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        let key = XcodeBuildFileLock.canonicalDirectory(directory)
        try await acquire(key)
        defer { release(key) }
        try Task.checkCancellation()
        return try await XcodeBuildFileLock.withLock(in: key, lockDirectory: lockDirectory, operation: operation)
    }

    nonisolated static func derivedDataDirectory(command: [String], workingDirectory: URL?) throws -> URL? {
        guard let flag = command.lastIndex(of: "-derivedDataPath") else { return nil }
        guard command.indices.contains(flag + 1), !command[flag + 1].isEmpty,
              !command[flag + 1].hasPrefix("-") else {
            throw XcodeProjectError.invalidConfig("Missing -derivedDataPath value")
        }
        let base = URL(
            fileURLWithPath: workingDirectory?.path ?? FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        return URL(fileURLWithPath: command[flag + 1], isDirectory: true, relativeTo: base).absoluteURL
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
