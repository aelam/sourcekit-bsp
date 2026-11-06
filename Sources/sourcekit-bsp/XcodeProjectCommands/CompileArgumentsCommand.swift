#if os(macOS)
import ArgumentParser
import Foundation
import PathKit
import XcodeProj
import XcodeProjectManagement

struct CompileArgumentsCommand: AsyncParsableCommand {
    @OptionGroup
    var options: SharedOptions
    @Option(
        name: .shortAndLong,
        help: "Source file path relative to the project folder"
    )
    var sourceFile: String

    static let configuration = CommandConfiguration(
        commandName: "compile-arguments",
        abstract: "Print compile arguments for a source file."
    )

    mutating func run() async throws {
        let targetInfo = TargetInfo(sharedOptions: options)
        let fileInfo = SourceFileInfo(targetInfo: targetInfo, filePath: sourceFile)

        try await printCompileArguments(fileInfo: fileInfo)
    }

    private func printCompileArguments(fileInfo: SourceFileInfo) async throws {
        let xcodeGlobalSettings =
            XcodeGlobalSettings(derivedDataPath: fileInfo.targetInfo.derivedDataPath)

        let xcodeToolchain = XcodeToolchain(workingDirectory: fileInfo.targetInfo.projectFolder)
        try await xcodeToolchain.initialize()
        guard let xcodeInstallation = await xcodeToolchain
            .getSelectedInstallation() else {
            return
        }
        try await xcodeToolchain.initialize()
        let xcodeProj = try XcodeProj(path: Path(fileInfo.targetInfo.projectFileFullPath.path))

        let targetIdentifier = XcodeTargetIdentifier(
            projectFilePath: fileInfo.targetInfo.projectFileFullPath.path,
            targetName: fileInfo.targetInfo.targetName
        )
        let sourceItems = SourceFileLister.loadSourceFiles(
            for: xcodeProj,
            targets: [fileInfo.targetInfo.targetName]
        )[targetIdentifier.rawValue] ?? []

        let generator = try CompileArgGenerator.create(
            xcodeInstallation: xcodeInstallation,
            xcodeGlobalSettings: xcodeGlobalSettings,
            xcodeProj: xcodeProj,
            target: fileInfo.targetInfo.targetName,
            configurationName: fileInfo.targetInfo.configurationName,
            fileURL: fileInfo.fileFullPath,
            sourceItems: sourceItems
        )
        let flags = generator.compileArguments()
        for flag in flags {
            print(flag)
        }
    }
}
#endif
