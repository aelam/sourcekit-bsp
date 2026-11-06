import BuildServerProtocol
import Foundation
import Testing
import XcodeProj
@testable import XcodeProjectManagement

@Suite(.serialized)
struct XcodeBuildContextTests {
    @Test
    func expiredDiscoveryReturnsBeforeRefreshAndSharesItsFlightWithResolution() async throws {
        let inventory = ContextInventory()
        let clock = ContextClock()
        let fixture = try await ContextFixture.make(inventory: inventory, clock: clock)
        defer { fixture.remove() }
        let selection = ["xcode.scheme": fixture.schemeID, "xcode.destination": "BSP-DEVICE"]
        clock.advance(by: .milliseconds(1999))
        _ = try await fixture.manager.contextOptions(.init(selection: selection))
        #expect(await inventory.calls == 1)

        clock.advance(by: .milliseconds(1))
        await inventory.pause()
        let cached = try await fixture.manager.contextOptions(.init(selection: selection))
        #expect(cached.dimensions.last?.options.first { $0.id == "BSP-DEVICE" }?.availability == true)
        await inventory.waitUntilPaused()
        let repeated = try await fixture.manager.contextOptions(.init(selection: selection))
        #expect(repeated == cached)
        #expect(await inventory.calls == 2)

        let initialReads = clock.reads
        let resolution = Task {
            try await fixture.manager.resolveContext(.init(operation: .run, selection: selection))
        }
        await clock.waitForReads(initialReads + 1)
        await inventory.disconnect()
        await inventory.resume()
        await #expect(throws: BuildContextError.self) { try await resolution.value }
        #expect(await inventory.calls == 2)
        let refreshed = try await fixture.manager.contextOptions(.init(selection: selection))
        #expect(refreshed.dimensions.last?.options.first { $0.id == "BSP-DEVICE" }?.availability == false)
        await #expect(throws: BuildContextError.self) {
            try await fixture.manager.resolveContext(.init(operation: .run, selection: selection))
        }
        #expect(await inventory.calls == 3)
    }

    @Test
    func failedBackgroundRefreshInvalidatesTheReusableSnapshot() async throws {
        let inventory = ContextInventory()
        let clock = ContextClock()
        let fixture = try await ContextFixture.make(inventory: inventory, clock: clock)
        defer { fixture.remove() }
        let selection = ["xcode.scheme": fixture.schemeID]
        clock.advance(by: .seconds(2))
        await inventory.pause()
        await inventory.fail()
        _ = try await fixture.manager.contextOptions(.init(selection: selection))
        await inventory.waitUntilPaused()
        let refresh = try #require(await fixture.manager.destinationRefreshTask)
        await inventory.resume()
        await #expect(throws: ContextInventory.Failure.self) { try await refresh.value }
        await #expect(throws: ContextInventory.Failure.self) {
            try await fixture.manager.contextOptions(.init(selection: selection))
        }
        await #expect(throws: ContextInventory.Failure.self) {
            try await fixture.manager.resolveContext(.init(operation: .compile, selection: selection))
        }
        #expect(await inventory.calls == 4)
    }

    @Test
    func doesNotDiscoverDestinationsUntilAValidSchemeIsSelected() async throws {
        let inventory = ContextInventory()
        let clock = ContextClock()
        let fixture = try await ContextFixture.make(inventory: inventory, clock: clock)
        defer { fixture.remove() }
        await inventory.fail()
        clock.advance(by: .seconds(2))
        for selection in [[:], ["xcode.scheme": "missing"]] {
            let options = try await fixture.manager.contextOptions(.init(selection: selection))
            #expect(options.dimensions.map(\.id) == ["xcode.scheme", "xcode.configuration", "xcode.destination"])
            #expect(options.dimensions.dropFirst().allSatisfy { $0.enabled == false })
        }
        #expect(await inventory.calls == 1)
        let selection = ["xcode.scheme": fixture.schemeID]
        await #expect(throws: ContextInventory.Failure.self) {
            try await fixture.manager.resolveContext(.init(operation: .compile, selection: selection))
        }
        await #expect(throws: ContextInventory.Failure.self) {
            try await fixture.manager.contextOptions(.init(selection: selection))
        }
        #expect(await inventory.calls == 3)
    }

    @Test
    func reloadPreventsAnOldRefreshFromPublishingOrClearingTheNewRefresh() async throws {
        let inventory = ContextInventory()
        let clock = ContextClock()
        let fixture = try await ContextFixture.make(inventory: inventory, clock: clock)
        defer { fixture.remove() }
        let selection = ["xcode.scheme": fixture.schemeID]
        clock.advance(by: .seconds(2))
        await inventory.pause()
        _ = try await fixture.manager.contextOptions(.init(selection: selection))
        await inventory.waitUntilPaused()
        let previous = try #require(await fixture.manager.destinationRefreshTask)
        let reload = Task { try await fixture.manager.reloadProject() }
        await inventory.waitUntilPaused(call: 3)
        let currentID = try #require(await fixture.manager.destinationRefreshID)
        await inventory.resume(call: 2)
        await #expect(throws: CancellationError.self) { try await previous.value }
        #expect(await fixture.manager.destinationRefreshID == currentID)
        #expect(await fixture.manager.destinationRefreshInstant == nil)
        await inventory.disconnect()
        await inventory.resume()
        try await reload.value
        let refreshed = try await fixture.manager.contextOptions(.init(selection: selection))
        #expect(refreshed.dimensions.last?.options.first { $0.id == "BSP-DEVICE" }?.availability == false)
        #expect(await inventory.calls == 3)
    }

    @Test
    func shutdownRejectsCancelledQueriesAndLateBackgroundResults() async throws {
        let inventory = ContextInventory()
        let clock = ContextClock()
        let fixture = try await ContextFixture.make(inventory: inventory, clock: clock)
        defer { fixture.remove() }
        let selection = ["xcode.scheme": fixture.schemeID]
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.manager.contextOptions(.init(selection: selection))
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await inventory.calls == 1)

        clock.advance(by: .seconds(2))
        await inventory.pause()
        _ = try await fixture.manager.contextOptions(.init(selection: selection))
        await inventory.waitUntilPaused()
        let refresh = try #require(await fixture.manager.destinationRefreshTask)
        let stopping = Task { await fixture.manager.stopContextDestinationDiscovery() }
        await inventory.waitUntilCancelled(call: 2)
        await inventory.disconnect()
        await inventory.resume()
        await stopping.value
        await #expect(throws: CancellationError.self) { try await refresh.value }
        #expect(await fixture.manager.destinationRefreshInstant == nil)
        let loader = await fixture.manager.destinationLoader
        #expect(loader.allDestinations.first { $0.id == "BSP-DEVICE" }?.isAvailable == true)
        await #expect(throws: CancellationError.self) { try await fixture.manager.contextOptions(.init()) }
        await #expect(throws: CancellationError.self) {
            try await fixture.manager.resolveContext(.init(operation: .compile, selection: selection))
        }
        #expect(await inventory.calls == 2)
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
