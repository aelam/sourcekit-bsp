import BuildServerProtocol
import Foundation
import Support
import Testing
@testable import BSPServer
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// Allow for scheduling delays while other suites build fixture projects in CI.
private let deferredTestTimeout: Duration = .seconds(30)

private enum DeferredTestError: Error {
    case timedOut(String)
}

@MainActor
struct DeferredDAPSessionTests {
    @Test
    func bufferedResponsesSurviveExpiredWait() async throws {
        let relay = DeferredDAPSession { _, _ in
            Issue.record("Initialize must not prepare a backend")
            throw CancellationError()
        }
        let client = try await DeferredTestClient(uri: relay.start())
        do {
            try await client.send(request(1, "initialize"))
            try await client.send(request(2, "initialize"))
            #expect(try await object(client.response(2))["success"] as? Bool == false)
            // Response 1 arrived before response 2 and must already be buffered.
            #expect(try await object(client.response(1, timeout: .zero))["success"] as? Bool == true)
        } catch {
            await client.close()
            await relay.stop()
            throw error
        }
        await client.close()
        await relay.stop()
    }

    @Test(arguments: ["stdout", "stderr", "console"])
    func forwardsApplicationOutputToDebugClientUnchanged(category: String) async throws {
        let original = "2026-11-12 16:51:50.715363+0900 LINE-Dev[23851:967083] [main] Message\n"
        let native = try DeferredFakeAdapter(emittedOutput: (category: category, text: original))
        let relay = DeferredDAPSession { _, _ in
            await DebugSessionBackend(connection: .init(uri: native.start(), request: .launch, program: "/tmp/Hello")) {
                await native.stop()
            }
        }
        let client = try await DeferredTestClient(uri: relay.start())
        try await client.send(request(1, "initialize"))
        _ = try await client.response(1)
        try await client.send(request(2, "launch"))
        _ = try await client.response(2)
        let output = try await object(client.event("output"))
        let body = try #require(output["body"] as? [String: Any])
        #expect(body["category"] as? String == category)
        #expect(body["output"] as? String == original)
        try await client.send(request(3, "disconnect"))
        _ = try await client.response(3)
        await relay.stop()
        await client.close()
    }

    @Test(arguments: [Duration.zero, .seconds(2)])
    func initializeDefersPreparationAndLaunchKeepsItsResponseCommand(disconnectTimeout: Duration) async throws {
        let native = try DeferredFakeAdapter(holdStart: true)
        let state = CrossPlatformLock(initialState: (prepares: 0, stops: 0))
        let relay = DeferredDAPSession(disconnectTimeout: disconnectTimeout) { request, pid in
            #expect(request == .launch)
            #expect(pid == nil)
            state.withLock { $0.prepares += 1 }
            let uri = await native.start()
            return DebugSessionBackend(connection: .init(uri: uri, request: .attach, pid: 42)) {
                state.withLock { $0.stops += 1 }
                await native.stop()
            }
        }
        let client = try await DeferredTestClient(uri: relay.start())
        try await client.send(request(40, "initialize", ["adapterID": "lldb", "pathFormat": "path"]))
        let initial = try await object(client.response(40))
        #expect(initial["command"] as? String == "initialize")
        #expect((initial["body"] as? [String: Any])?["supportsFunctionBreakpoints"] == nil)
        #expect(state.withLock { $0.prepares } == 0)
        #expect(await native.messages.isEmpty)
        try await client.send(request(71, "launch", ["stopOnEntry": true]))
        let capabilityEvent = try await object(client.event("capabilities"))
        let capabilityBody = try #require(capabilityEvent["body"] as? [String: Any])
        let capabilities = try #require(capabilityBody["capabilities"] as? [String: Any])
        #expect(capabilities["supportsFunctionBreakpoints"] as? Bool == true)
        let initializedEvent = try await object(client.event("initialized"))
        #expect(try #require(capabilityEvent["seq"] as? Int) < #require(initializedEvent["seq"] as? Int))
        try await client.send(request(80, "setBreakpoints", ["source": ["path": "/tmp/Hello.swift"]]))
        #expect(try await object(client.response(80))["command"] as? String == "setBreakpoints")
        try await client.send(request(82, "setFunctionBreakpoints", ["breakpoints": [["name": "Hello.main"]]]))
        #expect(try await object(client.response(82))["command"] as? String == "setFunctionBreakpoints")
        try await client.send(request(81, "configurationDone"))
        #expect(try await object(client.response(81))["success"] as? Bool == true)
        let launch = try await object(client.response(71))
        #expect(launch["command"] as? String == "launch")
        #expect(launch["success"] as? Bool == true)
        try await client.send(request(99, "disconnect", ["terminateDebuggee": true]))
        _ = try await client.response(99)
        await relay.stop()
        await client.close()
        let messages = try await native.messages.map(object)
        #expect(messages.compactMap { $0["command"] as? String } == [
            "initialize", "attach", "setBreakpoints", "setFunctionBreakpoints", "configurationDone", "disconnect"
        ])
        #expect((messages[0]["arguments"] as? [String: String])?["pathFormat"] == "path")
        #expect((messages[1]["arguments"] as? [String: Any])?["pid"] as? Int == 42)
        #expect((messages[1]["arguments"] as? [String: Any])?["stopOnEntry"] as? Bool == true)
        #expect(state.withLock { $0.prepares } == 1)
        #expect(state.withLock { $0.stops } == 1)
    }

    @Test(arguments: [DebugSessionConnection.Request.launch, .attach])
    func launchOnlyAllowsRestartForANativeLaunch(nativeRequest: DebugSessionConnection.Request) async throws {
        let native = try DeferredFakeAdapter()
        let relay = DeferredDAPSession { _, _ in
            await DebugSessionBackend(connection: .init(
                uri: native.start(), request: nativeRequest, program: "/tmp/Hello", pid: 42
            )) { await native.stop() }
        }
        let client = try await DeferredTestClient(uri: relay.start())
        try await client.send(request(1, "initialize"))
        _ = try await client.response(1)
        try await client.send(request(2, "launch"))
        _ = try await client.response(2)
        let capabilityEvent = try await object(client.event("capabilities"))
        let body = try #require(capabilityEvent["body"] as? [String: Any])
        let capabilities = try #require(body["capabilities"] as? [String: Any])
        #expect(capabilities["supportsRestartRequest"] as? Bool == (nativeRequest == .launch))
        try await client.send(request(3, "restart"))
        #expect(try await object(client.response(3))["success"] as? Bool == (nativeRequest == .launch))
        #expect(await native.hasCommand("restart") == (nativeRequest == .launch))
        try await client.send(request(4, "threads"))
        #expect(try await object(client.response(4))["success"] as? Bool == true)
        try await client.send(request(5, "disconnect"))
        _ = try await client.response(5)
        await relay.stop()
        await client.close()
    }

    @Test(arguments: ["disconnect", "terminate", "eof", "shutdown"])
    func attachAlwaysDetaches(reason: String) async throws {
        let native = try DeferredFakeAdapter()
        let relay = DeferredDAPSession { request, pid in
            #expect(request == .attach)
            #expect(pid == 42)
            return await DebugSessionBackend(
                connection: .init(uri: native.start(), request: .attach, program: "/tmp/Hello", pid: 42)
            ) { await native.stop() }
        }
        let client = try await DeferredTestClient(uri: relay.start())
        try await client.send(request(1, "initialize"))
        _ = try await client.response(1)
        try await client.send(request(2, "attach", [
            "pid": "42", "program": "/tmp/unrelated", "attachCommands": ["run"],
            "initCommands": ["settings set target.inline-breakpoint-strategy always"],
            "terminateCommands": ["process kill"], "waitFor": true
        ]))
        _ = try await client.response(2)
        try await client.send(request(3, "restart"))
        #expect(try await object(client.response(3))["success"] as? Bool == false)
        if reason == "eof" {
            await client.close()
            try await eventually { await native.hasCommand("disconnect") }
        } else if reason != "shutdown" {
            try await client.send(request(4, reason, ["terminateDebuggee": true, "suspendDebuggee": true]))
            let response = try await object(client.response(4))
            #expect(response["command"] as? String == reason)
        }
        await relay.stop()
        await client.close()
        let messages = try await native.messages.map(object)
        let attach = try #require(messages.first { $0["command"] as? String == "attach" })
        let arguments = try #require(attach["arguments"] as? [String: Any])
        #expect(arguments["program"] as? String == "/tmp/Hello")
        #expect(arguments["pid"] as? Int == 42)
        #expect(arguments["initCommands"] as? [String] == ["settings set target.inline-breakpoint-strategy always"])
        #expect(arguments["attachCommands"] == nil)
        #expect(arguments["terminateCommands"] == nil)
        #expect(arguments["waitFor"] == nil)
        let disconnect = try #require(messages.first { $0["command"] as? String == "disconnect" })
        #expect(disconnect["arguments"] as? [String: Bool] == [
            "terminateDebuggee": false, "suspendDebuggee": false, "restart": false
        ])
        #expect(messages.allSatisfy { !["launch", "restart", "terminate"].contains($0["command"] as? String ?? "") })
    }

    @Test
    func identityIsRecheckedAfterInitializeBeforeNativeAttach() async throws {
        let native = try DeferredFakeAdapter()
        let relay = DeferredDAPSession { _, _ in
            await DebugSessionBackend(
                connection: .init(uri: native.start(), request: .attach, pid: 42),
                validate: { throw HostAttachError.invalid("The process identity changed.") },
                stop: { await native.stop() }
            )
        }
        let client = try await DeferredTestClient(uri: relay.start())
        try await client.send(request(1, "initialize"))
        _ = try await client.response(1)
        try await client.send(request(2, "attach"))
        let response = try await object(client.response(2))
        #expect(response["success"] as? Bool == false)
        #expect((response["message"] as? String)?.contains("identity changed") == true)
        await relay.stop()
        await client.close()
        #expect(await !(native.hasCommand("attach")))
    }

    @Test(arguments: ["disconnect", "cancel", "eof", "shutdown"])
    func cancellationStopsALateBackendExactlyOnce(reason: String) async throws {
        let gate = DeferredPreparationGate()
        let stopped = CrossPlatformLock(initialState: 0)
        let relay = DeferredDAPSession { _, _ in
            await gate.wait()
            // Simulate a backend that returns a resource after cancellation.
            return DebugSessionBackend(connection: .init(uri: "tcp://127.0.0.1:1", request: .launch)) {
                stopped.withLock { $0 += 1 }
            }
        }
        let client = try await DeferredTestClient(uri: relay.start())
        try await client.send(request(1, "initialize"))
        _ = try await client.response(1)
        try await client.send(request(2, "launch"))
        try await eventually { await gate.entered }
        let stopTask: Task<Void, Never>?
        if reason == "eof" {
            await client.close()
            stopTask = nil
        } else if reason == "shutdown" {
            stopTask = Task { await relay.stop() }
        } else {
            try await client.send(request(3, reason, reason == "cancel" ? ["requestId": 2] : [:]))
            _ = try await client.response(3)
            stopTask = nil
        }
        // Ensure EOF or shutdown reaches the relay before the late return.
        try await Task.sleep(for: .milliseconds(50))
        await gate.release()
        await stopTask?.value
        await relay.stop()
        await client.close()
        #expect(stopped.withLock { $0 } == 1)
    }

    @Test(arguments: [false, true])
    func discardsUnusedEndpointWithoutPreparing(initialize: Bool) async throws {
        let closed = CrossPlatformLock(initialState: 0)
        let relay = DeferredDAPSession { _, _ in
            Issue.record("Discarding an unused endpoint must not prepare a backend")
            throw CancellationError()
        } onClose: { closed.withLock { $0 += 1 } }
        let uri = try await relay.start()
        let client = try DeferredTestClient(uri: uri)
        do {
            if initialize {
                try await client.send(request(1, "initialize", ["adapterID": "bsp-debug"]))
                _ = try await client.response(1)
            }
            try await client.send(request(2, "disconnect", [
                "terminateDebuggee": false, "suspendDebuggee": false, "restart": false
            ]))
            #expect(try await object(client.response(2))["success"] as? Bool == true)
            try await eventually { closed.withLock { $0 } == 1 }
        } catch {
            await client.close()
            await relay.stop()
            throw error
        }
        await client.close()
        await relay.stop()
        // The old port can be reused after close; the callback confirms that this session closed.
        #expect(closed.withLock { $0 } == 1)
    }

    @Test
    func idleSessionClosesItsListenerWithoutPreparing() async throws {
        let closed = CrossPlatformLock(initialState: false)
        let relay = DeferredDAPSession(idleTimeout: .milliseconds(30)) { _, _ in
            Issue.record("An idle session must not prepare a backend")
            throw CancellationError()
        } onClose: { closed.withLock { $0 = true } }
        _ = try await relay.start()
        try await eventually { closed.withLock { $0 } }
        await relay.stop()
    }

    @Test
    func validatesPIDWithoutCoercingBooleansOrFractions() throws {
        #expect(try DeferredDAPSession.pid(nil) == nil)
        #expect(try DeferredDAPSession.pid("42") == 42)
        #expect(try DeferredDAPSession.pid(42) == 42)
        for value: Any in [true, false, 1.5, 0, -1, "invalid", "", Int64.max] {
            #expect(throws: HostAttachError.self) { try DeferredDAPSession.pid(value) }
        }
    }

    private func request(_ seq: Int, _ command: String, _ arguments: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "seq": seq, "type": "request", "command": command, "arguments": arguments
        ])
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now + deferredTestTimeout
        while await !condition() {
            guard end > .now else { throw DeferredTestError.timedOut("waiting for a test condition") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor DeferredPreparationGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume(); continuation = nil
    }
}

private actor DeferredTestClient {
    var fd: Int32
    var parser = DebugAdapterFrameBuffer()
    var buffered: [Data] = []
    init(uri: String) throws {
        fd = try AttachDAPSocket.connectTo(uri)
    }

    func close() {
        if fd >= 0 {
            #if os(macOS)
            Darwin.close(fd)
            #elseif os(Linux)
            Glibc.close(fd)
            #endif
            fd = -1
        }
    }

    func send(_ body: Data) async throws {
        var pending = DebugAdapterFrameBuffer.frame(body)
        let end = ContinuousClock.now + deferredTestTimeout
        while !pending.isEmpty {
            try AttachDAPSocket.flush(&pending, to: fd)
            guard !pending.isEmpty else { return }
            guard end > .now else { throw DeferredTestError.timedOut("sending a DAP message") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func response(_ sequence: Int, timeout: Duration = deferredTestTimeout) async throws -> Data {
        try await receive(sequence: sequence, event: nil, timeout: timeout)
    }

    func event(_ event: String) async throws -> Data {
        try await receive(sequence: nil, event: event, timeout: deferredTestTimeout)
    }

    private func receive(sequence: Int?, event: String?, timeout: Duration) async throws -> Data {
        let end = ContinuousClock.now + timeout
        while true {
            if let message = bufferedMessage(sequence: sequence, event: event) { return message }
            if let data = try AttachDAPSocket.read(fd) { try buffered.append(contentsOf: parser.append(data)) }
            if let message = bufferedMessage(sequence: sequence, event: event) { return message }
            guard end > .now else {
                let expected = sequence.map { "response to request \($0)" } ?? "event \(event ?? "unknown")"
                throw DeferredTestError.timedOut("waiting for DAP \(expected)")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func bufferedMessage(sequence: Int?, event: String?) -> Data? {
        guard let index = buffered.firstIndex(where: { data in
            let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return sequence.map { message?["request_seq"] as? Int == $0 } ?? (message?["event"] as? String == event)
        }) else { return nil }
        return buffered.remove(at: index)
    }
}

private actor DeferredFakeAdapter {
    let listener: Int32
    let port: Int
    var client: Int32 = -1
    var task: Task<Void, Never>?
    var messages: [Data] = []
    let holdStart: Bool
    let emittedOutput: (category: String, text: String)?
    init(holdStart: Bool = false, emittedOutput: (category: String, text: String)? = nil) throws {
        self.holdStart = holdStart
        self.emittedOutput = emittedOutput
        (listener, port) = try AttachDAPSocket.listener()
    }

    func start() -> String {
        task = Task { await serve() }
        return "tcp://127.0.0.1:\(port)"
    }

    func stop() async {
        task?.cancel(); await task?.value
    }

    func hasCommand(_ command: String) -> Bool {
        messages.contains {
            ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any])?["command"] as? String == command
        }
    }

    private func serve() async {
        defer { close(listener); if client >= 0 { close(client) } }
        var parser = DebugAdapterFrameBuffer()
        var pending = Data()
        var heldResponse = Data()
        do {
            while !Task.isCancelled {
                if client < 0 {
                    client = accept(listener, nil, nil)
                    if client >= 0 {
                        try AttachDAPSocket.nonblocking(client)
                        #if os(macOS)
                        var enabled: Int32 = 1
                        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
                        #endif
                    }
                } else {
                    if let bytes = try AttachDAPSocket.read(client) {
                        for body in try parser.append(bytes) {
                            messages.append(body)
                            let request = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                            let command = request["command"] as? String ?? ""
                            let response = try DebugAdapterFrameBuffer.frame(JSONSerialization.data(withJSONObject: [
                                "seq": 100, "type": "response", "request_seq": request["seq"] as? Int ?? 0,
                                "command": command, "success": true,
                                "body": command == "initialize" ? [
                                    "supportsConfigurationDoneRequest": true, "supportsFunctionBreakpoints": true,
                                    "supportsRestartRequest": true
                                ] : [:]
                            ]))
                            if holdStart && (command == "attach" || command == "launch") {
                                heldResponse = response
                            } else {
                                pending.append(response)
                            }
                            if command == "configurationDone" {
                                pending.append(heldResponse)
                                heldResponse.removeAll()
                            }
                            if command == "attach" || command == "launch" {
                                try pending
                                    .append(DebugAdapterFrameBuffer.frame(JSONSerialization.data(withJSONObject: [
                                        "seq": 100,
                                        "type": "event",
                                        "event": "initialized"
                                    ])))
                                try appendEmittedOutput(to: &pending)
                            }
                        }
                    }
                    try AttachDAPSocket.flush(&pending, to: client)
                }
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch {}
    }

    private func appendEmittedOutput(to pending: inout Data) throws {
        guard let emittedOutput else { return }
        try pending.append(DebugAdapterFrameBuffer.frame(JSONSerialization.data(withJSONObject: [
            "seq": 101,
            "type": "event",
            "event": "output",
            "body": ["category": emittedOutput.category, "output": emittedOutput.text]
        ])))
    }
}
