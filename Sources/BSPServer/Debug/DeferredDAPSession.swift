import BuildServerProtocol
import CoreFoundation
import Foundation
import Support
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// Defers backend preparation until the client chooses DAP launch or attach.
actor DeferredDAPSession {
    typealias Prepare = @Sendable (DebugSessionConnection.Request, Int?) async throws -> DebugSessionBackend

    private let prepare: Prepare
    private let onClose: @Sendable () async -> Void
    private let idleTimeout: Duration
    private var listener: Int32 = -1
    private var client: Int32 = -1
    private var adapter: Int32 = -1
    private var loop: Task<Void, Never>?
    private var startup: Task<Void, Never>?
    private var backend: DebugSessionBackend?
    private var initialize: Data?
    private var startRequest: Data?
    private var mode: DebugSessionConnection.Request?
    private var initialized = false
    private var startAnswered = false
    private var disconnectAcknowledged = false
    private var stopping = false
    private var clientAlive = true
    private var deadline: ContinuousClock.Instant?
    private var disconnectSequence: Int?
    private var initializeSequence: Int?
    private var nativeSequence = 0
    private var clientSequence = 0
    private var requests: [Int: (sequence: Int, command: String)] = [:]
    private var reverseRequests: [Int: Int] = [:]
    private var queued: [Data] = []
    private var clientFrames = DebugAdapterFrameBuffer()
    private var adapterFrames = DebugAdapterFrameBuffer()
    private var toClient = Data()
    private var toAdapter = Data()

    init(
        idleTimeout: Duration = .seconds(60),
        prepare: @escaping Prepare,
        onClose: @escaping @Sendable () async -> Void = {}
    ) {
        self.idleTimeout = idleTimeout
        self.prepare = prepare
        self.onClose = onClose
    }

    func start() throws -> String {
        guard loop == nil, !stopping else { throw DebugAdapterRelayError.closed }
        let (fd, port) = try AttachDAPSocket.listener()
        listener = fd
        deadline = .now + idleTimeout
        loop = Task { await run() }
        return "tcp://127.0.0.1:\(port)"
    }

    func stop() async {
        stopping = true
        startup?.cancel()
        await loop?.value
    }

    private func run() async {
        do {
            while try shouldRun() {
                if listener >= 0, !stopping { try acceptClient() }
                try readClient()
                try await readAdapter()
                if client >= 0, clientAlive { try AttachDAPSocket.flush(&toClient, to: client) }
                guard toClient.count <= Self.bufferLimit, toAdapter.count <= Self.bufferLimit,
                      queued.reduce(0, { $0 + $1.count }) <= Self.bufferLimit else {
                    throw DebugAdapterRelayError.invalidFrame
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            try? failStart(error)
        }
        startup?.cancel()
        await startup?.value
        startup = nil
        await detachAndClose()
        await backend?.stop()
        backend = nil
        for fd in [listener, client, adapter] where fd >= 0 {
            close(fd)
        }
        listener = -1
        client = -1
        adapter = -1
        loop = nil
        stopping = true
        await onClose()
    }

    private func shouldRun() throws -> Bool {
        if let deadline, deadline <= .now {
            if !stopping { try failStart(DebugAdapterRelayError.timedOut) }
            return false
        }
        guard stopping else { return true }
        startup?.cancel()
        if adapter >= 0 { try queueDisconnect() }
        return !(adapter < 0 && (toClient.isEmpty || !clientAlive))
    }

    private func readClient() throws {
        guard client >= 0, clientAlive, !stopping else { return }
        do {
            if let bytes = try AttachDAPSocket.read(client) {
                for body in try clientFrames.append(bytes) {
                    try clientMessage(body)
                }
            }
        } catch DebugAdapterRelayError.closed {
            clientAlive = false
            stopping = true
            startup?.cancel()
        }
    }

    private func readAdapter() async throws {
        guard adapter >= 0 else { return }
        if let bytes = try AttachDAPSocket.read(adapter) {
            for body in try adapterFrames.append(bytes) {
                try await adapterMessage(body)
            }
        }
        try AttachDAPSocket.flush(&toAdapter, to: adapter)
    }

    private static let bufferLimit = 64 * 1024 * 1024

    private func acceptClient() throws {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
            throw DebugAdapterRelayError.closed
        }
        client = fd
        try AttachDAPSocket.nonblocking(fd)
        #if os(macOS)
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        #endif
        close(listener)
        listener = -1
    }
}

extension DeferredDAPSession {
    private func clientMessage(_ body: Data) throws {
        let message = try Self.object(body)
        if message["type"] as? String == "response" {
            try forwardReverseResponse(message)
            return
        }
        guard message["type"] as? String == "request", let command = message["command"] as? String,
              message["seq"] is Int else { throw DebugAdapterRelayError.invalidFrame }
        switch command {
        case "initialize":
            try initializeClient(body, message: message)
        case "disconnect", "terminate":
            try disconnectClient(message)
        case "launch", "attach":
            try beginStart(body, message: message, command: command)
        case "cancel" where !initialized:
            try cancelStartup(message)
        default:
            try forwardOrQueue(body, message: message, command: command)
        }
    }

    private func forwardReverseResponse(_ original: [String: Any]) throws {
        var message = original
        guard let sequence = message["request_seq"] as? Int,
              let native = reverseRequests.removeValue(forKey: sequence) else { return }
        message["request_seq"] = native
        nativeSequence += 1
        message["seq"] = nativeSequence
        try sendNative(message)
    }

    private func initializeClient(_ body: Data, message: [String: Any]) throws {
        guard initialize == nil else {
            try respond(message, error: "DAP initialize was already received.")
            return
        }
        initialize = body
        try respond(message, body: ["supportsConfigurationDoneRequest": true])
    }

    private func disconnectClient(_ message: [String: Any]) throws {
        if initialized {
            try forward(message)
        } else {
            try respond(message)
            try failStart(CancellationError())
        }
        stopping = true
        startup?.cancel()
    }

    private func beginStart(_ body: Data, message: [String: Any], command: String) throws {
        guard initialize != nil, startRequest == nil else {
            try respond(message, error: "Send initialize, then one launch or attach request.")
            return
        }
        let request: DebugSessionConnection.Request = command == "attach" ? .attach : .launch
        let arguments = message["arguments"] as? [String: Any] ?? [:]
        let pid: Int?
        do { pid = request == .attach ? try Self.pid(arguments["pid"]) : nil } catch {
            try respond(message, error: error.localizedDescription)
            return
        }
        startRequest = body
        mode = request
        deadline = nil
        startup = Task { await prepareBackend(request, pid: pid) }
    }

    private func prepareBackend(_ request: DebugSessionConnection.Request, pid: Int?) async {
        do {
            let prepared = try await prepare(request, pid)
            if stopping || Task.isCancelled {
                await prepared.stop()
                return
            }
            backend = prepared
            adapter = try AttachDAPSocket.connectTo(prepared.connection.uri)
            guard let initialize else { throw DebugAdapterRelayError.invalidFrame }
            var nativeInitialize = try Self.object(initialize)
            nativeSequence += 1
            initializeSequence = nativeSequence
            nativeInitialize["seq"] = nativeSequence
            try sendNative(nativeInitialize)
            deadline = .now + idleTimeout
        } catch {
            try? failStart(error)
        }
    }

    private func cancelStartup(_ message: [String: Any]) throws {
        let arguments = message["arguments"] as? [String: Any]
        let active = try startRequest.map(Self.object)?["seq"] as? Int
        try respond(message)
        if let active, arguments?["requestId"] as? Int == active { try failStart(CancellationError()) }
    }

    private func forwardOrQueue(_ body: Data, message: [String: Any], command: String) throws {
        if initialized {
            try forward(message)
        } else if startRequest != nil {
            queued.append(body)
        } else {
            try respond(message, error: "Send launch or attach before \(command).")
        }
    }
}

extension DeferredDAPSession {
    private func adapterMessage(_ body: Data) async throws {
        var message = try Self.object(body)
        let type = message["type"] as? String
        if type == "response", message["command"] as? String == "initialize",
           message["request_seq"] as? Int == initializeSequence, !initialized {
            try await completeInitialization(message)
            return
        }
        if type == "response" {
            guard let response = try await mappedResponse(message) else { return }
            message = response
        } else if type == "request", let sequence = message["seq"] as? Int {
            reverseRequests[clientSequence + 1] = sequence
        }
        try sendClient(message)
    }

    private func completeInitialization(_ message: [String: Any]) async throws {
        guard message["success"] as? Bool == true else {
            throw HostAttachError.invalid(message["message"] as? String ?? "The native debugger could not initialize.")
        }
        guard let backend, let startRequest else { throw DebugAdapterRelayError.invalidFrame }
        try await backend.validate()
        guard !stopping else { return }
        initialized = true
        if var capabilities = message["body"] as? [String: Any] {
            if mode == .attach { capabilities["supportsRestartRequest"] = false }
            try sendClient(["type": "event", "event": "capabilities", "body": ["capabilities": capabilities]])
        }
        try forward(Self.object(startRequest))
        for data in queued {
            try forward(Self.object(data))
        }
        queued.removeAll()
    }

    private func mappedResponse(_ original: [String: Any]) async throws -> [String: Any]? {
        var message = original
        guard let sequence = message["request_seq"] as? Int else { return message }
        if sequence == disconnectSequence {
            disconnectAcknowledged = true
            deadline = .now
        }
        guard let request = requests.removeValue(forKey: sequence) else { return nil }
        message["request_seq"] = request.sequence
        message["command"] = request.command
        if request.command == "launch" || request.command == "attach" {
            try await completeStart(success: message["success"] as? Bool == true)
        }
        return message
    }

    private func completeStart(success: Bool) async throws {
        if success { try await backend?.validate() }
        startAnswered = true
        if !stopping { deadline = nil }
        if success {
            await backend?.didStart()
        } else {
            stopping = true
        }
    }

    private func forward(_ original: [String: Any]) throws {
        var message = original
        guard let sequence = message["seq"] as? Int, let command = message["command"] as? String else {
            throw DebugAdapterRelayError.invalidFrame
        }
        if mode == .attach, command == "restart" || command == "launch" {
            try respond(original, error: "An attach session cannot launch or restart the application.")
            return
        }
        if command == "launch" || command == "attach" { try configureStart(&message) }
        if mode == .attach, command == "terminate" || command == "disconnect" {
            message["command"] = "disconnect"
            message["arguments"] = Self.detachArguments
        }
        nativeSequence += 1
        message["seq"] = nativeSequence
        requests[nativeSequence] = (sequence, command)
        if command == "disconnect" || command == "terminate" {
            disconnectSequence = nativeSequence
            deadline = .now + .seconds(2)
        }
        try sendNative(message)
    }

    private func configureStart(_ message: inout [String: Any]) throws {
        guard let connection = backend?.connection, let nativeRequest = connection.request else {
            throw DebugAdapterRelayError.invalidFrame
        }
        // The client request can be launch while LLDB attaches to a suspended simulator process.
        message["command"] = nativeRequest.rawValue
        var arguments = message["arguments"] as? [String: Any] ?? [:]
        arguments["program"] = connection.program
        arguments["pid"] = connection.pid
        if let args = connection.args { arguments["args"] = args }
        if let env = connection.env { arguments["env"] = env }
        if let cwd = connection.cwd { arguments["cwd"] = cwd }
        if mode == .attach {
            for key in [
                "attachCommands",
                "launchCommands",
                "preRunCommands",
                "postRunCommands",
                "exitCommands",
                "terminateCommands",
                "name",
                "waitFor",
                "restart",
                "processId"
            ] {
                arguments.removeValue(forKey: key)
            }
            arguments["detachOnError"] = true
        }
        message["arguments"] = arguments
    }
}

extension DeferredDAPSession {
    private func queueDisconnect() throws {
        guard disconnectSequence == nil else { return }
        nativeSequence += 1
        disconnectSequence = nativeSequence
        deadline = .now + .seconds(2)
        let arguments: [String: Any] = mode == .attach ? Self.detachArguments : ["terminateDebuggee": true]
        try sendNative([
            "seq": nativeSequence, "type": "request", "command": "disconnect", "arguments": arguments
        ])
    }

    private static var detachArguments: [String: Any] {
        ["terminateDebuggee": false, "suspendDebuggee": false, "restart": false]
    }

    private func failStart(_ error: Error) throws {
        if !startAnswered, let startRequest {
            startAnswered = true
            let request = try Self.object(startRequest)
            try respond(
                request,
                error: error is CancellationError ? "Debug startup cancelled." : error.localizedDescription
            )
            try sendClient(["type": "event", "event": "terminated"])
        }
        stopping = true
        startup?.cancel()
        deadline = .now + .seconds(2)
    }

    /// Wait for detach before stopping the adapter, including EOF and server shutdown.
    private func detachAndClose() async {
        let end = ContinuousClock.now + .seconds(2)
        if adapter >= 0 { try? queueDisconnect() }
        while end > .now {
            if client >= 0, clientAlive { try? AttachDAPSocket.flush(&toClient, to: client) }
            guard adapter >= 0, !disconnectAcknowledged else {
                if toClient.isEmpty || !clientAlive { return }
                try? await Task.sleep(for: .milliseconds(10))
                continue
            }
            do {
                try AttachDAPSocket.flush(&toAdapter, to: adapter)
                if let bytes = try AttachDAPSocket.read(adapter) {
                    for body in try adapterFrames.append(bytes) {
                        let message = try Self.object(body)
                        if message["type"] as? String == "response",
                           message["request_seq"] as? Int == disconnectSequence { return }
                    }
                }
            } catch { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func respond(_ request: [String: Any], body: [String: Any] = [:], error: String? = nil) throws {
        var message: [String: Any] = [
            "type": "response", "request_seq": request["seq"] as? Int ?? 0,
            "command": request["command"] as? String ?? "", "success": error == nil, "body": body
        ]
        if let error { message["message"] = error }
        try sendClient(message)
    }

    private func sendClient(_ message: [String: Any]) throws {
        var message = message
        clientSequence += 1
        message["seq"] = clientSequence
        try toClient.append(DebugAdapterFrameBuffer.frame(JSONSerialization.data(withJSONObject: message)))
    }

    private func sendNative(_ message: [String: Any]) throws {
        try toAdapter.append(DebugAdapterFrameBuffer.frame(JSONSerialization.data(withJSONObject: message)))
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DebugAdapterRelayError.invalidFrame
        }
        return result
    }

    static func pid(_ value: Any?) throws -> Int? {
        guard let value else { return nil }
        let text: String
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            text = number.stringValue
        } else if let string = value as? String { text = string } else {
            throw HostAttachError.invalid("pid must be a positive process ID.")
        }
        guard let pid = Int(text), pid > 0, Int32(exactly: pid) != nil else {
            throw HostAttachError.invalid("pid must be a positive process ID.")
        }
        return pid
    }
}
