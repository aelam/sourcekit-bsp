import Foundation
import Support
import Testing
@testable import XcodeProjectManagement

private struct DeviceTestAdapter: DebugAdapterServing {
    let stopped: CrossPlatformLock<Int>
    func start() async throws -> DebugAdapterEndpoint {
        DebugAdapterEndpoint(uri: "tcp://127.0.0.1:1") { stopped.withLock { $0 += 1 } }
    }
}

private struct UnusedSimulatorLauncher: WaitForDebuggerLaunching {
    func launchWaitingForDebugger(deviceID: String, appIdentifier: String) async throws -> Int {
        Issue.record("A physical-device request used the simulator launcher")
        throw DebugSessionError.unsupportedPlatform(.iOS)
    }
}

struct DeviceDebugSessionTests {
    @Test
    func existingDeviceProcessIsNeverLaunchedOrTerminated() async throws {
        let stopped = CrossPlatformLock(initialState: 0)
        let adapter = DeviceTestAdapter(stopped: stopped)
        let commands = DeviceCommandRunner { _, _ in
            Issue.record("Attach must not launch or terminate the existing device process")
            throw CancellationError()
        }
        let manager = DebugSessionManager(
            adapter: adapter,
            simulatorLauncher: UnusedSimulatorLauncher(),
            deviceSession: DeviceDebugSession(commands: commands, adapter: adapter)
        )
        let identity = DeviceProcessIdentity(
            deviceID: "PHONE",
            bundleID: "test.Hello",
            pid: 42,
            executable: "/device/Hello.app/Hello",
            localExecutable: "/local/Hello.app/Hello"
        )
        let connection = try await manager.makeDeviceAttachConnection(identity: identity)
        #expect(connection.request == .attach)
        #expect(connection.pid == 42)
        #expect(connection.bundleId == "test.Hello")
        await manager.stopConnection(uri: connection.uri)
        await manager.terminateAll()
        #expect(stopped.withLock { $0 } == 1)
    }

    @Test
    func cancelledDeviceAttachClosesTheAdapterWithoutTerminatingTheApp() async throws {
        let stopped = CrossPlatformLock(initialState: 0)
        let session = DeviceDebugSession(
            commands: DeviceCommandRunner { _, _ in
                Issue.record("Cancelled Attach must not change device state")
                throw CancellationError()
            },
            adapter: CancellingDeviceAdapter(stopped: stopped)
        )
        let task = Task {
            try await session.attach(identity: .init(
                deviceID: "PHONE",
                bundleID: "test.Hello",
                pid: 42,
                executable: "/device/Hello.app/Hello",
                localExecutable: "/local/Hello.app/Hello"
            ))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(stopped.withLock { $0 } == 1)
    }

    @Test(arguments: [false, true])
    func deviceSessionKeepsTheWireContractAndWaitsForCleanup(cancel: Bool) async throws {
        let stopped = CrossPlatformLock(initialState: 0)
        let terminated = CrossPlatformLock(initialState: [Int]())
        let adapter = DeviceTestAdapter(stopped: stopped)
        let launchedArguments = CrossPlatformLock(initialState: [String]())
        let commands = DeviceCommandRunner { arguments, _ in
            if arguments.contains("launch") {
                launchedArguments.withLock { $0 = arguments }
                let index = try #require(arguments.firstIndex(of: "--json-output"))
                try #"{"info":{"outcome":"success"},"result":{"process":{"processIdentifier":42}}}"#
                    .write(toFile: arguments[index + 1], atomically: true, encoding: .utf8)
            } else if arguments.contains("terminate") {
                let index = try #require(arguments.firstIndex(of: "--pid"))
                let pid = try #require(Int(arguments[index + 1]))
                terminated.withLock { $0.append(pid) }
            }
            return ProcessExecutionResult(output: "", error: nil, exitCode: 0)
        }
        let manager = DebugSessionManager(
            adapter: adapter,
            simulatorLauncher: UnusedSimulatorLauncher(),
            deviceSession: DeviceDebugSession(commands: commands, adapter: adapter)
        )
        let product = DebugProduct(
            platform: .iOS,
            binaryPath: "/tmp/Hello.app",
            bundleId: "com.hello.Hello",
            destinationID: "PHONE",
            executablePath: "/bin/sleep",
            launchSettings: XcodeLaunchSettings(arguments: ["--message", "hello world"])
        )
        let operation = Task {
            try await manager.makeConnection(for: product) { message in
                if cancel, message.contains("DAP client") { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        if cancel {
            await #expect(throws: CancellationError.self) { try await operation.value }
        } else {
            let result = try await operation.value
            #expect(result.request == .attach)
            #expect(result.pid == 42)
            #expect(result.program == nil)
            #expect(result.uri.hasPrefix("tcp://127.0.0.1:"))
        }
        await manager.terminateAll()
        await manager.terminateAll()
        #expect(launchedArguments.withLock { Array($0.suffix(3)) } == ["com.hello.Hello", "--message", "hello world"])
        #expect(terminated.withLock { $0 } == [42])
        #expect(stopped.withLock { $0 } == 1)
    }

    @Test
    func failedLaunchClosesTheUnusedAdapter() async throws {
        let stopped = CrossPlatformLock(initialState: 0)
        let adapter = DeviceTestAdapter(stopped: stopped)
        let commands = DeviceCommandRunner { _, _ in
            ProcessExecutionResult(output: "", error: "Device is locked", exitCode: 1)
        }
        let session = DeviceDebugSession(commands: commands, adapter: adapter)
        let product = DebugProduct(
            platform: .iOS,
            binaryPath: "/tmp/Hello.app",
            bundleId: "com.hello.Hello",
            destinationID: "PHONE",
            executablePath: "/bin/sleep"
        )
        await #expect(throws: XcodeRunError.self) { try await session.start(product: product, progressHandler: nil) }
        #expect(stopped.withLock { $0 } == 1)
    }
}

private struct CancellingDeviceAdapter: DebugAdapterServing {
    let stopped: CrossPlatformLock<Int>
    func start() async throws -> DebugAdapterEndpoint {
        withUnsafeCurrentTask { $0?.cancel() }
        return DebugAdapterEndpoint(uri: "tcp://127.0.0.1:1") { stopped.withLock { $0 += 1 } }
    }
}
