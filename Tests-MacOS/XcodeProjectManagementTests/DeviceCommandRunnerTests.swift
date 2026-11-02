import Foundation
import Support
import Testing
@testable import XcodeProjectManagement

private actor DeviceCalls {
    private(set) var arguments: [[String]] = []
    func append(_ arguments: [String]) {
        self.arguments.append(arguments)
    }
}

struct DeviceCommandRunnerTests {
    @Test
    func installsWithTheCoreDeviceCommand() async throws {
        let calls = DeviceCalls()
        let runner = DeviceCommandRunner { arguments, timeout in
            await calls.append(arguments)
            #expect(timeout == 125)
            return ProcessExecutionResult(output: "Installed", error: nil, exitCode: 0)
        }
        _ = try await DeviceInstaller(commands: runner).installApp(
            appPath: "/tmp/Hello App.app", deviceID: "PHONE", progressHandler: nil
        )
        let expected = [
            "devicectl",
            "--timeout",
            "120",
            "device",
            "install",
            "app",
            "--device",
            "PHONE",
            "/tmp/Hello App.app"
        ]
        #expect(await calls.arguments == [expected])
    }

    @Test(arguments: [false, true])
    func launchParsesJSONAndOnlyDebugWaitsForAttach(stopped: Bool) async throws {
        let runner = DeviceCommandRunner { arguments, _ in
            #expect(arguments.prefix(6) == ["devicectl", "--timeout", "60", "device", "process", "launch"])
            #expect(arguments.contains("--start-stopped") == stopped)
            #expect(arguments.contains("--terminate-existing"))
            #expect(!arguments.contains("--console"))
            let index = try #require(arguments.firstIndex(of: "--json-output"))
            try Self.launchReport.write(toFile: arguments[index + 1], atomically: true, encoding: .utf8)
            return ProcessExecutionResult(output: "Human-readable text may change", error: nil, exitCode: 0)
        }
        #expect(try await runner.launch(deviceID: "PHONE", bundleID: "com.hello.Hello", stopped: stopped) == 4321)
    }

    @Test(arguments: [
        "{}", "not JSON",
        #"{"info":{"outcome":"failed"},"result":{"process":{"processIdentifier":4321}}}"#,
        #"{"info":{"outcome":"success"},"result":{"process":{"processIdentifier":0}}}"#,
        #"{"info":{"outcome":"success"},"result":{"process":{"processIdentifier":-1}}}"#
    ])
    func invalidLaunchReportsFail(json: String) {
        #expect(throws: XcodeRunError.self) { try DeviceCommandRunner.launchPID(from: Data(json.utf8)) }
    }

    @Test
    func reportsDeviceErrorsWithTheFailedStage() async throws {
        let runner = DeviceCommandRunner { _, _ in
            ProcessExecutionResult(output: "", error: "Device needs to be unlocked", exitCode: 1)
        }
        let error = try await #require(throws: XcodeRunError.self) {
            try await runner.launch(deviceID: "PHONE", bundleID: "com.hello.Hello", stopped: true)
        }
        #expect(error.localizedDescription.contains("Launching com.hello.Hello on device PHONE"))
        #expect(error.localizedDescription.contains("Device needs to be unlocked"))
    }

    @Test
    func cancellationAfterLaunchTerminatesTheSuspendedProcess() async throws {
        let calls = DeviceCalls()
        let runner = DeviceCommandRunner { arguments, _ in
            await calls.append(arguments)
            if arguments.contains("launch") {
                let index = try #require(arguments.firstIndex(of: "--json-output"))
                try Self.launchReport.write(toFile: arguments[index + 1], atomically: true, encoding: .utf8)
                withUnsafeCurrentTask { $0?.cancel() }
                throw CancellationError()
            }
            try Task.checkCancellation()
            return ProcessExecutionResult(output: "", error: nil, exitCode: 0)
        }
        let task = Task { try await runner.launch(deviceID: "PHONE", bundleID: "com.hello.Hello", stopped: true) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await calls.arguments.last == [
            "devicectl", "--timeout", "15", "device", "process", "terminate", "--device", "PHONE",
            "--pid", "4321", "--kill"
        ])
    }

    @Test
    func resolvesTheDeviceAndLocalExecutableFromBuildSettings() throws {
        let product = try DebugProduct(buildSettings: [
            "PLATFORM_NAME": "iphoneos", "TARGET_BUILD_DIR": "/tmp/Products",
            "FULL_PRODUCT_NAME": "Hello App.app", "EXECUTABLE_PATH": "Hello App.app/CustomExecutable",
            "PRODUCT_BUNDLE_IDENTIFIER": "com.hello.Hello", "TARGET_DEVICE_IDENTIFIER": "WRONG"
        ], arguments: ["-destination", "platform=iOS,id=PHONE"])
        try product.validate()
        #expect(product.destinationID == "PHONE")
        #expect(product.binaryPath == "/tmp/Products/Hello App.app")
        #expect(product.executablePath == "/tmp/Products/Hello App.app/CustomExecutable")
    }

    private static let launchReport = #"{"info":{"outcome":"success"},"result":{"process":{"processIdentifier":4321}}}"#
}
