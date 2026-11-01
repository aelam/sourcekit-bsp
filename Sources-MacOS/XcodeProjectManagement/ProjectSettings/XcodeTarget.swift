import Foundation
import XcodeProj

/// Target information with complete project context
public struct XcodeTarget: Sendable, Hashable, Codable {
    public typealias ProductType = XcodeProductType

    public let targetIdentifier: XcodeTargetIdentifier
    public let name: String
    public let projectURL: URL
    public let projectName: String
    public let productName: String?
    public let isFromWorkspace: Bool
    public let buildForTesting: Bool
    public let buildForRunning: Bool
    public let xcodeTargetPlatform: Platform
    public let xcodeProductType: XcodeProductType
    public let buildConfigurations: [String]
    public let destinations: [XcodeDestination]

    public var productNameWithExtension: String? {
        guard
            let productName,
            let fileExtension = xcodeProductType.fileExtension
        else {
            return productName
        }
        return productName + "." + fileExtension
    }

    /// Computed property for legacy compatibility
    public var targetName: String {
        name
    }

    public init(
        targetIdentifier: XcodeTargetIdentifier,
        name: String,
        projectURL: URL,
        productName: String?,
        isFromWorkspace: Bool = false,
        buildForTesting: Bool = true,
        buildForRunning: Bool = true,
        xcodeTargetPlatform: Platform = .iOS,
        xcodeProductType: ProductType,
        buildConfigurations: [String] = ["Debug", "Release"],
        destinations: [XcodeDestination] = []
    ) {
        self.targetIdentifier = targetIdentifier
        self.name = name
        self.projectURL = projectURL
        self.projectName = projectURL.deletingPathExtension().lastPathComponent
        self.productName = productName
        self.isFromWorkspace = isFromWorkspace
        self.buildForTesting = buildForTesting
        self.buildForRunning = buildForRunning
        self.xcodeTargetPlatform = xcodeTargetPlatform
        self.xcodeProductType = xcodeProductType
        self.buildConfigurations = buildConfigurations
        self.destinations = destinations
    }

    public var debugDescription: String {
        "XcodeTarget(name: \(name), " +
            "projectURL: \(projectURL.path), " +
            "isFromWorkspace: \(isFromWorkspace), " +
            "platform: \(xcodeTargetPlatform.rawValue))"
    }
}

public typealias XcodeSchemeTargetInfo = XcodeTarget

public struct GroupedTargetsKey: Hashable, Sendable {
    let projectURL: URL
    let platform: Platform
}
