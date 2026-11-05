import Foundation
import SwiftyBeaver

/// The inherited serial queue owns file writes and rotation.
final class RotatingFileDestination: BaseDestination {
    private let url: URL
    private let maxBytes: Int
    private let fileCount: Int
    private let failureOutput: FileHandle
    private var reportedFailure = false

    init(url: URL, maxBytes: Int = 5 * 1024 * 1024, fileCount: Int = 3, failureOutput: FileHandle = .standardError) {
        precondition(maxBytes > 0 && fileCount > 0)
        self.url = url
        self.maxBytes = maxBytes
        self.fileCount = fileCount
        self.failureOutput = failureOutput
        super.init()
        format = "$Dyyyy-MM-dd HH:mm:ss.SSS$d $L pid=\(ProcessInfo.processInfo.processIdentifier) $N.$F:$l $M"
    }

    override func send(
        _ level: SwiftyBeaver.Level,
        msg: String,
        thread: String,
        file: String,
        function: String,
        line: Int,
        context: Any? = nil
    ) -> String? {
        let prefix = msg.prefix(4096)
        let bounded = String(prefix) + (prefix.endIndex < msg.endIndex ? " [truncated]" : "")
        let singleLine = bounded.replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        guard let formatted = super.send(
            level,
            msg: singleLine,
            thread: thread,
            file: file,
            function: function,
            line: line,
            context: context
        ) else { return nil }
        do {
            try append(Data((formatted + "\n").utf8))
        } catch {
            if !reportedFailure {
                reportedFailure = true
                let message = "sourcekit-bsp: Cannot write log at \(url.path): \(error.localizedDescription)\n"
                try? failureOutput.write(contentsOf: Data(message.utf8))
            }
        }
        return formatted
    }

    private func append(_ data: Data) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: url.path) {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            if size + data.count > maxBytes { try rotate() }
        }
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func rotate() throws {
        let manager = FileManager.default
        for index in stride(from: fileCount - 1, through: 0, by: -1) {
            let source = rotatedURL(index)
            guard manager.fileExists(atPath: source.path) else { continue }
            if index == fileCount - 1 {
                try manager.removeItem(at: source)
            } else {
                try manager.moveItem(at: source, to: rotatedURL(index + 1))
            }
        }
    }

    private func rotatedURL(_ index: Int) -> URL {
        index == 0 ? url : url.deletingPathExtension().appendingPathExtension("\(index).log")
    }
}
