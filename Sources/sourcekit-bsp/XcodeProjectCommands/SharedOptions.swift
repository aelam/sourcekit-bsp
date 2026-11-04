#if os(macOS)
//
//  SharedOptions.swift
//  sourcekit-bsp
//
//  Created by wang.lun on 2025/09/04.
//

import ArgumentParser

struct SharedOptions: ParsableArguments {
    @Option(
        name: .shortAndLong,
        help: "Folder that contains an .xcodeproj or .xcworkspace"
    )
    var workspaceFolder: String

    @Option(
        name: .shortAndLong,
        help: "Xcode project path relative to the project folder, e.g. MyApp.xcodeproj"
    )
    var xcodeproj: String

    @Option(name: .shortAndLong, help: "Xcode target name")
    var target: String

    @Option(name: .shortAndLong, help: "Build configuration, e.g., Debug or Release")
    var configuration: String = "Debug"
}
#endif
