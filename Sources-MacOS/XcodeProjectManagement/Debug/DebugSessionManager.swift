import BuildServerProtocol
import Foundation
import Logger
import Support

/// The build product to debug, resolved from a target.
public struct DebugProduct: Sendable {
    public let platform: Platform
    public let binaryPath: String // macOS: executable; simulator: .app path
    public let bundleId: String?
    public let destinationID: String?
    public let executablePath: String?
    public let launchSettings: XcodeLaunchSettings

    public var simulatorUDID: String? {
        destinationID
    }

    public init(
        platform: Platform,
        binaryPath: String,
        bundleId: String?,
        simulatorUDID: String?,
        launchSettings: XcodeLaunchSettings = .init()
    ) {
        self.platform = platform
        self.binaryPath = binaryPath
        self.bundleId = bundleId
        self.destinationID = simulatorUDID
        self.executablePath = nil
        self.launchSettings = launchSettings
    }

    public init(
        platform: Platform,
        binaryPath: String,
        bundleId: String?,
        destinationID: String?,
        executablePath: String?,
        launchSettings: XcodeLaunchSettings = .init()
    ) {
        self.platform = platform
        self.binaryPath = binaryPath
        self.bundleId = bundleId
        self.destinationID = destinationID
        self.executablePath = executablePath
        self.launchSettings = launchSettings
    }
}

public enum DebugSessionError: Error, LocalizedError {
    case buildFailed
    case missingBundleId
    case missingSimulatorUDID
    case missingDeviceID
    case missingExecutable
    case unresolvedPlatform
    case unsupportedPlatform(Platform)
    case unsupportedProduct(String)
    case productNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .buildFailed: "Build failed before starting the debug session"
        case .missingBundleId: "Could not resolve the app's bundle identifier"
        case .missingSimulatorUDID: "No simulator destination selected"
        case .missingDeviceID: "No physical device selected. Select an iPhone destination."
        case .missingExecutable: "Could not resolve the executable path for device debugging"
        case .unresolvedPlatform: "Could not resolve the target's platform (PLATFORM_NAME)"
        case let .unsupportedPlatform(p): "Debugging is not supported for platform \(p.rawValue)"
        case let .unsupportedProduct(name): "Debugging requires an application target: \(name)"
        case let .productNotFound(path):
            "Build product not found: \(path). " +
                "Compile the target with the selected configuration and destination first."
        }
    }
}

/// Orchestrates a debug session: (build already done by the caller) → start an
/// lldb-dap endpoint → produce a `DebugSessionConnection` describing how the
/// client should attach (macOS: launch a program; simulator: attach to a PID).
///
/// The adapter and simulator launcher are injected so this is unit-testable
/// without Xcode or a running simulator.
public actor DebugSessionManager {
    private let adapter: DebugAdapterServing
    private let simulatorLauncher: WaitForDebuggerLaunching
    private var deviceSession: DeviceDebugSession?
    private var liveEndpoints: [DebugAdapterEndpoint] = []
    private var pendingSimulatorProcesses: [String: HostProcessIdentity] = [:]
    var captureLaunchedProcess: @Sendable (Int, String) -> HostProcessIdentity? = { pid, device in
        guard let identity = HostProcessIdentity.read(pid: pid),
              identity.executable.contains("/CoreSimulator/Devices/\(device)/") else { return nil }
        return identity
    }

    var stopPendingProcess: @Sendable (HostProcessIdentity) -> Void = { identity in
        // Stop only the process this launch created, and only before DAP takes ownership.
        guard (try? identity.validate()) != nil, let pid = Int32(exactly: identity.pid) else { return }
        _ = kill(pid, SIGKILL)
    }

    public init(adapter: DebugAdapterServing, simulatorLauncher: WaitForDebuggerLaunching) {
        self.adapter = adapter
        self.simulatorLauncher = simulatorLauncher
    }

    init(adapter: DebugAdapterServing, simulatorLauncher: WaitForDebuggerLaunching, deviceSession: DeviceDebugSession) {
        self.adapter = adapter
        self.simulatorLauncher = simulatorLauncher
        self.deviceSession = deviceSession
    }

    /// Build (via the injected closure), then produce a connection for the product.
    public func startSession(
        build: @Sendable () async throws -> Bool,
        product: DebugProduct
    ) async throws -> DebugSessionConnection {
        guard try await build() else { throw DebugSessionError.buildFailed }
        return try await makeConnection(for: product)
    }

    /// Product → connection. Assumes the build already succeeded.
    func makeConnection(
        for product: DebugProduct,
        progressHandler: (@Sendable (String) async -> Void)? = nil,
        launcher: (any WaitForDebuggerLaunching)? = nil
    ) async throws -> DebugSessionConnection {
        try Task.checkCancellation()
        try product.validate()
        if product.platform == .iOS {
            guard let deviceSession else { throw DebugSessionError.unsupportedPlatform(product.platform) }
            let (connection, endpoint) = try await deviceSession.start(
                product: product,
                progressHandler: progressHandler
            )
            liveEndpoints.append(endpoint)
            return connection
        }
        if product.platform.isSimulator,
           let consoleLauncher = (launcher ?? simulatorLauncher) as? any ConsoleDebuggerLaunching {
            return try await makeSimulatorConsoleConnection(product: product, launcher: consoleLauncher)
        }
        let endpoint = try await adapter.start()
        var succeeded = false
        defer {
            if succeeded {
                liveEndpoints.append(endpoint)
            } else {
                endpoint.terminate()
            }
        }

        switch product.platform {
        case .macOS:
            succeeded = true
            return DebugSessionConnection(
                uri: endpoint.uri,
                request: .launch,
                program: product.binaryPath,
                pid: nil,
                bundleId: product.bundleId,
                args: product.launchSettings.arguments.isEmpty ? nil : product.launchSettings.arguments,
                env: product.launchSettings.consoleEnvironment,
                cwd: product.launchSettings.workingDirectory
            )
        case .iOSSimulator, .watchSimulator, .tvSimulator, .visionSimulator:
            guard let udid = product.simulatorUDID else { throw DebugSessionError.missingSimulatorUDID }
            guard let bundleId = product.bundleId else { throw DebugSessionError.missingBundleId }
            let pid = try await (launcher ?? simulatorLauncher).launchWaitingForDebugger(
                deviceID: udid, appIdentifier: bundleId, settings: product.launchSettings
            )
            try registerPendingSimulatorProcess(pid: pid, deviceID: udid, uri: endpoint.uri)
            succeeded = true
            return DebugSessionConnection(
                uri: endpoint.uri,
                request: .attach,
                program: nil,
                pid: pid,
                bundleId: bundleId
            )
        default:
            throw DebugSessionError.unsupportedPlatform(product.platform)
        }
    }

    private func makeSimulatorConsoleConnection(
        product: DebugProduct, launcher: any ConsoleDebuggerLaunching
    ) async throws -> DebugSessionConnection {
        guard let device = product.destinationID, let bundle = product.bundleId else {
            throw DebugSessionError.missingSimulatorUDID
        }
        let upstream = try await adapter.start()
        var console: ApplicationConsole?
        var relay: DeviceDAPRelay?
        do {
            let (pid, launched) = try await launcher.launchConsoleWaitingForDebugger(
                deviceID: device, appIdentifier: bundle, settings: product.launchSettings
            )
            console = launched
            let identity = captureLaunchedProcess(pid, device)
            let stop = stopPendingProcess
            let prepared = DeviceDAPRelay(upstream: upstream, console: launched) {
                if let identity { stop(identity) }
            }
            relay = prepared
            let endpoint = try await prepared.start()
            try Task.checkCancellation()
            liveEndpoints.append(endpoint)
            return .init(uri: endpoint.uri, request: .attach, pid: pid, bundleId: bundle)
        } catch {
            if let relay {
                await relay.close(reason: error, terminateDebuggee: true)
            } else {
                upstream.terminate()
                await console?.stop(terminateApp: true)
            }
            throw error
        }
    }

    private func registerPendingSimulatorProcess(pid: Int, deviceID: String, uri: String) throws {
        if let identity = captureLaunchedProcess(pid, deviceID) {
            pendingSimulatorProcesses[uri] = identity
        }
        if Task.isCancelled {
            if let identity = pendingSimulatorProcesses.removeValue(forKey: uri) {
                stopPendingProcess(identity)
            }
            throw CancellationError()
        }
    }

    func makeAttachConnection(identity: HostProcessIdentity) async throws -> DebugSessionConnection {
        let timing = AttachTiming.current ?? AttachTiming()
        let endpoint = try await timing.measure("lldb.start") { try await adapter.start() }
        do {
            try Task.checkCancellation()
            liveEndpoints.append(endpoint)
            return .init(uri: endpoint.uri, request: .attach, program: identity.executable, pid: identity.pid)
        } catch {
            await endpoint.stop()
            throw error
        }
    }

    func makeDeviceAttachConnection(identity: DeviceProcessIdentity) async throws -> DebugSessionConnection {
        guard let deviceSession else { throw DebugSessionError.unsupportedPlatform(.iOS) }
        let (connection, endpoint) = try await deviceSession.attach(identity: identity)
        liveEndpoints.append(endpoint)
        return connection
    }

    func didStartConnection(uri: String) {
        pendingSimulatorProcesses[uri] = nil
    }

    func stopConnection(uri: String) async {
        if let identity = pendingSimulatorProcesses.removeValue(forKey: uri) { stopPendingProcess(identity) }
        let endpoints = liveEndpoints.filter { $0.uri == uri }
        liveEndpoints.removeAll { $0.uri == uri }
        for endpoint in endpoints {
            await endpoint.stop()
        }
    }

    /// Terminate every lldb-dap we started (call on shutdown).
    public func terminateAll() async {
        let endpoints = liveEndpoints
        liveEndpoints.removeAll()
        let pending = pendingSimulatorProcesses.values
        pendingSimulatorProcesses.removeAll()
        for identity in pending {
            stopPendingProcess(identity)
        }
        for endpoint in endpoints {
            await endpoint.stop()
        }
    }
}

extension DebugProduct {
    func validate() throws {
        switch platform {
        case .macOS:
            break
        case .iOS:
            guard let destinationID, !destinationID.isEmpty else { throw DebugSessionError.missingDeviceID }
            guard let bundleId, !bundleId.isEmpty else { throw DebugSessionError.missingBundleId }
            guard let executablePath, !executablePath.isEmpty else { throw DebugSessionError.missingExecutable }
        case .iOSSimulator, .watchSimulator, .tvSimulator, .visionSimulator:
            guard let simulatorUDID, !simulatorUDID.isEmpty else {
                throw DebugSessionError.missingSimulatorUDID
            }
            guard let bundleId, !bundleId.isEmpty else { throw DebugSessionError.missingBundleId }
        default:
            throw DebugSessionError.unsupportedPlatform(platform)
        }
    }
}
