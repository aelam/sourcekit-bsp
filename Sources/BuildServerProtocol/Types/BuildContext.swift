import Foundation

public enum BuildContextOperation: String, Codable, Hashable, Sendable, CaseIterable {
    case compile, run, test, debug
}

public struct BuildContextScope: Codable, Hashable, Sendable {
    public let workspaceUri: URI?
    public let targets: [BSPBuildTargetIdentifier]?

    public init(workspaceUri: URI? = nil, targets: [BSPBuildTargetIdentifier]? = nil) {
        self.workspaceUri = workspaceUri
        self.targets = targets
    }
}

public struct BuildContextOptionsParams: Codable, Hashable, Sendable {
    public let scope: BuildContextScope?
    public let selection: [String: String]?

    public init(scope: BuildContextScope? = nil, selection: [String: String]? = nil) {
        self.scope = scope
        self.selection = selection
    }
}

public struct BuildContextParams: Codable, Hashable, Sendable {
    public let scope: BuildContextScope?
    public let operation: BuildContextOperation
    public let selection: [String: String]?

    public init(scope: BuildContextScope? = nil, operation: BuildContextOperation, selection: [String: String]? = nil) {
        self.scope = scope
        self.operation = operation
        self.selection = selection
    }
}

public struct BuildContextOption: Codable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let description: String?
    public let reason: String?
    public let availability: Bool?
    public let dataKind: String?
    public let data: LSPAny?

    public init(
        id: String,
        label: String,
        description: String? = nil,
        reason: String? = nil,
        availability: Bool? = nil,
        dataKind: String? = nil,
        data: LSPAny? = nil
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.reason = reason
        self.availability = availability
        self.dataKind = dataKind
        self.data = data
    }
}

public struct BuildContextPlatform: Codable, Hashable, Sendable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct BuildContextDestination: Codable, Hashable, Sendable {
    public static let dataKind = "execution-destination"
    public let kind: String
    public let platform: BuildContextPlatform
    public let osVersion: String?
    public let architecture: String?
    public let state: String?

    public init(
        kind: String,
        platform: BuildContextPlatform,
        osVersion: String? = nil,
        architecture: String? = nil,
        state: String? = nil
    ) {
        self.kind = kind
        self.platform = platform
        self.osVersion = osVersion
        self.architecture = architecture
        self.state = state
    }

    public func encodeToLSPAny() -> LSPAny {
        var data: [String: LSPAny] = [
            "kind": .string(kind),
            "platform": .dictionary(["id": .string(platform.id), "label": .string(platform.label)])
        ]
        if let osVersion { data["osVersion"] = .string(osVersion) }
        if let architecture { data["architecture"] = .string(architecture) }
        if let state { data["state"] = .string(state) }
        return .dictionary(data)
    }
}

public struct BuildContextDimension: Codable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let kind: String
    public let required: Bool
    public let options: [BuildContextOption]
    public let value: String?
    public let enabled: Bool?
    public let reason: String?

    public init(
        id: String,
        label: String,
        kind: String = "enum",
        required: Bool = true,
        options: [BuildContextOption],
        value: String? = nil,
        enabled: Bool? = nil,
        reason: String? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.required = required
        self.options = options
        self.value = value
        self.enabled = enabled
        self.reason = reason
    }
}

public struct BuildContextOptionsResult: Codable, Hashable, Sendable {
    public let dimensions: [BuildContextDimension]
    public let selection: [String: String]
    public let operations: [BuildContextOperation]?

    public init(
        dimensions: [BuildContextDimension],
        selection: [String: String],
        operations: [BuildContextOperation]? = nil
    ) {
        self.dimensions = dimensions
        self.selection = selection
        self.operations = operations
    }
}

/// A provider's immutable execution selection. It does not change indexing settings.
public struct BuildContext: Codable, Hashable, Sendable {
    public let operation: BuildContextOperation
    public let targets: [BSPBuildTargetIdentifier]
    public let selection: [String: String]

    public init(operation: BuildContextOperation, targets: [BSPBuildTargetIdentifier], selection: [String: String]) {
        self.operation = operation
        self.targets = targets
        self.selection = selection
    }
}

public struct BuildContextReference: Codable, Hashable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public struct BuildContextResolution: Codable, Hashable, Sendable {
    public let id: String
    public let operation: BuildContextOperation
    public let targets: [BSPBuildTargetIdentifier]
    public let selection: [String: String]

    public init(id: String, context: BuildContext) {
        self.id = id
        self.operation = context.operation
        self.targets = context.targets
        self.selection = context.selection
    }
}

public struct BuildContextExtension: Codable, Hashable, Sendable {
    public static let name = "vscode-bsp.build-context"
    public let version: String
    public let required: Bool
    public let operations: [BuildContextOperation]

    public init(operations: [BuildContextOperation]) {
        self.version = "0.1"
        self.required = true
        self.operations = operations
    }
}

public enum BuildContextError: Error, LocalizedError, Sendable, Equatable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(message): "Build context: \(message)"
        }
    }
}
