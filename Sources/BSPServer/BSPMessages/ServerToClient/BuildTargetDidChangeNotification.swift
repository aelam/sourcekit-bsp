//
//  BuildTargetDidChangeNotification.swift
//  sourcekit-bsp
//
//  Created by ST22956 on 2024/11/23.
//

import SourceKitBSPProtocol

/// Sent to clients when targets or their compiler options change.
enum BuildTargetDidChangeNotification {
    static func method() -> String {
        "buildTarget/didChange"
    }

    struct Params: Codable, Sendable {
        let changes: [BuildTargetEvent]?
    }
}

public struct BuildTargetEvent: Codable, Hashable, Sendable {
    public typealias BuildTargetEventData = LSPAny

    /// The identifier for the changed build target.
    public let target: BSPBuildTargetIdentifier

    /// The kind of change for this build target.
    public let kind: BuildTargetEventKind?

    /// Kind of data to expect in the `data` field. If this field is not set, the kind of data is not specified.
    public let dataKind: BuildTargetEventDataKind?

    /// Any additional metadata about what information changed.
    public let data: BuildTargetEventData?
}

public enum BuildTargetEventKind: Int, Codable, Hashable, Sendable {
    /// The build target is new.
    case created = 1

    /// The build target has changed.
    case changed = 2

    /// The build target has been deleted.
    case deleted = 3
}

public struct BuildTargetEventDataKind: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
