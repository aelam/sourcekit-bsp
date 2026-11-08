import Foundation
import Support
import Testing
import XcodeProj
@testable import XcodeProjectManagement

struct ContextFixture {
    let root: URL
    let manager: XcodeProjectManager

    var schemeURL: URL {
        root.appendingPathComponent("Hello.xcodeproj/xcshareddata/xcschemes/Hello.xcscheme")
    }

    var schemeID: String {
        schemeURL.resolvingSymlinksInPath().standardizedFileURL.absoluteString
    }

    static func make(
        inventory: ContextInventory? = nil,
        clock: ContextClock = ContextClock(),
        edit: (XCScheme, URL) throws -> Void = { _, _ in }
    ) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ContextTests-\(UUID().uuidString)")
        let source = try #require(Bundle.module.resourceURL?.appendingPathComponent("DemoProjects/HelloProject"))
        try FileManager.default.copyItem(at: source, to: root)
        do {
            let schemeURL = root.appendingPathComponent("Hello.xcodeproj/xcshareddata/xcschemes/Hello.xcscheme")
            let directory = schemeURL.deletingLastPathComponent()
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where file.pathExtension == "xcscheme" && file.lastPathComponent != "Hello.xcscheme" {
                try FileManager.default.removeItem(at: file)
            }
            let scheme = try XCScheme(pathString: schemeURL.path)
            try edit(scheme, schemeURL.deletingLastPathComponent())
            try scheme.write(path: .init(schemeURL.path), override: true)
            let toolchain = XcodeToolchain(workingDirectory: root)
            let manager = XcodeProjectManager(
                rootURL: root,
                toolchain: toolchain,
                projectLocator: XcodeProjectLocator(),
                settingsLoader: XcodeSettingsLoader(commandBuilder: XcodeBuildCommandBuilder(), toolchain: toolchain),
                contextDiscoveryClock: { clock.now },
                destinationDiscovery: {
                    if let inventory { return try await inventory.discover() }
                    return ContextInventory.connected
                }
            )
            try await manager.initialize()
            return Self(root: root, manager: manager)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func schemeFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: schemeURL.deletingLastPathComponent().path).sorted()
    }
}

actor ContextInventory {
    enum Failure: Error { case unavailable }
    static let connected = """
    == Devices ==
    iPhone 16 Pro (18.5) (BSP-DEVICE)
    == Simulators ==
    iPhone 16 Simulator (18.5) (BSP-SIMULATOR)
    """

    private var output = connected
    private var failed = false
    private(set) var calls = 0
    private enum Event: Hashable {
        case paused(Int)
        case cancelled(Int)
    }

    private var shouldPause = false
    private var paused: [Int: CheckedContinuation<Void, Never>] = [:]
    private var events: Set<Event> = []
    private var waiters: [Event: [CheckedContinuation<Void, Never>]] = [:]

    func discover() async throws -> String {
        calls += 1
        let call = calls
        if shouldPause {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    paused[call] = continuation
                    signal(.paused(call))
                }
            } onCancel: {
                Task { await self.signal(.cancelled(call)) }
            }
        }
        if failed { throw Failure.unavailable }
        return output
    }

    func pause() {
        shouldPause = true
    }

    func waitUntilPaused(call: Int = 2) async {
        await wait(for: .paused(call))
    }

    func waitUntilCancelled(call: Int) async {
        await wait(for: .cancelled(call))
    }

    func resume(call: Int? = nil) {
        if let call {
            paused.removeValue(forKey: call)?.resume()
        } else {
            shouldPause = false
            for continuation in paused.values {
                continuation.resume()
            }
            paused.removeAll()
        }
    }

    private func signal(_ event: Event) {
        events.insert(event)
        for waiter in waiters.removeValue(forKey: event) ?? [] {
            waiter.resume()
        }
    }

    private func wait(for event: Event) async {
        if events.contains(event) { return }
        await withCheckedContinuation { waiters[event, default: []].append($0) }
    }

    func disconnect() {
        output = """
        == Devices Offline ==
        iPhone 16 Pro (18.5) (BSP-DEVICE)
        """
    }

    func fail() {
        failed = true
    }
}

final class ContextClock: Sendable {
    private struct State: Sendable {
        var instant = ContinuousClock.now
        var reads = 0
        var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    }

    private let state = CrossPlatformLock(initialState: State())

    var now: ContinuousClock.Instant {
        state.withLock { state in
            state.reads += 1
            let reads = state.reads
            state.waiters.removeAll { count, waiter in
                guard reads >= count else { return false }
                waiter.resume()
                return true
            }
            return state.instant
        }
    }

    var reads: Int {
        state.withLock { $0.reads }
    }

    func advance(by duration: Duration) {
        state.withLock { $0.instant = $0.instant.advanced(by: duration) }
    }

    func waitForReads(_ count: Int) async {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                if state.reads >= count {
                    continuation.resume()
                } else {
                    state.waiters.append((count, continuation))
                }
            }
        }
    }
}
