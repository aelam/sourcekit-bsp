import Foundation
import Support

/// Shares matching queries and retains successful settings until invalidation or expiry.
final class ResolvedBuildSettingsCache: Sendable {
    struct Key: Hashable, Sendable {
        let target: XcodeTargetIdentifier
        let arguments: [String]
        let developerDirectory: URL
        let buildVersion: String
    }

    private struct Cached: Sendable {
        let value: [String: String]
        let expires: ContinuousClock.Instant
        var access: UInt64
    }

    private struct Flight: Sendable {
        let key: Key
        let task: Task<Void, Never>
        let reuse: Bool
        var waiters: [UUID: CheckedContinuation<[String: String], Error>]
    }

    private struct State: Sendable {
        var values: [Key: Cached] = [:]
        var current: [Key: UUID] = [:]
        var flights: [UUID: Flight] = [:]
        var access: UInt64 = 0
    }

    private let state = CrossPlatformLock(initialState: State())
    private let lifetime: Duration
    private let capacity: Int
    private let clock: @Sendable () -> ContinuousClock.Instant

    func waiterCount(for key: Key) -> Int {
        state.withLock { state in
            guard let id = state.current[key] else { return 0 }
            return state.flights[id]?.waiters.count ?? 0
        }
    }

    init(
        capacity: Int = 32,
        lifetime: Duration = .seconds(300),
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.capacity = capacity
        self.lifetime = lifetime
        self.clock = clock
    }

    func settings(
        for key: Key,
        reuse: Bool = true,
        load: @escaping @Sendable () async throws -> [String: String]
    ) async throws -> [String: String] {
        let waiterID = UUID()
        let cancelled = CrossPlatformLock(initialState: false)
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<[String: String], Error>? = state.withLock { state in
                    guard !cancelled.withLock({ $0 }) else { return .failure(CancellationError()) }
                    state.access &+= 1
                    if reuse, var cached = state.values[key], cached.expires > clock() {
                        cached.access = state.access
                        state.values[key] = cached
                        return .success(cached.value)
                    }
                    state.values.removeValue(forKey: key)
                    if let id = state.current[key] {
                        state.flights[id]?.waiters[waiterID] = continuation
                        return nil
                    }
                    let id = UUID()
                    let task = Task {
                        let result: Result<[String: String], Error>
                        do {
                            try Task.checkCancellation()
                            let value = try await load()
                            try Task.checkCancellation()
                            result = .success(value)
                        } catch { result = .failure(error) }
                        self.finish(id: id, result: result)
                    }
                    state.current[key] = id
                    state.flights[id] = Flight(key: key, task: task, reuse: reuse, waiters: [waiterID: continuation])
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
            self.cancel(waiterID: waiterID, key: key)
        }
        try Task.checkCancellation()
        return value
    }

    private func cancel(waiterID: UUID, key: Key) {
        let removed = state.withLock { state -> (CheckedContinuation<[String: String], Error>?, Task<Void, Never>?) in
            guard let id = state.current[key],
                  let waiter = state.flights[id]?.waiters.removeValue(forKey: waiterID) else { return (nil, nil) }
            if state.flights[id]?.waiters.isEmpty == true {
                state.current.removeValue(forKey: key)
                return (waiter, state.flights[id]?.task)
            }
            return (waiter, nil)
        }
        removed.0?.resume(throwing: CancellationError())
        removed.1?.cancel()
    }

    private func finish(id: UUID, result: Result<[String: String], Error>) {
        let waiters = state.withLock { state -> [CheckedContinuation<[String: String], Error>] in
            guard let flight = state.flights.removeValue(forKey: id) else { return [] }
            if state.current[flight.key] == id {
                state.current.removeValue(forKey: flight.key)
                if flight.reuse, capacity > 0, case let .success(value) = result {
                    state.access &+= 1
                    state.values[flight.key] = Cached(value: value, expires: clock() + lifetime, access: state.access)
                    if state.values.count > capacity,
                       let oldest = state.values.min(by: { $0.value.access < $1.value.access })?.key {
                        state.values.removeValue(forKey: oldest)
                    }
                }
            }
            return Array(flight.waiters.values)
        }
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    @discardableResult
    func invalidate() -> [Task<Void, Never>] {
        let pending = state.withLock { state in
            state.values.removeAll()
            state.current.removeAll()
            let tasks = state.flights.values.map(\.task)
            let waiters = state.flights.values.flatMap(\.waiters.values)
            for id in Array(state.flights.keys) {
                state.flights[id]?.waiters.removeAll()
            }
            return (tasks, waiters)
        }
        for waiter in pending.1 {
            waiter.resume(throwing: CancellationError())
        }
        for task in pending.0 {
            task.cancel()
        }
        return pending.0
    }
}
