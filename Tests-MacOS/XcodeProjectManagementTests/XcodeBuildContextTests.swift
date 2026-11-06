import BuildServerProtocol
import Foundation
import Testing
import XcodeProj
@testable import XcodeProjectManagement

@Suite(.serialized)
struct XcodeBuildContextTests {
    @Test
    func refreshesInventoryForQueriesAndResolutionAndPropagatesFailures() async throws {
        let inventory = ContextInventory()
        let fixture = try await ContextFixture.make(inventory: inventory)
        defer { fixture.remove() }
        let selection = ["xcode.scheme": fixture.schemeID, "xcode.destination": "BSP-DEVICE"]
        let connected = try await fixture.manager.contextOptions(.init(selection: selection))
        #expect(connected.dimensions.last?.options.first { $0.id == "BSP-DEVICE" }?.availability == true)
        await inventory.disconnect()
        let disconnected = try await fixture.manager.contextOptions(.init(selection: selection))
        #expect(disconnected.dimensions.last?.options.first { $0.id == "BSP-DEVICE" }?.availability == false)
        await #expect(throws: BuildContextError.self) {
            try await fixture.manager.resolveContext(.init(operation: .run, selection: selection))
        }
        await inventory.fail()
        await #expect(throws: ContextInventory.Failure.self) {
            try await fixture.manager.contextOptions(.init(selection: selection))
        }
        await #expect(throws: ContextInventory.Failure.self) {
            try await fixture.manager.resolveContext(.init(
                operation: .compile,
                selection: ["xcode.scheme": fixture.schemeID]
            ))
        }
        #expect(await inventory.calls == 6)
    }
}

extension XcodeBuildContextTests {
    @Test
    func sharedDiscoveryDoesNotChooseActionDefaults() async throws {
        let fixture = try await ContextFixture.make { scheme, _ in
            scheme.launchAction?.buildConfiguration = "Release"
            scheme.testAction?.buildConfiguration = "Debug"
        }
        defer { fixture.remove() }
        let initial = try await fixture.manager.contextOptions(.init())
        #expect(initial.dimensions.map(\.id) == ["xcode.scheme", "xcode.configuration", "xcode.destination"])
        #expect(initial.selection.isEmpty)
        #expect(initial.dimensions.dropFirst().allSatisfy {
            $0.enabled == false && $0.options.isEmpty && $0.reason != nil
        })
        let selected = try await fixture.manager.contextOptions(.init(selection: ["xcode.scheme": fixture.schemeID]))
        #expect(selected.dimensions.map(\.id) == ["xcode.scheme", "xcode.configuration", "xcode.destination"])
        #expect(selected.selection == ["xcode.scheme": fixture.schemeID])
        #expect(selected.dimensions.dropFirst().allSatisfy { !$0.required && $0.value == nil })
        let destinations = try #require(selected.dimensions.first { $0.id == "xcode.destination" })
        #expect(!destinations.options.isEmpty)
        #expect(destinations.options.allSatisfy { $0.dataKind == BuildContextDestination.dataKind && $0.data != nil })
        let generic = try #require(destinations.options.first { $0.id == "generic/platform=iOS Simulator" })
        #expect(generic.data == BuildContextDestination(
            kind: "generic", platform: .init(id: "ios", label: "iOS")
        ).encodeToLSPAny())
        #expect(selected.operations?.contains(.compile) == true)
        let build = try await fixture.manager.resolveContext(.init(operation: .compile, selection: selected.selection))
        #expect(build.selection["xcode.configuration"] == "Release")
        let test = try await fixture.manager.operationContextOptions(.init(
            operation: .test,
            selection: selected.selection
        ))
        #expect(test.selection["xcode.configuration"] == "Debug")
    }

    @Test
    func workspaceStartsWithSchemeAndPreservesInvalidSelections() async throws {
        let fixture = try await ContextFixture.make()
        defer { fixture.remove() }
        let options = try await fixture.manager.contextOptions(.init())
        #expect(options.dimensions.map(\.id) == ["xcode.scheme", "xcode.configuration", "xcode.destination"])
        #expect(options.selection["xcode.scheme"] == nil)
        #expect(options.selection["xcode.debugMode"] == nil)
        let stale = ["xcode.destination": "old-device"]
        let partial = try await fixture.manager.contextOptions(.init(selection: stale))
        #expect(partial.dimensions.map(\.id) == ["xcode.scheme", "xcode.configuration", "xcode.destination"])
        #expect(partial.selection == stale)
        let invalid = try await fixture.manager.contextOptions(.init(
            selection: ["xcode.scheme": "missing", "xcode.destination": "old-device"]
        ))
        #expect(invalid.dimensions.first?.options.last?.availability == false)
        #expect(invalid.selection["xcode.scheme"] == "missing")
        await #expect(throws: BuildContextError.self) {
            try await fixture.manager.resolveContext(.init(operation: .compile, selection: invalid.selection))
        }
        let destination = try await fixture.manager.contextOptions(.init(
            selection: ["xcode.scheme": fixture.schemeID, "xcode.destination": "removed-device"]
        ))
        #expect(destination.selection["xcode.destination"] == "removed-device")
        #expect(destination.dimensions.last?.options.last?.availability == false)
        #expect(destination.dimensions.last?.options.last?.dataKind == nil)
        #expect(destination.dimensions.last?.options.last?.data == nil)
        await #expect(throws: BuildContextError.self) {
            try await fixture.manager.resolveContext(.init(operation: .compile, selection: destination.selection))
        }
        #expect(try fixture.schemeFiles() == ["Hello.xcscheme"])
    }

    @Test
    func freezesActionConfigurationAndUsesOneSchemeArgument() async throws {
        let fixture = try await ContextFixture.make { scheme, _ in
            scheme.launchAction?.buildConfiguration = "Release"
            scheme.testAction?.buildConfiguration = "Debug"
        }
        defer { fixture.remove() }
        let base = try #require(await fixture.manager.projectSnapshot)
        let app = try #require(base.xcodeTargets.first { $0.name == "Hello" })
        let appID = try BSPBuildTargetIdentifier(uri: URI(string: app.targetIdentifier.rawValue))
        let context = try await fixture.manager.resolveContext(.init(
            operation: .compile, selection: ["xcode.scheme": fixture.schemeID]
        ))
        #expect(context.targets == [appID])
        #expect(context.selection["xcode.configuration"] == "Release")
        #expect(context.selection["xcode.destination"] == "generic/platform=iOS Simulator")
        let command = try await fixture.manager.contextBuildCommand(context, arguments: nil)
        #expect(command.count { $0 == "-scheme" } == 1)
        #expect(command.contains("Hello"))
        #expect(command.contains("Release"))
        #expect(command.contains("build"))
        let direct = try await fixture.manager.resolveContext(.init(
            scope: .init(targets: [appID]),
            operation: .compile
        ))
        #expect(direct == context)
        let scheme = try XCScheme(pathString: fixture.schemeURL.path)
        scheme.launchAction?.buildConfiguration = "Debug"
        try scheme.write(path: .init(fixture.schemeURL.path), override: true)
        let frozen = try await fixture.manager.contextBuildCommand(context, arguments: nil)
        #expect(frozen.contains("Release"))
        let flags = try await fixture.manager.contextArguments(context, arguments: nil)
        let settings = try await fixture.manager.resolvedBuildSettings(for: app, arguments: flags)
        #expect(settings["CONFIGURATION"] == "Release")
        #expect(settings["TARGET_BUILD_DIR"]?.contains("Release-iphonesimulator") == true)
        for arguments in [
            ["-configuration", "Debug"],
            ["-scheme", "Hello"],
            ["-sdk", "iphoneos"],
            ["CONFIGURATION=Debug"],
            ["clean"]
        ] {
            await #expect(throws: BuildContextError.self) {
                try await fixture.manager.contextArguments(context, arguments: arguments)
            }
        }
        let invalid = try await fixture.manager.contextOptions(.init(
            selection: ["xcode.scheme": fixture.schemeID, "xcode.configuration": "Missing"]
        ))
        #expect(invalid.selection["xcode.configuration"] == "Missing")
        #expect(invalid.dimensions.first { $0.id == "xcode.configuration" }?.options.last?.availability == false)
        await #expect(throws: BuildContextError.self) {
            try await fixture.manager.resolveContext(.init(operation: .compile, selection: invalid.selection))
        }
    }

    @Test
    func selectionKeepsItsActionAndTargetScope() async throws {
        let fixture = try await ContextFixture.make { scheme, _ in
            scheme.launchAction?.buildConfiguration = "Release"
            scheme.testAction?.buildConfiguration = "Debug"
        }
        defer { fixture.remove() }
        let base = try #require(await fixture.manager.projectSnapshot)
        let target = try #require(base.xcodeTargets.first { $0.name == "HelloTests" })
        let id = try BSPBuildTargetIdentifier(uri: URI(string: target.targetIdentifier.rawValue))
        let context = try await fixture.manager.resolveContext(.init(scope: .init(targets: [id]), operation: .compile))
        #expect(context.selection["xcode.configuration"] == "Debug")
        let command = try await fixture.manager.contextBuildCommand(context, arguments: nil)
        #expect(command.contains("build-for-testing"))
        #expect(command.contains("-only-testing:HelloTests"))
        #expect(!command.contains("-only-testing:HelloUITests"))
        let commands = try await fixture.manager.testCommands(
            for: [target.targetIdentifier],
            arguments: ["-scheme", "Hello", "-configuration", "Debug", "-destination", "id=TEST-SIMULATOR"]
        )
        #expect(commands.count == 1)
        #expect(commands[0].count { $0 == "-scheme" } == 1)
        #expect(commands[0].contains("-only-testing:HelloTests"))
        #expect(!commands[0].contains("-only-testing:HelloUITests"))
        let generic = try await fixture.manager.contextOptions(.init(
            scope: .init(targets: [id]),
            selection: ["xcode.scheme": fixture.schemeID, "xcode.destination": "generic/platform=iOS Simulator"]
        ))
        #expect(generic.selection["xcode.configuration"] == nil)
        #expect(generic.dimensions.last?.options.first { $0.id == "generic/platform=iOS Simulator" }?
            .availability == true)
        #expect(generic.operations == [.compile])
        let testOptions = try await fixture.manager.operationContextOptions(.init(
            scope: .init(targets: [id]), operation: .test, selection: generic.selection
        ))
        let testDestination = try #require(testOptions.dimensions.last?.options
            .first { $0.id == "generic/platform=iOS Simulator" })
        #expect(testDestination.availability == false)
        #expect(testDestination.dataKind == BuildContextDestination.dataKind)
        #expect(testDestination.data == BuildContextDestination(
            kind: "generic", platform: .init(id: "ios", label: "iOS")
        ).encodeToLSPAny())
        await #expect(throws: BuildContextError.self) {
            try await fixture.manager.resolveContext(.init(
                scope: .init(targets: [id]),
                operation: .test,
                selection: generic.selection
            ))
        }
    }

    @Test
    func debugResolutionInfersModeFromSchemeAndTarget() async throws {
        let fixture = try await ContextFixture.make { scheme, directory in
            let testOnly = try XCScheme(pathString: directory.appendingPathComponent("Hello.xcscheme").path)
            testOnly.name = "TestsOnly"
            testOnly.launchAction = nil
            testOnly.testAction?.shouldUseLaunchSchemeArgsEnv = false
            testOnly.testAction?.testables.removeAll { $0.buildableReference.blueprintName != "HelloTests" }
            try testOnly.write(path: .init(directory.appendingPathComponent("TestsOnly.xcscheme").path), override: true)
            scheme.testAction?.testables.removeAll { $0.buildableReference.blueprintName != "HelloTests" }
        }
        defer { fixture.remove() }
        let options = try await fixture.manager.contextOptions(.init())
        #expect(options.dimensions.map(\.id) == ["xcode.scheme", "xcode.configuration", "xcode.destination"])
        let testOnly = try #require(options.dimensions[0].options.first { $0.label == "TestsOnly" })
        #expect(testOnly.availability == true)
        let selected = try await fixture.manager.operationContextOptions(.init(
            operation: .debug,
            selection: ["xcode.scheme": testOnly.id]
        ))
        #expect(selected.selection["xcode.debugMode"] == "test")
        #expect(selected.dimensions.first?.id == "xcode.scheme")
        #expect(!selected.dimensions.contains { $0.id == "xcode.debugMode" })
        let both = try await fixture.manager.operationContextOptions(.init(
            operation: .debug,
            selection: ["xcode.scheme": fixture.schemeID]
        ))
        #expect(!both.dimensions.contains { $0.id == "xcode.debugMode" })
        #expect(both.selection["xcode.debugMode"] == "run")
        let base = try #require(await fixture.manager.projectSnapshot)
        let target = try #require(base.xcodeTargets.first { $0.name == "HelloTests" })
        let id = try BSPBuildTargetIdentifier(uri: URI(string: target.targetIdentifier.rawValue))
        let direct = try await fixture.manager.operationContextOptions(.init(
            scope: .init(targets: [id]), operation: .debug, selection: ["xcode.scheme": fixture.schemeID]
        ))
        #expect(direct.selection["xcode.debugMode"] == "test")
        await #expect(throws: BuildContextError.self) {
            try await fixture.manager.resolveContext(.init(
                operation: .debug, selection: ["xcode.scheme": fixture.schemeID, "xcode.debugMode": "unknown"]
            ))
        }
        let unsupportedLaunch = try XCScheme(pathString: fixture.schemeURL.path)
        unsupportedLaunch.launchAction?.launchStyle = .wait
        unsupportedLaunch.testAction?.shouldUseLaunchSchemeArgsEnv = false
        try unsupportedLaunch.write(path: .init(fixture.schemeURL.path), override: true)
        await #expect(throws: BuildContextError.self) {
            try await fixture.manager.operationContextOptions(.init(
                operation: .debug, selection: ["xcode.scheme": fixture.schemeID]
            ))
        }
        let explicitTests = try await fixture.manager.operationContextOptions(.init(
            operation: .debug, selection: ["xcode.scheme": fixture.schemeID, "xcode.debugMode": "test"]
        ))
        #expect(explicitTests.selection["xcode.debugMode"] == "test")
    }

    @Test
    func duplicateSchemeNamesRemainVisibleAndCannotResolve() async throws {
        let fixture = try await ContextFixture.make { _, directory in
            let duplicate = directory
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("xcuserdata/other.xcuserdatad/xcschemes")
            try FileManager.default.createDirectory(at: duplicate, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: directory.appendingPathComponent("Hello.xcscheme"),
                to: duplicate.appendingPathComponent("Hello.xcscheme")
            )
        }
        defer { fixture.remove() }
        let options = try await fixture.manager.contextOptions(.init())
        #expect(options.dimensions[0].options.count == 2)
        #expect(Set(options.dimensions[0].options.map(\.id)).count == 2)
        #expect(options.dimensions[0].options.allSatisfy { $0.availability == false })
        await #expect(throws: BuildContextError.self) {
            try await fixture.manager.resolveContext(.init(
                operation: .compile,
                selection: ["xcode.scheme": fixture.schemeID]
            ))
        }
    }

    @Test
    func unsupportedSchemeActionsHaveDiagnosticsAndNeverGenerateSchemes() async throws {
        let fixture = try await ContextFixture.make { scheme, _ in
            scheme.testAction?.testPlans = [.init(reference: "container:Example.xctestplan", default: true)]
            scheme.launchAction?.launchStyle = .wait
        }
        defer { fixture.remove() }
        let discovery = try await fixture.manager.contextOptions(.init())
        #expect(discovery.dimensions[0].options.allSatisfy { $0.availability == true })
        let selected = try await fixture.manager.contextOptions(.init(selection: ["xcode.scheme": fixture.schemeID]))
        #expect(selected.operations == [.compile])
        for operation in [BuildContextOperation.test, .run] {
            await #expect(throws: BuildContextError.self) {
                try await fixture.manager.resolveContext(.init(
                    operation: operation,
                    selection: ["xcode.scheme": fixture.schemeID]
                ))
            }
        }
        #expect(try fixture.schemeFiles() == ["Hello.xcscheme"])
        try FileManager.default.removeItem(at: fixture.schemeURL)
        let base = try #require(await fixture.manager.projectSnapshot)
        let app = try #require(base.xcodeTargets.first { $0.name == "Hello" })
        let id = try BSPBuildTargetIdentifier(uri: URI(string: app.targetIdentifier.rawValue))
        let withoutScheme = try await fixture.manager.contextOptions(.init(scope: .init(targets: [id])))
        #expect(withoutScheme.dimensions[0].options.allSatisfy { $0.availability == false })
        await #expect(throws: (any Error).self) {
            try await fixture.manager.resolveContext(.init(scope: .init(targets: [id]), operation: .compile))
        }
        #expect(try fixture.schemeFiles().isEmpty)
    }
}

private struct ContextFixture {
    let root: URL
    let manager: XcodeProjectManager

    var schemeURL: URL {
        root.appendingPathComponent("Hello.xcodeproj/xcshareddata/xcschemes/Hello.xcscheme")
    }

    var schemeID: String {
        schemeURL.resolvingSymlinksInPath().standardizedFileURL.absoluteString
    }

    static func make(
        inventory: ContextInventory? = nil,
        edit: (XCScheme, URL) throws -> Void = { _, _ in }
    ) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ContextTests-\(UUID().uuidString)")
        let source = try #require(Bundle.module.resourceURL?.appendingPathComponent("DemoProjects/HelloProject"))
        try FileManager.default.copyItem(at: source, to: root)
        do {
            let schemeURL = root.appendingPathComponent("Hello.xcodeproj/xcshareddata/xcschemes/Hello.xcscheme")
            let directory = schemeURL.deletingLastPathComponent()
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where file.pathExtension == "xcscheme" && file.lastPathComponent != "Hello.xcscheme" {
                try FileManager.default.removeItem(at: file)
            }
            let scheme = try XCScheme(pathString: schemeURL.path)
            try edit(scheme, schemeURL.deletingLastPathComponent())
            try scheme.write(path: .init(schemeURL.path), override: true)
            let toolchain = XcodeToolchain(workingDirectory: root)
            let manager = XcodeProjectManager(
                rootURL: root,
                toolchain: toolchain,
                projectLocator: XcodeProjectLocator(),
                settingsLoader: XcodeSettingsLoader(commandBuilder: XcodeBuildCommandBuilder(), toolchain: toolchain)
            ) {
                if let inventory { return try await inventory.discover() }
                return ContextInventory.connected
            }
            try await manager.initialize()
            return Self(root: root, manager: manager)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func schemeFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: schemeURL.deletingLastPathComponent().path).sorted()
    }
}

private actor ContextInventory {
    enum Failure: Error { case unavailable }
    static let connected = """
    == Devices ==
    iPhone 16 Pro (18.5) (BSP-DEVICE)
    == Simulators ==
    iPhone 16 Simulator (18.5) (BSP-SIMULATOR)
    """

    private var output = connected
    private var failed = false
    private(set) var calls = 0

    func discover() throws -> String {
        calls += 1
        if failed { throw Failure.unavailable }
        return output
    }

    func disconnect() {
        output = """
        == Devices Offline ==
        iPhone 16 Pro (18.5) (BSP-DEVICE)
        """
    }

    func fail() {
        failed = true
    }
}
