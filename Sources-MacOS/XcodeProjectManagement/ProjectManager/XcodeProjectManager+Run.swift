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
            let projectSnapshot,
            let target = projectSnapshot.xcodeTargets
            .first(where: { $0.targetIdentifier == xcodeTargetIdentifier })
        else {
            return XcodeRunResult(statusCode: .error, message: "Project not loaded")
        }
        guard target.xcodeProductType.isApplication else {
            return XcodeRunResult(statusCode: .error, message: "Running requires an application target: \(target.name)")
        }

        await progressHandler?("Resolving build settings for \(target.name)")
        let buildSettings: [String: String]
        var settings: XcodeLaunchSettings
        do {
            buildSettings = try await resolvedBuildSettings(for: target, arguments: arguments)
            settings = try launchSettings(for: target, arguments: arguments, buildSettings: buildSettings)
            settings.environment.merge(environmentVariables ?? [:]) { _, new in new }
            if let workingDirectory { settings.workingDirectory = workingDirectory.path }
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
                message: "Build product not found: \(binaryPath). " +
                    "Compile this target with the same configuration and destination first."
            )
        }
        if sdk == .macOS {
            logger.info("Running on macOS")
            return await runOnMac(
                binaryPath: binaryPath, settings: settings, targetName: target.name, progressHandler: progressHandler
            )
        }

        guard let destinationID = getDestination(from: arguments, buildSettings: buildSettings) else {
            return XcodeRunResult(
                statusCode: .error,
                message: "Destination ID not found. Please specify -destination id=XXXX in arguments"
            )
        }

        let isSimulator: Bool
        if sdk == .iOS || sdk == .tvOS || sdk == .watchOS {
            isSimulator = false
        } else if sdk == .iOSSimulator || sdk == .tvSimulator || sdk == .watchSimulator {
            isSimulator = true
        } else {
            return XcodeRunResult(
                statusCode: .error,
                message: "error: Unsupported SDK \(sdk.rawValue) for running apps"
            )
        }
        let destinationKind = isSimulator ? "simulator" : "device"
        do {
            try await installOnNonMac(
                isSimulator: isSimulator,
                outputPath: binaryPath,
                deviceID: destinationID,
                progressHandler: progressHandler
            )
            await progressHandler?("Launching \(target.name) on \(destinationKind) \(destinationID)")
            let code = try await runAppOnNonMac(
                isSimulator: isSimulator,
                deviceID: destinationID,
                appIdentifier: appIdentifier,
                executableName: buildSettings["EXECUTABLE_NAME"] ?? URL(fileURLWithPath: binaryPath)
                    .deletingPathExtension().lastPathComponent,
                settings: settings,
                progressHandler: progressHandler
            )
            await progressHandler?("App exited with code \(code)")
            return XcodeRunResult(statusCode: code == 0 ? .success : .error, message: "App exited with code \(code)")
        } catch {
            return XcodeRunResult(
                statusCode: .error,
                message: "Failed to launch on \(destinationKind): \(error.localizedDescription)"
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

    private func runOnMac(
        binaryPath: String,
        settings: XcodeLaunchSettings,
        targetName: String,
        progressHandler: (@Sendable (String) async -> Void)?
    ) async -> XcodeRunResult {
        do {
            await progressHandler?("Running \(targetName) on macOS; waiting for the app to exit")
            let console = try ApplicationConsole(
                executable: binaryPath,
                arguments: settings.arguments,
                environment: settings.consoleEnvironment,
                workingDirectory: settings.workingDirectory.map { URL(fileURLWithPath: $0) }
            )
            await console.output.connect { await progressHandler?($0.runMessage) }
            let code = try await console.wait()
            await progressHandler?("App exited with code \(code)")
            return XcodeRunResult(
                statusCode: code == 0 ? .success : .error,
                message: "App exited with code \(code)"
            )
        } catch {
            return XcodeRunResult(
                statusCode: .error,
                message: "Failed to run on macOS: \(error.localizedDescription)"
            )
        }
    }

    // MARK: simulators / real device

    func installOnNonMac(
        isSimulator: Bool,
        outputPath: String,
        deviceID: String,
        progressHandler: (@Sendable (String) async -> Void)? = nil
    ) async throws {
        let commands = DeviceCommandRunner(developerDirectory: projectSnapshot?.xcodeInstallation.developerDir)
        let installer: AppInstaller = isSimulator
            ?
            SimulatorInstaller(commands: SimulatorCommandRunner(developerDirectory: projectSnapshot?
                    .xcodeInstallation.developerDir))
            : DeviceInstaller(commands: commands)
        _ = try await installer.installApp(
            appPath: outputPath,
            deviceID: deviceID,
            progressHandler: progressHandler
        )
    }

    private func runAppOnNonMac(
        isSimulator: Bool, deviceID: String, appIdentifier: String, executableName: String,
        settings: XcodeLaunchSettings,
        progressHandler: (@Sendable (String) async -> Void)?
    ) async throws -> Int32 {
        let developerDirectory = projectSnapshot?.xcodeInstallation.developerDir
        let console: ApplicationConsole
        let commands = DeviceCommandRunner(developerDirectory: developerDirectory)
        var devicePID: Int?
        if isSimulator {
            let commands = SimulatorCommandRunner(developerDirectory: developerDirectory)
            console = try commands.launchConsole(deviceID: deviceID, appIdentifier: appIdentifier, settings: settings)
        } else {
            let launched = try await commands.launchConsole(
                deviceID: deviceID, bundleID: appIdentifier, localExecutable: executableName,
                settings: settings, stopped: false, outputHandler: { await progressHandler?($0.runMessage) }
            )
            console = launched.console
            devicePID = launched.pid
        }
        await console.output.connect { await progressHandler?($0.runMessage) }
        do {
            if isSimulator { _ = try await console.waitForSimulatorLaunch() }
            return try await console.wait()
        } catch {
            let pid = devicePID
            await Task.detached {
                if let pid { await commands.terminate(deviceID: deviceID, pid: pid) }
                await console.stop(terminateApp: true)
            }.value
            throw error
        }
    }
}
