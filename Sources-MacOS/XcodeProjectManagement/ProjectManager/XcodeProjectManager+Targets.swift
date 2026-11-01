import Foundation
import Logger
import XcodeProj

extension XcodeProjectManager {
    /// Load actual targets, handling both workspace and project cases
    func loadActualTargets(
        projectLocation: XcodeProjectLocation
    ) async throws -> [XcodeTarget] {
        switch projectLocation {
        case .explicitWorkspace:
            // For workspace, load containers to get actual targets from projects
            try await loadTargetsFromWorkspaceContainers(projectLocation: projectLocation)
        case let .implicitWorkspace(projectURL, _):
            // For project, load targets using XcodeProj
            try loadTargetsFromXcodeProj(projectURL: projectURL, isFromWorkspace: false)
        case let .standaloneProject(projectURL):
            // For standalone project, load targets using XcodeProj
            try loadTargetsFromXcodeProj(projectURL: projectURL, isFromWorkspace: false)
        }
    }

    /// Load targets from workspace containers using XcodeProj
    private func loadTargetsFromWorkspaceContainers(
        projectLocation: XcodeProjectLocation
    ) async throws -> [XcodeTarget] {
        guard case let .explicitWorkspace(workspaceURL) = projectLocation else {
            return []
        }

        let workspace = try XCWorkspace(pathString: workspaceURL.path)
        var allTargets: [XcodeTarget] = []
        for element in workspace.data.children {
            if case let .file(fileRef) = element,
               fileRef.location.path.hasSuffix(".xcodeproj"),
               let projectURL = resolveProjectPath(from: fileRef.location, workspaceURL: workspaceURL) {
                allTargets += try loadTargetsFromXcodeProj(projectURL: projectURL, isFromWorkspace: true)
            }
        }
        return allTargets
    }

    /// Load targets from XcodeProj directly
    func loadTargetsFromXcodeProj(projectURL: URL, isFromWorkspace: Bool = false) throws -> [XcodeTarget] {
        guard let project = loadXcodeProjCache(projectURL: projectURL) else {
            throw XcodeProjectError.invalidConfig("Cannot load project: \(projectURL.path)")
        }
        var targets = [XcodeTarget]()
        for target in project.pbxproj.nativeTargets {
            let buildConfigurations = target.buildConfigurationList?.buildConfigurations
            let buildSettings = buildConfigurations?.first?.buildSettings
            let projectSettings = project.pbxproj.rootObject?.buildConfigurationList?.buildConfigurations
                .first?.buildSettings
            let SDKROOT = buildSettings?["SDKROOT"] as? String
                ?? projectSettings?["SDKROOT"] as? String ?? "iphonesimulator"
            let platform = Platform(rawValue: SDKROOT) ?? .iOS
            let pbxProductType = target.productType ?? .none
            let productType = XcodeProductType(rawValue: pbxProductType.rawValue) ?? .none
            let targetIdentifier = XcodeTargetIdentifier(projectFilePath: projectURL.path, targetName: target.name)
            let configurationNames = target.buildConfigurationList?.buildConfigurations
                .map(\.name) ?? []

            targets.append(
                XcodeTarget(
                    targetIdentifier: targetIdentifier,
                    name: target.name,
                    projectURL: projectURL,
                    productName: target.productName,
                    isFromWorkspace: isFromWorkspace,
                    xcodeTargetPlatform: platform,
                    xcodeProductType: productType,
                    buildConfigurations: configurationNames,
                    destinations: loadDestinations(for: platform),
                )
            )
        }
        return targets
    }

    private func loadDestinations(for platform: Platform) -> [XcodeDestination] {
        switch platform {
        case .iOS, .iOSSimulator:
            destinationLoader.iosDestinations
        case .tvOS, .tvSimulator:
            destinationLoader.tvosDestinations
        case .watchOS, .watchSimulator:
            destinationLoader.watchosDestinations
        case .visionOS, .visionSimulator:
            destinationLoader.visionosDestinations
        case .macOS:
            destinationLoader.macDestinations
        }
    }
}
