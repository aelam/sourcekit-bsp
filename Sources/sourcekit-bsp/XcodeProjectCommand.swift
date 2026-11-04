#if os(macOS)
import ArgumentParser

struct XcodeProjectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcode-project",
        abstract: "Inspect and compile Xcode projects.",
        subcommands: [
            ResolveProjectCommand.self,
            BuildSettingsCommand.self,
            CompileArgumentsCommand.self,
            CompileTargetCommand.self,
        ]
    )
}
#endif
