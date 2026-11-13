import Foundation
import JSONRPCConnection
import SourceKitBSPProtocol

actor BuildOutputReporter {
    private let manager: BSPTaskManager
    private let task: BSPTask
    private var parser: XcodeBuildOutputParser
    private var rawLog: FileHandle?
    private var rawURL: URL?
    private var isFinished = false

    init(manager: BSPTaskManager, task: BSPTask, context: BuildOutputContext) {
        self.manager = manager
        self.task = task
        self.parser = XcodeBuildOutputParser(context: context)
    }

    func start(context: BuildOutputContext) async {
        await manager.diagnostics.begin(
            task: task,
            targets: context.affectedTargets,
            service: manager.notificationService
        )
        do {
            try FileManager.default.createDirectory(at: context.logDirectory, withIntermediateDirectories: true)
            let url = context.logDirectory.appendingPathComponent("\(UUID().uuidString).log")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            rawLog = try FileHandle(forWritingTo: url)
            rawURL = url
            await log("Raw build log: \(url.path)", type: 3)
        } catch {
            await log("Cannot save the raw build log: \(error.localizedDescription). Streaming all output.", type: 2)
        }
        try? await manager.updateTaskProgress(taskId: task.taskId, progress: nil, message: task.currentMessage)
    }

    func consume(_ lines: [String]) async {
        guard !lines.isEmpty else { return }
        if let rawLog {
            do {
                try rawLog.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
            } catch {
                try? rawLog.close()
                self.rawLog = nil
                await log(
                    "Cannot write the raw build log: \(error.localizedDescription). Streaming all output.",
                    type: 2
                )
            }
        }
        var messages: [(Int, String)] = []
        var diagnostics: [BuildOutputDiagnostic] = []
        var progress: String?
        for line in lines {
            let parsed = parser.parse(line)
            if let diagnostic = parsed.diagnostic { diagnostics.append(diagnostic) }
            if let stage = parsed.progress { progress = stage }
            if let message = rawLog == nil ? line : parsed.message {
                if messages.last?.0 == parsed.type {
                    messages[messages.count - 1].1 += "\n" + message
                } else {
                    messages.append((parsed.type, message))
                }
            }
        }
        for (type, message) in messages {
            await log(message, type: type)
        }
        await manager.diagnostics.publish(diagnostics, task: task, service: manager.notificationService)
        if let progress {
            try? await manager.updateTaskProgress(
                taskId: task.taskId,
                progress: Double(parser.steps),
                unit: "build steps",
                message: progress
            )
        }
    }

    func finish() async {
        guard !isFinished else { return }
        isFinished = true
        try? rawLog?.close()
        rawLog = nil
        await manager.diagnostics.end(taskId: task.taskId)
        if let rawURL { await log("Raw build log: \(rawURL.path)", type: 3) }
    }

    private func log(_ message: String, type: Int) async {
        try? await manager.notificationService?.sendNotification(ServerJSONRPCNotification(
            method: "build/logMessage",
            params: BuildLogMessageParams(type: type, originId: task.originId, message: message)
        ))
    }
}
