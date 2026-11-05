//
//  XcodeProjectManagerProvider.swift
//  XcodeProjectManagerProvider Module
//
//  Copyright © 2024 Wang Lun.
//

import Foundation

#if os(macOS)
import BuildServerProtocol
import Logger
import XcodeProj
import XcodeProjectManagement

public struct XcodeProjectManagerProvider: ProjectManagerProvider {
    public let name = "XcodeProjectManagerProvider"

    public init() {}

    public func canHandle(projectURL: URL) async -> Bool {
        let fileManager = FileManager.default
        do {
            let contents = try fileManager.contentsOfDirectory(atPath: projectURL.path)
            return contents.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
        } catch {
            return false
        }
    }

    public func createProjectManager(
        rootURL: URL,
        config: ProjectConfiguration?
    ) async throws -> any ProjectManager {
        let toolchain: XcodeToolchain = try await Task.detached {
            let toolchain = XcodeToolchain(workingDirectory: rootURL)
            try await toolchain.initialize()
            return toolchain
        }.value

        // Initialize the project manager
        let projectManager = XcodeProjectManager(
            rootURL: rootURL,
            toolchain: toolchain,
            projectLocator: XcodeProjectLocator(),
            settingsLoader: XcodeSettingsLoader(
                commandBuilder: XcodeBuildCommandBuilder(),
                toolchain: toolchain
            )
        )

        return XcodeBSPProjectManager(backend: projectManager)
    }
}

#else
public struct XcodeProjectManagerProvider: ProjectManagerProvider {
    public let name = "Xcode Project Provider (Disabled)"

    public init() {}

    public func canHandle(projectURL: URL) async -> Bool {
        false
    }

    public func createProjectManager(
        rootURL: URL,
        config: ProjectConfiguration?
    ) async throws -> any ProjectManager {
        throw XcodeProjectManagerProviderError
            .notAvailable("XcodeProjectManagerProvider not available on this platform")
    }
}
#endif

// MARK: - 错误类型

public enum XcodeProjectManagerProviderError: Error, LocalizedError {
    case notAvailable(String)
    case notImplemented(String)

    public var errorDescription: String? {
        switch self {
        case let .notAvailable(message):
            "Xcode provider not available: \(message)"
        case let .notImplemented(message):
            "Xcode provider not implemented: \(message)"
        }
    }
}
