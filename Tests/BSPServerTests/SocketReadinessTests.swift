import Foundation
import Support
import Testing

struct SocketReadinessTests {
    @Test(.timeLimit(.minutes(1)))
    func rearmsAfterEachReadAndHandlesBufferedData() async throws {
        let pipe = Pipe()
        let activity = SocketReadiness()
        defer {
            activity.finish()
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        for _ in 0 ..< 50 {
            try pipe.fileHandleForWriting.write(contentsOf: Data([42]))
            try await activity.wait(
                read: [pipe.fileHandleForReading.fileDescriptor],
                write: [],
                until: .now + .seconds(5)
            )
            #expect(try pipe.fileHandleForReading.read(upToCount: 1) == Data([42]))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func idleWaitOnlyCompletesOnASignalOrDeadline() async throws {
        let activity = SocketReadiness()
        defer { activity.finish() }
        let completed = CrossPlatformLock(initialState: false)
        let wait = Task {
            try await activity.wait(read: [], write: [], until: nil)
            completed.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!completed.withLock { $0 })
        activity.signal()
        try await wait.value
        let start = ContinuousClock.now
        try await activity.wait(read: [], write: [], until: start + .milliseconds(30))
        #expect(ContinuousClock.now >= start + .milliseconds(30))
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationAndFinishReleaseAnIdleWait() async throws {
        let cancelled = SocketReadiness()
        let wait = Task { try await cancelled.wait(read: [], write: [], until: nil) }
        wait.cancel()
        await #expect(throws: CancellationError.self) { try await wait.value }
        cancelled.finish()
        let finished = SocketReadiness()
        let closeWait = Task { try await finished.wait(read: [], write: [], until: nil) }
        finished.finish()
        try await closeWait.value
    }
}
