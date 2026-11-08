import BuildServerProtocol
import Foundation
import Testing
@testable import XcodeProjectManagement

struct XcodeBuildPolicyTests {
    @Test
    func reuseTestsKeepSelectionAndCannotGenerateBuildCommands() async throws {
        let fixture = try await ContextFixture.make()
        defer { fixture.remove() }
        let base = try #require(await fixture.manager.projectSnapshot)
        let target = try #require(base.xcodeTargets.first { $0.name == "HelloTests" })
        let id = try BSPBuildTargetIdentifier(uri: URI(string: target.targetIdentifier.rawValue))
        let context = try await fixture.manager.resolveContext(.init(
            scope: .init(targets: [id]),
            operation: .test,
            selection: [
                "xcode.scheme": fixture.schemeID, "xcode.configuration": "Debug",
                "xcode.destination": "BSP-SIMULATOR"
            ],
            buildPolicy: .reuse
        ))
        #expect(context.buildPolicy == .reuse)
        try await fixture.manager.validateContext(context)
        let filter = "-only-testing:HelloTests/Example/testValue"
        let flags = try await fixture.manager.contextArguments(context, arguments: [filter])
        let commands = try await fixture.manager.testCommands(
            for: [target.targetIdentifier], arguments: flags, skipBuild: true
        )
        let command = try #require(commands.first)
        #expect(commands.count == 1)
        #expect(command.contains("test-without-building"))
        #expect(!command.contains("test"))
        #expect(!command.contains("build"))
        #expect(!command.contains("build-for-testing"))
        #expect(command.filter { $0.hasPrefix("-only-testing:") } == [filter])
        for (key, value) in [("-scheme", "Hello"), ("-configuration", "Debug"), ("-destination", "id=BSP-SIMULATOR")] {
            let index = try #require(command.firstIndex(of: key))
            #expect(command[index + 1] == value)
        }
        await #expect(throws: BuildContextError.self) {
            try await fixture.manager.contextBuildCommand(context, arguments: nil)
        }
        await #expect(throws: BuildContextError.self) {
            try await fixture.manager.resolveContext(.init(
                scope: .init(targets: [id]),
                operation: .compile,
                selection: context.selection,
                buildPolicy: .reuse
            ))
        }
    }

    @Test(arguments: [(BuildContextOperation.run, "Hello"), (.debug, "Hello"), (.debug, "HelloTests")])
    func reuseRunAndDebugPreservePolicyThroughValidation(operation: BuildContextOperation, name: String) async throws {
        let fixture = try await ContextFixture.make()
        defer { fixture.remove() }
        let base = try #require(await fixture.manager.projectSnapshot)
        let target = try #require(base.xcodeTargets.first { $0.name == name })
        let id = try BSPBuildTargetIdentifier(uri: URI(string: target.targetIdentifier.rawValue))
        let context = try await fixture.manager.resolveContext(.init(
            scope: .init(targets: [id]),
            operation: operation,
            selection: ["xcode.scheme": fixture.schemeID, "xcode.destination": "BSP-SIMULATOR"],
            buildPolicy: .reuse
        ))
        #expect(context.buildPolicy == .reuse)
        try await fixture.manager.validateContext(context)
        #expect(try await fixture.manager.contextArguments(context, arguments: nil).contains("id=BSP-SIMULATOR"))
        await #expect(throws: BuildContextError.self) {
            try await fixture.manager.compileContext(context, arguments: nil)
        }
    }
}
