import Darwin
import Foundation
import Logger
import Support

/// Bounds both queued pipe bytes and text that has no newline.
enum ApplicationConsoleReader {
    private struct Chunk: Sendable {
        let sequence: Int
        let data: Data
    }

    private struct ReadState: Sendable {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var sequence = 0
    }

    static func stream(
        _ handle: FileHandle,
        text: @escaping @Sendable (String) async -> Void,
        overflow: @escaping @Sendable () async -> Void
    ) async {
        let fd = dup(handle.fileDescriptor)
        guard fd >= 0 else {
            await overflow()
            return
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let state = CrossPlatformLock(initialState: ReadState())
        let stream = AsyncThrowingStream<Chunk, Error>(bufferingPolicy: .bufferingOldest(64)) { continuation in
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
                close(fd)
                continuation.finish(throwing: POSIXError(.EBADF))
                return
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd)
            source.setEventHandler {
                for _ in 0 ..< 16 {
                    let result = state.withLock { state -> (Chunk?, Int, Int32) in
                        let count = read(fd, &state.buffer, state.buffer.count)
                        guard count > 0 else { return (nil, count, errno) }
                        let chunk = Chunk(sequence: state.sequence, data: Data(state.buffer.prefix(count)))
                        state.sequence += 1
                        return (chunk, count, 0)
                    }
                    if let chunk = result.0 {
                        continuation.yield(chunk)
                    } else if result.1 == 0 {
                        continuation.finish()
                        return
                    } else if result.2 == EINTR {
                        continue
                    } else if result.2 == EAGAIN || result.2 == EWOULDBLOCK {
                        return
                    } else {
                        continuation.finish(throwing: POSIXError(POSIXErrorCode(rawValue: result.2) ?? .EIO))
                        return
                    }
                }
            }
            source.setCancelHandler {
                close(fd)
                continuation.finish()
            }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
        var expected = 0
        var decoder = ApplicationConsoleText()
        do {
            for try await chunk in stream {
                if chunk.sequence != expected {
                    decoder.discardPartialLine()
                    await overflow()
                }
                expected = chunk.sequence + 1
                decoder.append(chunk.data)
                while let batch = decoder.take() {
                    await text(batch)
                }
            }
            if state.withLock({ $0.sequence }) != expected {
                await overflow()
            } else if let final = decoder.finish() {
                await text(final)
            }
        } catch {
            if !Task.isCancelled {
                logger.error("Cannot read application console: \(error)")
                await overflow()
            }
        }
    }
}

struct ApplicationConsoleText {
    private var bytes = Data()
    private var skippingLine = false
    private let limit = 32768

    var bufferedBytes: Int {
        bytes.count
    }

    mutating func discardPartialLine() {
        bytes.removeAll(keepingCapacity: true)
        skippingLine = true
    }

    mutating func append(_ data: Data) {
        if skippingLine {
            guard let newline = data.firstIndex(of: 10) else { return }
            skippingLine = false
            bytes.append(data.suffix(from: data.index(after: newline)))
        } else {
            bytes.append(data)
        }
    }

    mutating func take() -> String? {
        let newline = bytes.lastIndex(of: 10)
        guard newline != nil || bytes.count >= limit else { return nil }
        let available = newline.map { bytes.distance(from: bytes.startIndex, to: $0) + 1 } ?? bytes.count
        var count = min(available, limit)
        let end = bytes.index(bytes.startIndex, offsetBy: count)
        var lead = bytes.index(before: end)
        while lead > bytes.startIndex, bytes[lead] & 0xC0 == 0x80 {
            lead -= 1
        }
        let first = bytes[lead]
        let width = first < 0xC0 ? 1 : first < 0xE0 ? 2 : first < 0xF0 ? 3 : 4
        if lead + width > end { count = lead - bytes.startIndex }
        if count > 0, bytes[bytes.startIndex + count - 1] == 13 { count -= 1 }
        guard count > 0 else { return nil }
        let result = String(decoding: bytes.prefix(count), as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        bytes.removeFirst(count)
        return result
    }

    mutating func finish() -> String? {
        guard !bytes.isEmpty else { return nil }
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
        bytes.removeAll()
        return text.isEmpty ? nil : text + "\n"
    }
}
