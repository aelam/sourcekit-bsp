//
//  XcodeProjectManager.swift
//
//  Copyright © 2024 Wang Lun.
//

import Foundation
import Logger
import XcodeProj

/// Project Level buildSettings
public struct XcodeGlobalSettings: Sendable, Codable, Hashable {
    public let derivedDataPath: URL // @see PathHash.derivedDataFullPath

    public var indexStoreURL: URL {
        derivedDataPath.appendingPathComponent("Index.noindex/DataStore")
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

public actor XcodeProjectManager {
    public let rootURL: URL
    let projectLocator: XcodeProjectLocator
    let toolchain: XcodeToolchain
    let buildExecutor: XcodeBuildExecutor
    let settingsLoader: XcodeSettingsLoader
    let schemeLoader: XCSchemeLoader
    let destinationLoader = XcodeDestinationLoader()
    var debugSessionManager: DebugSessionManager?
    var indexPreparationTasks: [UUID: Task<[XcodeTargetIdentifier], Error>] = [:]

    private let xcodeProjectReference: XcodeProjectReference?
    private var currentProjectReference: XcodeProjectReference?
    var preferredSchemeName: String? {
        currentProjectReference?.scheme
    }

    public private(set) var projectSnapshot: XcodeProjectSnapshot?

    var projectStore = XcodeProjectStore()

    func loadXcodeProjCache(projectURL: URL) -> XcodeProj? {
        projectStore.project(at: projectURL)
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
        self.currentProjectReference = xcodeProjectReference
        self.toolchain = toolchain
        self.buildExecutor = XcodeBuildExecutor(toolchain: toolchain)
        self.projectLocator = projectLocator
        self.settingsLoader = settingsLoader
        self.schemeLoader = schemeLoader
    }

    /// Cancel this manager's builds and reject further build requests.
    public func shutdownBuilds() async {
        await buildExecutor.shutdown()
    }

    public func initialize() async throws {
        let configURL = rootURL.appendingPathComponent(".sourcekit-bsp/project.json")
        let reference = if FileManager.default.fileExists(atPath: configURL.path) {
            try JSONDecoder().decode(XcodeProjectReference.self, from: Data(contentsOf: configURL))
        } else {
            xcodeProjectReference
        }
        try await toolchain.initialize()
        guard let selectedXcodeInstallation = await toolchain.getSelectedInstallation() else {
            throw XcodeProjectError.toolchainError("No Xcode installation selected")
        }

        let projectLocation = try projectLocator.resolveProjectType(
            rootURL: rootURL,
            xcodeProjectReference: reference
        )

        // Get project-level buildSettings without `xcodebuild`
        let derivedDataPath = PathHash.derivedDataFullPath(for: projectLocation.workspaceOrProjectFileURL.path)
        let xcodeGlobalSettings = XcodeGlobalSettings(derivedDataPath: derivedDataPath)

        try await destinationLoader.loadDestinations(reload: true)

        // Load containers for workspace projects to get actual targets
        var store = XcodeProjectStore()
        let actualTargets = try loadActualTargets(
            projectLocation: projectLocation, store: &store
        )

        let schemes = try schemeLoader.listSchemes(
            projectLocation: projectLocation,
            includeUserSchemes: true
        )

        let projectSnapshot = XcodeProjectSnapshot(
            rootURL: rootURL,
            projectLocation: projectLocation,
            xcodeGlobalSettings: xcodeGlobalSettings,
            xcodeTargets: actualTargets,
            schemes: schemes,
            configuration: reference?.configuration ?? "Debug",
            xcodeInstallation: selectedXcodeInstallation,
        )
        // Publish the project and its caches together after loading succeeds.
        self.currentProjectReference = reference
        self.projectStore = store
        self.projectSnapshot = projectSnapshot
    }

    public func reloadProject() async throws {
        try await initialize()
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
}
