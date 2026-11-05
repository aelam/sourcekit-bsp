import Foundation

public struct XcodeProjectSnapshot: Sendable, Codable {
    public let rootURL: URL
    public let projectLocation: XcodeProjectLocation
    public let xcodeGlobalSettings: XcodeGlobalSettings
    public let xcodeTargets: [XcodeTarget]
    public let schemes: [XcodeScheme]
    public let configuration: String
    public let xcodeInstallation: XcodeInstallation

    public var name: String {
        projectLocation.name
    }
}
