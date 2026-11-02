import Foundation
import Logger
import Network

/// Forwards one DAP session and supplies the device attach commands to LLDB.
actor DeviceDAPRelay {
    private let upstream: DebugAdapterEndpoint
    private let configuration: DAPAttachConfiguration
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
    private var closed = false

    init(
        upstream: DebugAdapterEndpoint,
        configuration: DAPAttachConfiguration,
        cleanup: @escaping @Sendable () async -> Void
    ) {
        self.upstream = upstream
        self.configuration = configuration
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
                    let outgoing = try fromClient ? configuration.configure(body) : body
                    let failedAttach = !fromClient && observe(body)
                    try await send(DAPFrameBuffer.frame(outgoing), to: destination)
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

    private func observe(_ body: Data) -> Bool {
        guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              message["type"] as? String == "response", message["command"] as? String == "attach" else { return false }
        guard message["success"] as? Bool == true else { return true }
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
        if !attached || terminateDebuggee {
            let cleanup = cleanup
            let task = Task.detached { await cleanup() }
            cleanupTask = task
            await task.value
        }
    }
}
