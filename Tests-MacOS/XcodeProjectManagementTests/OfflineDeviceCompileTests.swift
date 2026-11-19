import Foundation
import SourceKitBSPProtocol
import Testing
@testable import XcodeProjectManagement

struct OfflineDeviceCompileTests {
    @Test
    func offlineDevicesRemainSelectableForAppAndTestBundleCompilation() async throws {
        let inventory = ContextInventory()
        await inventory.disconnect()
        let fixture = try await ContextFixture.make(inventory: inventory)
        defer { fixture.remove() }
        let selection = ["xcode.scheme": fixture.schemeID, "xcode.destination": "BSP-DEVICE"]
        let shared = try await fixture.manager.contextOptions(.init(selection: selection))
        let option = try #require(shared.dimensions.last?.options.first { $0.id == "BSP-DEVICE" })
        #expect(option.availability == true)
        #expect(option.description == "Build only")
        let metadata = try JSONDecoder().decode(
            BuildContextDestination.self, from: JSONEncoder().encode(option.data)
        )
        #expect(metadata.state == "disconnected")
        #expect(shared.selection["xcode.destination"] == "BSP-DEVICE")

        let snapshot = try #require(await fixture.manager.projectSnapshot)
        for name in ["Hello", "HelloTests"] {
            let target = try #require(snapshot.xcodeTargets.first { $0.name == name })
            let id = try BSPBuildTargetIdentifier(uri: URI(string: target.targetIdentifier.rawValue))
            let context = try await fixture.manager.resolveContext(.init(
                scope: .init(targets: [id]), operation: .compile, selection: selection
            ))
            let command = try await fixture.manager.contextBuildCommand(context, arguments: nil)
            #expect(command.contains("generic/platform=iOS"))
            #expect(!command.contains("id=BSP-DEVICE"))
            #expect(command.contains(name == "Hello" ? "build" : "build-for-testing"))
            #expect(context.selection["xcode.destination"] == "BSP-DEVICE")
            #expect(try await fixture.manager.indexingSelection(context).platform == "iphoneos")
        }
        for operation in [BuildContextOperation.run, .test, .debug] {
            let options = try await fixture.manager.operationContextOptions(.init(
                operation: operation, selection: selection
            ))
            let device = try #require(options.dimensions.last?.options.first { $0.id == "BSP-DEVICE" })
            #expect(device.availability == false)
            #expect(device.reason == "This destination is offline or unavailable")
            await #expect(throws: BuildContextError.self) {
                try await fixture.manager.resolveContext(.init(operation: operation, selection: selection))
            }
        }
    }

    @Test
    func disconnectingDoesNotInvalidateAResolvedCompileContext() async throws {
        let inventory = ContextInventory()
        let fixture = try await ContextFixture.make(inventory: inventory)
        defer { fixture.remove() }
        let selection = ["xcode.scheme": fixture.schemeID, "xcode.destination": "BSP-DEVICE"]
        let compile = try await fixture.manager.resolveContext(.init(operation: .compile, selection: selection))
        let run = try await fixture.manager.resolveContext(.init(operation: .run, selection: selection))
        let command = try await fixture.manager.contextBuildCommand(compile, arguments: nil)
        #expect(command.contains("generic/platform=iOS"))
        #expect(try await fixture.manager.contextArguments(run, arguments: nil).contains("id=BSP-DEVICE"))
        await inventory.disconnect()
        try await fixture.manager.refreshContextDestinations()
        #expect(try await fixture.manager.contextBuildCommand(compile, arguments: nil) == command)
        await #expect(throws: BuildContextError.self) {
            try await fixture.manager.contextArguments(run, arguments: nil)
        }
    }

    @Test
    func legacyCompileKeepsOverridesAndUnrecognizedDestinations() async throws {
        let fixture = try await ContextFixture.make()
        defer { fixture.remove() }
        let overrides = ["-configuration", "Release", "-arch", "arm64", "CODE_SIGN_IDENTITY=Apple Development"]
        let device = ["-destination", "id=BSP-DEVICE"] + overrides
        #expect(await fixture.manager.compileDestinationArguments(device)
            == ["-destination", "generic/platform=iOS"] + overrides)
        for destination in [
            "id=BSP-SIMULATOR",
            "id=UNKNOWN",
            "platform=macOS,arch=arm64",
            "generic/platform=iOS",
            "platform=iOS,id=BSP-DEVICE,OS=18.5"
        ] {
            let arguments = ["-destination", destination] + overrides
            #expect(await fixture.manager.compileDestinationArguments(arguments) == arguments)
        }
        #expect(await fixture.manager.compileDestinationArguments(["-destination"]) == ["-destination"])
    }

    @Test(arguments: [XcodeDestinationPlatform.iOS, .tvOS, .watchOS, .visionOS])
    func offlineBuildsKeepTheDevicePlatform(platform: XcodeDestinationPlatform) {
        let device = XcodeDestination(
            name: "Offline device", id: "DEVICE", platform: platform, type: .device,
            isAvailable: false, state: "disconnected"
        )
        #expect(device.isAvailableForBuild)
        #expect(device.genericDeviceDestination == "generic/platform=\(platform.rawValue)")
        let unavailable = XcodeDestination(
            name: "Unavailable simulator", id: "SIMULATOR", platform: platform, type: .simulator,
            isAvailable: false
        )
        #expect(!unavailable.isAvailableForBuild)
        #expect(unavailable.genericDeviceDestination == nil)
        #expect(XcodeDestination.myMac().genericDeviceDestination == nil)
    }
}
