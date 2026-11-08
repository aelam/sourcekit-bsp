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
            let contents = try fileManager.contentsOfDirectory(at: projectURL, includingPropertiesForKeys: nil)
            return contents.contains(where: XcodeContainerDiscovery.isBuildContainer)
        } catch {
            return false
        }
    }

    public func canHandle(projectURL: URL, config: ProjectConfiguration?) async throws -> Bool {
        guard await canHandle(projectURL: projectURL) else { return false }
        var directory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: projectURL.appendingPathComponent("Package.swift").path, isDirectory: &directory
        ), !directory.boolValue {
            throw XcodeProjectManagerProviderError.ambiguousBuildSystems
        }
        return true
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

        let project = config?.customSettings["project"]
        let workspace = config?.customSettings["workspace"]
        let reference = project == nil && workspace == nil ? nil : XcodeProjectReference(
            workspace: workspace, project: project
        )
        // Initialize the project manager
        let projectManager = XcodeProjectManager(
            rootURL: rootURL,
            xcodeProjectReference: reference,
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
    case ambiguousBuildSystems

    public var errorDescription: String? {
        switch self {
        case .ambiguousBuildSystems:
            "Both an Xcode container and Package.swift are present. "
                + "Select --package, --project, or --workspace, or configure .sourcekit-bsp/project.json."
        case let .notAvailable(message):
            "Xcode provider not available: \(message)"
        case let .notImplemented(message):
            "Xcode provider not implemented: \(message)"
        }
    }
}
