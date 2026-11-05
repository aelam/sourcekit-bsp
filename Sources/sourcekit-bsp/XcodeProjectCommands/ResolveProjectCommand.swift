#if os(macOS)
//
//  ResolveProjectCommand.swift
//  sourcekit-bsp
//
//  Created by wang.lun on 2025/09/04.
//

import ArgumentParser
import Foundation
import XcodeProjectManagement

struct ResolveProjectCommand: AsyncParsableCommand {
    @Option(
        name: .shortAndLong,
        help: "Folder that contains an .xcodeproj or .xcworkspace"
    )
    var workspaceFolder: String

    static let configuration = CommandConfiguration(
        commandName: "resolve-project",
        abstract: "Resolve the Xcode project for a folder.",
        discussion: """
        Pass the project folder, not the .xcodeproj file. If the folder \
        contains multiple projects or workspaces, configure \
        .sourcekit-bsp/project.json first.
        """
    )

    mutating func run() async throws {
        try await resolveProject()
    }

    private func resolveProject() async throws {
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

        guard let baseProjectInfo = await projectManager.projectSnapshot else {
            print("❌ Project loaded Failed")
            return
        }
        print("✅ Project loaded successfully")

        print("  - Root URL: \(baseProjectInfo.rootURL.path)")
        print("  - Project Configuration: \(baseProjectInfo.configuration)")
        print(
            " - Project Targets: \(baseProjectInfo.xcodeTargets.map(\.name).joined(separator: ", "))"
        )

        // Targets
        print("\n✅🗂️ Target Information:")
        for target in baseProjectInfo.xcodeTargets {
            print("  - Target Name: \(target.name)")
            print("  - xcodeProductType: \(target.xcodeProductType)")
        }

        // Show indexing paths
        let xcodeGlobalSettings = baseProjectInfo.xcodeGlobalSettings
        print("\n✅🗂️ Indexing Information:")
        print("  - Index Store URL: \(xcodeGlobalSettings.indexStoreURL.path)")
        print("  - Index Database URL: \(xcodeGlobalSettings.indexDatabaseURL.path)")
        print("  - Derived Data Path: \(xcodeGlobalSettings.derivedDataPath.path)")
        print("  - Configuration: \(baseProjectInfo.configuration)")
        let targetIdentifiers = baseProjectInfo.xcodeTargets.map(\.targetIdentifier)
        let sourcesItems = await projectManager
            .getSourcesItems(targetIdentifiers: targetIdentifiers)
        for sourcesItem in sourcesItems {
            print("Sources for target \(sourcesItem.target):")
            for source in sourcesItem.sources {
                print(" - \(source.path)")
            }
        }

        let endTimestamp = Date()
        print("Loading time: \(endTimestamp.timeIntervalSince(timestamp)) seconds")
    }
}
#endif
