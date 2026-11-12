import Foundation
import Support

struct ApplicationOutput: Sendable, Equatable {
    enum Channel: String, Sendable { case stdout, stderr, console }
    let channel: Channel
    let text: String

    var runMessage: String {
        ApplicationLogText.forBuildLog(text, standardError: channel == .stderr)
    }
}

/// Retains startup output until the debug client completes initialization.
actor ApplicationOutputBuffer {
    typealias Handler = @Sendable (ApplicationOutput) async -> Void
    private var handler: Handler?
    private var pending: ArraySlice<ApplicationOutput> = []
    private var size = 0
    private var dropped = false
    private var closed = false
    private var drainTask: Task<Void, Never>?
    private(set) var simulatorPID: Int?
    private(set) var recentText = ""

    func append(_ output: ApplicationOutput) {
        guard !closed else { return }
        recentText = String((recentText + output.text).suffix(8192))
        if size + output.text.utf8.count <= 256 * 1024 {
            pending.append(output)
            size += output.text.utf8.count
        } else {
            dropped = true
        }
        startDraining()
    }

    func recordSimulatorPID(_ pid: Int) {
        simulatorPID = pid
    }

    func connect(_ handler: @escaping Handler) {
        guard !closed else { return }
        self.handler = handler
        startDraining()
    }

    private func startDraining() {
        guard handler != nil, drainTask == nil, !pending.isEmpty || dropped else { return }
        drainTask = Task { await drain() }
    }

    private func drain() async {
        while !closed, let handler {
            if !pending.isEmpty {
                let output = pending.removeFirst()
                size -= output.text.utf8.count
                if pending.isEmpty { pending = [] }
                await handler(output)
            } else if dropped {
                dropped = false
                await handler(.init(channel: .console, text: "Some application output exceeded the console buffer.\n"))
            } else {
                break
            }
        }
        drainTask = nil
    }

    func close() {
        closed = true
        handler = nil
        pending = []
        size = 0
        drainTask?.cancel()
        drainTask = nil
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
                        await StreamingFileHandleReader.streamPipe(handle) { line in
                            if channel == .stdout, let bundle = simulatorBundleID,
                               await output.simulatorPID == nil, line.hasPrefix(bundle + ": "),
                               let pid = SimulatorDebugLauncher.parsePID(from: line), pid > 0 {
                                await output.recordSimulatorPID(pid)
                            } else {
                                await output.append(.init(channel: channel, text: line + "\n"))
                            }
                        }
                    }
                }
            }
            try? stdout.close()
            try? stderr.close()
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
