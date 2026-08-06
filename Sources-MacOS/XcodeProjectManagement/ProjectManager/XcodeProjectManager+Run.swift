import Foundation
import Logger
import PathKit
import Support
import XcodeProj

enum XcodeRunError: Error {
    case projectNotLoaded
    case appNotFound(String)
    case simulatorNotFound(String)
    case deviceNotFound(String)
    case failedToLaunchApp(String)
    case cancelled
}

public struct XcodeRunResult {
    public enum StatusCode: Int {
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
        workingDirectory: URL?
    ) async -> XcodeRunResult {
        guard
            let xcodeProjectBaseInfo,
            let target = xcodeProjectBaseInfo.xcodeTargets
            .first(where: { $0.targetIdentifier == xcodeTargetIdentifier }),
            let xcodeProj = loadXcodeProjCache(projectURL: URL(fileURLWithPath: xcodeTargetIdentifier.projectFilePath))
        else {
            return XcodeRunResult(statusCode: .error, message: "Project not loaded")
        }
        let configuration = getConfiguration(from: arguments)

        let buildSettings: [String: String]
        do {
            buildSettings = try BuildSettingResolver(
                xcodeInstallation: xcodeProjectBaseInfo.xcodeInstallation,
                xcodeGlobalSettings: xcodeProjectBaseInfo.xcodeGlobalSettings,
                xcodeProj: xcodeProj,
                target: xcodeTargetIdentifier.targetName,
                configuration: configuration
            ).resolvedBuildSettings
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

        logger.info("Build settings loaded., \(buildSettings)")
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
        logger.info("Binary path: \(binaryPath)")
        if sdk == .macOS {
            logger.info("Running on macOS")
            do {
                let result = try await runOnMac(binaryPath: binaryPath)
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

        guard let destinationID = getDestination(from: arguments) else {
            return XcodeRunResult(
                statusCode: .error,
                message: "Destination ID not found. Please specify -destination id=XXXX in arguments"
            )
        }

        if sdk == .iOS || sdk == .tvOS || sdk == .watchOS {
            // real device
            do {
                try await installOnNonMac(isSimulator: false, outputPath: binaryPath, deviceID: destinationID)
                try await launchAppOnNonMac(isSimulator: false, deviceID: destinationID, appIdentifier: appIdentifier)
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
                try await installOnNonMac(isSimulator: true, outputPath: binaryPath, deviceID: destinationID)
                try await launchAppOnNonMac(isSimulator: true, deviceID: destinationID, appIdentifier: appIdentifier)
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

    private func getConfiguration(from arguments: [String]?) -> String {
        if let arguments,
           let index = arguments.firstIndex(of: "-configuration"),
           index < arguments.count - 1 {
            arguments[index + 1]
        } else if let configuration = xcodeProjectBaseInfo?.configuration {
            configuration
        } else {
            "Debug"
        }
    }

    private func getDestination(from arguments: [String]?) -> String? {
        if let arguments,
           let index = arguments.firstIndex(of: "-destination"),
           index < arguments.count - 1 {
            let destination = arguments[index + 1]
            if destination.starts(with: "id=") {
                return String(destination.dropFirst(3))
            }
            return nil
        }
        return nil
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

    func installOnNonMac(isSimulator: Bool, outputPath: String, deviceID: String) async throws {
        let installer: AppInstaller = isSimulator ? SimulatorInstaller() : DeviceInstaller()
        _ = try await installer.installApp(
            appPath: outputPath,
            deviceID: deviceID
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
