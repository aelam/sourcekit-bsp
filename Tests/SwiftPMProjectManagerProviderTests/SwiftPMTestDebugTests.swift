import BuildServerProtocol
import Foundation
import Testing
@testable import SwiftPMProjectManagerProvider

struct SwiftPMTestDebugTests {
    @Test(arguments: [false, true])
    func usesBuiltTestsInOneDebugSession(merged: Bool) async throws {
        let fixture = try TemporarySwiftPMPackage()
        let executor = try TestDebugExecutor(fixture: fixture, merged: merged)
        let lifecycle = DebugLifecycle()
        let manager = SwiftPMProjectManager(
            rootURL: fixture.root,
            executable: fixture.root.appendingPathComponent("swift"),
            executor: executor,
            debugAdapter: TestDebugAdapter(lifecycle: lifecycle)
        )
        try await manager.initialize()
        let targets = await manager.getTargetList()
        let tests = try #require(targets.first { $0.displayName == "Selected-Tests" })
        #expect(tests.capabilities.canTest == true)
        #expect(tests.capabilities.canDebug == true)
        #expect(tests.capabilities.canRun == false)
        #expect(targets.first { $0.displayName == "Core" }?.capabilities.canDebug == false)
        let sibling = try #require(targets.first { $0.displayName == "Selected-TestsExtra" })
        let arguments = ["-c", "release", "--scratch-path", "custom build"]
        #expect(try await manager.startBuild(
            targetIdentifiers: [tests.id, sibling.id],
            arguments: arguments,
            logHandler: nil
        ) == .ok)
        let builtCalls = await executor.calls.count
        let connection = try await manager.startDebugSession(
            targetIdentifiers: [tests.id],
            arguments: arguments,
            logHandler: nil,
            progressHandler: nil
        )
        #expect(connection.program == "/Xcode/Contents/Developer/usr/bin/xctest")
        #expect(connection.args == [
            "-XCTest", "Selected_Tests.Case/testExample,Selected_Tests.swiftTest()", executor.bundle.path
        ])
        #expect(connection.cwd == fixture.root.path)
        #expect(connection.env?["DYLD_FRAMEWORK_PATH"]?.contains("Developer/Library/Frameworks") == true)
        #expect(connection.env?["DYLD_LIBRARY_PATH"]?.hasPrefix(executor.directory.path) == true)
        let calls = await executor.calls
        #expect(calls.dropFirst(builtCalls).filter { $0.first == "build" }.allSatisfy {
            $0.contains("--show-bin-path")
        })
        #expect(calls.count { $0.contains("--build-tests") } == 1)
        #expect(calls.contains(["build", "--package-path", fixture.root.path] + arguments + ["--build-tests"]))
        #expect(calls.contains(["test", "list", "--package-path", fixture.root.path] + arguments + ["--skip-build"]))
        #expect(calls.filter { $0.first == "test" }.allSatisfy { $0.contains("list") })
        #expect(lifecycle.events == ["started"])
        await manager.shutdown()
        #expect(lifecycle.events == ["started", "stopped"])
    }

    @Test
    func missingBundleDoesNotBuildOrStartAnAdapter() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let executor = try TestDebugExecutor(fixture: fixture, merged: false)
        try FileManager.default.removeItem(at: executor.bundle)
        let lifecycle = DebugLifecycle()
        let manager = SwiftPMProjectManager(
            rootURL: fixture.root,
            executable: fixture.root.appendingPathComponent("swift"),
            executor: executor,
            debugAdapter: TestDebugAdapter(lifecycle: lifecycle)
        )
        try await manager.initialize()
        let tests = try #require(await manager.getTargetList().first { $0.capabilities.canTest == true })
        do {
            _ = try await manager.startDebugSession(
                targetIdentifiers: [tests.id],
                arguments: nil,
                logHandler: nil,
                progressHandler: nil
            )
            Issue.record("Expected a missing test bundle")
        } catch let SwiftPMProjectError.productNotBuilt(path) {
            #expect(path == executor.bundle.path)
        }
        #expect(await executor.calls.filter { $0.first == "build" }.allSatisfy { $0.contains("--show-bin-path") })
        #expect(lifecycle.events.isEmpty)
        await manager.shutdown()
    }

    @Test
    func rejectsMissingOrAmbiguousTestSelection() throws {
        #expect(throws: SwiftPMProjectError.self) {
            try SwiftPMTestBundle.selectedTests(
                module: "Selected",
                listing: "SelectedExtra.test()\nOther.test()"
            )
        }
        #expect(throws: SwiftPMProjectError.self) {
            try SwiftPMTestBundle.selectedTests(
                module: "Selected",
                listing: "Selected.test,withComma()"
            )
        }
        #expect(try SwiftPMTestBundle.selectedTests(
            module: "Selected",
            listing: "Selected.test()\nSelected.test()\nSelectedExtra.test()"
        ) == ["Selected.test()"])
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownCancelsPreparationBeforeStartingTheAdapter() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let executor = try TestDebugExecutor(fixture: fixture, merged: false)
        let lifecycle = DebugLifecycle()
        let manager = SwiftPMProjectManager(
            rootURL: fixture.root,
            executable: fixture.root.appendingPathComponent("swift"),
            executor: executor,
            debugAdapter: TestDebugAdapter(lifecycle: lifecycle)
        )
        try await manager.initialize()
        let tests = try #require(await manager.getTargetList().first { $0.capabilities.canTest == true })
        await executor.waitDuringListing()
        let task = Task {
            try await manager.startDebugSession(
                targetIdentifiers: [tests.id],
                arguments: nil,
                logHandler: nil,
                progressHandler: nil
            )
        }
        defer { task.cancel() }
        for _ in 0 ..< 100 {
            if await executor.calls.contains(where: { $0.contains("list") }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await executor.calls.contains { $0.contains("list") })
        await manager.shutdown()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(lifecycle.events.isEmpty)
    }
}

private final class DebugLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var events: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

private struct TestDebugAdapter: SwiftPMDebugAdapterServing {
    let lifecycle: DebugLifecycle
    func start() async throws -> SwiftPMDebugEndpoint {
        lifecycle.append("started")
        return SwiftPMDebugEndpoint(uri: "tcp://127.0.0.1:12345") { lifecycle.append("stopped") }
    }
}

private actor TestDebugExecutor: SwiftPMCommandExecuting {
    let metadata: Data
    let directory: URL
    let bundle: URL
    private(set) var calls: [[String]] = []
    private var waits = false

    init(fixture: TemporarySwiftPMPackage, merged: Bool) throws {
        metadata = try fixture.describe(targets: [
            describedTarget("Core"), describedTarget("Selected-Tests", type: "test"),
            describedTarget("Selected-TestsExtra", type: "test")
        ])
        directory = fixture.root.appendingPathComponent("bin", isDirectory: true)
        let product = merged ? "UnrelatedPackageTests" : "Selected-Tests"
        bundle = directory.appendingPathComponent(product + ".xctest", isDirectory: true)
        let binary = bundle.appendingPathComponent("Contents/MacOS/" + product)
        try fixture.write("fixture", to: "bin/\(product).xctest/Contents/MacOS/\(product)")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        if merged {
            let description: [String: Any] = [
                "builtTestProducts": [
                    ["binaryPath": binary.path, "packagePath": fixture.root.path]
                ]
            ]
            try JSONSerialization.data(withJSONObject: description)
                .write(to: directory.appendingPathComponent("description.json"))
        }
    }

    func waitDuringListing() {
        waits = true
    }

    func execute(executable: URL, arguments: [String], workingDirectory: URL) async throws -> SwiftPMCommandResult {
        calls.append(arguments)
        if arguments.contains("describe") { return .init(standardOutput: metadata, standardError: Data(), exitCode: 0) }
        if waits, arguments.contains("list") { try await Task.sleep(for: .seconds(60)) }
        let output: String = if arguments.contains("--show-bin-path") {
            directory.path
        } else if arguments.contains("list") {
            "Selected_Tests.Case/testExample\nSelected_Tests.swiftTest()\nSelected_TestsExtra.unexpected()\n"
        } else if arguments.contains("--show-sdk-platform-path") {
            "/Xcode/Contents/Developer/Platforms/MacOSX.platform"
        } else if arguments.last == "xctest" {
            "/Xcode/Contents/Developer/usr/bin/xctest"
        } else if arguments.last == "swift" {
            "/Xcode/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
        } else {
            ""
        }
        return .init(standardOutput: Data(output.utf8), standardError: Data(), exitCode: 0)
    }
}
