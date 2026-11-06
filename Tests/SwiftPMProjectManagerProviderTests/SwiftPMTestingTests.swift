import BuildServerProtocol
import Foundation
import Testing
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
@testable import SwiftPMProjectManagerProvider

struct SwiftPMTestingTests {
    @Test
    func runsOnlySelectedTestModulesAndPropagatesFailures() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let executor = try TestCommandRecorder(fixture: fixture)
        let manager = fixture.manager(executor: executor)
        try await manager.initialize()
        let targets = await manager.getTargetList()
        let selected = try #require(targets.first { $0.displayName == "Selected-Tests" })
        let sibling = try #require(targets.first { $0.displayName == "SiblingTests" })
        let logs = TestOutput()
        #expect(try await manager.test(
            targetIdentifiers: [selected.id, selected.id],
            arguments: ["-c", "release", "--scratch-path", "custom build", "--parallel"],
            environmentVariables: ["PROBE": "value"],
            workingDirectory: URI(fixture.root)
        ) { logs.append($0) } == .ok)
        let call = try #require(await executor.calls.last)
        #expect(call.arguments == [
            "test", "--package-path", fixture.root.path,
            "-c", "release", "--scratch-path", "custom build", "--parallel", "--filter", "^(Selected_Tests)\\."
        ])
        #expect(call.environment == ["PROBE": "value"])
        #expect(call.directory == fixture.root)
        #expect(logs.text == "test output\n")
        await executor.setExitCode(1)
        #expect(try await manager.test(
            targetIdentifiers: [sibling.id, selected.id],
            arguments: nil,
            environmentVariables: nil,
            workingDirectory: nil,
            logHandler: nil
        ) == .error)
        #expect(await executor.calls.last?.arguments.suffix(2) == ["--filter", "^(Selected_Tests|SiblingTests)\\."])
        await manager.shutdown()
    }

    @Test
    func rejectsNonTestTargetsSelectionsAndOptionsThatChangeExecution() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let executor = try TestCommandRecorder(fixture: fixture)
        let manager = fixture.manager(executor: executor)
        try await manager.initialize()
        let targets = await manager.getTargetList()
        let selected = try #require(targets.first { $0.displayName == "Selected-Tests" })
        let core = try #require(targets.first { $0.displayName == "Core" })
        let unknown = BSPBuildTargetIdentifier(uri: URI(fixture.root.appendingPathComponent("unknown")))
        for identifiers in [[], [core.id], [selected.id, core.id], [unknown]] {
            await #expect(throws: SwiftPMProjectError.self) {
                try await manager.test(
                    targetIdentifiers: identifiers,
                    arguments: nil,
                    environmentVariables: nil,
                    workingDirectory: nil,
                    logHandler: nil
                )
            }
        }
        let invalid = [
            ["--filter", "Sibling"], ["--filter=Sibling"], ["--skip", "Selected"], ["--specifier", "Other"],
            ["-sOther"], ["--package-path", "/tmp"], ["--target", "Other"], ["--list-tests"], ["-l"],
            ["-ql"], ["list"], ["last"], ["--show-codecov-path"], ["--show-code-coverage-path"],
            ["--show-coverage-path"], ["--debugger"], ["--help"], ["-help"], ["--version"], ["--"],
            ["--disable-xctest"], ["--disable-swift-testing"], ["--configuration"], [""]
        ]
        for arguments in invalid {
            await #expect(throws: SwiftPMProjectError.self) {
                try await manager.test(
                    targetIdentifiers: [selected.id],
                    arguments: arguments,
                    environmentVariables: nil,
                    workingDirectory: nil,
                    logHandler: nil
                )
            }
        }
        await #expect(throws: TestSelectionError.self) {
            try await manager.testArguments(
                targetIdentifiers: [selected.id],
                arguments: nil,
                dataKind: "sourcekit-test-selection",
                data: .dictionary([:])
            )
        }
        #expect(try await manager.testArguments(
            targetIdentifiers: [selected.id],
            arguments: ["--skip-build"],
            dataKind: nil,
            data: nil
        ) == ["--skip-build"])
        await #expect(throws: SwiftPMProjectError.self) {
            try await manager.test(
                targetIdentifiers: [selected.id],
                arguments: nil,
                environmentVariables: nil,
                workingDirectory: URI(fixture.directory),
                logHandler: nil
            )
        }
        #expect(selected.capabilities.canTest == true)
        #expect(selected.capabilities.canRun == false)
        #expect(selected.capabilities.canDebug == false)
        do {
            _ = try await manager.startDebugSession(
                targetIdentifiers: [selected.id],
                arguments: nil,
                logHandler: nil,
                progressHandler: nil
            )
            Issue.record("Expected unsupported test debugging")
        } catch {
            #expect(error.localizedDescription.contains("debugging SwiftPM test targets"))
        }
        #expect(await executor.calls.isEmpty)
        await manager.shutdown()
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [false, true]
    )
    func cancelsTestsOnRequestOrShutdown(shutdown: Bool) async throws {
        let fixture = try TemporarySwiftPMPackage()
        let executor = try TestCommandRecorder(fixture: fixture)
        let manager = fixture.manager(executor: executor)
        try await manager.initialize()
        let selected = try #require(await manager.getTargetList().first { $0.capabilities.canTest == true })
        await executor.waitDuringTest()
        let task = Task {
            try await manager.test(
                targetIdentifiers: [selected.id],
                arguments: nil,
                environmentVariables: nil,
                workingDirectory: nil,
                logHandler: nil
            )
        }
        defer { task.cancel() }
        for _ in 0 ..< 100 {
            if await !executor.calls.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await !executor.calls.isEmpty)
        if shutdown { await manager.shutdown() } else { task.cancel() }
        await #expect(throws: CancellationError.self) { try await task.value }
        await manager.shutdown()
    }

    @Test(.timeLimit(.minutes(3)))
    func runsRealXCTestAndSwiftTestingWithoutSiblingTests() async throws {
        let fixture = try TemporarySwiftPMPackage()
        try writeMixedTests(fixture)
        let manager = try await SwiftPMProjectManagerProvider().createProjectManager(rootURL: fixture.root, config: nil)
        try await manager.initialize()
        let targets = await manager.getTargetList()
        let selected = try #require(targets.first { $0.displayName == "Selected-Tests" })
        let sibling = try #require(targets.first { $0.displayName == "Selected-TestsExtra" })
        let output = TestOutput()
        #expect(try await manager.test(
            targetIdentifiers: [selected.id],
            arguments: nil,
            environmentVariables: ["PROBE": "世界"],
            workingDirectory: nil
        ) { output.append($0) } == .ok)
        #expect(output.text.contains("SELECTED_XCTEST:世界"))
        #expect(output.text.contains("SELECTED_SWIFT_TEST:世界"))
        #expect(!output.text.contains("UNEXPECTED_SIBLING_EXECUTION"))
        for style in ["xctest", "swift"] {
            #expect(try await manager.test(
                targetIdentifiers: [selected.id],
                arguments: ["--skip-build"],
                environmentVariables: ["FAIL_STYLE": style],
                workingDirectory: nil,
                logHandler: nil
            ) == .error)
        }
        #expect(try await manager.test(
            targetIdentifiers: [selected.id, sibling.id],
            arguments: ["--skip-build"],
            environmentVariables: nil,
            workingDirectory: nil,
            logHandler: nil
        ) == .error)
        let ready = fixture.root.appendingPathComponent("ready")
        let finished = fixture.root.appendingPathComponent("finished")
        let task = Task {
            try await manager.test(
                targetIdentifiers: [selected.id],
                arguments: ["--skip-build"],
                environmentVariables: ["WAIT_MARKER": ready.path, "WAIT_FINISH": finished.path],
                workingDirectory: nil,
                logHandler: nil
            )
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = (try? String(contentsOf: ready, encoding: .utf8)).flatMap(Int32.init)
        task.cancel()
        #expect(FileManager.default.fileExists(atPath: ready.path))
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: finished.path))
        #if !os(Windows)
        let processID = try #require(pid)
        let reapDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while kill(processID, 0) == 0, ContinuousClock.now < reapDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let processStatus = kill(processID, 0)
        let processError = errno
        #expect(processStatus == -1)
        #expect(processError == ESRCH)
        #endif
        await manager.shutdown()
    }

    private func writeMixedTests(_ fixture: TemporarySwiftPMPackage) throws {
        try fixture.write("""
        // swift-tools-version: 6.1
        import PackageDescription
        let package = Package(name: "TestProbe", targets: [
            .testTarget(name: "Selected-Tests"), .testTarget(name: "Selected-TestsExtra")
        ])
        """, to: "Package.swift")
        try fixture.write("""
        import Foundation
        import Testing
        import XCTest
        func probe(_ style: String) -> Bool {
            let environment = ProcessInfo.processInfo.environment
            let marker = style == "xctest" ? "SELECTED_XCTEST:" : "SELECTED_SWIFT_TEST:"
            FileHandle.standardOutput.write(Data((marker + (environment["PROBE"] ?? "") + "\\n").utf8))
            if let marker = environment["WAIT_MARKER"], let finish = environment["WAIT_FINISH"] {
                FileManager.default.createFile(
                    atPath: marker, contents: Data(String(ProcessInfo.processInfo.processIdentifier).utf8)
                )
                Thread.sleep(forTimeInterval: 60)
                FileManager.default.createFile(atPath: finish, contents: Data())
            }
            return environment["FAIL_STYLE"] != style
        }
        @Test func selectedSwift() { #expect(probe("swift")) }
        final class SelectedCase: XCTestCase { func testSelected() { XCTAssertTrue(probe("xctest")) } }
        """, to: "Tests/Selected-Tests/Tests.swift")
        try fixture.write("""
        import Foundation
        import Testing
        import XCTest
        func unexpectedExecution() -> Bool {
            FileHandle.standardOutput.write(Data("UNEXPECTED_SIBLING_EXECUTION\\n".utf8))
            return false
        }
        @Test func siblingSwift() { #expect(unexpectedExecution()) }
        final class SiblingCase: XCTestCase { func testSibling() { XCTAssertTrue(unexpectedExecution()) } }
        """, to: "Tests/Selected-TestsExtra/Tests.swift")
    }
}

private final class TestOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    var text: String {
        lock.withLock { storage }
    }

    func append(_ text: String) {
        lock.withLock { storage += text }
    }
}

private actor TestCommandRecorder: SwiftPMCommandExecuting {
    struct Call: Sendable {
        let arguments: [String]
        let directory: URL
        let environment: [String: String]
    }

    let metadata: Data
    private(set) var calls: [Call] = []
    private var exitCode: Int32 = 0
    private var waits = false

    init(fixture: TemporarySwiftPMPackage) throws {
        metadata = try fixture.describe(targets: [
            describedTarget("Core"), describedTarget("Selected-Tests", type: "test"),
            describedTarget("SiblingTests", type: "test")
        ])
    }

    func setExitCode(_ code: Int32) {
        exitCode = code
    }

    func waitDuringTest() {
        waits = true
    }

    func execute(
        executable: URL,
        arguments: [String],
        workingDirectory: URL
    ) async throws -> SwiftPMCommandResult {
        .init(standardOutput: metadata, standardError: Data(), exitCode: 0)
    }

    func execute(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        outputHandler: (@Sendable (String) -> Void)?
    ) async throws -> SwiftPMCommandResult {
        calls.append(Call(arguments: arguments, directory: workingDirectory, environment: environment))
        outputHandler?("test output\n")
        if waits { try await Task.sleep(for: .seconds(60)) }
        return .init(standardOutput: Data(), standardError: Data(), exitCode: exitCode)
    }
}
