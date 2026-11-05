import Foundation
import Support

/// Shares active preparations. The caller must include all build inputs in the key.
final class IndexPreparationCoordinator<Key: Hashable & Sendable>: Sendable {
    typealias LogHandler = @Sendable (String) -> Void

    private struct Waiter: Sendable {
        let continuation: CheckedContinuation<Bool, Error>
        let logHandler: LogHandler?
    }

    private struct Preparation: Sendable {
        let key: Key
        let task: Task<Void, Never>
        var waiters: [UUID: Waiter]
    }

    private struct State: Sendable {
        var current: [Key: UUID] = [:]
        var preparations: [UUID: Preparation] = [:]
        var drains = 0
        var stopped = false
    }

    private let state = CrossPlatformLock(initialState: State())

    var operationCount: Int {
        state.withLock { $0.preparations.count }
    }

    var isAcceptingRequests: Bool {
        state.withLock { !$0.stopped && $0.drains == 0 }
    }

    func waiterCount(for key: Key) -> Int {
        state.withLock { state in
            guard let id = state.current[key] else { return 0 }
            return state.preparations[id]?.waiters.count ?? 0
        }
    }

    /// Returns whether compiler options changed. Completed results are never cached.
    /// Only the first operation runs; every current waiter receives subsequent log messages.
    func prepare(
        for key: Key,
        logHandler: LogHandler? = nil,
        operation: @escaping @Sendable (@escaping LogHandler) async throws -> Bool
    ) async throws -> Bool {
        let waiterID = UUID()
        let cancelled = CrossPlatformLock(initialState: false)
        let changed = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let error = register(
                    key: key,
                    waiterID: waiterID,
                    cancelled: cancelled,
                    waiter: Waiter(continuation: continuation, logHandler: logHandler),
                    operation: operation
                )
                if let error { continuation.resume(throwing: error) }
            }
        } onCancel: {
            // The flag also covers cancellation before registration acquires the state lock.
            cancelled.withLock { $0 = true }
            self.cancel(waiterID: waiterID, for: key)
        }
        try Task.checkCancellation()
        return changed
    }

    /// Reject new requests during cleanup, then accept requests again.
    func cancelAll() async {
        await drain(stopping: false)
    }

    /// Reject all future requests and wait for every operation to finish cleanup.
    func stop() async {
        await drain(stopping: true)
    }

    private func register(
        key: Key,
        waiterID: UUID,
        cancelled: CrossPlatformLock<Bool>,
        waiter: Waiter,
        operation: @escaping @Sendable (@escaping LogHandler) async throws -> Bool
    ) -> (any Error)? {
        state.withLock { state in
            let isCancelled = cancelled.withLock { $0 }
            guard !state.stopped, state.drains == 0, !isCancelled else { return CancellationError() }
            if let id = state.current[key], var preparation = state.preparations[id] {
                preparation.waiters[waiterID] = waiter
                state.preparations[id] = preparation
                return nil
            }
            let id = UUID()
            let task = Task {
                let result: Result<Bool, Error>
                do {
                    try Task.checkCancellation()
                    let changed = try await operation { message in
                        self.broadcast(message, preparationID: id)
                    }
                    try Task.checkCancellation()
                    result = .success(changed)
                } catch {
                    result = .failure(error)
                }
                self.finish(preparationID: id, result: result)
            }
            state.current[key] = id
            state.preparations[id] = Preparation(key: key, task: task, waiters: [waiterID: waiter])
            return nil
        }
    }

    private func cancel(waiterID: UUID, for key: Key) {
        let cancelled: (Waiter, Task<Void, Never>?)? = state.withLock { state in
            guard let id = state.current[key], var preparation = state.preparations[id],
                  let waiter = preparation.waiters.removeValue(forKey: waiterID) else { return nil }
            state.preparations[id] = preparation
            if preparation.waiters.isEmpty {
                // Keep the task for cleanup, but let a new request use a new slot for this key.
                state.current.removeValue(forKey: key)
                return (waiter, preparation.task)
            }
            return (waiter, nil)
        }
        cancelled?.0.continuation.resume(throwing: CancellationError())
        cancelled?.1?.cancel()
    }

    private func finish(preparationID: UUID, result: Result<Bool, Error>) {
        let waiters: [Waiter] = state.withLock { state in
            guard let preparation = state.preparations.removeValue(forKey: preparationID) else { return [] }
            // An abandoned operation must not remove its replacement.
            if state.current[preparation.key] == preparationID {
                state.current.removeValue(forKey: preparation.key)
            }
            return Array(preparation.waiters.values)
        }
        for waiter in waiters {
            waiter.continuation.resume(with: result)
        }
    }

    private func broadcast(_ message: String, preparationID: UUID) {
        let handlers: [LogHandler] = state.withLock { state in
            state.preparations[preparationID]?.waiters.values.compactMap(\.logHandler) ?? []
        }
        // Callbacks run outside the lock and can safely call back into the coordinator.
        // Cancellation can overlap delivery of a message already in this snapshot.
        for handler in handlers {
            handler(message)
        }
    }

    private func drain(stopping: Bool) async {
        let pending: ([Task<Void, Never>], [Waiter]) = state.withLock { state in
            state.stopped = state.stopped || stopping
            state.drains += 1
            state.current.removeAll()
            let tasks = state.preparations.values.map(\.task)
            let waiters = state.preparations.values.flatMap(\.waiters.values)
            for id in Array(state.preparations.keys) {
                state.preparations[id]?.waiters.removeAll()
            }
            return (tasks, waiters)
        }
        for waiter in pending.1 {
            waiter.continuation.resume(throwing: CancellationError())
        }
        for task in pending.0 {
            task.cancel()
        }
        for task in pending.0 {
            await task.value
        }
        state.withLock { $0.drains -= 1 }
    }
}
