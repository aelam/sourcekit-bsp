// MARK: - Stream Utility

@preconcurrency import Foundation
import Logger

public enum StreamingFileHandleReader {
    public static func streamPipe(
        _ fileHandle: FileHandle,
        lineHandler: @escaping @Sendable (String) async -> Void
    ) async {
        var lineBuffer = Data()
        let bufferSize = 8192

        do {
            let dataStream = AsyncThrowingStream<Data, Error> { continuation in
                let source = DispatchSource.makeReadSource(fileDescriptor: fileHandle.fileDescriptor)

                source.setEventHandler {
                    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                    defer { buffer.deallocate() }

                    let bytesRead = read(fileHandle.fileDescriptor, buffer, bufferSize)
                    if bytesRead > 0 {
                        let data = Data(bytes: buffer, count: bytesRead)
                        continuation.yield(data)
                    } else if bytesRead == 0 {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: POSIXError(.EIO))
                    }
                }

                source.setCancelHandler {
                    continuation.finish()
                }

                continuation.onTermination = { _ in
                    source.cancel()
                }

                source.resume()
            }

            for try await data in dataStream {
                lineBuffer.append(data)

                while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
                    let lineData = lineBuffer.prefix(through: newlineIndex)
                    lineBuffer.removeFirst(lineData.count)

                    if let string = String(data: lineData, encoding: .utf8) {
                        await lineHandler(string.trimmingCharacters(in: .newlines))
                    }
                }
            }

            if !lineBuffer.isEmpty, let string = String(data: lineBuffer, encoding: .utf8) {
                let finalString = string.trimmingCharacters(in: .newlines)
                if !finalString.isEmpty {
                    await lineHandler(finalString)
                }
            }

        } catch {
            if !Task.isCancelled {
                logger.error("Error reading pipe: \(error)")
            }
        }
    }
}
