import Foundation

/// Reads the pins in Package.resolved formats 1, 2, and 3.
public struct SwiftPackageResolvedFile: Sendable {
    public struct Pin: Decodable, Sendable {
        public let identity: String
        public let location: String
        public let state: State

        public struct State: Decodable, Sendable {
            public let version: String?
            public let revision: String?
            public let branch: String?
        }

        public var version: String {
            state.version ?? state.revision ?? state.branch ?? ""
        }

        private enum CodingKeys: String, CodingKey {
            case identity, location, repositoryURL, state
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            location = try container.decodeIfPresent(String.self, forKey: .location)
                ?? container.decode(String.self, forKey: .repositoryURL)
            identity = try container.decodeIfPresent(String.self, forKey: .identity)?.lowercased()
                ?? SwiftPackageResolvedFile.identity(for: location)
            state = try container.decode(State.self, forKey: .state)
        }
    }

    public let pins: [Pin]

    /// Missing lockfiles have no pins. Invalid lockfiles throw a decoding error.
    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            pins = []
            return
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        pins = file.pins ?? file.object?.pins ?? []
    }

    public func pin(identity: String) -> Pin? {
        pins.first { $0.identity == identity.lowercased() }
    }

    public func pin(repository: String) -> Pin? {
        pins.first { Self.normalizedRepository($0.location) == Self.normalizedRepository(repository) }
    }

    public static func identity(for repository: String) -> String {
        String(normalizedRepository(repository).split(separator: "/").last ?? "").lowercased()
    }

    private static func normalizedRepository(_ repository: String) -> String {
        var value = repository
        while value.hasSuffix("/") {
            value.removeLast()
        }
        if value.hasSuffix(".git") { value.removeLast(4) }
        return value
    }

    private struct File: Decodable {
        let pins: [Pin]?
        let object: LegacyObject?

        struct LegacyObject: Decodable {
            let pins: [Pin]
        }
    }
}
