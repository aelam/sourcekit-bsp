import Foundation
import Logger
import Network

/// Forwards one DAP session and supplies the device attach commands to LLDB.
actor DeviceDAPRelay {
    private let upstream: DebugAdapterEndpoint
    private let configuration: DAPAttachConfiguration?
    private let console: ApplicationConsole?
    private var consoleTask: Task<Void, Never>?
    private var sequence = 0
    private var reverseRequests: [Int: Int] = [:]
    private let timing: AttachTiming?
    private var attachSpan: AttachTiming.Span?
    private let cleanup: @Sendable () async -> Void
    private let queue = DispatchQueue(label: "sourcekit-bsp.device-dap")
    private var listener: NWListener?
    private var client: NWConnection?
    private var adapter: NWConnection?
    private var ready: CheckedContinuation<String, Error>?
    private var deadline: Task<Void, Never>?
    private var clientFrames = DAPFrameBuffer()
    private var adapterFrames = DAPFrameBuffer()
    private var cleanupTask: Task<Void, Never>?
    private var attached = false
    private var detachRequested = false
    private var closed = false

    init(
        upstream: DebugAdapterEndpoint,
        configuration: DAPAttachConfiguration? = nil,
        console: ApplicationConsole? = nil,
        timing: AttachTiming? = nil,
        cleanup: @escaping @Sendable () async -> Void
    ) {
        self.upstream = upstream
        self.configuration = configuration
        self.console = console
        self.timing = timing
        self.cleanup = cleanup
    }

    func start(timeout: Duration = .seconds(120)) async throws -> DebugAdapterEndpoint {
        try Task.checkCancellation()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { connection in Task { await self.accept(connection) } }
        listener.stateUpdateHandler = { state in Task { await self.listenerChanged(state) } }
        deadline = Task {
            do {
                try await Task.sleep(for: timeout)
                await close(reason: DAPRelayError.timedOut)
            } catch {}
        }
        let uri = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                listener.start(queue: queue)
            }
        } onCancel: {
            Task { await self.close(reason: CancellationError()) }
        }
        var endpoint = DebugAdapterEndpoint(uri: uri) {
            Task { await self.close(reason: nil, terminateDebuggee: true) }
        }
        endpoint.waitForTermination = { await self.close(reason: nil, terminateDebuggee: true) }
        return endpoint
    }

    private func listenerChanged(_ state: NWListener.State) async {
        switch state {
        case .ready:
            if let port = listener?.port {
                ready?.resume(returning: "tcp://127.0.0.1:\(port.rawValue)")
                ready = nil
            }
        case let .failed(error): await close(reason: error)
        default: break
        }
    }

    private func accept(_ connection: NWConnection) async {
        guard !closed, client == nil, let url = URL(string: upstream.uri),
              url.host == "127.0.0.1", let portValue = url.port,
              let rawPort = UInt16(exactly: portValue), let port = NWEndpoint.Port(rawValue: rawPort) else {
            connection.cancel()
            return
        }
        client = connection
        listener?.cancel()
        listener = nil
        let adapter = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        self.adapter = adapter
        for item in [connection, adapter] {
            item.stateUpdateHandler = { state in
                if case let .failed(error) = state { Task { await self.close(reason: error) } }
            }
            item.start(queue: queue)
        }
        receive(fromClient: true)
        receive(fromClient: false)
    }

    private func receive(fromClient: Bool) {
        guard !closed, let source = fromClient ? client : adapter else { return }
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            Task {
                await self.forward(
                    data,
                    complete: complete,
                    error: error,
                    fromClient: fromClient
                )
            }
        }
    }

    private func forward(
        _ data: Data?,
        complete: Bool,
        error: NWError?,
        fromClient: Bool
    ) async {
        guard !closed, let destination = fromClient ? adapter : client else { return }
        do {
            if let data, !data.isEmpty {
                let bodies = try fromClient ? clientFrames.append(data) : adapterFrames.append(data)
                for body in bodies {
                    if !fromClient,
                       let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                       message["type"] as? String == "event", message["event"] as? String == "terminated" {
                        await console?.finishOutput()
                    }
                    if fromClient, timing != nil, !attached,
                       let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                       message["type"] as? String == "request" {
                        if message["command"] as? String == "attach", attachSpan == nil {
                            attachSpan = timing?.start("lldb.attach")
                        } else if message["command"] as? String == "disconnect" {
                            attachSpan?.finish(.cancelled)
                            attachSpan = nil
                        }
                    }
                    let outgoing = try fromClient ? clientMessage(body) : adapterMessage(body)
                    let failedAttach = !fromClient && observe(body)
                    try await send(DAPFrameBuffer.frame(outgoing), to: destination)
                    if !fromClient { connectConsole(after: body) }
                    if failedAttach {
                        await close(reason: nil)
                        return
                    }
                }
            }
            if complete || error != nil {
                await close(reason: error)
            } else {
                receive(fromClient: fromClient)
            }
        } catch {
            await close(reason: error)
        }
    }

    private func clientMessage(_ body: Data) throws -> Data {
        let body = try configuration?.configure(body) ?? body
        guard var message = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw DAPRelayError.invalidFrame
        }
        if attached, message["type"] as? String == "request", message["command"] as? String == "disconnect",
           let arguments = message["arguments"] as? [String: Any], arguments["terminateDebuggee"] as? Bool == false {
            detachRequested = true
        }
        if message["type"] as? String == "response", let request = message["request_seq"] as? Int {
            message["request_seq"] = reverseRequests.removeValue(forKey: request) ?? request
        }
        return try JSONSerialization.data(withJSONObject: message)
    }

    private func adapterMessage(_ body: Data) throws -> Data {
        guard var message = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw DAPRelayError.invalidFrame
        }
        sequence += 1
        if message["type"] as? String == "request", let original = message["seq"] as? Int {
            reverseRequests[sequence] = original
        }
        message["seq"] = sequence
        return try JSONSerialization.data(withJSONObject: message)
    }

    private func connectConsole(after body: Data) {
        guard consoleTask == nil, let console,
              let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              message["type"] as? String == "response", message["command"] as? String == "initialize",
              message["success"] as? Bool == true else { return }
        consoleTask = Task { [weak self] in
            await console.output.connect { [weak self] output in await self?.sendOutput(output) }
        }
    }

    private func sendOutput(_ output: ApplicationOutput) async {
        guard !closed, let client else { return }
        do {
            sequence += 1
            let body = try JSONSerialization.data(withJSONObject: [
                "seq": sequence, "type": "event", "event": "output",
                "body": ["category": output.channel.rawValue, "output": output.text]
            ])
            try await send(DAPFrameBuffer.frame(body), to: client)
        } catch {
            Task { await self.close(reason: error) }
        }
    }

    private func observe(_ body: Data) -> Bool {
        guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              message["type"] as? String == "response", message["command"] as? String == "attach" else { return false }
        let succeeded = message["success"] as? Bool == true
        attachSpan?.finish(succeeded ? .ok : .failed)
        attachSpan = nil
        guard succeeded else { return true }
        attached = true
        deadline?.cancel()
        deadline = nil
        return false
    }

    private func send(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func close(reason: (any Error)?, terminateDebuggee: Bool = false) async {
        guard !closed else {
            await cleanupTask?.value
            return
        }
        closed = true
        attachSpan?.finish(reason.map { AttachTiming.Outcome.failure($0) } ?? .incomplete)
        attachSpan = nil
        if let reason { logger.error("Device debug session: \(reason.localizedDescription)") }
        ready?.resume(throwing: reason ?? DAPRelayError.closed)
        ready = nil
        deadline?.cancel()
        deadline = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for connection in [client, adapter].compactMap(\.self) {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        client = nil
        adapter = nil
        upstream.terminate()
        consoleTask?.cancel()
        consoleTask = nil
        let cleanup = cleanup
        let console = console
        let stopApp = !attached || (terminateDebuggee && !detachRequested)
        let task = Task.detached {
            if stopApp { await cleanup() }
            await console?.stop(terminateApp: false)
        }
        cleanupTask = task
        await task.value
    }
}
