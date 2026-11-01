import Foundation
import JSONRPCConnection
import Testing
@testable import BSPServer

actor MemoryTransport: JSONRPCServerTransport {
    nonisolated let messageStream: AsyncStream<JSONRPCMessage>
    nonisolated let errorStream: AsyncStream<JSONRPCTransportError>
    nonisolated let output: AsyncStream<Data>
    private let messages: AsyncStream<JSONRPCMessage>.Continuation
    private let errors: AsyncStream<JSONRPCTransportError>.Continuation
    private let outputContinuation: AsyncStream<Data>.Continuation
    private(set) var sent: [Data] = []

    init() {
        (messageStream, messages) = AsyncStream.makeStream()
        (errorStream, errors) = AsyncStream.makeStream()
        (output, outputContinuation) = AsyncStream.makeStream()
    }

    func listen() async throws {}
    func close() async {
        messages.finish()
        errors.finish()
    }

    func receive(_ json: String) throws {
        let data = Data(json.utf8)
        try messages.yield(JSONRPCMessage(
            request: JSONDecoder().decode(JSONRPCRequest.self, from: data),
            rawData: data
        ))
    }

    func send(response: ResponseType) async throws {
        let data = try JSONEncoder().encode(response)
        sent.append(data)
        outputContinuation.yield(data)
    }

    func send(notification: ServerJSONRPCNotification<some Codable & Sendable>) async throws {
        let data = try JSONEncoder().encode(notification)
        sent.append(data)
        outputContinuation.yield(data)
    }
}

private actor LifecycleHandler: MessageHandler {
    nonisolated let events: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let gate: AsyncStream<Void>
    private let release: AsyncStream<Void>.Continuation
    private var value = 0
    private(set) var cancelled = false

    init() {
        (events, continuation) = AsyncStream.makeStream()
        (gate, release) = AsyncStream.makeStream()
    }

    func request(block: Bool) async -> Int {
        if block {
            continuation.yield("request")
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancelled = true
            }
        }
        return value
    }

    func update() async {
        continuation.yield("notification")
        for await _ in gate {}
        value = 42
    }

    func releaseNotification() {
        release.finish()
    }
}

private struct LifecycleRequest: RequestType {
    struct Params: Codable { let block: Bool }
    struct Response: ResponseType {
        var jsonrpc = "2.0"
        let id: RequestID
        let result: Int
    }

    let params: Params
    static func method() -> String {
        "test/read"
    }

    func handle(handler: MessageHandler, id: RequestID) async -> ResponseType? {
        guard let handler = handler as? LifecycleHandler else { return nil }
        return await Response(id: id, result: handler.request(block: params.block))
    }
}

private struct LifecycleNotification: NotificationType {
    static func method() -> String {
        "test/update"
    }

    func handle(handler: MessageHandler) async throws {
        await (handler as? LifecycleHandler)?.update()
    }
}

struct ConnectionLifecycleTests {
    @Test(.timeLimit(.minutes(1)))
    func cancellationBypassesNotificationsAndReadsWaitForUpdates() async throws {
        let transport = MemoryTransport()
        let handler = LifecycleHandler()
        let connection = JSONRPCConnection(
            transport: transport,
            messageRegistry: MessageRegistry(
                requests: [LifecycleRequest.self],
                notifications: [LifecycleNotification.self]
            ),
            messageHandler: handler
        )
        try await connection.listen()
        var events = handler.events.makeAsyncIterator()
        var responses = transport.output.makeAsyncIterator()
        try await transport.receive(#"{"jsonrpc":"2.0","id":"build","method":"test/read","params":{"block":true}}"#)
        #expect(await events.next() == "request")
        try await transport.receive(#"{"jsonrpc":"2.0","method":"test/update"}"#)
        #expect(await events.next() == "notification")
        try await transport.receive(#"{"jsonrpc":"2.0","id":2,"method":"test/read","params":{"block":false}}"#)
        try await transport.receive(#"{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":"build"}}"#)
        let cancelled = try #require(await responses.next())
        let error = try #require(JSONSerialization.jsonObject(with: cancelled) as? [String: Any])
        #expect(error["id"] as? String == "build")
        #expect((error["error"] as? [String: Any])?["code"] as? Int == -32800)
        #expect(await handler.cancelled)
        await handler.releaseNotification()
        let read = try #require(await responses.next())
        let result = try #require(JSONSerialization.jsonObject(with: read) as? [String: Any])
        #expect(result["id"] as? Int == 2)
        #expect(result["result"] as? Int == 42)
        #expect(await transport.sent.count == 2)
        await connection.close()
    }
}
