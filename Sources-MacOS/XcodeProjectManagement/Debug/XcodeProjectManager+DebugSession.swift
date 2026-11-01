import BuildServerProtocol
import Foundation
import Logger

public extension XcodeProjectManager {
    func startDebugSession(
        xcodeTargetIdentifier: XcodeTargetIdentifier,
        arguments: [String]?
    ) async throws -> DebugSessionConnection {
        let product = try await resolveDebugProduct(
            xcodeTargetIdentifier: xcodeTargetIdentifier, arguments: arguments
        )
        try product.validate()
        let exitCode = try await compileTarget(
            targetIdentifier: xcodeTargetIdentifier,
            configuration: nil,
            arguments: arguments
        )
        guard exitCode == 0 else { throw DebugSessionError.buildFailed }

        guard FileManager.default.fileExists(atPath: product.binaryPath) else {
            throw DebugSessionError.productNotFound(product.binaryPath)
        }

        if product.platform.isSimulator {
            guard let udid = product.simulatorUDID else { throw DebugSessionError.missingSimulatorUDID }
            try await installOnNonMac(isSimulator: true, outputPath: product.binaryPath, deviceID: udid)
        }

        let manager: DebugSessionManager
        if let existing = debugSessionManager {
            manager = existing
        } else {
            guard let base = xcodeProjectBaseInfo else { throw DebugSessionError.buildFailed }
            manager = DebugSessionManager(
                adapter: LLDBDAPServer(developerDirectory: base.xcodeInstallation.developerDir),
                simulatorLauncher: SimulatorDebugLauncher()
            )
            debugSessionManager = manager
        }
        return try await manager.makeConnection(for: product)
    }

    func stopDebugSessions() async {
        await debugSessionManager?.terminateAll()
        debugSessionManager = nil
    }

    internal func resolveDebugProduct(
        xcodeTargetIdentifier: XcodeTargetIdentifier,
        arguments: [String]?
    ) async throws -> DebugProduct {
        guard let base = xcodeProjectBaseInfo,
              let target = base.xcodeTargets.first(where: { $0.targetIdentifier == xcodeTargetIdentifier }) else {
            throw DebugSessionError.buildFailed
        }
        guard target.xcodeProductType.isApplication else {
            throw DebugSessionError.unsupportedProduct(target.name)
        }
        let buildSettings = try await resolvedBuildSettings(for: target, arguments: arguments)
        return try DebugProduct(buildSettings: buildSettings, arguments: arguments ?? [])
    }
}

extension DebugProduct {
    init(buildSettings: [String: String], arguments: [String]) throws {
        guard let platformName = buildSettings["PLATFORM_NAME"],
              let platform = Platform(rawValue: platformName) else {
            throw DebugSessionError.unresolvedPlatform
        }
        guard let buildDirectory = buildSettings["TARGET_BUILD_DIR"],
              let relativePath = buildSettings[platform == .macOS ? "EXECUTABLE_PATH" : "FULL_PRODUCT_NAME"],
              !relativePath.isEmpty else {
            throw DebugSessionError.buildFailed
        }

        var destinationID = buildSettings["TARGET_DEVICE_IDENTIFIER"]
        if let index = arguments.firstIndex(of: "-destination"), index + 1 < arguments.count {
            for component in arguments[index + 1].split(separator: ",") {
                let pair = component.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if pair.count == 2, pair[0] == "id" { destinationID = pair[1] }
            }
        }
        if destinationID?.contains("placeholder") == true { destinationID = nil }
        self.init(
            platform: platform,
            binaryPath: URL(fileURLWithPath: buildDirectory).appendingPathComponent(relativePath).path,
            bundleId: buildSettings["PRODUCT_BUNDLE_IDENTIFIER"],
            simulatorUDID: destinationID
        )
    }
}
