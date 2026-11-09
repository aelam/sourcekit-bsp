import BuildServerProtocol
import Foundation
import Support
import Testing
@testable import XcodeProjectManagement

struct AttachTimingIntegrationTests {
    @Test
    func timedBackendPreservesRepeatedValidationAndCleanup() async throws {
        let calls = CrossPlatformLock(initialState: [String]())
        let summaries = CrossPlatformLock(initialState: [String]())
        let report: @Sendable (String)
            async -> Void = { message in
                summaries.withLock { $0.append(message) }
            }
        let timing = XcodeAttachTiming.$report.withValue(report) { AttachTiming() }
        let backend = timing.track(DebugSessionBackend(
            connection: .init(uri: "tcp://127.0.0.1:1", request: .attach, pid: 42),
            validate: { calls.withLock { $0.append("validate") } },
            didStart: { calls.withLock { $0.append("started") } },
            stop: { calls.withLock { $0.append("stop") } }
        ))
        #expect(backend.connection.pid == 42)
        try await backend.validate()
        try await backend.validate()
        #expect(summaries.withLock { $0.isEmpty })
        await backend.didStart()
        await backend.stop()
        await backend.stop()
        #expect(calls.withLock { $0 } == ["validate", "validate", "started", "stop", "stop"])
        let messages = summaries.withLock { $0 }
        #expect(messages.count == 1)
        let summary = try #require(messages.first)
        #expect(summary.contains(" ok total="))
        #expect(summary.contains("identity.recheck="))
        #expect(summary.contains("ms(n=2)"))
    }

    @Test(arguments: [false, true])
    func validationFailurePreservesTheErrorAndReportsAfterCleanup(cancelled: Bool) async throws {
        let stopped = CrossPlatformLock(initialState: false)
        let summaries = CrossPlatformLock(initialState: [String]())
        let report: @Sendable (String)
            async -> Void = { message in
                #expect(stopped.withLock { $0 })
                #expect(!Task.isCancelled)
                summaries.withLock { $0.append(message) }
            }
        let timing = XcodeAttachTiming.$report.withValue(report) { AttachTiming() }
        let backend = timing.track(DebugSessionBackend(
            connection: .init(uri: "tcp://127.0.0.1:1", request: .attach, pid: 42),
            validate: {
                if cancelled { throw CancellationError() }
                throw HostAttachError.invalid("The selected process changed")
            },
            didStart: { Issue.record("Failed validation must not start the session") },
            stop: { stopped.withLock { $0 = true } }
        ))
        let operation = Task {
            if cancelled {
                await #expect(throws: CancellationError.self) { try await backend.validate() }
                withUnsafeCurrentTask { $0?.cancel() }
            } else {
                await #expect(throws: HostAttachError.self) { try await backend.validate() }
            }
            await backend.stop()
            await backend.stop()
        }
        await operation.value
        let messages = summaries.withLock { $0 }
        #expect(messages.count == 1)
        let summary = try #require(messages.first)
        #expect(summary.contains(cancelled ? " cancelled at=identity.recheck " : " failed at=identity.recheck "))
    }
}
