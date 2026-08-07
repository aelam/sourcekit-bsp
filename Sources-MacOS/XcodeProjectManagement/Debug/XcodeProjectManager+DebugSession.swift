import BuildServerProtocol
import Foundation
import Logger

public extension XcodeProjectManager {
    /// Build the target for Debug, resolve its product, (simulator only) install
    /// it, then start an lldb-dap endpoint and return how the client should
    /// attach. macOS → launch a program; simulator → attach to a PID.
    func startDebugSession(
        xcodeTargetIdentifier: XcodeTargetIdentifier,
        arguments: [String]?
    ) async throws -> DebugSessionConnection {
        // 1. Build (Debug). The compile path injects a platform-correct destination.
        // Pass configuration: nil — the `-configuration` flag is already in
        // `arguments`. Passing it here too would duplicate `-configuration` on
        // the xcodebuild command line (which xcodebuild rejects with exit 64).
        let exitCode = try await compileTarget(
            targetIdentifier: xcodeTargetIdentifier,
            configuration: nil,
            arguments: arguments
        )
        guard exitCode == 0 else { throw DebugSessionError.buildFailed }

        // 2. Resolve the product to debug.
        let product = try resolveDebugProduct(xcodeTargetIdentifier: xcodeTargetIdentifier, arguments: arguments)

        // 3. Simulator: install the freshly built .app before launching. macOS
        //    needs no install — lldb launches the binary directly.
        if product.platform.isSimulator {
            guard let udid = product.simulatorUDID else { throw DebugSessionError.missingSimulatorUDID }
            try await installOnNonMac(isSimulator: true, outputPath: product.binaryPath, deviceID: udid)
        }

        // 4. Start lldb-dap + (simulator) launch --wait-for-debugger.
        // TODO(debug-followup): the manager is created per request and not
        // retained, so `terminateAll()` is not yet wired to build/shutdown. The
        // lldb-dap process is torn down when the client disconnects the DAP
        // socket. Retaining sessions for explicit stop/cancel is a follow-up.
        let manager = DebugSessionManager(
            adapter: LLDBDAPServer(),
            simulatorLauncher: SimulatorDebugLauncher()
        )
        return try await manager.makeConnection(for: product)
    }

    private func resolveDebugProduct(
        xcodeTargetIdentifier: XcodeTargetIdentifier,
        arguments: [String]?
    ) throws -> DebugProduct {
        guard
            let base = xcodeProjectBaseInfo,
            let target = base.xcodeTargets.first(where: { $0.targetIdentifier == xcodeTargetIdentifier }),
            let xcodeProj = loadXcodeProjCache(
                projectURL: URL(fileURLWithPath: xcodeTargetIdentifier.projectFilePath)
            )
        else {
            throw DebugSessionError.buildFailed
        }

        let buildSettings = try BuildSettingResolver(
            xcodeInstallation: base.xcodeInstallation,
            xcodeGlobalSettings: base.xcodeGlobalSettings,
            xcodeProj: xcodeProj,
            target: xcodeTargetIdentifier.targetName,
            configuration: debugConfiguration(from: arguments)
        ).resolvedBuildSettings

        guard
            let platformName = buildSettings["PLATFORM_NAME"],
            let platform = Platform(rawValue: platformName)
        else {
            throw DebugSessionError.unresolvedPlatform
        }

        guard let binaryPath = getOutputPath(
            buildSettings: buildSettings,
            productType: target.xcodeProductType,
            isMacApp: platform == .macOS
        ) else {
            throw DebugSessionError.buildFailed
        }

        return DebugProduct(
            platform: platform,
            binaryPath: binaryPath,
            bundleId: buildSettings["PRODUCT_BUNDLE_IDENTIFIER"] ?? buildSettings["APP_IDENTIFIER"],
            simulatorUDID: debugDestinationID(from: arguments)
        )
    }

    private func debugConfiguration(from arguments: [String]?) -> String {
        if let arguments,
           let index = arguments.firstIndex(of: "-configuration"),
           index < arguments.count - 1 {
            arguments[index + 1]
        } else {
            xcodeProjectBaseInfo?.configuration ?? "Debug"
        }
    }

    /// Extract the simulator UDID from a `-destination id=<udid>` argument.
    private func debugDestinationID(from arguments: [String]?) -> String? {
        guard let arguments,
              let index = arguments.firstIndex(of: "-destination"),
              index < arguments.count - 1 else {
            return nil
        }
        let destination = arguments[index + 1]
        return destination.hasPrefix("id=") ? String(destination.dropFirst(3)) : nil
    }
}
