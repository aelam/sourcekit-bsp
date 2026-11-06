import Foundation
import PathKit
import XcodeProj
@testable import XcodeProjectManagement

struct SourceFileInfo: Sendable {
    let projectFolder: URL
    let filePath: String // relative to projectFolder
    let projectFilePath: String // relative to projectFolder
    let targetName: String
    let configurationName: String = "Debug"
    var derivedDataPath: URL {
        PathHash.derivedDataFullPath(for: projectFolder.appendingPathComponent(projectFilePath).path)
    }

    var projectFileFullPath: URL {
        projectFolder.appendingPathComponent(projectFilePath)
    }
}

func processFileCompileArguments(_ fileInfo: SourceFileInfo) async throws {
    let xcodeGlobalSettings =
        XcodeGlobalSettings(derivedDataPath: fileInfo.derivedDataPath)

    let xcodeToolchain = XcodeToolchain()
    try await xcodeToolchain.initialize()
    guard let xcodeInstallation = await xcodeToolchain
        .getSelectedInstallation() else {
        return
    }
    try await xcodeToolchain.initialize()
    let xcodeProj = try XcodeProj(path: Path(fileInfo.projectFileFullPath.path))

    let file = fileInfo.projectFolder
        .appendingPathComponent(fileInfo.filePath)

    let targetIdentifier = XcodeTargetIdentifier(
        projectFilePath: fileInfo.projectFileFullPath.path,
        targetName: fileInfo.targetName
    )
    let sourceItems = SourceFileLister.loadSourceFiles(
        for: xcodeProj,
        targets: [fileInfo.targetName]
    )[targetIdentifier.rawValue] ?? []

    let generator = try CompileArgGenerator.create(
        xcodeInstallation: xcodeInstallation,
        xcodeGlobalSettings: xcodeGlobalSettings,
        xcodeProj: xcodeProj,
        target: fileInfo.targetName,
        configurationName: fileInfo.configurationName,
        fileURL: file,
        sourceItems: sourceItems
    )
    let flags = generator.compileArguments()
    for flag in flags {
        print(flag)
    }
}
