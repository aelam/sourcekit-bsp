import BuildServerProtocol
import Foundation
import Testing
@testable import SwiftPMProjectManagerProvider

struct SwiftPMBuildContextTests {
    @Test(arguments: [
        ("arm64-apple-macosx14.0", "macos", "arm64"),
        ("x86_64-unknown-linux-gnu", "linux", "x86_64"),
        ("aarch64-unknown-windows-msvc", "windows", "aarch64")
    ])
    func hostDestinationReportsPlatformAndArchitectureWithoutInventingOSVersion(
        triple: String, platform: String, architecture: String
    ) async throws {
        let fixture = try TemporarySwiftPMPackage()
        let recorder = try ContextCommandRecorder(fixture: fixture)
        await recorder.setHost(triple)
        let manager = fixture.manager(executor: recorder)
        try await manager.initialize()
        let options = try await manager.contextOptions(.init())
        let dimension = try #require(options.dimensions.first { $0.id == "swiftpm.destination" })
        let host = try #require(dimension.options.first)
        #expect(host.dataKind == BuildContextDestination.dataKind)
        #expect(host.description == triple)
        let data = try #require(host.data)
        let metadata = try JSONDecoder().decode(BuildContextDestination.self, from: JSONEncoder().encode(data))
        #expect(metadata.kind == "host")
        #expect(metadata.platform.id == platform)
        #expect(metadata.architecture == architecture)
        #expect(metadata.osVersion == nil)
        #expect(metadata.state == nil)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(data)) as? [String: Any])
        #expect(object["osVersion"] == nil)
        #expect(object["state"] == nil)
    }

    @Test
    func sharedDiscoveryListsTargetsWithoutChoosingAnActionConfiguration() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let recorder = try ContextCommandRecorder(fixture: fixture)
        let manager = fixture.manager(executor: recorder)
        try await manager.initialize()
        let options = try await manager.contextOptions(.init())
        let targetDimension = try #require(options.dimensions.first { $0.id == "swiftpm.target" })
        #expect(targetDimension.options.map(\.label) == ["App", "AppTests", "Core"])
        let configuration = try #require(options.dimensions.first { $0.id == "swiftpm.configuration" })
        #expect(!configuration.required)
        #expect(configuration.value == nil)
        #expect(options.selection["swiftpm.configuration"] == nil)
        #expect(options.operations == [.compile, .run])
        let resolved = try await manager.resolveContext(.init(operation: .run, selection: options.selection))
        #expect(resolved.selection["swiftpm.configuration"] == "debug")
        let explicit = try await manager.contextOptions(.init(selection: ["swiftpm.configuration": "release"]))
        #expect(explicit.selection["swiftpm.configuration"] == "release")
        for (name, operations) in [("Core", [BuildContextOperation.compile]), ("AppTests", [.compile, .test])] {
            let target = try #require(await manager.getTargetList().first { $0.displayName == name })
            let scoped = try await manager.contextOptions(.init(scope: .init(targets: [target.id])))
            #expect(scoped.operations == operations)
            #expect(scoped.dimensions.allSatisfy { $0.id != "swiftpm.target" })
            #expect(scoped.selection["swiftpm.configuration"] == nil)
        }
        await #expect(throws: BuildContextError.self) {
            try await manager.contextOptions(.init(selection: ["swiftpm.configuration": "profile"]))
        }
    }

    @Test
    func discoversOnlyRealDimensionsAndRejectsUnavailableSelections() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let recorder = try ContextCommandRecorder(fixture: fixture)
        let manager = fixture.manager(executor: recorder)
        try await manager.initialize()
        let options = try await manager.contextOptions(.init())
        #expect(options.dimensions.map(\.id) == ["swiftpm.target", "swiftpm.configuration", "swiftpm.destination"])
        #expect(options.selection["swiftpm.configuration"] == nil)
        #expect(options.selection["swiftpm.destination"] == "arm64-apple-macosx26.0")
        #expect(options.dimensions[0].options.map(\.label) == ["App", "AppTests", "Core"])
        for selection in [
            ["scheme": "Fake"],
            ["swiftpm.configuration": "profile"],
            ["swiftpm.destination": "ios"],
            ["swiftpm.target": "file:///unknown"]
        ] {
            await #expect(throws: BuildContextError.self) {
                try await manager.resolveContext(.init(operation: .run, selection: selection))
            }
        }
        await #expect(throws: BuildContextError.self) {
            try await manager.contextOptions(.init(scope: .init(workspaceUri: URI(fixture.directory))))
        }
        let core = try #require(await manager.getTargetList().first { $0.displayName == "Core" })
        await #expect(throws: BuildContextError.self) {
            try await manager.resolveContext(.init(scope: .init(targets: [core.id]), operation: .run))
        }
    }

    @Test
    func runBuildsAndLaunchesTheFrozenConfigurationWithProgramArguments() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let recorder = try ContextCommandRecorder(fixture: fixture)
        let manager = fixture.manager(executor: recorder)
        try await manager.initialize()
        for configuration in ["release", "debug", "release"] {
            let context = try await manager.resolveContext(.init(operation: .run, selection: [
                "swiftpm.configuration": configuration
            ]))
            let target = try #require(context.targets.first)
            #expect(try await manager.run(
                targetIdentifier: target,
                arguments: ["--configuration", "program-value"],
                environmentVariables: ["PROBE": "yes"],
                workingDirectory: URI(fixture.directory),
                progressHandler: nil,
                context: context
            ) == .ok)
            let calls = await recorder.calls
            let launch = try #require(calls.last)
            #expect(launch.executable.path == fixture.root.appendingPathComponent("bin/\(configuration)/app-tool").path)
            #expect(launch.arguments == ["--configuration", "program-value"])
            #expect(launch.environment == ["PROBE": "yes"])
            #expect(launch.directory == fixture.directory)
            let build = try #require(calls.dropLast().last { $0.arguments.contains("--product") })
            #expect(build.arguments == [
                "build",
                "--package-path",
                fixture.root.path,
                "--configuration",
                configuration,
                "--product",
                "app-tool"
            ])
            let paths = try await manager.outputPaths(for: [target])
            #expect(paths[0].outputPaths[0].uri == URI(fixture.root.appendingPathComponent("bin/\(configuration)")))
        }
    }

    @Test
    func failedBuildDoesNotLaunchAnExistingProduct() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let recorder = try ContextCommandRecorder(fixture: fixture)
        let manager = fixture.manager(executor: recorder)
        try await manager.initialize()
        let context = try await manager.resolveContext(.init(operation: .run, selection: [
            "swiftpm.configuration": "release"
        ]))
        await recorder.failBuild()
        let target = try #require(context.targets.first)
        let status = try await manager.run(
            targetIdentifier: target,
            arguments: nil,
            environmentVariables: nil,
            workingDirectory: nil,
            progressHandler: nil,
            context: context
        )
        #expect(status == .error)
        #expect(await recorder.calls.allSatisfy { $0.executable.lastPathComponent != "app-tool" })
        #expect(await recorder.calls.allSatisfy { !$0.arguments.contains("--show-bin-path") })
    }

    @Test
    func explicitConfigurationConflictsFailAndCompilerOperandsStayIntact() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let recorder = try ContextCommandRecorder(fixture: fixture)
        let manager = fixture.manager(executor: recorder)
        try await manager.initialize()
        let context = try await manager.resolveContext(.init(operation: .compile, selection: [
            "swiftpm.configuration": "release"
        ]))
        for arguments in [
            ["-c", "debug"],
            ["--configuration=debug"],
            ["--configuration"],
            ["--triple", "other"],
            ["-Xswiftc"]
        ] {
            await #expect(throws: BuildContextError.self) {
                try await manager.startBuild(
                    targetIdentifiers: context.targets,
                    arguments: arguments,
                    logHandler: nil,
                    context: context
                )
            }
        }
        #expect(try await manager.startBuild(
            targetIdentifiers: context.targets,
            arguments: ["-c", "release", "-Xswiftc", "-c"],
            logHandler: nil,
            context: context
        ) == .ok)
        let call = try #require(await recorder.calls.last)
        #expect(call.arguments.contains("release"))
        #expect(call.arguments.contains("-Xswiftc"))
        #expect(call.arguments.count { $0 == "-c" } == 1)
    }

    @Test
    func selectionIsIndependentOfTheBuildConfiguration() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let recorder = try ContextCommandRecorder(fixture: fixture)
        let manager = fixture.manager(executor: recorder)
        try await manager.initialize()
        let context = try await manager.resolveContext(.init(operation: .test, selection: [
            "swiftpm.configuration": "release"
        ]))
        let target = try #require(context.targets.first)
        let selection = SwiftPMTestSelection(tests: [.init(target: target, id: "Example/testValue()", style: "XCTest")])
        let arguments = try await manager.testArguments(
            targetIdentifiers: [target],
            arguments: nil,
            dataKind: SwiftPMTestSelection.dataKind,
            data: JSONDecoder().decode(
                LSPAny.self,
                from: JSONEncoder().encode(selection)
            )
        )
        _ = try await manager.test(
            targetIdentifiers: [target],
            arguments: arguments,
            environmentVariables: nil,
            workingDirectory: nil,
            logHandler: nil,
            testEventHandler: nil,
            context: context
        )
        let call = try #require(await recorder.calls.last { $0.arguments.first == "test" })
        #expect(call.arguments.contains("release"))
        let filterIndex = try #require(call.arguments.firstIndex(of: "--filter"))
        let filter = try NSRegularExpression(pattern: call.arguments[filterIndex + 1])
        func matches(_ candidate: String) -> Bool {
            filter.firstMatch(
                in: candidate,
                range: NSRange(candidate.startIndex ..< candidate.endIndex, in: candidate)
            ) != nil
        }
        #expect(matches("AppTests.Example/testValue"))
        for candidate in [
            "OtherTests.Example/testValue", "AppTests.Other/testValue", "AppTests.Example/testOther",
            "AppTests.Example/testValueSuffix", "OtherAppTests.Example/testValue", "AppTestsXExample/testValue"
        ] {
            #expect(!matches(candidate))
        }
        #expect(!call.arguments.contains { $0.hasPrefix(SwiftPMTestSelection.argumentPrefix) })
        await #expect(throws: BuildContextError.self) {
            try await manager.test(
                targetIdentifiers: [target],
                arguments: ["-c", "debug"],
                environmentVariables: nil,
                workingDirectory: nil,
                logHandler: nil,
                testEventHandler: nil,
                context: context
            )
        }
    }

    @Test
    func reloadRefreshesTheHostAndRejectsAnOldDestination() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let recorder = try ContextCommandRecorder(fixture: fixture)
        let manager = fixture.manager(executor: recorder)
        try await manager.initialize()
        let context = try await manager.resolveContext(.init(operation: .run))
        await recorder.setHost("x86_64-apple-macosx26.0")
        try await manager.updateBuildGraph()
        await #expect(throws: BuildContextError.self) {
            try await manager.resolveContext(.init(operation: .run, selection: context.selection))
        }
        let updated = try await manager.resolveContext(.init(operation: .run))
        #expect(updated.selection["swiftpm.destination"] == "x86_64-apple-macosx26.0")
    }

    @Test
    func debugBuildsAndLocatesTheSelectedConfiguration() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let recorder = try ContextCommandRecorder(fixture: fixture)
        let manager = SwiftPMProjectManager(
            rootURL: fixture.root,
            executable: fixture.root.appendingPathComponent("swift"),
            executor: recorder,
            debugAdapter: ContextDebugAdapter()
        )
        try await manager.initialize()
        let context = try await manager.resolveContext(.init(operation: .debug, selection: [
            "swiftpm.configuration": "release"
        ]))
        let session = try await manager.startDebugSession(
            targetIdentifiers: context.targets,
            arguments: ["hello"],
            logHandler: nil,
            progressHandler: nil,
            context: context
        )
        #expect(session.program == fixture.root.appendingPathComponent("bin/release/app-tool").path)
        #expect(session.args == ["hello"])
        #expect(await recorder.calls
            .contains { $0.arguments.contains("--product") && $0.arguments.contains("release") })
        await manager.shutdown()
    }
}

private struct ContextDebugAdapter: SwiftPMDebugAdapterServing {
    func start() async throws -> SwiftPMDebugEndpoint {
        .init(uri: "tcp://127.0.0.1:12345") {}
    }
}

private actor ContextCommandRecorder: SwiftPMCommandExecuting {
    struct Call: Sendable {
        let executable: URL
        let arguments: [String]
        let directory: URL
        let environment: [String: String]
    }

    let root: URL
    let metadata: Data
    private(set) var calls: [Call] = []
    private var host = "arm64-apple-macosx26.0"
    private var buildFails = false

    func failBuild() {
        buildFails = true
    }

    func setHost(_ host: String) {
        self.host = host
    }

    init(fixture: TemporarySwiftPMPackage) throws {
        root = fixture.root
        metadata = try fixture.describe(
            targets: [
                describedTarget("Core"),
                describedTarget("App", type: "executable"),
                describedTarget("AppTests", type: "test", path: "Tests/AppTests")
            ],
            products: [["name": "app-tool", "targets": ["App"]]]
        )
        for configuration in ["debug", "release"] {
            let path = "bin/\(configuration)/app-tool"
            try fixture.write("#!/bin/sh\nexit 0\n", to: path)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: fixture.root.appendingPathComponent(path).path
            )
        }
    }

    func execute(executable: URL, arguments: [String], workingDirectory: URL) async throws -> SwiftPMCommandResult {
        try await execute(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: [:],
            outputHandler: nil
        )
    }

    func execute(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        outputHandler: (@Sendable (String) -> Void)?
    ) async throws -> SwiftPMCommandResult {
        calls.append(.init(
            executable: executable,
            arguments: arguments,
            directory: workingDirectory,
            environment: environment
        ))
        let data: Data
        if arguments.contains("describe") {
            data = metadata
        } else if arguments == ["-print-target-info"] {
            data = try JSONSerialization.data(withJSONObject: ["target": ["triple": host]])
        } else if arguments.contains("--show-bin-path") {
            let configuration = arguments.contains("release") ? "release" : "debug"
            data = Data(root.appendingPathComponent("bin/\(configuration)").path.utf8)
        } else { data = Data() }
        let failed = buildFails && arguments.first == "build" && !arguments.contains("--show-bin-path")
        return .init(standardOutput: data, standardError: Data(), exitCode: failed ? 1 : 0)
    }
}
