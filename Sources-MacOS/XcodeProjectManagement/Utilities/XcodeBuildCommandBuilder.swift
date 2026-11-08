//
//  XcodeBuildCommandBuilder.swift
//
//  Copyright © 2024 Wang Lun.
//

import Foundation

public enum XcodeProjectConfiguration: Sendable {
    public enum ProjectBuildMode: Sendable {
        case scheme(String)
        case targets([String])
    }

    case project(projectURL: URL, buildMode: ProjectBuildMode)
    case workspace(workspaceURL: URL, scheme: String?)
}

public enum XcodeBuildDestination: Sendable {
    case macOS
    case iOS
    case iOSSimulator
    case watchOS
    case watchSimulator
    case tvOS
    case tvSimulator
    case custom(String)

    public var destinationString: String {
        switch self {
        case .macOS:
            "generic/platform=macOS"
        case .iOS:
            "generic/platform=iOS"
        case .iOSSimulator:
            "generic/platform=iOS Simulator"
        case .watchOS:
            "generic/platform=watchOS"
        case .watchSimulator:
            "generic/platform=watchOS Simulator"
        case .tvOS:
            "generic/platform=tvOS"
        case .tvSimulator:
            "generic/platform=tvOS Simulator"
        case let .custom(destination):
            destination
        }
    }
}

public enum XcodeBuildCommand: Sendable {
    case list
    case showdestinations
    case showBuildSettings(
        sdk: XcodeSDK?,
        destination: XcodeBuildDestination?,
        configuration: String?,
        derivedDataPath: String?
    )
    case showBuildSettingsForIndex(
        sdk: XcodeSDK?,
        destination: XcodeBuildDestination?,
        configuration: String?,
        derivedDataPath: String?
    )
    case build(
        action: BuildAction,
        sdk: XcodeSDK?,
        destination: XcodeBuildDestination?,
        configuration: String?,
        derivedDataPath: String?,
        resultBundlePath: String?
    )

    public enum BuildAction: String, CaseIterable, Sendable {
        case build
        case buildForTesting = "build-for-testing"
        case clean
        case test
        case testWithoutBuilding = "test-without-building"
        case archive
        case analyze
        case installsrc
        case install
    }
}

public struct XcodeBuildFlags: OptionSet, Sendable {
    public static let json = XcodeBuildFlags(rawValue: 1 << 0)
    public static let quiet = XcodeBuildFlags(rawValue: 1 << 1)
    public static let verbose = XcodeBuildFlags(rawValue: 1 << 2)
    public static let dryRun = XcodeBuildFlags(rawValue: 1 << 3)

    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

public struct XcodeBuildOptions: Sendable {
    public let command: XcodeBuildCommand
    public let flags: XcodeBuildFlags
    public let customFlags: [String]

    public init(
        command: XcodeBuildCommand = .build(
            action: .build,
            sdk: nil,
            destination: nil,
            configuration: nil,
            derivedDataPath: nil,
            resultBundlePath: nil
        ),
        flags: XcodeBuildFlags = [],
        customFlags: [String] = []
    ) {
        self.command = command
        self.flags = flags
        self.customFlags = customFlags
    }
}

public extension XcodeBuildOptions {
    static func buildSettingsJSON(
        sdk: XcodeSDK? = nil,
        destination: XcodeBuildDestination? = nil,
        configuration: String? = nil,
        derivedDataPath: String? = nil,
        customFlags: [String] = []
    ) -> XcodeBuildOptions {
        XcodeBuildOptions(
            command: .showBuildSettings(
                sdk: sdk,
                destination: destination,
                configuration: configuration,
                derivedDataPath: derivedDataPath
            ),
            flags: [.json],
            customFlags: customFlags
        )
    }

    static func buildSettingsForIndexJSON(
        sdk: XcodeSDK? = nil,
        destination: XcodeBuildDestination? = nil,
        configuration: String? = nil,
        derivedDataPath: String? = nil
    ) -> XcodeBuildOptions {
        XcodeBuildOptions(
            command: .showBuildSettingsForIndex(
                sdk: sdk,
                destination: destination,
                configuration: configuration,
                derivedDataPath: derivedDataPath
            ),
            flags: [.json]
        )
    }

    static let listSchemesJSON = XcodeBuildOptions(command: .list, flags: [.json])
}

public struct XcodeBuildCommandBuilder {
    public init() {}

    public func buildCommand(
        project: XcodeProjectConfiguration,
        options: XcodeBuildOptions = XcodeBuildOptions()
    ) -> [String] {
        var arguments: [String] = []

        arguments.append(contentsOf: projectArguments(from: project))
        arguments.append(contentsOf: commandArguments(from: options.command))
        arguments.append(contentsOf: buildOptionsArguments(options: options))

        return arguments
    }

    private func projectArguments(from project: XcodeProjectConfiguration) -> [String] {
        var arguments: [String] = []

        switch project {
        case let .project(projectURL, buildMode):
            arguments.append(contentsOf: ["-project", projectURL.path])
            arguments.append(contentsOf: buildModeArguments(from: buildMode))
        case let .workspace(workspaceURL, scheme):
            arguments.append(contentsOf: ["-workspace", workspaceURL.path])
            if let scheme {
                arguments.append(contentsOf: ["-scheme", scheme])
            }
        }

        return arguments
    }

    private func buildModeArguments(from buildMode: XcodeProjectConfiguration.ProjectBuildMode) -> [String] {
        var arguments: [String] = []

        switch buildMode {
        case let .targets(targets):
            for target in targets {
                arguments.append(contentsOf: ["-target", target])
            }
        case let .scheme(scheme):
            arguments.append(contentsOf: ["-scheme", scheme])
        }

        return arguments
    }

    private func commandArguments(from command: XcodeBuildCommand) -> [String] {
        var arguments: [String] = []

        switch command {
        case let .build(action, sdk, destination, configuration, derivedDataPath, resultBundlePath):
            arguments.append(contentsOf: sdkArguments(from: sdk))
            arguments.append(contentsOf: destinationArguments(from: destination, withSingleQuote: false))
            arguments.append(contentsOf: configurationArguments(from: configuration))
            arguments.append(action.rawValue)
            arguments.append(contentsOf: derivedDataArguments(from: derivedDataPath))
            arguments.append(contentsOf: resultBundleArguments(from: resultBundlePath))
        case let .showBuildSettings(sdk, destination, configuration, derivedDataPath):
            arguments.append(contentsOf: sdkArguments(from: sdk))
            arguments.append(contentsOf: destinationArguments(from: destination, withSingleQuote: false))
            arguments.append(contentsOf: configurationArguments(from: configuration))
            arguments.append(contentsOf: derivedDataArguments(from: derivedDataPath))
        case let .showBuildSettingsForIndex(sdk, destination, configuration, derivedDataPath):
            arguments.append(contentsOf: sdkArguments(from: sdk))
            arguments.append(contentsOf: destinationArguments(from: destination, withSingleQuote: false))
            arguments.append(contentsOf: configurationArguments(from: configuration))
            arguments.append(contentsOf: derivedDataArguments(from: derivedDataPath))
        case .list, .showdestinations:
            break
        }

        return arguments
    }

    private func sdkArguments(from sdk: XcodeSDK?) -> [String] {
        guard let sdk else { return [] }
        return ["-sdk", sdk.rawValue]
    }

    private func destinationArguments(from destination: XcodeBuildDestination?, withSingleQuote: Bool) -> [String] {
        guard let destination else { return [] }
        let destinationString = withSingleQuote ? "'\(destination.destinationString)'" : destination.destinationString
        return ["-destination", destinationString]
    }

    private func configurationArguments(from configuration: String?) -> [String] {
        guard let configuration else { return [] }
        return ["-configuration", configuration]
    }

    private func derivedDataArguments(from derivedDataPath: String?) -> [String] {
        guard let derivedDataPath else { return [] }
        return ["-derivedDataPath", derivedDataPath]
    }

    private func resultBundleArguments(from resultBundlePath: String?) -> [String] {
        guard let resultBundlePath else { return [] }
        return ["-resultBundlePath", resultBundlePath]
    }

    public func listSchemesCommand(project: XcodeProjectConfiguration) -> [String] {
        buildCommand(
            project: project,
            options: XcodeBuildOptions.listSchemesJSON
        )
    }

    private func buildOptionsArguments(options: XcodeBuildOptions) -> [String] {
        var arguments: [String] = []

        switch options.command {
        case .build:
            break
        case .showBuildSettings:
            arguments.append("-showBuildSettings")
        case .showBuildSettingsForIndex:
            arguments.append("-showBuildSettingsForIndex")
        case .list:
            arguments.append("-list")
        case .showdestinations:
            arguments.append("-showdestinations")
        }

        if options.flags.contains(.json) {
            arguments.append("-json")
        }

        if options.flags.contains(.quiet) {
            arguments.append("-quiet")
        }

        if options.flags.contains(.verbose) {
            arguments.append("-verbose")
        }

        if options.flags.contains(.dryRun) {
            arguments.append("-dry-run")
        }

        arguments.append(contentsOf: options.customFlags)

        return arguments
    }
}
