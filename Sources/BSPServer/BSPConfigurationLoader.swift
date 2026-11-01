//
//  BSPConfigurationLoader.swift
//
//  Copyright © 2024 Wang Lun.
//

import Foundation

/// BSP Configuration for Xcode projects
///
/// Supports conditional loading to reduce project loading overhead:
/// - `workspace`: Optional workspace path
/// - `project`: Optional project path
/// - `scheme`: Optional single scheme name
/// - `configuration`: Optional build configuration (defaults to "Debug")
///
/// When schemes are specified, only those schemes and their targets will be loaded,
/// significantly reducing initialization time for large projects.
///
/// Example .sourcekit-bsp/project.json:
/// ```json
/// {
///   "workspace": "MyApp.xcworkspace",
///   "project": "MyApp.xcodeproj",
///   "scheme": "MyApp",
///   "configuration": "Debug"
/// }
/// ```
public struct XcodeBSPConfiguration: Codable, Sendable {
    public let workspace: String?
    public let project: String?
    public let scheme: String?
    public let configuration: String?

    public init(
        workspace: String? = nil,
        project: String? = nil,
        scheme: String? = nil,
        configuration: String? = "Debug"
    ) {
        self.workspace = workspace
        self.project = project
        self.scheme = scheme
        self.configuration = configuration
    }
}

public final class BSPServerConfigurationLoader: Sendable {
    private let rootURL: URL
    private let configurationPath: String

    public init(rootURL: URL, configurationPath: String = ".bsp/xcode.json") {
        self.rootURL = rootURL
        self.configurationPath = configurationPath
    }

    public func findConfiguration() -> URL? {
        let configSearchPaths = [
            // Standard BSP config location for xcode.json
            rootURL.appendingPathComponent(".sourcekit-bsp/project.json"),
        ]

        // First try specific xcode.json path
        if FileManager.default.fileExists(atPath: configSearchPaths[0].path) {
            return configSearchPaths[0]
        }

        // Check .sourcekit-bsp directory for any JSON files
        let bspDir = rootURL.appendingPathComponent(".sourcekit-bsp")
        if FileManager.default.fileExists(atPath: bspDir.path) {
            do {
                let jsonFiles = try FileManager.default
                    .contentsOfDirectory(at: bspDir, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }

                if let firstConfig = jsonFiles.first {
                    return firstConfig
                }
            } catch {
                // Continue to legacy location
            }
        }

        // Fallback to legacy location
        if FileManager.default.fileExists(atPath: configSearchPaths[2].path) {
            return configSearchPaths[2]
        }

        return nil
    }

    public func loadConfiguration() throws -> XcodeBSPConfiguration? {
        let configFileURL: URL

        if configurationPath == ".sourcekit-bsp/project.json" {
            // Use findConfiguration for default path
            guard let foundURL = findConfiguration() else {
                return nil
            }
            configFileURL = foundURL
        } else {
            // Use explicit path
            configFileURL = rootURL.appendingPathComponent(configurationPath)
            guard FileManager.default.fileExists(atPath: configFileURL.path) else {
                return nil
            }
        }

        let data = try Data(contentsOf: configFileURL)
        return try JSONDecoder().decode(XcodeBSPConfiguration.self, from: data)
    }
}
