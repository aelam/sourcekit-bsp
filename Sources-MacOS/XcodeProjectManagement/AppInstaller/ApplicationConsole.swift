import Foundation
import Support

struct ApplicationOutput: Sendable, Equatable {
    enum Channel: String, Sendable { case stdout, stderr, console }
    let channel: Channel
    let text: String

    var runMessage: String {
        ApplicationLogText.forBuildLog(text, stripMirrorTimestamp: true)
    }
}

/// Owns the console process and drains both streams before reporting exit.
final class ApplicationConsole: Sendable {
    let output: ApplicationOutputBuffer
    private let process: Process
    private let completion: Task<Int32, Never>
    private let status: CrossPlatformLock<Int32?>

    var exitCode: Int32? {
        status.withLock { $0 }
    }

    init(
        executable: String = "/usr/bin/xcrun",
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        simulatorBundleID: String? = nil,
        output: ApplicationOutputBuffer = ApplicationOutputBuffer()
    ) throws {
        self.output = output
        let process = ProcessExecutor.createProcess(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment
        )
        self.process = process
        let status = CrossPlatformLock<Int32?>(initialState: nil)
        self.status = status
        let termination = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { process in
            status.withLock { $0 = process.terminationStatus }
            termination.continuation.yield(process.terminationStatus)
            termination.continuation.finish()
        }
        guard let outputPipe = process.standardOutput as? Pipe, let errorPipe = process.standardError as? Pipe else {
            throw XcodeRunError.failedToLaunchApp("Cannot open application console pipes")
        }
        try Task.checkCancellation()
        try process.run()
        let stdout = outputPipe.fileHandleForReading
        let stderr = errorPipe.fileHandleForReading
        completion = Task {
            await withTaskGroup(of: Void.self) { group in
                for (handle, channel) in [(stdout, ApplicationOutput.Channel.stdout), (stderr, .stderr)] {
                    group.addTask {
                        await ApplicationConsoleReader.stream(handle, text: { batch in
                            var text = batch
                            if channel == .stdout, let bundle = simulatorBundleID,
                               await output.simulatorPID == nil, text.hasPrefix(bundle + ": "),
                               let newline = text.firstIndex(of: "\n"),
                               let pid = SimulatorDebugLauncher.parsePID(from: String(text[..<newline])), pid > 0 {
                                await output.recordSimulatorPID(pid)
                                text = String(text[text.index(after: newline)...])
                            }
                            await output.append(.init(channel: channel, text: text))
                        }, overflow: { await output.reportOverflow() })
                    }
                }
            }
            try? stdout.close()
            try? stderr.close()
            await output.finish()
            for await code in termination.stream {
                return code
            }
            return 1
        }
    }

    func wait() async throws -> Int32 {
        let code = await withTaskCancellationHandler {
            await completion.value
        } onCancel: {
            Task { await self.stop(terminateApp: true) }
        }
        try Task.checkCancellation()
        return code
    }

    func stop(terminateApp: Bool) async {
        if process.isRunning {
            if terminateApp {
                // Console tools forward catchable signals to the application.
                process.interrupt()
                for _ in 0 ..< 20 where process.isRunning {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            // SIGKILL closes the helper without forwarding a signal on detach.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        _ = await completion.value
        await output.flush()
        await output.close()
    }

    func finishOutput() async {
        for _ in 0 ..< 20 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        await stop(terminateApp: false)
    }
}

extension XcodeLaunchSettings {
    var consoleEnvironment: [String: String] {
        var defaults = ["OS_ACTIVITY_MODE": "debug", "NSUnbufferedIO": "YES"]
        if environment["IDE_DISABLED_OS_ACTIVITY_DT_MODE"] == nil { defaults["OS_ACTIVITY_DT_MODE"] = "enable" }
        return defaults.merging(environment) { _, user in user }
    }
}
