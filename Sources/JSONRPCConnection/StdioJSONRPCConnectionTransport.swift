//
//  StdioJSONRPCConnectionTransport.swift
//
//  Copyright © 2024 Wang Lun.
//

import Foundation
import Logger
#if os(Linux)
import Glibc
#endif

/// Stream-based stdio transport for JSON-RPC communication
public final class StdioJSONRPCConnectionTransport: JSONRPCServerTransport, @unchecked Sendable {
    private let input: FileHandle
    private let output: FileHandle

    /// Serial queue for all stdout writes. Responses are produced concurrently
    /// (JSONRPCConnection spawns a task per request), so without serialization
    /// two messages' `write(header)` / `write(data)` calls interleave on the
    /// shared stdout fd and corrupt the JSON-RPC framing — which makes the
    /// client (SourceKit-LSP) read a mis-framed message and crash. A serial
    /// queue guarantees each message is written atomically and in order.
    private let writeQueue = DispatchQueue(label: "com.sourcekit-bsp.jsonrpc.stdout")

    private let messageContinuation: AsyncStream<JSONRPCMessage>.Continuation
    private let errorContinuation: AsyncStream<JSONRPCTransportError>.Continuation
    private let inputChunks: AsyncStream<Data>
    private let inputContinuation: AsyncStream<Data>.Continuation

    public let messageStream: AsyncStream<JSONRPCMessage>
    public let errorStream: AsyncStream<JSONRPCTransportError>

    private let stateLock = NSLock()
    private var _isListening = false
    private var isClosed = false
    private var closeContinuation: CheckedContinuation<Void, Error>?
    private var inputTask: Task<Void, Never>?

    private var isListening: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isListening
    }

    public init(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        self.input = input
        self.output = output
        (messageStream, messageContinuation) = AsyncStream.makeStream()
        (errorStream, errorContinuation) = AsyncStream.makeStream()
        (inputChunks, inputContinuation) = AsyncStream.makeStream()
    }

    public func listen() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                stateLock.lock()
                guard !_isListening, !isClosed else {
                    let error: JSONRPCTransportError = isClosed ? .transportClosed : .listenFailed
                    stateLock.unlock()
                    continuation.resume(throwing: error)
                    return
                }
                guard !Task.isCancelled else {
                    stateLock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                _isListening = true
                closeContinuation = continuation
                inputTask = Task { [weak self] in
                    await self?.readMessages()
                }
                input.readabilityHandler = { [weak self] handle in
                    self?.handleIncomingData(from: handle)
                }
                stateLock.unlock()
            }
        } onCancel: {
            self.close()
        }
    }

    public func close() {
        stateLock.lock()
        guard !isClosed else {
            stateLock.unlock()
            return
        }
        isClosed = true
        _isListening = false
        let continuation = closeContinuation
        closeContinuation = nil
        let task = inputTask
        inputTask = nil
        stateLock.unlock()

        input.readabilityHandler = nil
        inputContinuation.finish()
        task?.cancel()
        messageContinuation.finish()
        errorContinuation.finish()
        continuation?.resume()
    }

    private func readMessages() async {
        var parser = JSONRPCParser()
        for await chunk in inputChunks {
            guard !Task.isCancelled else { return }
            for result in parser.feed(chunk: chunk) {
                switch result {
                case let .success(message):
                    messageContinuation.yield(message)
                case let .failure(error):
                    errorContinuation.yield(error)
                    logger.error("Invalid JSON-RPC input; closing connection: \(error)")
                    close()
                    return
                }
            }
        }
        guard !Task.isCancelled else { return }
        if let error = parser.finish() { errorContinuation.yield(error) }
        close()
    }

    public func send(response: ResponseType) async throws {
        try await sendMessage(response)
    }

    public func send(notification: ServerJSONRPCNotification<some Codable & Sendable>) async throws {
        try await sendMessage(notification)
    }

    private func sendMessage(_ message: some Encodable) async throws {
        guard isListening else {
            throw JSONRPCTransportError.transportClosed
        }

        let data = try JSONEncoder().encode(message)
        let header = "Content-Length:\(data.count)\r\n\r\n"
        let headerData = header.data(using: .utf8)!

        // Perform write operations with timeout to prevent hanging
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Add timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                throw JSONRPCTransportError.timeout
            }

            // Add write task
            group.addTask {
                // Write operations with timeout protection
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    // Serial queue: header + data + flush for one message are
                    // written atomically relative to other messages, so the
                    // JSON-RPC framing on stdout is never interleaved.
                    self.writeQueue.async {
                        self.output.write(headerData)
                        self.output.write(data)
                        // Try to flush the output
                        fsync(self.output.fileDescriptor)
                        continuation.resume()
                    }
                }
            }

            // Wait for the first task to complete and cancel the others
            try await group.next()
            group.cancelAll()
        }
    }

    private func handleIncomingData(from fileHandle: FileHandle) {
        repeat {
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                inputContinuation.finish()
                return
            }
            // One consumer preserves byte order across separate header and body writes.
            inputContinuation.yield(data)
        } while hasInputHangup(fileHandle)
    }

    private func hasInputHangup(_ fileHandle: FileHandle) -> Bool {
        #if os(Linux)
        // Linux may omit the EOF callback after delivering the last buffered bytes.
        // POLLHUP means all writers closed, so draining the pipe cannot block.
        var descriptor = pollfd(fd: fileHandle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, 0) > 0 && descriptor.revents & Int16(POLLHUP) != 0
        #else
        return false
        #endif
    }
}
