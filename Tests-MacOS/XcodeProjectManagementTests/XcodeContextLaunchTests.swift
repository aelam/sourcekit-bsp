import Foundation
import SourceKitBSPProtocol
import Testing
import XcodeProj
@testable import XcodeProjectManagement

struct XcodeContextLaunchTests {
    @Test
    func buildParticipationDoesNotReplaceAnActionExecutableOrTests() async throws {
        let fixture = try await ContextFixture.make { scheme, _ in
            for entry in scheme.buildAction?.buildActionEntries ?? [] {
                entry.buildFor = [.running, .testing, .profiling]
            }
            scheme.launchAction?.runnable = nil
            scheme.testAction?.testables = []
            scheme.testAction?.testPlans = nil
        }
        defer { fixture.remove() }
        let options = try await fixture.manager.contextOptions(.init(selection: [
            "xcode.scheme": fixture.schemeID, "xcode.destination": "BSP-SIMULATOR"
        ]))
        #expect(options.operations == [.compile])
    }

    @Test
    func appActionsAcceptRuntimeSettingsAndIgnoreDebuggerInit() async throws {
        let fixture = try await ContextFixture.make { scheme, _ in
            scheme.launchAction?.commandlineArguments = .init(arguments: [
                .init(name: "-FeatureEnabled YES", enabled: true)
            ])
            scheme.launchAction?.environmentVariables = [
                .init(variable: "FEATURE_ENV", value: "$(CONFIGURATION)", enabled: true)
            ]
            scheme.launchAction?.customLLDBInitFile = "$(SRCROOT)/.lldbinit"
        }
        defer { fixture.remove() }
        let selection = ["xcode.scheme": fixture.schemeID, "xcode.destination": "BSP-SIMULATOR"]
        let options = try await fixture.manager.contextOptions(.init(selection: selection))
        #expect(options.operations?.contains(.run) == true)
        #expect(options.operations?.contains(.debug) == true)
        for operation in [BuildContextOperation.run, .debug] {
            for policy in [BuildContextBuildPolicy.build, .reuse] {
                let context = try await fixture.manager.resolveContext(.init(
                    operation: operation, selection: selection, buildPolicy: policy
                ))
                #expect(context.targets.count == 1)
                #expect(context.buildPolicy == policy)
                #expect(context.selection["xcode.destination"] == "BSP-SIMULATOR")
                let flags = try await fixture.manager.contextArguments(context, arguments: nil)
                #expect(flags.contains("-scheme"))
                #expect(!flags.contains("-FeatureEnabled"))
            }
        }
    }

    @Test
    func genericDestinationDoesNotHideSchemeActions() async throws {
        let fixture = try await ContextFixture.make { scheme, _ in
            scheme.launchAction?.customLLDBInitFile = "$(SRCROOT)/.lldbinit"
        }
        defer { fixture.remove() }
        let options = try await fixture.manager.contextOptions(.init(selection: [
            "xcode.scheme": fixture.schemeID,
            "xcode.destination": "generic/platform=iOS Simulator"
        ]))
        #expect(options.operations == BuildContextOperation.allCases)
        await #expect(throws: BuildContextError.self) {
            try await fixture.manager.resolveContext(.init(
                operation: .run,
                selection: [
                    "xcode.scheme": fixture.schemeID,
                    "xcode.destination": "generic/platform=iOS Simulator"
                ]
            ))
        }
    }

    @Test
    func debugDoesNotSilentlyIgnoreInheritedLaunchSettings() async throws {
        let fixture = try await ContextFixture.make { scheme, _ in
            scheme.launchAction?.commandlineArguments = .init(arguments: [
                .init(name: "-FeatureEnabled YES", enabled: true)
            ])
            scheme.testAction?.shouldUseLaunchSchemeArgsEnv = true
            scheme.testAction?.testables.removeAll { $0.buildableReference.blueprintName != "HelloTests" }
        }
        defer { fixture.remove() }
        let selection = [
            "xcode.scheme": fixture.schemeID,
            "xcode.destination": "BSP-SIMULATOR",
            "xcode.debugMode": "test"
        ]
        await #expect(throws: BuildContextError.self) {
            try await fixture.manager.resolveContext(.init(operation: .debug, selection: selection))
        }
    }
}
