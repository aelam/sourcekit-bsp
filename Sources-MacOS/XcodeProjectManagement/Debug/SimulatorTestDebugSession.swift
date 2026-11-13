import Foundation
import SourceKitBSPProtocol
import Support

struct SimulatorTestDebugProduct: Sendable {
    let hostApp: URL
    let testBundleName: String
    let productsDirectory: URL
    let destinationID: String

    init(settings: [String: String], arguments: [String]) throws {
        guard settings["PLATFORM_NAME"] == "iphonesimulator" else {
            throw XcodeProjectError.invalidConfig("Test debugging currently requires an iOS simulator destination")
        }
        guard let host = settings["TEST_HOST"], !host.isEmpty,
              let bundle = settings["FULL_PRODUCT_NAME"], bundle.hasSuffix(".xctest"),
              URL(fileURLWithPath: bundle).lastPathComponent == bundle,
              let products = settings["BUILT_PRODUCTS_DIR"], !products.isEmpty else {
            throw XcodeProjectError.invalidConfig("Test debugging requires an app-hosted unit test target")
        }
        let app = URL(fileURLWithPath: host).deletingLastPathComponent()
        guard app.pathExtension == "app" else {
            throw XcodeProjectError.invalidConfig("Cannot resolve the test host app from TEST_HOST")
        }
        let destination = try DebugProduct(buildSettings: settings, arguments: arguments).destinationID
        guard let destination, !destination.isEmpty else { throw DebugSessionError.missingSimulatorUDID }
        self.hostApp = app
        self.testBundleName = bundle
        self.productsDirectory = URL(fileURLWithPath: products)
        self.destinationID = destination
    }

    func debugProduct() throws -> DebugProduct {
        let testBundle = hostApp.appendingPathComponent("PlugIns").appendingPathComponent(testBundleName)
        guard FileManager.default.fileExists(atPath: testBundle.path) else {
            throw DebugSessionError.productNotFound(testBundle.path)
        }
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: hostApp.appendingPathComponent("Info.plist")), format: nil
        ) as? [String: Any]
        guard let bundleID = info?["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            throw DebugSessionError.missingBundleId
        }
        return DebugProduct(
            platform: .iOSSimulator,
            binaryPath: hostApp.path,
            bundleId: bundleID,
            simulatorUDID: destinationID
        )
    }
}

struct SimulatorTestDebugLauncher: WaitForDebuggerLaunching {
    typealias Execute = @Sendable ([String], [String: String]) async throws -> ProcessExecutionResult

    let product: SimulatorTestDebugProduct
    let developerDirectory: URL
    var execute: Execute = { arguments, environment in
        try await ProcessExecutor().execute(
            executable: "/usr/bin/xcrun", arguments: arguments, environment: environment, timeout: 90
        )
    }

    func launchWaitingForDebugger(deviceID: String, appIdentifier: String) async throws -> Int {
        let environment = ["DEVELOPER_DIR": developerDirectory.path]
        let app = try await run(["simctl", "get_app_container", deviceID, appIdentifier, "app"], environment)
        let data = try await run(["simctl", "get_app_container", deviceID, appIdentifier, "data"], environment)
        let childEnvironment = try Self.environment(
            appPath: app.output.trimmingCharacters(in: .whitespacesAndNewlines),
            dataPath: data.output.trimmingCharacters(in: .whitespacesAndNewlines),
            product: product,
            developerDirectory: developerDirectory
        )
        let result = try await run(
            ["simctl", "launch", "--terminate-running-process", "--wait-for-debugger", deviceID, appIdentifier],
            environment.merging(childEnvironment) { _, new in new }
        )
        guard let pid = SimulatorDebugLauncher.parsePID(from: result.output) else {
            throw XcodeRunError.failedToLaunchApp("The test host did not return a process ID")
        }
        return pid
    }

    static func environment(
        appPath: String, dataPath: String, product: SimulatorTestDebugProduct, developerDirectory: URL
    ) throws -> [String: String] {
        guard appPath.hasPrefix("/"), dataPath.hasPrefix("/") else {
            throw XcodeRunError.failedToLaunchApp("The simulator did not return valid test host container paths")
        }
        let app = URL(fileURLWithPath: appPath)
        let platform = developerDirectory.appendingPathComponent("Platforms/iPhoneSimulator.platform/Developer")
        return [
            "SIMCTL_CHILD_XCTestBundlePath": app.appendingPathComponent("PlugIns/\(product.testBundleName)").path,
            "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": app.appendingPathComponent("Frameworks/libXCTestBundleInject.dylib")
                .path,
            "SIMCTL_CHILD_DYLD_FRAMEWORK_PATH": [
                app.appendingPathComponent("Frameworks").path, product.productsDirectory.path,
                platform.appendingPathComponent("Library/Frameworks").path,
                platform.appendingPathComponent("Library/PrivateFrameworks").path
            ].joined(separator: ":"),
            "SIMCTL_CHILD_DYLD_LIBRARY_PATH": [
                product.productsDirectory.path, platform.appendingPathComponent("usr/lib").path
            ].joined(separator: ":"),
            "SIMCTL_CHILD_LLVM_PROFILE_FILE": URL(fileURLWithPath: dataPath)
                .appendingPathComponent("tmp/sourcekit-bsp-test-debug-%p.profraw").path
        ]
    }

    private func run(_ arguments: [String], _ environment: [String: String]) async throws -> ProcessExecutionResult {
        let result = try await execute(arguments, environment)
        guard result.isSuccess else {
            throw XcodeRunError.failedToLaunchApp(result.error ?? result.output)
        }
        return result
    }
}

extension XcodeProjectManager {
    func startTestDebugSession(
        target: XcodeTarget, arguments: [String]?,
        progressHandler: (@Sendable (String) async -> Void)?
    ) async throws -> DebugSessionConnection {
        guard target.xcodeProductType == .unitTestBundle, let base = projectSnapshot else {
            throw XcodeProjectError
                .invalidConfig("Test debugging currently supports app-hosted unit tests on iOS simulators")
        }
        let unsupportedOptions = [
            "-only-testing", "-skip-testing", "-testPlan", "-only-test-configuration", "-skip-test-configuration"
        ]
        if (arguments ?? []).contains(where: { argument in
            unsupportedOptions.contains { argument.hasPrefix($0) }
        }) {
            throw XcodeProjectError
                .invalidConfig("Debug Tests runs the entire test target; test filters and test plans are not supported")
        }
        await progressHandler?("Resolving test host and simulator")
        let arguments = try testArguments(for: target, arguments: arguments)
        let settings = try await resolvedBuildSettings(for: target, arguments: arguments)
        let testProduct = try SimulatorTestDebugProduct(settings: settings, arguments: arguments)
        await progressHandler?("Using existing test host: \(testProduct.hostApp.path)")
        try Task.checkCancellation()
        let product = try testProduct.debugProduct()
        try await installOnNonMac(
            isSimulator: true,
            outputPath: product.binaryPath,
            deviceID: testProduct.destinationID,
            progressHandler: progressHandler
        )
        await progressHandler?("Launching test host; tests will wait for the debugger")
        let launcher = SimulatorTestDebugLauncher(
            product: testProduct,
            developerDirectory: base.xcodeInstallation.developerDir
        )
        return try await getDebugSessionManager().makeConnection(
            for: product,
            progressHandler: progressHandler,
            launcher: launcher
        )
    }
}
