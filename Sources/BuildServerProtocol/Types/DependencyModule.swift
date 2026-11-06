import Foundation

/// An external library used by a build target.
public struct DependencyModule: Codable, Hashable, Sendable {
    public let name: String
    /// The resolved version or revision, or an empty string when unknown.
    public let version: String
    public let dataKind: String?
    public let data: LSPAny?

    public init(name: String, version: String, dataKind: String? = nil, data: LSPAny? = nil) {
        self.name = name
        self.version = version
        self.dataKind = dataKind
        self.data = data
    }
}

/// External libraries for one requested build target.
public struct DependencyModulesItem: Codable, Hashable, Sendable {
    public let target: BSPBuildTargetIdentifier
    public let modules: [DependencyModule]

    public init(target: BSPBuildTargetIdentifier, modules: [DependencyModule]) {
        self.target = target
        self.modules = modules
    }
}

/// Errors from dependency module queries.
public enum DependencyModulesError: Error, LocalizedError, Sendable {
    case unsupported
    case notInitialized
    case unknownTarget(BSPBuildTargetIdentifier)

    public var errorDescription: String? {
        switch self {
        case .unsupported: "Dependency modules are not supported by this project provider."
        case .notInitialized: "The project has not been initialized."
        case let .unknownTarget(target): "Unknown build target: \(target.uri.stringValue)"
        }
    }
}
