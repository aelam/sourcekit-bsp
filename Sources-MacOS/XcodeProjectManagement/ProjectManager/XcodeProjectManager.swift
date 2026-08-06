//
//  XcodeProjectManager.swift
//
//  Copyright © 2024 Wang Lun.
//

import Foundation
import Logger
import PathKit
import XcodeProj

/// Project Level buildSettings
public struct XcodeGlobalSettings: Sendable, Codable, Hashable {
    public let derivedDataPath: URL // @see PathHash.derivedDataFullPath

    public var indexStoreURL: URL {
        derivedDataPath.appendingPathComponent("Index.noIndex/DataStore")
    }

    public var indexDatabaseURL: URL {
        derivedDataPath.appendingPathComponent("IndexDatabase.noIndex")
    }

    public var symRoot: URL {
        derivedDataPath.appendingPathComponent("Build/Products")
    }

    public var objRoot: URL {
        derivedDataPath.appendingPathComponent("Build/Intermediates.noindex")
    }

    public var sdkStatCacheDir: URL { // SDK_STAT_CACHE_DIR
        derivedDataPath.deletingLastPathComponent()
    }

    public var sdkStatCachePath: URL { // SDK_STAT_CACHE_PATH
        sdkStatCacheDir.appendingPathComponent("SDKStatCache")
    }

    public var moduleCachePath: URL { // parent of derivedDataPath
        derivedDataPath.deletingLastPathComponent()
            .appendingPathComponent("ModuleCache.noindex")
    }

    public var buildDir: URL {
        derivedDataPath.appendingPathComponent("Build/Products")
    }

    public init(derivedDataPath: URL) {
        self.derivedDataPath = derivedDataPath
    }
}

public struct XcodeTargetInfo: Sendable {
    public let targetIdentifier: String
    public let name: String
    public let xcodeProductType: XcodeProductType
    public let buildSettings: [String: String]

    public init(
        targetIdentifier: String,
        name: String,
        xcodeProductType:
        XcodeProductType,
        buildSettings: [String: String]
    ) {
        self.targetIdentifier = targetIdentifier
        self.name = name
        self.xcodeProductType = xcodeProductType
        self.buildSettings = buildSettings
    }
}

public actor XcodeProjectManager {
    public let rootURL: URL
    let projectLocator: XcodeProjectLocator
    let toolchain: XcodeToolchain
    let settingsLoader: XcodeSettingsLoader
    let schemeLoader: XCSchemeLoader
    let destinationLoader = XcodeDestinationLoader()

    private let xcodeProjectReference: XcodeProjectReference?
    public private(set) var xcodeProjectBaseInfo: XcodeProjectBaseInfo?

    private var xcodeProjCache: [URL: XcodeProj] = [:]
    private var sourceFileMapCache: [String: [SourceItem]] = [:]

    func loadXcodeProjCache(projectURL: URL) -> XcodeProj? {
        if let cachedXcodeProj = xcodeProjCache[projectURL] {
            return cachedXcodeProj
        }
        let projectURLPath = Path(projectURL.path)
        let xcodeProj = try? XcodeProj(path: projectURLPath)
        xcodeProjCache[projectURL] = xcodeProj
        return xcodeProj
    }

    /// Invalidate cached parsed projects and source-file maps so the next
    /// query re-reads them from disk. Called when watched files change.
    public func clearCaches() {
        xcodeProjCache.removeAll()
        sourceFileMapCache.removeAll()
    }

    public init(
        rootURL: URL,
        xcodeProjectReference: XcodeProjectReference? = nil,
        toolchain: XcodeToolchain,
        projectLocator: XcodeProjectLocator,
        settingsLoader: XcodeSettingsLoader,
        schemeLoader: XCSchemeLoader = XCSchemeLoader()
    ) {
        self.rootURL = rootURL
        self.xcodeProjectReference = xcodeProjectReference
        self.toolchain = toolchain
        self.projectLocator = projectLocator
        self.settingsLoader = settingsLoader
        self.schemeLoader = schemeLoader
    }

    public func initialize() async throws {
        try await toolchain.initialize()
        guard let selectedXcodeInstallation = await toolchain.getSelectedInstallation() else {
            throw XcodeProjectError.toolchainError("No Xcode installation selected")
        }

        let projectLocation = try projectLocator.resolveProjectType(
            rootURL: rootURL,
            xcodeProjectReference: xcodeProjectReference
        )

        // Get project-level buildSettings without `xcodebuild`
        let derivedDataPath = PathHash.derivedDataFullPath(for: projectLocation.workspaceOrProjectFileURL.path)
        let xcodeGlobalSettings = XcodeGlobalSettings(derivedDataPath: derivedDataPath)

        try await destinationLoader.loadDestinations(reload: true)

        // Load containers for workspace projects to get actual targets
        let actualTargets = try await loadActualTargets(
            projectLocation: projectLocation
        )

        let schemes = try schemeLoader.listSchemes(
            projectLocation: projectLocation,
            includeUserSchemes: true
        )

        let xcodeProjectBaseInfo = XcodeProjectBaseInfo(
            rootURL: rootURL,
            projectLocation: projectLocation,
            xcodeGlobalSettings: xcodeGlobalSettings,
            xcodeTargets: actualTargets,
            schemes: schemes,
            configuration: xcodeProjectReference?.configuration ?? "Debug",
            xcodeInstallation: selectedXcodeInstallation,
        )
        self.xcodeProjectBaseInfo = xcodeProjectBaseInfo
    }
}

// MARK: - Utilities Extension

extension XcodeProjectManager {
    /// Resolve project path from workspace file reference
    func resolveProjectPath(from location: XCWorkspaceDataElementLocationType, workspaceURL: URL) -> URL? {
        let workspaceDir = workspaceURL.deletingLastPathComponent()

        switch location {
        case let .group(path):
            return workspaceDir.appendingPathComponent(path)
        case let .absolute(path):
            return URL(fileURLWithPath: path)
        case let .container(path):
            return workspaceDir.appendingPathComponent(path)
        case let .current(path):
            return workspaceDir.appendingPathComponent(path)
        case let .developer(path):
            // Developer directory path - this is more complex, but for now treat as relative
            return workspaceDir.appendingPathComponent(path)
        case let .other(_, path):
            // Fallback: treat as relative path
            return workspaceDir.appendingPathComponent(path)
        }
    }

    /// Load targets from a single project using XcodeProj
    private func loadTargetsFromProject(projectURL: URL) async throws -> [XcodeTarget] {
        try loadTargetsFromXcodeProj(projectURL: projectURL)
    }
}
