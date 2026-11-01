import Foundation
import Logger
import Support

// MARK: - Process Output Handler Protocol

public protocol ProcessOutputHandler: Sendable {
    func handleProcess(output: FileHandle, error: FileHandle) async
    func handleCompletion(_ exitCode: Int32) async
}

// MARK: - Default Output Handler

struct DefaultOutputHandler: ProcessOutputHandler {
    func handleProcess(output: FileHandle, error: FileHandle) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await StreamingFileHandleReader.streamPipe(output) { line in
                    logger.info("Build output: \(line)")
                }
            }

            group.addTask {
                await StreamingFileHandleReader.streamPipe(error) { line in
                    logger.error("Build error: \(line)")
                }
            }
        }
    }

    func handleCompletion(_ exitCode: Int32) async {
        logger.info("Process completed with exit code: \(exitCode)")
    }
}

// MARK: - Closure Output Handler

/// Forwards every build output/error line to a caller-supplied closure so the
/// BSP layer can stream build output to the client.
public struct ClosureOutputHandler: ProcessOutputHandler {
    private let onLine: @Sendable (String) -> Void
    private let onExit: @Sendable (Int32) -> Void

    public init(
        onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void = { _ in }
    ) {
        self.onLine = onLine
        self.onExit = onExit
    }

    public func handleProcess(output: FileHandle, error: FileHandle) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await StreamingFileHandleReader.streamPipe(output) { self.onLine($0) }
            }
            group.addTask {
                await StreamingFileHandleReader.streamPipe(error) { self.onLine($0) }
            }
        }
    }

    public func handleCompletion(_ exitCode: Int32) async {
        onExit(exitCode)
    }
}
