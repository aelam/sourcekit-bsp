import Foundation
import SourceKitBSPProtocol
import Testing
import XcodeProj
@testable import XcodeProjectManagement

struct XcodeContextTestPlanTests {
    @Test
    func defaultPlanDefinesTheScopeWithoutReadingOtherPlans() async throws {
        let fixture = try await ContextFixture.make { scheme, directory in
            let tests = try #require(scheme.testAction?.testables)
            let unit = try #require(tests.first { $0.buildableReference.blueprintName == "HelloTests" })
            try writePlan("Unit", targets: [planTarget(unit)], in: directory)
            scheme.testAction?.testables = []
            scheme.testAction?.testPlans = [
                .init(reference: "container:TestPlans/Missing.xctestplan"),
                .init(reference: "container:TestPlans/Unit.xctestplan", default: true)
            ]
        }
        defer { fixture.remove() }
        let selection = ["xcode.scheme": fixture.schemeID, "xcode.destination": "BSP-SIMULATOR"]
        let options = try await fixture.manager.contextOptions(.init(selection: selection))
        #expect(options.operations?.contains(.test) == true)
        let context = try await fixture.manager.resolveContext(.init(operation: .test, selection: selection))
        let base = try #require(await fixture.manager.projectSnapshot)
        let target = try #require(base.xcodeTargets.first { $0.name == "HelloTests" })
        let id = try BSPBuildTargetIdentifier(uri: URI(string: target.targetIdentifier.rawValue))
        #expect(context.targets == [id])
        let scoped = try await fixture.manager.contextOptions(.init(scope: .init(targets: [id])))
        #expect(scoped.selection["xcode.scheme"] == fixture.schemeID)
        #expect(scoped.operations?.contains(.test) == true)
        let flags = try await fixture.manager.contextArguments(context, arguments: nil)
        let commands = try await fixture.manager.testCommands(for: [target.targetIdentifier], arguments: flags)
        let command = try #require(commands.first)
        #expect(commands.count == 1)
        #expect(command.contains("test"))
        #expect(command.filter { $0.hasPrefix("-only-testing:") } == ["-only-testing:HelloTests"])
        let schemeIndex = try #require(command.firstIndex(of: "-scheme"))
        #expect(command[schemeIndex + 1] == "Hello")
        let planIndex = try #require(command.firstIndex(of: "-testPlan"))
        #expect(command[planIndex + 1] == "Unit")
        #expect(try fixture.schemeFiles() == ["Hello.xcscheme"])
        let ui = try #require(base.xcodeTargets.first { $0.name == "HelloUITests" })
        let uiID = try BSPBuildTargetIdentifier(uri: URI(string: ui.targetIdentifier.rawValue))
        await #expect(throws: BuildContextError.self) {
            try await fixture.manager.resolveContext(.init(
                scope: .init(targets: [uiID]), operation: .test, selection: selection
            ))
        }
    }

    @Test
    func disabledTargetsAreExcludedAndIdentifiersResolveTheProjectTarget() async throws {
        let fixture = try await ContextFixture.make { scheme, directory in
            let tests = try #require(scheme.testAction?.testables)
            let unit = try #require(tests.first { $0.buildableReference.blueprintName == "HelloTests" })
            let ui = try #require(tests.first { $0.buildableReference.blueprintName == "HelloUITests" })
            var enabled = try planTarget(unit)
            var reference = try #require(enabled["target"] as? [String: String])
            reference["name"] = "PreviousName"
            enabled["target"] = reference
            var disabled = try planTarget(ui)
            disabled["enabled"] = false
            try writePlan("Unit", targets: [enabled, enabled, disabled], in: directory)
            scheme.testAction?.testables = []
            scheme.testAction?.testPlans = [.init(reference: "container:TestPlans/Unit.xctestplan")]
        }
        defer { fixture.remove() }
        let context = try await fixture.manager.resolveContext(.init(
            operation: .test, selection: ["xcode.scheme": fixture.schemeID]
        ))
        let base = try #require(await fixture.manager.projectSnapshot)
        let unit = try #require(base.xcodeTargets.first { $0.name == "HelloTests" })
        #expect(context.targets.map(\.uri.stringValue) == [unit.targetIdentifier.rawValue])
    }

    @Test
    func planTestsPreserveFiltersAndTheWithoutBuildingPolicy() async throws {
        let fixture = try await ContextFixture.make { scheme, directory in
            let unit = try #require(scheme.testAction?.testables.first {
                $0.buildableReference.blueprintName == "HelloTests"
            })
            var entry = try planTarget(unit)
            entry["selectedTests"] = ["Example/testValue()"]
            try writePlan("Unit", targets: [entry], in: directory)
            scheme.testAction?.testables = []
            scheme.testAction?.testPlans = [.init(reference: "container:TestPlans/Unit.xctestplan", default: true)]
        }
        defer { fixture.remove() }
        let selection = ["xcode.scheme": fixture.schemeID, "xcode.destination": "BSP-SIMULATOR"]
        let context = try await fixture.manager.resolveContext(.init(
            operation: .test, selection: selection, buildPolicy: .reuse
        ))
        let filter = "-only-testing:HelloTests/Example/testValue"
        let flags = try await fixture.manager.contextArguments(context, arguments: [filter])
        let base = try #require(await fixture.manager.projectSnapshot)
        let unit = try #require(base.xcodeTargets.first { $0.name == "HelloTests" })
        let commands = try await fixture.manager.testCommands(
            for: [unit.targetIdentifier], arguments: flags, skipBuild: true
        )
        let command = try #require(commands.first)
        #expect(command.contains("test-without-building"))
        #expect(!command.contains("test"))
        #expect(command.filter { $0.hasPrefix("-only-testing:") } == [filter])
        let compile = try await fixture.manager.resolveContext(.init(
            scope: .init(targets: context.targets), operation: .compile, selection: selection
        ))
        let build = try await fixture.manager.contextBuildCommand(compile, arguments: nil)
        #expect(build.contains("build-for-testing"))
        #expect(build.contains("-only-testing:HelloTests"))
        let planIndex = try #require(build.firstIndex(of: "-testPlan"))
        #expect(build[planIndex + 1] == "Unit")
        await #expect(throws: BuildContextError.self) {
            try await fixture.manager.contextArguments(context, arguments: ["-testPlan", "Other"])
        }
        await #expect(throws: BuildContextError.self) {
            try await fixture.manager.resolveContext(.init(
                operation: .debug,
                selection: selection.merging(["xcode.debugMode": "test"]) { _, new in new }
            ))
        }
    }

    @Test(arguments: [false, true])
    func anAmbiguousDefaultDoesNotDisableOtherSchemeActions(multipleDefaults: Bool) async throws {
        let fixture = try await ContextFixture.make { scheme, _ in
            scheme.testAction?.testables = []
            scheme.testAction?.testPlans = [
                .init(reference: "container:First.xctestplan", default: multipleDefaults),
                .init(reference: "container:Second.xctestplan", default: multipleDefaults)
            ]
        }
        defer { fixture.remove() }
        let selection = ["xcode.scheme": fixture.schemeID, "xcode.destination": "BSP-SIMULATOR"]
        let options = try await fixture.manager.contextOptions(.init(selection: selection))
        #expect(options.operations?.contains(.compile) == true)
        #expect(options.operations?.contains(.run) == true)
        #expect(options.operations?.contains(.test) == false)
        await #expect(throws: BuildContextError.self) {
            try await fixture.manager.resolveContext(.init(operation: .test, selection: selection))
        }
    }

    @Test
    func duplicatePlanNamesCannotSelectADifferentFileAtExecution() async throws {
        let fixture = try await ContextFixture.make { scheme, directory in
            let unit = try #require(scheme.testAction?.testables.first)
            try writePlan("Unit", targets: [planTarget(unit)], in: directory)
            scheme.testAction?.testables = []
            scheme.testAction?.testPlans = [
                .init(reference: "container:TestPlans/Unit.xctestplan", default: true),
                .init(reference: "container:Unit.xctestplan")
            ]
        }
        defer { fixture.remove() }
        let selection = ["xcode.scheme": fixture.schemeID, "xcode.destination": "BSP-SIMULATOR"]
        let options = try await fixture.manager.contextOptions(.init(selection: selection))
        #expect(options.operations?.contains(.test) == false)
        #expect(options.operations?.contains(.run) == true)
        await #expect(throws: BuildContextError.self) {
            try await fixture.manager.resolveContext(.init(operation: .test, selection: selection))
        }
    }

    @Test
    func aPlanTargetCannotMatchByNameInTheWrongProject() async throws {
        let fixture = try await ContextFixture.make { scheme, directory in
            let unit = try #require(scheme.testAction?.testables.first)
            var entry = try planTarget(unit)
            var reference = try #require(entry["target"] as? [String: String])
            reference["containerPath"] = "container:Other.xcodeproj"
            entry["target"] = reference
            try writePlan("Unit", targets: [entry], in: directory)
            scheme.testAction?.testables = []
            scheme.testAction?.testPlans = [.init(reference: "container:TestPlans/Unit.xctestplan", default: true)]
        }
        defer { fixture.remove() }
        await #expect(throws: BuildContextError.self) {
            try await fixture.manager.resolveContext(.init(
                operation: .test, selection: ["xcode.scheme": fixture.schemeID]
            ))
        }
    }
}

private func planTarget(_ test: XCScheme.TestableReference) throws -> [String: Any] {
    let reference = test.buildableReference
    return try [
        "target": [
            "containerPath": reference.referencedContainer,
            "identifier": #require(reference.blueprintIdentifier),
            "name": reference.blueprintName
        ]
    ]
}

private func writePlan(_ name: String, targets: [[String: Any]], in directory: URL) throws {
    let root = directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let plans = root.appendingPathComponent("TestPlans")
    try FileManager.default.createDirectory(at: plans, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: [
        "version": 1,
        "configurations": [["id": UUID().uuidString, "name": "Default", "options": [:]]],
        "defaultOptions": [:],
        "testTargets": targets
    ], options: [.prettyPrinted, .sortedKeys])
    try data.write(to: plans.appendingPathComponent(name + ".xctestplan"))
}
