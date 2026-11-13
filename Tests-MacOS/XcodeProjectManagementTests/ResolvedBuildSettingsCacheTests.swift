import Foundation
import Support
import Testing
@testable import XcodeProjectManagement

struct ResolvedBuildSettingsCacheTests {
    private func key(_ arguments: [String] = []) -> ResolvedBuildSettingsCache.Key {
        .init(
            target: .init(projectFilePath: "/tmp/App.xcodeproj", targetName: "App"),
            arguments: arguments,
            developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app"),
            buildVersion: "123"
        )
    }

    @Test
    func sharesQueriesAndKeepsTheOtherCallerWhenOneCancels() async throws {
        let cache = ResolvedBuildSettingsCache()
        let gate = AsyncStream<Void>.makeStream()
        let calls = CrossPlatformLock(initialState: 0)
        let selected = key(["-configuration", "Debug", "-destination", "id=SIM"])
        let load: @Sendable () async throws -> [String: String] = {
            calls.withLock { $0 += 1 }
            for await _ in gate.stream {
                break
            }
            return ["TARGET_BUILD_DIR": "/tmp/Products"]
        }
        let first = Task { try await cache.settings(for: selected, load: load) }
        let second = Task { try await cache.settings(for: selected, load: load) }
        try await waitUntil { cache.waiterCount(for: selected) == 2 }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        gate.continuation.yield(())
        gate.continuation.finish()
        #expect(try await second.value["TARGET_BUILD_DIR"] == "/tmp/Products")
        for _ in 0 ..< 10 {
            _ = try await cache.settings(for: selected, load: load)
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test
    func invalidationRejectsLateResultsAndNewQueriesUseFreshSettings() async throws {
        let cache = ResolvedBuildSettingsCache()
        let gate = SettingsCacheGate()
        let selected = key()
        let old = Task {
            try await cache.settings(for: selected) {
                await gate.wait()
                return ["value": "old"]
            }
        }
        try await waitUntil { cache.waiterCount(for: selected) == 1 }
        let cancelled = cache.invalidate()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(try await cache.settings(for: selected) { ["value": "new"] } == ["value": "new"])
        await gate.release()
        for task in cancelled {
            await task.value
        }
        #expect(try await cache.settings(for: selected) { ["value": "unexpected"] } == ["value": "new"])
    }

    @Test
    func retriesFailuresAndDoesNotReuseExternalConfigurationResults() async throws {
        let cache = ResolvedBuildSettingsCache()
        let selected = key()
        await #expect(throws: CancellationError.self) {
            try await cache.settings(for: selected) { throw CancellationError() }
        }
        #expect(try await cache.settings(for: selected, reuse: false) { ["value": "first"] } == ["value": "first"])
        #expect(try await cache.settings(for: selected, reuse: false) { ["value": "second"] } == ["value": "second"])
    }

    @Test
    func keysExpiryAndCapacityPreventStaleOrUnboundedResults() async throws {
        let instant = CrossPlatformLock(initialState: ContinuousClock.now)
        let cache = ResolvedBuildSettingsCache(capacity: 2, lifetime: .seconds(60), clock: { instant.withLock { $0 } })
        let debug = key(["-configuration", "Debug"])
        let release = key(["-configuration", "Release"])
        let device = key(["-destination", "id=DEVICE"])
        #expect(try await cache.settings(for: debug) { ["mode": "debug"] } == ["mode": "debug"])
        #expect(try await cache.settings(for: release) { ["mode": "release"] } == ["mode": "release"])
        _ = try await cache.settings(for: debug) { [:] }
        _ = try await cache.settings(for: device) { ["mode": "device"] }
        #expect(try await cache.settings(for: release) { ["mode": "reloaded"] } == ["mode": "reloaded"])
        instant.withLock { $0 += .seconds(61) }
        #expect(try await cache.settings(for: device) { ["mode": "expired"] } == ["mode": "expired"])
    }

    @Test
    func lastCancellationStopsTheQueryAndAllowsAReplacement() async throws {
        let cache = ResolvedBuildSettingsCache()
        let selected = key()
        let state = CrossPlatformLock(initialState: (started: false, cancelled: false))
        let caller = Task {
            try await cache.settings(for: selected) {
                state.withLock { $0.started = true }
                do { try await Task.sleep(for: .seconds(30)) } catch {
                    state.withLock { $0.cancelled = true }
                    throw error
                }
                return ["value": "old"]
            }
        }
        try await waitUntil { state.withLock { $0.started } }
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
        try await waitUntil { state.withLock { $0.cancelled } }
        #expect(try await cache.settings(for: selected) { ["value": "new"] } == ["value": "new"])
        #expect(try await cache.settings(for: selected) { [:] } == ["value": "new"])
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < end else { throw DAPRelayError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor SettingsCacheGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if !released { await withCheckedContinuation { waiter = $0 } }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
