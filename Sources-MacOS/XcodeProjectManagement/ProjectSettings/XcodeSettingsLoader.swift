//
//  XcodeSettingsLoader.swift
//
//  Copyright © 2024 Wang Lun.
//

import Foundation
import Logger

public actor XcodeSettingsLoader {
    let commandBuilder: XcodeBuildCommandBuilder
    private let toolchain: XcodeToolchain
    let jsonDecoder = JSONDecoder()

    public init(commandBuilder: XcodeBuildCommandBuilder, toolchain: XcodeToolchain) {
        self.commandBuilder = commandBuilder
        self.toolchain = toolchain
    }

    public func runXcodeBuild(
        arguments: [String],
        workingDirectory: URL
    ) async throws -> String? {
        let result = try await toolchain.executeXcodeBuild(
            arguments: arguments,
            workingDirectory: workingDirectory
        )

        guard result.exitCode == 0 else {
            throw XcodeProjectError.invalidConfig(result.error ?? result.output)
        }
        return result.output.isEmpty ? nil : result.output
    }
}
