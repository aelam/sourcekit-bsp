//
//  BSPTestHarness.swift
//  sourcekit-bsp
//
//  Drives a real `BSPServerService` over an in-memory transport so tests can
//  exercise full JSON-RPC message sequences (request → routing → handler →
//  response / notification) without stdio or a child process.
//
//  Usage:
//
//      let h = await BSPTestHarness.make()
//      let response = try await h.request(method: "build/shutdown", id: 1)
//      let json = try h.json(response)
//      XCTAssertEqual(json["id"] as? Int, 1)
//      await h.shutdown()
//
//  For a notification the server sends back, await it by method:
//
//      let note = await h.nextNotification(method: "window/showMessage")
//
//  To test request sequences that need a loaded project, point the working
//  directory at a demo project and send `build/initialize` first — see the
//  example tests for the pattern.
//

import Foundation
@testable import BSPServer
@testable import JSONRPCConnection

/// Collects the server's outgoing messages and lets tests await them by
/// request id (responses) or method name (notifications).
private actor ResponseCollector {
    private var responses: [JSONRPCID: Data] = [:]
    private var responseWaiters: [JSONRPCID: [CheckedContinuation<Data, Never>]] = [:]

    private var notifications: [(method: String, data: Data)] = []
    private var notificationWaiters: [(method: String, cont: CheckedContinuation<Data, Never>)] = []

    func record(_ message: OutgoingMessage) {
        switch message {
        case let .response(id, data):
            guard let id else { return }
            if let waiters = responseWaiters[id], !waiters.isEmpty {
                responseWaiters[id] = nil
                for waiter in waiters {
                    waiter.resume(returning: data)
                }
            } else {
                responses[id] = data
            }
        case let .notification(method, data):
            if let index = notificationWaiters.firstIndex(where: { $0.method == method }) {
                let waiter = notificationWaiters.remove(at: index)
                waiter.cont.resume(returning: data)
            } else {
                notifications.append((method, data))
            }
        }
    }

    func response(id: JSONRPCID) async -> Data {
        if let data = responses.removeValue(forKey: id) { return data }
        return await withCheckedContinuation { cont in
            responseWaiters[id, default: []].append(cont)
        }
    }

    func notification(method: String) async -> Data {
        if let index = notifications.firstIndex(where: { $0.method == method }) {
            return notifications.remove(at: index).data
        }
        return await withCheckedContinuation { cont in
            notificationWaiters.append((method, cont))
        }
    }
}

final class BSPTestHarness: @unchecked Sendable {
    let transport: InMemoryTransport
    let service: BSPServerService

    private let collector = ResponseCollector()
    private var drainTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?

    private init(transport: InMemoryTransport, service: BSPServerService) {
        self.transport = transport
        self.service = service
    }

    /// Build a harness wired to a real `BSPServerService` + `bspRegistry` +
    /// `BSPMessageHandler`, exactly like `createStdioService` but with the
    /// in-memory transport. Starts the service in the background.
    static func make() async -> BSPTestHarness {
        let transport = InMemoryTransport()
        let handler = BSPMessageHandler()
        let connection = JSONRPCConnection(
            transport: transport,
            messageRegistry: bspRegistry,
            messageHandler: handler
        )
        let factory = await ProjectManagerProviderRegistry.createFactory()
        let service = BSPServerService(
            projectManagerProvider: factory,
            jsonrpcConnection: connection
        )
        handler.setBSPServerService(service)

        let harness = BSPTestHarness(transport: transport, service: service)
        harness.start()
        return harness
    }

    private func start() {
        drainTask = Task { [transport, collector] in
            for await message in transport.outgoingStream {
                await collector.record(message)
            }
        }
        runTask = Task { [service] in
            try? await service.start()
        }
    }

    // MARK: - Driving the server

    /// Send a request and await the correlated response (or error response).
    /// Fails the calling test if no response arrives within `timeout`.
    @discardableResult
    func request(
        method: String,
        id: Int,
        params: String = "{}",
        timeout: TimeInterval = 5
    ) async throws -> Data {
        try inject(rawJSON: """
        {"jsonrpc":"2.0","id":\(id),"method":"\(method)","params":\(params)}
        """)
        guard let data = await withTimeout(timeout, { [collector] in await collector.response(id: .int(id)) }) else {
            throw HarnessError.timedOut("response for \(method) id=\(id)")
        }
        return data
    }

    /// Send a notification (no response expected).
    func notify(method: String, params: String = "{}") throws {
        try inject(rawJSON: """
        {"jsonrpc":"2.0","method":"\(method)","params":\(params)}
        """)
    }

    /// Inject a fully-formed raw JSON-RPC message.
    func inject(rawJSON: String) throws {
        let data = Data(rawJSON.utf8)
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        transport.inject(JSONRPCMessage(request: request, rawData: data))
    }

    /// Await the next server→client notification with the given method.
    /// Returns nil on timeout.
    func nextNotification(method: String, timeout: TimeInterval = 2) async -> Data? {
        await withTimeout(timeout) { [collector] in await collector.notification(method: method) }
    }

    // MARK: - Teardown

    func shutdown() async {
        await service.stop()
        transport.close()
        drainTask?.cancel()
        runTask?.cancel()
    }

    // MARK: - Assertion helpers

    /// Decode a captured message into a `[String: Any]` for easy assertions.
    func json(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HarnessError.notAnObject
        }
        return object
    }

    enum HarnessError: Error {
        case timedOut(String)
        case notAnObject
    }
}

/// Race an async operation against a timeout. Returns nil if the timeout wins.
private func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    _ operation: @escaping @Sendable () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
