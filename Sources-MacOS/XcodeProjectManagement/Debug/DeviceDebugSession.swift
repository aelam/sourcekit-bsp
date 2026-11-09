import BuildServerProtocol
import Foundation

struct DeviceDebugSession: Sendable {
    let commands: DeviceCommandRunner
    let adapter: any DebugAdapterServing

    func attach(identity: DeviceProcessIdentity) async throws -> (DebugSessionConnection, DebugAdapterEndpoint) {
        try Task.checkCancellation()
        let timing = AttachTiming.current ?? AttachTiming()
        let upstream = try await timing.measure("lldb.start") { try await adapter.start() }
        let relay = DeviceDAPRelay(
            upstream: upstream,
            configuration: .device(id: identity.deviceID, pid: identity.pid, executable: identity.localExecutable),
            timing: timing
        ) {}
        do {
            let endpoint = try await timing.measure("relay.listen") { try await relay.start() }
            try Task.checkCancellation()
            return (
                DebugSessionConnection(
                    uri: endpoint.uri,
                    request: .attach,
                    pid: identity.pid,
                    bundleId: identity.bundleID
                ),
                endpoint
            )
        } catch {
            await relay.close(reason: error)
            throw error
        }
    }

    func start(
        product: DebugProduct,
        progressHandler: (@Sendable (String) async -> Void)?
    ) async throws -> (DebugSessionConnection, DebugAdapterEndpoint) {
        try product.validate()
        guard let deviceID = product.destinationID, let bundleID = product.bundleId,
              let executable = product.executablePath else { throw DebugSessionError.missingExecutable }
        guard FileManager.default.fileExists(atPath: executable) else {
            throw DebugSessionError.productNotFound(executable)
        }
        await progressHandler?("Starting LLDB for device \(deviceID)")
        let upstream = try await adapter.start()
        var process: DeviceDebugProcess?
        var relay: DeviceDAPRelay?
        do {
            await progressHandler?("Launching \(bundleID) on device \(deviceID), waiting for the debugger")
            let pid = try await commands.launch(
                deviceID: deviceID, bundleID: bundleID, stopped: true, settings: product.launchSettings
            )
            let launched = DeviceDebugProcess(commands: commands, deviceID: deviceID, pid: pid)
            process = launched
            try Task.checkCancellation()
            let preparedRelay = DeviceDAPRelay(
                upstream: upstream,
                configuration: .device(id: deviceID, pid: pid, executable: executable)
            ) {
                await launched.stop()
            }
            relay = preparedRelay
            let endpoint = try await preparedRelay.start()
            await progressHandler?("Device process \(pid) is waiting for the DAP client to attach")
            try Task.checkCancellation()
            return (
                DebugSessionConnection(uri: endpoint.uri, request: .attach, pid: pid, bundleId: bundleID),
                endpoint
            )
        } catch {
            if let relay {
                await relay.close(reason: error)
            } else {
                upstream.terminate()
            }
            await process?.stop()
            throw error
        }
    }
}

/// Owns only the process started for this debug session.
private actor DeviceDebugProcess {
    let commands: DeviceCommandRunner
    let deviceID: String
    let pid: Int
    private var stopped = false

    init(commands: DeviceCommandRunner, deviceID: String, pid: Int) {
        self.commands = commands
        self.deviceID = deviceID
        self.pid = pid
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        await Task.detached { [commands, deviceID, pid] in
            await commands.terminate(deviceID: deviceID, pid: pid)
        }.value
    }
}
