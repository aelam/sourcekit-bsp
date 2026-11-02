import Foundation
import Logger
import PathKit
import Support
import XcodeProj

public enum XcodeRunError: Error, LocalizedError {
    case projectNotLoaded
    case appNotFound(String)
    case simulatorNotFound(String)
    case deviceNotFound(String)
    case failedToLaunchApp(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .projectNotLoaded: "Project not loaded"
        case let .appNotFound(path): "App not found: \(path)"
        case let .simulatorNotFound(id): "Simulator not found: \(id)"
        case let .deviceNotFound(id): "Device not found: \(id)"
        case let .failedToLaunchApp(message): message
        case .cancelled: "Launch cancelled"
        }
    }
}

public struct XcodeRunResult: Sendable {
    public enum StatusCode: Int, Sendable {
        case success = 0
        case error = 1
    }

    public let statusCode: StatusCode
    public let message: String?
}

extension XcodeProjectManager {
    // swiftlint:disable:next cyclomatic_complexity
    public func run(
        xcodeTargetIdentifier: XcodeTargetIdentifier,
        arguments: [String]?, // e.g. ["-configuration", "Debug"]
        environmentVariables: [String: String]?,
        workingDirectory: URL?,
        progressHandler: (@Sendable (String) async -> Void)? = nil
    ) async -> XcodeRunResult {
        guard
            let xcodeProjectBaseInfo,
            let target = xcodeProjectBaseInfo.xcodeTargets
            .first(where: { $0.targetIdentifier == xcodeTargetIdentifier })
        else {
            return XcodeRunResult(statusCode: .error, message: "Project not loaded")
        }
        guard target.xcodeProductType.isApplication else {
            return XcodeRunResult(statusCode: .error, message: "Running requires an application target: \(target.name)")
        }

        await progressHandler?("Resolving build settings for \(target.name)")
        let buildSettings: [String: String]
        do {
            buildSettings = try await resolvedBuildSettings(for: target, arguments: arguments)
        } catch {
            return XcodeRunResult(
                statusCode: .error,
                message: "Failed to resolve build settings: \(error.localizedDescription)"
            )
        }

        guard
            let platformName = buildSettings["PLATFORM_NAME"],
            let sdk = XcodeSDK(rawValue: platformName)
        else {
            return XcodeRunResult(statusCode: .error, message: "PLATFORM_NAME not found in build settings")
        }

        guard let appIdentifier = buildSettings["PRODUCT_BUNDLE_IDENTIFIER"] ?? buildSettings["APP_IDENTIFIER"] else {
            return XcodeRunResult(statusCode: .error, message: "Bundle identifier not found in build settings")
        }

        guard let binaryPath = getOutputPath(
            buildSettings: buildSettings,
            productType: target.xcodeProductType,
            isMacApp: sdk == .macOS
        ) else {
            return XcodeRunResult(
                statusCode: .error,
                message: "App binary not found for target \(xcodeTargetIdentifier.rawValue)"
            )
        }
        await progressHandler?("Checking build product: \(binaryPath)")
        logger.info("Binary path: \(binaryPath)")
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            return XcodeRunResult(
                statusCode: .error,
                message: "Build product not found: \(binaryPath). Compile this target with the same configuration and destination first."
            )
        }
        if sdk == .macOS {
            logger.info("Running on macOS")
            do {
                await progressHandler?("Running \(target.name) on macOS; waiting for the app to exit")
                let result = try await runOnMac(binaryPath: binaryPath)
                await progressHandler?("App exited with code \(result.exitCode)")
                return XcodeRunResult(
                    statusCode: .init(rawValue: Int(result.exitCode)) ?? .error,
                    message: result.output
                )
            } catch {
                return XcodeRunResult(
                    statusCode: .error,
                    message: "Failed to run on macOS: \(error.localizedDescription)"
                )
            }
        }

        guard let destinationID = getDestination(from: arguments, buildSettings: buildSettings) else {
            return XcodeRunResult(
                statusCode: .error,
                message: "Destination ID not found. Please specify -destination id=XXXX in arguments"
            )
        }

        if sdk == .iOS || sdk == .tvOS || sdk == .watchOS {
            // real device
            do {
                try await installOnNonMac(
                    isSimulator: false, outputPath: binaryPath, deviceID: destinationID,
                    progressHandler: progressHandler
                )
                await progressHandler?("Launching \(target.name) on device \(destinationID)")
                try await launchAppOnNonMac(isSimulator: false, deviceID: destinationID, appIdentifier: appIdentifier)
                await progressHandler?("App launched on device \(destinationID)")
                return XcodeRunResult(
                    statusCode: .success,
                    message: "App launched on device \(destinationID)"
                )
            } catch {
                return XcodeRunResult(
                    statusCode: .error,
                    message: "Failed to launch on device: \(error.localizedDescription)"
                )
            }
        } else if sdk == .iOSSimulator || sdk == .tvSimulator || sdk == .watchSimulator {
            // simulator
            do {
                try await installOnNonMac(
                    isSimulator: true, outputPath: binaryPath, deviceID: destinationID,
                    progressHandler: progressHandler
                )
                await progressHandler?("Launching \(target.name) on simulator \(destinationID)")
                try await launchAppOnNonMac(isSimulator: true, deviceID: destinationID, appIdentifier: appIdentifier)
                await progressHandler?("App launched on simulator \(destinationID)")
                return XcodeRunResult(
                    statusCode: .success,
                    message: "App launched on simulator \(destinationID)"
                )
            } catch {
                return XcodeRunResult(
                    statusCode: .error,
                    message: "Failed to launch on simulator: \(error.localizedDescription)"
                )
            }
        } else {
            return XcodeRunResult(
                statusCode: .error,
                message: "error: Unsupported SDK \(sdk.rawValue) for running apps"
            )
        }
    }

    func getOutputPath(
        buildSettings: [String: String],
        productType: XcodeProductType,
        isMacApp: Bool = true
    ) -> String? {
        if let buildDir = buildSettings["TARGET_BUILD_DIR"],
           let productPath = buildSettings[isMacApp ? "EXECUTABLE_PATH" : "FULL_PRODUCT_NAME"],
           !productPath.isEmpty {
            return URL(fileURLWithPath: buildDir).appendingPathComponent(productPath).path
        }
        guard
            let buildDir = buildSettings["CONFIGURATION_BUILD_DIR"],
            let productName = buildSettings["PRODUCT_NAME"]
        else {
            return nil
        }

        let components: [String] = if let fileExtension = productType.fileExtension {
            if isMacApp {
                [
                    buildDir,
                    productName + "." + fileExtension,
                    isMacApp ? "Contents/MacOS" : "Contents/Resources",
                    productName
                ]
            } else {
                [
                    buildDir,
                    productName + "." + fileExtension
                ]
            }
        } else {
            [
                buildDir,
                productName
            ]
        }

        return components.joined(separator: "/")
    }

    func getDestination(from arguments: [String]?, buildSettings: [String: String]) -> String? {
        var destinationID = buildSettings["TARGET_DEVICE_IDENTIFIER"]
        if let arguments,
           let index = arguments.firstIndex(of: "-destination"),
           index < arguments.count - 1 {
            for component in arguments[index + 1].split(separator: ",") {
                let pair = component.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if pair.count == 2, pair[0] == "id" { destinationID = pair[1] }
            }
        }
        guard let destinationID, !destinationID.isEmpty, !destinationID.contains("placeholder") else { return nil }
        return destinationID
    }

    // MARK: - Run on Mac

    private func runOnMac(binaryPath: String) async throws -> ProcessExecutionResult {
        let executor = ProcessExecutor()
        return try await executor.execute(
            executable: binaryPath,
            arguments: [],
            workingDirectory: nil,
            environment: [:]
        )
    }

    // MARK: simulators / real device

    func installOnNonMac(
        isSimulator: Bool,
        outputPath: String,
        deviceID: String,
        progressHandler: (@Sendable (String) async -> Void)? = nil
    ) async throws {
        let installer: AppInstaller = isSimulator ? SimulatorInstaller() : DeviceInstaller()
        _ = try await installer.installApp(
            appPath: outputPath,
            deviceID: deviceID,
            progressHandler: progressHandler
        )
    }

    private func launchAppOnNonMac(isSimulator: Bool, deviceID: String, appIdentifier: String) async throws {
        let launcher: AppLauncher = isSimulator ? SimulatorLauncher() : DeviceLauncher()
        _ = try await launcher.launchApp(
            deviceID: deviceID,
            appIdentifier: appIdentifier
        )
    }
}
