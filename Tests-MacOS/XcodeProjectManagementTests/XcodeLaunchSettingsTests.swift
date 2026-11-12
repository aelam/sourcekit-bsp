import Foundation
import Support
import Testing
import XcodeProj
@testable import XcodeProjectManagement

struct XcodeLaunchSettingsTests {
    @Test
    func readsOnlyEnabledSettingsAndExpandsBuildSettingsWithoutSplittingTheirValues() throws {
        let action = XCScheme.LaunchAction(runnable: nil, buildConfiguration: "Debug")
        action.commandlineArguments = .init(arguments: [
            .init(name: #"-mode debug --message "hello world" --root $(SRCROOT) ''"#, enabled: true),
            .init(name: "--disabled", enabled: false)
        ])
        action.environmentVariables = [
            .init(variable: "RESOURCES", value: "${SRCROOT}/Assets", enabled: true),
            .init(variable: "DISABLED", value: "ignored", enabled: false)
        ]
        action.customLLDBInitFile = "$(UNRESOLVED)/.lldbinit"
        let settings = try XcodeLaunchSettings(action: action, buildSettings: ["SRCROOT": "/tmp/My Project"])
        #expect(settings.arguments == ["-mode", "debug", "--message", "hello world", "--root", "/tmp/My Project", ""])
        #expect(settings.environment == ["RESOURCES": "/tmp/My Project/Assets"])
        #expect(settings.workingDirectory == nil)
    }

    @Test
    func tokenizesQuotesAndEscapesWithoutExecutingShellSyntax() throws {
        let arguments = try XcodeLaunchSettings
            .splitArguments(#"one\ two "quoted \"word\"" 'literal $HOME' ; `command`"#)
        #expect(arguments == ["one two", "quoted \"word\"", "literal $HOME", ";", "`command`"])
    }

    @Test(arguments: ["'unterminated", "trailing\\"])
    func invalidArgumentSyntaxFails(value: String) {
        #expect(throws: XcodeRunError.self) { try XcodeLaunchSettings.splitArguments(value) }
    }

    @Test
    func rejectsUnresolvedOrCyclicBuildSettings() {
        #expect(throws: XcodeRunError.self) { try XcodeLaunchSettings.expand("$(MISSING)", using: [:]) }
        #expect(throws: XcodeRunError.self) {
            try XcodeLaunchSettings.expand("$(ROOT)", using: ["ROOT": "${ROOT}"])
        }
    }

    @Test(arguments: [false, true])
    func simulatorReceivesArgumentsAndChildEnvironment(stopped: Bool) async throws {
        let commands = SimulatorCommandRunner { arguments, environment, _ in
            if arguments.contains("bootstatus") {
                #expect(environment.isEmpty)
            } else {
                var expected = ["simctl", "launch"]
                if stopped { expected.append("--wait-for-debugger") }
                expected += ["SIM", "com.example.App", "--message", "hello world"]
                #expect(arguments == expected)
                #expect(!arguments.contains("--console"))
                #expect(environment == ["SIMCTL_CHILD_FEATURE": "enabled"])
            }
            return ProcessExecutionResult(output: "com.example.App: 4321", error: nil, exitCode: 0)
        }
        let settings = XcodeLaunchSettings(arguments: ["--message", "hello world"], environment: ["FEATURE": "enabled"])
        if stopped {
            let pid = try await SimulatorDebugLauncher(commands: commands).launchWaitingForDebugger(
                deviceID: "SIM", appIdentifier: "com.example.App", settings: settings
            )
            #expect(pid == 4321)
        } else {
            let result = try await SimulatorLauncher(commands: commands).launchApp(
                deviceID: "SIM", appIdentifier: "com.example.App", settings: settings
            )
            #expect(result.isSuccess)
        }
    }

    @Test(arguments: [false, true])
    func deviceReceivesArgumentsAndJSONEnvironment(stopped: Bool) async throws {
        let commands = DeviceCommandRunner { arguments, _ in
            #expect(arguments.contains("--start-stopped") == stopped)
            #expect(arguments.suffix(4) == ["com.example.App", "--", "--message", "hello world"])
            let environmentIndex = try #require(arguments.firstIndex(of: "--environment-variables"))
            let environment = try JSONDecoder().decode(
                [String: String].self,
                from: Data(arguments[environmentIndex + 1].utf8)
            )
            #expect(environment == ["FEATURE": "enabled", "QUOTED": "a\"b"])
            let outputIndex = try #require(arguments.firstIndex(of: "--json-output"))
            try #"{"info":{"outcome":"success"},"result":{"process":{"processIdentifier":4321}}}"#
                .write(toFile: arguments[outputIndex + 1], atomically: true, encoding: .utf8)
            return ProcessExecutionResult(output: "", error: nil, exitCode: 0)
        }
        let pid = try await commands.launch(
            deviceID: "PHONE",
            bundleID: "com.example.App",
            stopped: stopped,
            settings: .init(
                arguments: ["--message", "hello world"],
                environment: ["FEATURE": "enabled", "QUOTED": "a\"b"]
            )
        )
        #expect(pid == 4321)
    }
}
