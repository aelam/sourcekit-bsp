import Foundation

/// The server's workspace model. This is not a BSP wire message.
/// Sources are loaded through ProjectManager only when a client requests them.
public struct BSPProject: Sendable {
    public let rootURL: URL
    public let name: String
    public let targets: [BSPBuildTarget]
    public let buildRootURL: URL
    public let indexStoreURL: URL
    public let indexDatabaseURL: URL

    private let targetIndices: [BSPBuildTargetIdentifier: Int]

    public init(
        rootURL: URL,
        name: String,
        targets: [BSPBuildTarget],
        buildRootURL: URL,
        indexStoreURL: URL,
        indexDatabaseURL: URL
    ) {
        self.rootURL = rootURL
        self.name = name
        self.buildRootURL = buildRootURL
        self.indexStoreURL = indexStoreURL
        self.indexDatabaseURL = indexDatabaseURL

        // A workspace can reference the same project more than once.
        var seen = Set<BSPBuildTargetIdentifier>()
        self.targets = targets.filter { seen.insert($0.id).inserted }
        let indices = self.targets.enumerated().map { ($0.element.id, $0.offset) }
        self.targetIndices = Dictionary(uniqueKeysWithValues: indices)
    }

    public func target(for identifier: BSPBuildTargetIdentifier) -> BSPBuildTarget? {
        guard let index = targetIndices[identifier] else { return nil }
        return targets[index]
    }

    /// Include each requested target and its transitive dependencies once.
    public func dependencyClosure(for identifiers: [BSPBuildTargetIdentifier]) -> [BSPBuildTargetIdentifier] {
        var result: [BSPBuildTargetIdentifier] = []
        var seen = Set<BSPBuildTargetIdentifier>()
        var pending = Array(identifiers.reversed())
        while let identifier = pending.popLast() {
            guard seen.insert(identifier).inserted else { continue }
            result.append(identifier)
            pending.append(contentsOf: (target(for: identifier)?.dependencies ?? []).reversed())
        }
        return result
    }
}
