import Foundation
import PathKit
import Testing
import XcodeProj
@testable import XcodeProjectManagement

struct CompilerArgsGeneratorTests {
    ///
    @Test
    func resolveProjectSwiftCompilerFlags() async throws {
        let targetName = "HelloUITests"
        let fileName = "HelloUITestsLaunchTests.swift"

        let projectFolder = try #require(Bundle.module.resourceURL?
            .appendingPathComponent("DemoProjects")
            .appendingPathComponent("HelloWorkspace"))
        let projectFilePath = projectFolder
            .appendingPathComponent("Hello.xcodeproj").path
        let derivedDataPath = PathHash.derivedDataFullPath(for: projectFilePath)
        let xcodeGlobalSettings =
            XcodeGlobalSettings(derivedDataPath: derivedDataPath)

        let xcodeToolchain = XcodeToolchain()
        try await xcodeToolchain.initialize()
        guard let xcodeInstallation = await xcodeToolchain
            .getSelectedInstallation() else {
            return
        }
        try await xcodeToolchain.initialize()
        let xcodeProj = try XcodeProj(path: Path(projectFilePath))

        let swiftFile = projectFolder
            .appendingPathComponent(targetName)
            .appendingPathComponent(fileName)

        let targetIdentifier = XcodeTargetIdentifier(
            projectFilePath: projectFilePath,
            targetName: targetName
        )
        let sourceItems = SourceFileLister.loadSourceFiles(
            for: xcodeProj,
            targets: [targetName]
        )[targetIdentifier.rawValue] ?? []

        let generator = try CompileArgGenerator.create(
            xcodeInstallation: xcodeInstallation,
            xcodeGlobalSettings: xcodeGlobalSettings,
            xcodeProj: xcodeProj,
            target: targetName,
            configurationName: "Debug",
            fileURL: swiftFile,
            sourceItems: sourceItems
        )
        let flags = generator.compileArguments()
        let swiftVersionFlag = try #require(flags.firstIndex(of: "-swift-version"))
        #expect(flags[swiftVersionFlag + 1] == "5")
    }

    @Test
    func resolveProjectClangCompilerFlags() async throws {
        let projectFolder = try #require(Bundle.module.resourceURL?
            .appendingPathComponent("DemoProjects")
            .appendingPathComponent("HelloWorkspace"))
        let projectFilePath = projectFolder
            .appendingPathComponent("Hello.xcodeproj").path
        let derivedDataPath = PathHash.derivedDataFullPath(for: projectFilePath)
        let xcodeGlobalSettings =
            XcodeGlobalSettings(derivedDataPath: derivedDataPath)

        let xcodeToolchain = XcodeToolchain()
        try await xcodeToolchain.initialize()
        guard let xcodeInstallation = await xcodeToolchain
            .getSelectedInstallation() else {
            return
        }
        try await xcodeToolchain.initialize()
        let xcodeProj = try XcodeProj(path: Path(projectFilePath))

        let clangFile = projectFolder
            .appendingPathComponent("HelloObjectiveC")
            .appendingPathComponent("Person.m")

        let targetIdentifier = XcodeTargetIdentifier(
            projectFilePath: projectFilePath,
            targetName: "HelloObjectiveC"
        )
        let sourceItems = SourceFileLister.loadSourceFiles(
            for: xcodeProj,
            targets: ["HelloObjectiveC"]
        )[targetIdentifier.rawValue] ?? []

        let generator = try CompileArgGenerator.create(
            xcodeInstallation: xcodeInstallation,
            xcodeGlobalSettings: xcodeGlobalSettings,
            xcodeProj: xcodeProj,
            target: "HelloObjectiveC",
            configurationName: "Debug",
            fileURL: clangFile,
            sourceItems: sourceItems
        )
        let flags = generator.compileArguments()
        let hasTarget = flags.contains("-target")
        let hasSDKRoot = flags.contains("-isysroot")
        #expect(hasTarget)
        #expect(hasSDKRoot)
    }
}
