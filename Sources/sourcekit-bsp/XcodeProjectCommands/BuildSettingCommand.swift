#if os(macOS)
import ArgumentParser
import Foundation
import PathKit
import XcodeProj
import XcodeProjectManagement

struct BuildSettingsCommand: AsyncParsableCommand {
    @OptionGroup
    var options: SharedOptions

    static let configuration = CommandConfiguration(
        commandName: "buildSettings",
        abstract: "buildSettings: Print build settings for an Xcode target"
    )

    mutating func run() async throws {
        let targetInfo = TargetInfo(sharedOptions: options)
        try await printBuildSettings(targetInfo: targetInfo)
    }

    private func printBuildSettings(targetInfo: TargetInfo) async throws {
        let xcodeGlobalSettings =
            XcodeGlobalSettings(derivedDataPath: targetInfo.derivedDataPath)

        let xcodeToolchain = XcodeToolchain(workingDirectory: targetInfo.projectFolder)
        try await xcodeToolchain.initialize()
        guard let xcodeInstallation = await xcodeToolchain
            .getSelectedInstallation() else {
            print("No Xcode installation selected.")
            return
        }

        let xcodeProj = try XcodeProj(path: Path(targetInfo.projectFileFullPath.path))

        let buildSettingsResolver = try BuildSettingResolver(
            xcodeInstallation: xcodeInstallation,
            xcodeGlobalSettings: xcodeGlobalSettings,
            xcodeProj: xcodeProj,
            target: targetInfo.targetName,
            configuration: targetInfo.configurationName
        )
        for (key, value) in buildSettingsResolver.resolvedBuildSettings {
            print("\(key): \(value)")
        }
    }
}
#endif
