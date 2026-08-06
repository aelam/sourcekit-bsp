import BuildServerProtocol
import Foundation
import Logger

/// The build product to debug, resolved from a target.
public struct DebugProduct: Sendable {
    public let platform: Platform
    public let binaryPath: String // macOS: executable; simulator: .app path
    public let bundleId: String?
    public let simulatorUDID: String?

    public init(platform: Platform, binaryPath: String, bundleId: String?, simulatorUDID: String?) {
        self.platform = platform
        self.binaryPath = binaryPath
        self.bundleId = bundleId
        self.simulatorUDID = simulatorUDID
    }
}

public enum DebugSessionError: Error, LocalizedError {
    case buildFailed
    case missingBundleId
    case missingSimulatorUDID
    case unsupportedPlatform(Platform)

    public var errorDescription: String? {
        switch self {
        case .buildFailed: "Build failed before starting the debug session"
        case .missingBundleId: "Could not resolve the app's bundle identifier"
        case .missingSimulatorUDID: "No simulator destination selected"
        case let .unsupportedPlatform(p): "Debugging is not supported for platform \(p.rawValue)"
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
    private var liveEndpoints: [DebugAdapterEndpoint] = []

    public init(adapter: DebugAdapterServing, simulatorLauncher: WaitForDebuggerLaunching) {
        self.adapter = adapter
        self.simulatorLauncher = simulatorLauncher
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
    func makeConnection(for product: DebugProduct) async throws -> DebugSessionConnection {
        let endpoint = try await adapter.start()
        liveEndpoints.append(endpoint)

        switch product.platform {
        case .macOS:
            return DebugSessionConnection(
                uri: endpoint.uri, request: .launch,
                program: product.binaryPath, pid: nil, bundleId: product.bundleId
            )
        case .iOSSimulator, .watchSimulator, .tvSimulator, .visionSimulator:
            guard let udid = product.simulatorUDID else { throw DebugSessionError.missingSimulatorUDID }
            guard let bundleId = product.bundleId else { throw DebugSessionError.missingBundleId }
            let pid = try await simulatorLauncher.launchWaitingForDebugger(
                deviceID: udid, appIdentifier: bundleId
            )
            return DebugSessionConnection(
                uri: endpoint.uri, request: .attach,
                program: nil, pid: pid, bundleId: bundleId
            )
        default:
            throw DebugSessionError.unsupportedPlatform(product.platform)
        }
    }

    /// Terminate every lldb-dap we started (call on shutdown).
    public func terminateAll() {
        for endpoint in liveEndpoints {
            endpoint.terminate()
        }
        liveEndpoints.removeAll()
    }
}
