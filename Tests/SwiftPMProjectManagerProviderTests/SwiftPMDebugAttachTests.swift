import Foundation
import SourceKitBSPProtocol
import Support
import Testing
@testable import SwiftPMProjectManagerProvider

#if os(macOS)
struct SwiftPMDebugAttachTests {
    @Test(arguments: BuildContextBuildPolicy.allCases)
    func attachIgnoresBuildPolicyAndRechecksIdentityWithoutResolvingAgain(policy: BuildContextBuildPolicy) async throws {
        let fixture = try TemporarySwiftPMPackage()
        let recorder = try ContextCommandRecorder(fixture: fixture)
        let stops = CrossPlatformLock(initialState: 0)
        let manager = SwiftPMProjectManager(
            rootURL: fixture.root,
            executable: fixture.root.appendingPathComponent("swift"),
            executor: recorder,
            debugAdapter: AttachFixtureAdapter(stops: stops)
        )
        try await manager.initialize()
        let context = try await manager.resolveContext(.init(
            operation: .debug, selection: ["swiftpm.configuration": "release"], buildPolicy: policy
        ))
        let executable = fixture.root.appendingPathComponent("bin/release/app-tool").resolvingSymlinksInPath().path
        let identity = HostProcessIdentity(pid: 42, executable: executable, startToken: "first")
        let current = CrossPlatformLock(initialState: identity)
        let lookups = CrossPlatformLock(initialState: 0)
        await manager.setAttachFixture(lookup: { path in
            #expect(path == executable)
            lookups.withLock { $0 += 1 }
            return [identity]
        }, check: { expected in
            guard current.withLock({ $0 }) == expected else { throw HostAttachError.invalid("PID identity changed") }
        })
        await recorder.failBuild()
        let backend = try await manager.prepareDebugAttach(context: context, pid: nil)
        #expect(backend.connection.request == .attach)
        #expect(backend.connection.pid == 42)
        let calls = await recorder.calls.count
        try await backend.validate()
        #expect(await recorder.calls.count == calls)
        #expect(lookups.withLock { $0 } == 1)
        current.withLock { $0 = .init(pid: 42, executable: executable, startToken: "reused") }
        await #expect(throws: HostAttachError.self) { try await backend.validate() }
        let commands = await recorder.calls
        #expect(commands.filter { $0.arguments.first == "build" }
            .allSatisfy { $0.arguments.contains("--show-bin-path") })
        #expect(commands.allSatisfy { $0.executable.lastPathComponent != "app-tool" })
        await backend.stop()
        await manager.shutdown()
        #expect(stops.withLock { $0 } == 1)
    }

    @Test
    func attachRejectsTestsAndPIDsFromAnotherExecutable() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let recorder = try ContextCommandRecorder(fixture: fixture)
        let manager = SwiftPMProjectManager(
            rootURL: fixture.root,
            executable: fixture.root.appendingPathComponent("swift"),
            executor: recorder,
            debugAdapter: AttachFixtureAdapter(stops: CrossPlatformLock(initialState: 0))
        )
        try await manager.initialize()
        await manager.setAttachFixture(lookup: { _ in
            [.init(pid: 42, executable: "/another/executable", startToken: "one")]
        }, check: { _ in Issue.record("An unrelated process must not be validated") })
        let context = try await manager.resolveContext(.init(operation: .debug))
        await #expect(throws: HostAttachError.self) {
            try await manager.prepareDebugAttach(context: context, pid: 42)
        }
        let target = try #require(await manager.getTargetList().first { $0.displayName == "AppTests" })
        let testContext = try await manager.resolveContext(.init(scope: .init(targets: [target.id]), operation: .debug))
        await #expect(throws: HostAttachError.self) {
            try await manager.prepareDebugAttach(context: testContext, pid: nil)
        }
        await manager.shutdown()
    }
}

private struct AttachFixtureAdapter: SwiftPMDebugAdapterServing {
    let stops: CrossPlatformLock<Int>
    func start() async throws -> SwiftPMDebugEndpoint {
        .init(uri: "tcp://127.0.0.1:12345") { stops.withLock { $0 += 1 } }
    }
}

private extension SwiftPMProjectManager {
    func setAttachFixture(
        lookup: @escaping @Sendable (String) throws -> [HostProcessIdentity],
        check: @escaping @Sendable (HostProcessIdentity) throws -> Void
    ) {
        attachProcessLookup = lookup
        attachIdentityCheck = check
    }
}
#endif
