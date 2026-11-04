#if os(macOS)
import ArgumentParser

struct XcodeProjectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcode-project",
        abstract: "Inspect and compile Xcode projects.",
        discussion: """
        Use these commands with a folder that contains an .xcodeproj or \
        .xcworkspace. For projects with more than one Xcode container, \
        configure .sourcekit-bsp/project.json in that folder.
        """,
        subcommands: [
            ResolveProjectCommand.self,
            BuildSettingsCommand.self,
            CompileArgumentsCommand.self,
            CompileTargetCommand.self,
        ]
    )
}
#endif
