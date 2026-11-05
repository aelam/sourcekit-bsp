import Support
import Testing
@testable import XcodeProjectManagement

private typealias Coordinator = IndexPreparationCoordinator<String>

@Suite(.timeLimit(.minutes(1)))
struct IndexPreparationCoordinatorTests {
    @Test
    func sharesActiveWorkAndKeepsKeysIndependent() async throws {
        let coordinator = Coordinator()
        let first = PreparationProbe()
        let other = PreparationProbe()
        defer {
            first.release.open()
            other.release.open()
        }
        let one = request(coordinator, probe: first)
        await first.started.wait()
        let two = request(coordinator, probe: first)
        let independent = request(coordinator, key: "other", probe: other)
        await other.started.wait()
        try await waitUntil { coordinator.waiterCount(for: "target") == 2 }
        #expect(first.executions == 1)
        #expect(coordinator.operationCount == 2)
        first.release.open()
        #expect(try await one.value)
        #expect(try await two.value)
        #expect(coordinator.waiterCount(for: "other") == 1)
        other.release.open()
        #expect(try await independent.value)
        let again = request(coordinator, probe: first)
        #expect(try await again.value)
        #expect(first.executions == 2)
        #expect(coordinator.operationCount == 0)
    }

    @Test
    func cancellationIsIndependentAndLogsFollowWaiters() async throws {
        let coordinator = Coordinator()
        let probe = PreparationProbe()
        let messages = CrossPlatformLock(initialState: [String]())
        defer { probe.release.open() }
        let one = request(coordinator, probe: probe) { message in
            #expect(coordinator.waiterCount(for: "target") > 0)
            messages.withLock { $0.append("one: " + message) }
        }
        await probe.started.wait()
        probe.emit("early")
        let two = request(coordinator, probe: probe) { message in
            messages.withLock { $0.append("two: " + message) }
        }
        try await waitUntil { coordinator.waiterCount(for: "target") == 2 }
        probe.emit("shared")
        one.cancel()
        await expectCancelled(one)
        #expect(!probe.cancelled.isOpen)
        #expect(!probe.release.isOpen)
        probe.emit("late")
        #expect(messages.withLock { $0.sorted() } == ["one: early", "one: shared", "two: late", "two: shared"])
        probe.release.open()
        #expect(try await two.value)
    }

    @Test
    func abandonedCompletionCannotRemoveRetry() async throws {
        let coordinator = Coordinator()
        let old = PreparationProbe()
        let retry = PreparationProbe()
        defer {
            old.release.open()
            retry.release.open()
        }
        let one = request(coordinator, probe: old)
        await old.started.wait()
        let two = request(coordinator, probe: old)
        try await waitUntil { coordinator.waiterCount(for: "target") == 2 }
        one.cancel()
        two.cancel()
        await expectCancelled(one)
        await expectCancelled(two)
        await old.cancelled.wait()
        #expect(coordinator.waiterCount(for: "target") == 0)
        let replacement = request(coordinator, probe: retry)
        await retry.started.wait()
        old.release.open()
        try await waitUntil { coordinator.operationCount == 1 }
        let duplicate = request(coordinator, probe: retry)
        try await waitUntil { coordinator.waiterCount(for: "target") == 2 }
        #expect(retry.executions == 1)
        retry.release.open()
        #expect(try await replacement.value)
        #expect(try await duplicate.value)
    }

    @Test
    func failureAllowsRetryAndFalseIsPreserved() async throws {
        let coordinator = Coordinator()
        let probe = PreparationProbe(fails: true)
        defer { probe.release.open() }
        let one = request(coordinator, probe: probe)
        await probe.started.wait()
        let two = request(coordinator, probe: probe)
        try await waitUntil { coordinator.waiterCount(for: "target") == 2 }
        probe.release.open()
        await #expect(throws: PreparationFailure.self) { try await one.value }
        await #expect(throws: PreparationFailure.self) { try await two.value }
        #expect(probe.executions == 1)
        let changed = try await coordinator.prepare(for: "target") { _ in false }
        #expect(!changed)
        #expect(coordinator.operationCount == 0)
    }

    @Test(arguments: [false, true])
    func drainWaitsForActiveAndAbandonedCleanup(stopping: Bool) async throws {
        let coordinator = Coordinator()
        let old = PreparationProbe()
        let active = PreparationProbe()
        let drained = PreparationGate()
        defer {
            old.release.open()
            active.release.open()
        }
        let abandoned = request(coordinator, key: "old", probe: old)
        await old.started.wait()
        abandoned.cancel()
        await expectCancelled(abandoned)
        let current = request(coordinator, probe: active)
        await active.started.wait()
        let drain = Task {
            if stopping { await coordinator.stop() } else { await coordinator.cancelAll() }
            drained.open()
        }
        await active.cancelled.wait()
        await expectCancelled(current)
        #expect(!drained.isOpen)
        await #expect(throws: CancellationError.self) {
            try await coordinator.prepare(for: "new") { _ in true }
        }
        drain.cancel()
        old.release.open()
        try await waitUntil { coordinator.operationCount == 1 }
        #expect(!drained.isOpen)
        active.release.open()
        await drain.value
        #expect(coordinator.operationCount == 0)
        await coordinator.cancelAll()
        #expect(coordinator.isAcceptingRequests == !stopping)
        if stopping {
            await #expect(throws: CancellationError.self) {
                try await coordinator.prepare(for: "new") { _ in true }
            }
        } else {
            #expect(try await coordinator.prepare(for: "new") { _ in true })
        }
    }

    @Test
    func cancelledCallerCannotRegisterWork() async {
        let coordinator = Coordinator()
        let enter = PreparationGate()
        let task = Task {
            await enter.wait()
            return try await coordinator.prepare(for: "target") { _ in
                Issue.record("A cancelled caller started an operation")
                return true
            }
        }
        task.cancel()
        enter.open()
        await expectCancelled(task)
        #expect(coordinator.operationCount == 0)
    }
}

private struct PreparationFailure: Error {}

private func request(
    _ coordinator: Coordinator,
    key: String = "target",
    probe: PreparationProbe,
    logHandler: Coordinator.LogHandler? = nil
) -> Task<Bool, Error> {
    Task {
        try await coordinator.prepare(for: key, logHandler: logHandler) { log in
            try await probe.run(logHandler: log)
        }
    }
}

private func expectCancelled(_ task: Task<Bool, Error>) async {
    await #expect(throws: CancellationError.self) { try await task.value }
}

private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    // Test order depends on observed state, not elapsed time.
    while !condition() {
        try Task.checkCancellation()
        await Task.yield()
    }
}

private final class PreparationProbe: Sendable {
    private struct State: Sendable {
        var executions = 0
        var logHandler: Coordinator.LogHandler?
    }

    let started = PreparationGate()
    let cancelled = PreparationGate()
    let release = PreparationGate()
    private let state = CrossPlatformLock(initialState: State())
    private let fails: Bool

    init(fails: Bool = false) {
        self.fails = fails
    }

    var executions: Int {
        state.withLock { $0.executions }
    }

    func run(logHandler: @escaping Coordinator.LogHandler) async throws -> Bool {
        state.withLock {
            $0.executions += 1
            $0.logHandler = logHandler
        }
        started.open()
        defer { state.withLock { $0.logHandler = nil } }
        await withTaskCancellationHandler {
            await release.wait()
        } onCancel: {
            self.cancelled.open()
        }
        try Task.checkCancellation()
        if fails { throw PreparationFailure() }
        return true
    }

    func emit(_ message: String) {
        let handler = state.withLock { $0.logHandler }
        handler?(message)
    }
}

private final class PreparationGate: Sendable {
    private struct State: Sendable {
        var isOpen = false
        var continuations: [CheckedContinuation<Void, Never>] = []
    }

    private let state = CrossPlatformLock(initialState: State())
    var isOpen: Bool {
        state.withLock { $0.isOpen }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = state.withLock { state in
                if state.isOpen { return true }
                state.continuations.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let pending = state.withLock { state in
            state.isOpen = true
            defer { state.continuations.removeAll() }
            return state.continuations
        }
        for continuation in pending {
            continuation.resume()
        }
    }
}
