#if os(macOS)
//
//  CompileTargetCommand.swift
//  sourcekit-bsp
//
//  Created by wang.lun on 2025/09/07.
//

import ArgumentParser
import Foundation
import XcodeProjectManagement

struct CompileTargetCommand: AsyncParsableCommand {
    @Option(
        name: .shortAndLong,
        help: "Folder that contains an .xcodeproj or .xcworkspace"
    )
    var workspaceFolder: String

    @Option(name: .shortAndLong, help: "Xcode target name")
    var target: String

    static let configuration = CommandConfiguration(
        commandName: "compile-target",
        abstract: "Compile an Xcode target."
    )

    mutating func run() async throws {
        try await compileTarget()
    }

    private func compileTarget() async throws {
        let timestamp = Date()
        // Load the project
        print("Loading Xcode project at: \(timestamp)")
        print("Loading Xcode project from: \(workspaceFolder)")

        let workspaceFolder = workspaceFolder.absolutePath
        let rootURL = URL(fileURLWithPath: workspaceFolder)

        let preferredProjectInfoURL = rootURL.appendingPathComponent(".sourcekit-bsp/project.json")
        let xcodeProjectReference: XcodeProjectReference? =
            try? JSONDecoder().decode(
                XcodeProjectReference.self,
                from: Data(contentsOf: preferredProjectInfoURL)
            )

        let toolchain = XcodeToolchain(workingDirectory: rootURL)
        let projectManager = XcodeProjectManager(
            rootURL: rootURL,
            xcodeProjectReference: xcodeProjectReference,
            toolchain: toolchain,
            projectLocator: XcodeProjectLocator(),
            settingsLoader: XcodeSettingsLoader(
                commandBuilder: XcodeBuildCommandBuilder(),
                toolchain: toolchain
            )
        )

        try await projectManager.initialize()

        guard let baseProjectInfo = await projectManager.xcodeProjectBaseInfo else {
            print("❌ Project loaded Failed")
            return
        }

        guard let target = baseProjectInfo.xcodeTargets.first(where: { $0.name == target }) else {
            print("target not found")
            return
        }

        print("Compiling: \(workspaceFolder)")

        let result = try await projectManager.compileTarget(
            targetIdentifier: target.targetIdentifier,
            configuration: "Debug"
        )
        print(result)

        let endTimestamp = Date()
        print("Loading time: \(endTimestamp.timeIntervalSince(timestamp)) seconds")
    }
}
#endif
