import BuildServerProtocol
import Foundation
import Logger

public extension XcodeProjectManager {
    func startDebugSession(
        xcodeTargetIdentifier: XcodeTargetIdentifier,
        arguments: [String]?,
        outputHandler: ProcessOutputHandler? = nil,
        progressHandler: (@Sendable (String) async -> Void)? = nil
    ) async throws -> DebugSessionConnection {
        if let target = projectSnapshot?.xcodeTargets.first(where: {
            $0.targetIdentifier == xcodeTargetIdentifier && $0.xcodeProductType.isTestBundle
        }) {
            return try await startTestDebugSession(
                target: target,
                arguments: arguments,
                progressHandler: progressHandler
            )
        }
        let product = try await prepareDebugProduct(
            xcodeTargetIdentifier: xcodeTargetIdentifier,
            arguments: arguments,
            progressHandler: progressHandler
        )

        try Task.checkCancellation()
        if product.platform.isSimulator || product.platform == .iOS {
            guard let id = product.destinationID else { throw DebugSessionError.missingDeviceID }
            try await installOnNonMac(
                isSimulator: product.platform.isSimulator,
                outputPath: product.binaryPath,
                deviceID: id,
                progressHandler: progressHandler
            )
        }

        return try await getDebugSessionManager().makeConnection(for: product, progressHandler: progressHandler)
    }

    internal func prepareDebugProduct(
        xcodeTargetIdentifier: XcodeTargetIdentifier,
        arguments: [String]?,
        progressHandler: (@Sendable (String) async -> Void)? = nil
    ) async throws -> DebugProduct {
        try Task.checkCancellation()
        await progressHandler?("Resolving debug build settings")
        let product = try await resolveDebugProduct(
            xcodeTargetIdentifier: xcodeTargetIdentifier, arguments: arguments
        )
        try product.validate()
        await progressHandler?("Using existing build product: \(product.binaryPath)")

        guard FileManager.default.fileExists(atPath: product.binaryPath) else {
            throw DebugSessionError.productNotFound(product.binaryPath)
        }
        if let executable = product.executablePath,
           !FileManager.default.fileExists(atPath: executable) {
            throw DebugSessionError.productNotFound(executable)
        }

        try Task.checkCancellation()
        return product
    }

    internal func getDebugSessionManager() throws -> DebugSessionManager {
        let manager: DebugSessionManager
        if let existing = debugSessionManager {
            manager = existing
        } else {
            guard let base = projectSnapshot else { throw DebugSessionError.buildFailed }
            let adapter = LLDBDAPServer(developerDirectory: base.xcodeInstallation.developerDir)
            manager = DebugSessionManager(
                adapter: adapter,
                simulatorLauncher: SimulatorDebugLauncher(developerDirectory: base.xcodeInstallation.developerDir),
                deviceSession: DeviceDebugSession(
                    commands: DeviceCommandRunner(developerDirectory: base.xcodeInstallation.developerDir),
                    adapter: adapter
                )
            )
            debugSessionManager = manager
        }
        return manager
    }

    func stopDebugSessions() async {
        await debugSessionManager?.terminateAll()
        debugSessionManager = nil
    }

    internal func resolveDebugProduct(
        xcodeTargetIdentifier: XcodeTargetIdentifier,
        arguments: [String]?
    ) async throws -> DebugProduct {
        guard let base = projectSnapshot,
              let target = base.xcodeTargets.first(where: { $0.targetIdentifier == xcodeTargetIdentifier }) else {
            throw DebugSessionError.buildFailed
        }
        guard target.xcodeProductType.isApplication else {
            throw DebugSessionError.unsupportedProduct(target.name)
        }
        let buildSettings = try await resolvedBuildSettings(for: target, arguments: arguments)
        let settings = try launchSettings(
            for: target, arguments: arguments, buildSettings: buildSettings
        )
        return try DebugProduct(buildSettings: buildSettings, arguments: arguments ?? [], launchSettings: settings)
    }
}

extension DebugProduct {
    init(
        buildSettings: [String: String], arguments: [String], launchSettings: XcodeLaunchSettings = .init()
    ) throws {
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
            destinationID: destinationID,
            executablePath: buildSettings["EXECUTABLE_PATH"].flatMap {
                $0.isEmpty ? nil : URL(fileURLWithPath: buildDirectory).appendingPathComponent($0).path
            },
            launchSettings: launchSettings
        )
    }
}
