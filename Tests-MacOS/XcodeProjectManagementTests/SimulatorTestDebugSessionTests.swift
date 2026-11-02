import Foundation
import Support
import Testing
@testable import XcodeProjectManagement

struct SimulatorTestDebugSessionTests {
    private func settings() -> [String: String] {
        [
            "PLATFORM_NAME": "iphonesimulator",
            "TEST_HOST": "/tmp/Custom Products/Host.app/Executable",
            "FULL_PRODUCT_NAME": "RenamedTests.xctest",
            "TARGET_BUILD_DIR": "/tmp/Custom Products",
            "BUILT_PRODUCTS_DIR": "/tmp/Custom Products",
            "TARGET_DEVICE_IDENTIFIER": "placeholder"
        ]
    }

    @Test
    func resolvesHostAndUsesInstalledContainerForInjection() throws {
        let product = try SimulatorTestDebugProduct(settings: settings(), arguments: [
            "-destination", "platform=iOS Simulator,id=SIM-1,OS=latest"
        ])
        #expect(product.hostApp.path == "/tmp/Custom Products/Host.app")
        #expect(product.destinationID == "SIM-1")
        let environment = try SimulatorTestDebugLauncher.environment(
            appPath: "/installed/Host.app",
            dataPath: "/container",
            product: product,
            developerDirectory: URL(fileURLWithPath: "/Selected Xcode/Developer")
        )
        #expect(environment["SIMCTL_CHILD_XCTestBundlePath"] == "/installed/Host.app/PlugIns/RenamedTests.xctest")
        #expect(environment["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] ==
            "/installed/Host.app/Frameworks/libXCTestBundleInject.dylib")
        #expect(environment["SIMCTL_CHILD_DYLD_FRAMEWORK_PATH"]?.contains("Library/PrivateFrameworks") == true)
        #expect(environment["SIMCTL_CHILD_DYLD_LIBRARY_PATH"]?.contains("/Selected Xcode/Developer/") == true)
        #expect(environment["SIMCTL_CHILD_LLVM_PROFILE_FILE"]?.hasPrefix("/container/tmp/") == true)
    }

    @Test
    func rejectsUnsupportedOrIncompleteProductsBeforeLaunching() throws {
        for (key, value) in [
            ("PLATFORM_NAME", "iphoneos"), ("TEST_HOST", ""),
            ("TEST_HOST", "/tmp/tool"), ("FULL_PRODUCT_NAME", "../Other.xctest")
        ] {
            var values = settings()
            values[key] = value
            #expect(throws: (any Error).self) {
                try SimulatorTestDebugProduct(settings: values, arguments: ["-destination", "id=SIM"])
            }
        }
        #expect(throws: DebugSessionError.self) {
            try SimulatorTestDebugProduct(settings: settings(), arguments: [])
        }
    }

    @Test
    func launchesPausedWithTheSelectedToolchain() async throws {
        let product = try SimulatorTestDebugProduct(settings: settings(), arguments: ["-destination", "id=SIM"])
        let launcher = SimulatorTestDebugLauncher(
            product: product, developerDirectory: URL(fileURLWithPath: "/Xcode/Developer")
        ) { arguments, environment in
            #expect(environment["DEVELOPER_DIR"] == "/Xcode/Developer")
            if arguments.contains("get_app_container") {
                return ProcessExecutionResult(
                    output: arguments.last == "app" ? "/installed/Host.app\n" : "/data\n",
                    error: nil,
                    exitCode: 0
                )
            }
            #expect(arguments == [
                "simctl",
                "launch",
                "--terminate-running-process",
                "--wait-for-debugger",
                "SIM",
                "com.example.Host"
            ])
            #expect(environment["SIMCTL_CHILD_XCTestBundlePath"] == "/installed/Host.app/PlugIns/RenamedTests.xctest")
            return ProcessExecutionResult(output: "com.example.Host: 1234\n", error: nil, exitCode: 0)
        }
        let pid = try await launcher.launchWaitingForDebugger(deviceID: "SIM", appIdentifier: "com.example.Host")
        #expect(pid == 1234)
    }
}
