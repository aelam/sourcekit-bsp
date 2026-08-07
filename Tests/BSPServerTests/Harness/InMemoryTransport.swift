//
//  InMemoryTransport.swift
//  sourcekit-bsp
//
//  An in-memory JSONRPCServerTransport for protocol-level testing.
//
//  Instead of stdio, requests are injected directly into `messageStream` and
//  every response / notification the server emits is captured on
//  `outgoingStream`. This lets tests drive full request→handler→response
//  sequences without spawning a process or touching file handles.
//

import Foundation
@testable import JSONRPCConnection

/// A message the server sent back to the "client".
enum OutgoingMessage {
    /// A response to a request, keyed by the originating request id.
    case response(id: JSONRPCID?, data: Data)
    /// A server-initiated notification (no id), keyed by method.
    case notification(method: String, data: Data)
}

/// In-memory transport. Mirrors `StdioJSONRPCConnectionTransport` but keeps
/// everything in-process. Thread-safety is provided by a lock, matching the
/// stdio implementation's `@unchecked Sendable` approach.
final class InMemoryTransport: JSONRPCServerTransport, @unchecked Sendable {
    let messageStream: AsyncStream<JSONRPCMessage>
    let errorStream: AsyncStream<JSONRPCTransportError>

    /// Everything the server sends back. Drained by the test harness.
    let outgoingStream: AsyncStream<OutgoingMessage>

    private let messageContinuation: AsyncStream<JSONRPCMessage>.Continuation
    private let errorContinuation: AsyncStream<JSONRPCTransportError>.Continuation
    private let outgoingContinuation: AsyncStream<OutgoingMessage>.Continuation

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private let lock = NSLock()
    private var isListening = false
    private var closeContinuation: CheckedContinuation<Void, Never>?

    init() {
        (messageStream, messageContinuation) = AsyncStream.makeStream(of: JSONRPCMessage.self)
        (errorStream, errorContinuation) = AsyncStream.makeStream(of: JSONRPCTransportError.self)
        (outgoingStream, outgoingContinuation) = AsyncStream.makeStream(of: OutgoingMessage.self)
    }

    // MARK: - Test-facing injection

    /// Feed a client→server message into the pipeline. AsyncStream buffers
    /// (unbounded), so injecting before `listen()` has fully started is safe.
    func inject(_ message: JSONRPCMessage) {
        messageContinuation.yield(message)
    }

    func injectError(_ error: JSONRPCTransportError) {
        errorContinuation.yield(error)
    }

    // MARK: - JSONRPCServerTransport

    func listen() async throws {
        try beginListening()

        // Stay alive until `close()`, mirroring the stdio transport.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            storeCloseContinuation(cont)
        }
    }

    /// Synchronous lock helpers so locking never happens directly in an async
    /// context (NSLock is unavailable from async contexts).
    private func beginListening() throws {
        lock.lock()
        defer { lock.unlock() }
        if isListening {
            throw JSONRPCTransportError.listenFailed
        }
        isListening = true
    }

    private func storeCloseContinuation(_ cont: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        closeContinuation = cont
    }

    func close() {
        lock.lock()
        guard isListening else {
            lock.unlock()
            return
        }
        isListening = false
        let cont = closeContinuation
        closeContinuation = nil
        lock.unlock()

        messageContinuation.finish()
        errorContinuation.finish()
        outgoingContinuation.finish()
        cont?.resume()
    }

    func send(response: ResponseType) async throws {
        let data = try encoder.encode(response)
        let id = (try? JSONDecoder().decode(IDCarrier.self, from: data))?.id
        outgoingContinuation.yield(.response(id: id, data: data))
    }

    func send(notification: ServerJSONRPCNotification<some Codable & Sendable>) async throws {
        let data = try encoder.encode(notification)
        let method = (try? JSONDecoder().decode(MethodCarrier.self, from: data))?.method ?? ""
        outgoingContinuation.yield(.notification(method: method, data: data))
    }

    // MARK: - Decoding helpers

    private struct IDCarrier: Codable { let id: JSONRPCID? }
    private struct MethodCarrier: Codable { let method: String }
}
