import Foundation
import Support
import Testing
@testable import XcodeProjectManagement

struct ApplicationConsoleTests {
    @Test
    func runMessageRemovesAppleMirrorTimestampAndFinalNewline() {
        let original = "2026-11-12 16:51:50.715363+0900 LINE-Dev[23851:967083] [main] Invalid superset key name\n"
        let output = ApplicationOutput(channel: .stderr, text: original)
        #expect(output.runMessage == "LINE-Dev[23851:967083] [main] Invalid superset key name")
        #expect(output.text == original)
        #expect(ApplicationOutput(channel: .stdout, text: original).runMessage == String(original.dropLast()))
        #expect(ApplicationOutput(channel: .stderr, text: "2026-11-12 16:51:50 user message\n").runMessage
            == "2026-11-12 16:51:50 user message")
        #expect(ApplicationOutput(channel: .stderr, text: "plain stderr\n").runMessage == "plain stderr")
        #expect(ApplicationOutput(channel: .stdout, text: "first\nsecond\n").runMessage == "first\nsecond")
        #expect(ApplicationOutput(channel: .stderr, text: "no final newline").runMessage == "no final newline")
    }

    @Test
    func streamsBothChannelsBeforeExitAndDrainsTheFinalLine() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let console = try ApplicationConsole(
            executable: "/bin/sh", arguments: ["-c", """
            printf 'ready\\n'
            printf 'error\\n' >&2
            while [ ! -f release ]; do sleep 0.05; done
            printf 'last line'
            """], workingDirectory: directory
        )
        let received = CrossPlatformLock(initialState: [ApplicationOutput]())
        await console.output.connect { output in
            let ready = received.withLock { values in
                values.append(output)
                return values.contains { $0.text == "ready\n" } && values.contains { $0.text == "error\n" }
            }
            if ready { FileManager.default.createFile(
                atPath: directory.appendingPathComponent("release").path,
                contents: nil
            ) }
        }
        let code = try await withDeadline(console) { try await console.wait() }
        #expect(code == 0)
        let output = received.withLock { $0 }
        #expect(output.contains(.init(channel: .stdout, text: "ready\n")))
        #expect(output.contains(.init(channel: .stderr, text: "error\n")))
        #expect(output.last == .init(channel: .stdout, text: "last line\n"))
    }

    @Test
    func preservesOutputUntilAClientConnects() async throws {
        let console = try ApplicationConsole(executable: "/bin/sh", arguments: ["-c", "printf 'early\\n'"])
        #expect(try await console.wait() == 0)
        let received = CrossPlatformLock(initialState: "")
        await console.output.connect { output in received.withLock { $0 += output.text } }
        #expect(received.withLock { $0 } == "early\n")
    }

    @Test
    func cancellationStopsTheConsoleAndWaitsForExit() async throws {
        let console = try ApplicationConsole(executable: "/bin/sleep", arguments: ["30"])
        let task = Task { try await console.wait() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await withDeadline(console) { try await task.value } }
        #expect(console.exitCode != nil)
    }

    @Test
    func startupBufferReportsTruncationAndContinuesStreaming() async {
        let buffer = ApplicationOutputBuffer()
        await buffer.append(.init(channel: .stdout, text: "first\n"))
        await buffer.append(.init(channel: .stdout, text: String(repeating: "x", count: 256 * 1024)))
        let received = CrossPlatformLock(initialState: [ApplicationOutput]())
        await buffer.connect { output in received.withLock { $0.append(output) } }
        await buffer.append(.init(channel: .stderr, text: "live\n"))
        let output = received.withLock { $0 }
        #expect(output.count == 3)
        #expect(output[0].text == "first\n")
        #expect(output[1].channel == .console)
        #expect(output[2].text == "live\n")
    }

    @Test
    func consoleDefaultsPreserveUserLoggingSettings() {
        let defaults = XcodeLaunchSettings().consoleEnvironment
        #expect(defaults["OS_ACTIVITY_DT_MODE"] == "enable")
        #expect(defaults["OS_ACTIVITY_MODE"] == "debug")
        let settings = XcodeLaunchSettings(environment: [
            "IDE_DISABLED_OS_ACTIVITY_DT_MODE": "1", "OS_ACTIVITY_MODE": "disable", "NSUnbufferedIO": "NO"
        ])
        #expect(settings.consoleEnvironment["OS_ACTIVITY_DT_MODE"] == nil)
        #expect(settings.consoleEnvironment["OS_ACTIVITY_MODE"] == "disable")
        #expect(settings.consoleEnvironment["NSUnbufferedIO"] == "NO")
    }

    private func withDeadline<T: Sendable>(
        _ console: ApplicationConsole, operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                await console.stop(terminateApp: false)
                throw DAPRelayError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
