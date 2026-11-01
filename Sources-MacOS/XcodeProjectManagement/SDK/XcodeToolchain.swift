//
//  XcodeToolchain.swift
//
//  Copyright © 2024 Wang Lun.
//

import Foundation
import Support

public enum XcodeToolchainError: Error, LocalizedError {
    case xcodeNotFound
    case xcodeVersionNotSupported(String)
    case xcodebuildNotFound
    case invalidDeveloperDir(String)
    case toolchainSelectionFailed(String)
    case invalidSDK(String)

    public var errorDescription: String? {
        switch self {
        case .xcodeNotFound:
            "No Xcode installation found"
        case let .xcodeVersionNotSupported(version):
            "Xcode version \(version) is not supported"
        case .xcodebuildNotFound:
            "xcodebuild tool not found"
        case let .invalidDeveloperDir(path):
            "Invalid DEVELOPER_DIR: \(path)"
        case let .toolchainSelectionFailed(reason):
            "Failed to select toolchain: \(reason)"
        case let .invalidSDK(reason):
            "Invalid SDK: \(reason)"
        }
    }
}

public struct XcodeInstallation: Sendable, Codable {
    public let path: URL
    public let version: String
    public let buildVersion: String
    public let isXcodeVersionFileVersion: Bool // .xcode-version
    public let isDeveloperDirVersion: Bool // DEVELOPER_DIR
    public let isXcodeSelectedVersion: Bool // xcode-select --print-path

    public var developerDir: URL {
        path.appendingPathComponent("Contents/Developer")
    }

    public var xcodebuildPath: URL {
        developerDir.appendingPathComponent("usr/bin/xcodebuild")
    }

    public var isValid: Bool {
        FileManager.default.fileExists(atPath: xcodebuildPath.path)
    }

    public var toolchainDir: URL {
        developerDir.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain")
    }
}

public extension XcodeInstallation {
    func defaultDeploymentTarget(
        for platformName: String,
        forSimulator: Bool = false
    ) throws -> SDK {
        let platform = Platform(rawValue: platformName) ?? .iOSSimulator

        let sdkDir = developerDir
            .appendingPathComponent("Platforms")
            .appendingPathComponent(
                "\(platform.platformPathName).platform/Developer/SDKs"
            )

        guard
            let contents = try? FileManager.default
            .contentsOfDirectory(atPath: sdkDir.path)
        else {
            throw XcodeToolchainError.invalidSDK("No SDK found for \(platformName)")
        }
        let sdkNames = contents.filter { $0.hasSuffix(".sdk") }
            .sorted(by: compareSDK)
            .reversed()
        guard let sdkName = sdkNames.first else {
            throw XcodeToolchainError.invalidSDK("No SDK found for \(platformName)")
        }
        let sdkPath = sdkDir.appendingPathComponent(sdkName).path
        let plistPath = sdkPath + "/System/Library/CoreServices/SystemVersion.plist"

        guard let dict = NSDictionary(contentsOfFile: plistPath) else {
            throw XcodeToolchainError.invalidSDK("Cannot read SDK plist at \(plistPath)")
        }
        guard let buildVersion = dict["ProductBuildVersion"] as? String else {
            throw XcodeToolchainError.invalidSDK("Cannot find ProductBuildVersion in \(plistPath)")
        }
        guard let productVersion = dict["ProductVersion"] as? String else {
            throw XcodeToolchainError.invalidSDK("Cannot find ProductVersion in \(plistPath)")
        }

        return SDK(
            name: platformName,
            version: productVersion,
            path: sdkPath,
            buildVersion: buildVersion
        )
    }
}

public struct XcodeBuildResult: Sendable {
    public let output: String
    public let error: String?
    public let exitCode: XcodeBuildExitCode
}

public typealias XcodeBuildExitCode = Int32

public actor XcodeToolchain {
    private var selectedInstallation: XcodeInstallation?
    private var availableInstallations: [XcodeInstallation] = []
    private let customDeveloperDir: String?
    private let workingDirectory: URL?
    private let processExecutor = ProcessExecutor()
    private let commonXcodePaths = [
        "/Applications/Xcode.app",
        "/Applications/Xcode-beta.app"
    ]

    public init(
        customDeveloperDir: String? = nil,
        workingDirectory: URL? = nil
    ) {
        self.customDeveloperDir = customDeveloperDir
        self.workingDirectory = workingDirectory
    }

    deinit {
        // Clean up any remaining resources
        selectedInstallation = nil
        availableInstallations.removeAll()
    }

    public func initialize() async throws {
        guard selectedInstallation == nil else {
            return
        }
        try await discoverXcodeInstallations()
        try await selectBestInstallation()
    }

    public func getSelectedInstallation() -> XcodeInstallation? {
        selectedInstallation
    }

    public func createXcodeBuildProcess(
        arguments: [String],
        workingDirectory: URL? = nil,
        xcodeBuildEnvironments: [String: String] = [:]
    ) throws -> Process {
        guard let installation = selectedInstallation else {
            throw XcodeToolchainError.xcodeNotFound
        }

        return ProcessExecutor.createXcodeBuildProcess(
            arguments: arguments,
            workingDirectory: workingDirectory,
            xcodeInstallationPath: installation.path,
            xcodeBuildEnvironments: xcodeBuildEnvironments
        )
    }

    public func executeXcodeBuild(
        arguments: [String],
        workingDirectory: URL? = nil,
        xcodeBuildEnvironments: [String: String] = [:]
    ) async throws -> XcodeBuildResult {
        guard let installation = selectedInstallation else {
            throw XcodeToolchainError.xcodeNotFound
        }

        let result = try await processExecutor.executeXcodeBuild(
            arguments: arguments,
            workingDirectory: workingDirectory,
            xcodeInstallationPath: installation.path,
            xcodeBuildEnvironments: xcodeBuildEnvironments
        )

        return XcodeBuildResult(
            output: result.output,
            error: result.error,
            exitCode: result.exitCode
        )
    }

    public func getXcodeVersion() async throws -> String {
        guard selectedInstallation != nil else {
            throw XcodeToolchainError.xcodeNotFound
        }

        let result = try await executeXcodeBuild(arguments: ["-version"])
        guard result.exitCode == 0 else {
            let errorMessage = result.error ?? "xcodebuild -version failed"
            throw XcodeToolchainError.toolchainSelectionFailed(errorMessage)
        }

        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func isXcodeBuildAvailable() async -> Bool {
        guard let installation = selectedInstallation else {
            return false
        }

        return installation.isValid
    }

    // MARK: - Private Methods

    private func discoverXcodeInstallations() async throws {
        var installations: [XcodeInstallation] = []

        installations += await findDeveloperDirInstallations()
        installations += await findCommonPathInstallations()
        installations += await findAdditionalXcodeVersions()

        self.availableInstallations = deduplicateInstallations(installations)
    }

    private func selectBestInstallation() async throws {
        guard !availableInstallations.isEmpty else {
            throw XcodeToolchainError.xcodeNotFound
        }

        // 1. .xcode-version file
        if let workingDirectory {
            let xcodeVersionFileURL = workingDirectory.appendingPathComponent(".xcode-version")
            if let versionString = try? String(contentsOf: xcodeVersionFileURL)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !versionString.isEmpty,
                let fileVersionInstallation = availableInstallations
                .first(where: { $0.version.contains(versionString) }) {
                selectedInstallation = fileVersionInstallation
                return
            }
        }

        // 2. Prefer DEVELOPER_DIR set installation
        if let developerDirInstallation = availableInstallations
            .first(where: { $0.isDeveloperDirVersion }) {
            selectedInstallation = developerDirInstallation
            return
        }

        // 3. Prefer the active Xcode installation
        if let activeInstallation = availableInstallations.first(where: { $0.isXcodeSelectedVersion }) {
            selectedInstallation = activeInstallation
            return
        }

        // 3. Use the latest available version
        selectedInstallation = availableInstallations.first
    }

    private func createInstallation(
        from xcodeURL: URL,
        isXcodeVersionFileVersion: Bool = false,
        isDeveloperDirVersion: Bool = false,
        isXcodeSelectedVersion: Bool = false
    ) async throws -> XcodeInstallation {
        try XcodeInstallationFactory.createInstallation(
            from: xcodeURL,
            isXcodeVersionFileVersion: isXcodeVersionFileVersion,
            isDeveloperDirVersion: isDeveloperDirVersion,
            isXcodeSelectedVersion: isXcodeSelectedVersion
        )
    }

    private func findActiveXcodePath() async throws -> String? {
        try await XcodePathResolver.findActiveXcodePath()
    }

    private func findDeveloperDirInstallations() async -> [XcodeInstallation] {
        var installations: [XcodeInstallation] = []

        // Check DEVELOPER_DIR environment variable
        if let customDir = customDeveloperDir ?? ProcessInfo.processInfo
            .environment["DEVELOPER_DIR"] {
            let developerDirURL = URL(fileURLWithPath: customDir)
            let xcodeURL = developerDirURL.deletingLastPathComponent()
                .deletingLastPathComponent()

            if let installation = try? await createInstallation(
                from: xcodeURL,
                isDeveloperDirVersion: true
            ) {
                installations.append(installation)
            }
        }

        // Check current xcode-select --print-path
        if let currentDeveloperDir = try? await XcodePathResolver
            .getCurrentDeveloperDir() {
            let developerDirURL = URL(fileURLWithPath: currentDeveloperDir)
            let xcodeURL = developerDirURL.deletingLastPathComponent()
                .deletingLastPathComponent()

            let alreadyFound = installations
                .contains { $0.path.path == xcodeURL.path }
            if !alreadyFound, let installation = try? await createInstallation(
                from: xcodeURL,
                isDeveloperDirVersion: false,
                isXcodeSelectedVersion: true
            ) {
                installations.append(installation)
            }
        }

        return installations
    }

    private func findCommonPathInstallations() async -> [XcodeInstallation] {
        var installations: [XcodeInstallation] = []
        for path in commonXcodePaths {
            let xcodeURL = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: xcodeURL.path),
               let installation = try? await createInstallation(
                   from: xcodeURL,
                   isXcodeVersionFileVersion: false,
                   isDeveloperDirVersion: false,
                   isXcodeSelectedVersion: false
               ) {
                installations.append(installation)
            }
        }

        return installations
    }

    private func findAdditionalXcodeVersions() async -> [XcodeInstallation] {
        var installations: [XcodeInstallation] = []

        if let applicationsContents = try? FileManager.default
            .contentsOfDirectory(atPath: "/Applications") {
            for item in applicationsContents {
                if item.hasPrefix("Xcode"), item.hasSuffix(".app"),
                   !commonXcodePaths.contains("/Applications/\(item)") {
                    let xcodeURL = URL(fileURLWithPath: "/Applications/\(item)")
                    if let installation = try? await createInstallation(
                        from: xcodeURL
                    ) {
                        installations.append(installation)
                    }
                }
            }
        }

        return installations
    }

    private func deduplicateInstallations(_ installations: [XcodeInstallation])
        -> [XcodeInstallation] {
        let uniqueInstallations = installations
            .reduce(into: [String: XcodeInstallation]()) { dict, installation in
                let path = installation.path.path
                if let existing = dict[path] {
                    dict[path] = installation
                        .isDeveloperDirVersion ? installation : existing
                } else {
                    dict[path] = installation
                }
            }.values

        return uniqueInstallations.sorted {
            let comparison = $0.version.compare($1.version, options: .numeric)
            return comparison == .orderedSame
                ? $0.path.path < $1.path.path
                : comparison == .orderedDescending
        }
    }
}

// MARK: - Helper Classes

private enum XcodeInstallationFactory {
    static func createInstallation(
        from xcodeURL: URL,
        isXcodeVersionFileVersion: Bool = false,
        isDeveloperDirVersion: Bool = false,
        isXcodeSelectedVersion: Bool = false
    ) throws -> XcodeInstallation {
        let infoPlistURL = xcodeURL
            .appendingPathComponent("Contents/Info.plist")
        guard let plistData = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: plistData,
                  format: nil
              ) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String,
              let buildVersion = plist["CFBundleVersion"] as? String else {
            throw XcodeToolchainError.invalidDeveloperDir(xcodeURL.path)
        }

        return XcodeInstallation(
            path: xcodeURL,
            version: version,
            buildVersion: buildVersion,
            isXcodeVersionFileVersion: isXcodeVersionFileVersion,
            isDeveloperDirVersion: isDeveloperDirVersion,
            isXcodeSelectedVersion: isXcodeSelectedVersion
        )
    }
}

private enum XcodePathResolver {
    private static let processExecutor = ProcessExecutor()

    static func findActiveXcodePath() async throws -> String? {
        let result = try await processExecutor
            .executeXcrun(arguments: ["--show-sdk-path"])

        guard result.isSuccess else {
            return nil
        }

        let output = result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let components = output.split(separator: "/")
        if let appIndex = components
            .firstIndex(where: { $0.hasSuffix(".app") }) {
            return "/" + components[1 ... appIndex]
                .joined(separator: "/")
        }

        return nil
    }

    static func getCurrentDeveloperDir() async throws -> String? {
        let result = try await processExecutor.executeXcodeSelect()

        guard result.isSuccess else {
            return nil
        }

        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func compareSDK(_ lhs: String, _ rhs: String) -> Bool {
    func parseVersion(_ name: String) -> (Int, Int) {
        let base = name.replacingOccurrences(of: ".sdk", with: "")
        guard let idx = base.firstIndex(where: { $0.isNumber }) else {
            return (0, 0) // 没有数字，比如 MacOSX.sdk
        }
        let versionPart = base[idx...]
        let comps = versionPart.split(separator: ".")
        let major = Int(comps.first ?? "0") ?? 0
        let minor = comps.count > 1 ? Int(comps[1]) ?? 0 : 0
        return (major, minor)
    }

    let lv = parseVersion(lhs)
    let rv = parseVersion(rhs)
    if lv.0 != rv.0 { return lv.0 < rv.0 }
    return lv.1 < rv.1
}
