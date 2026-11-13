import Foundation
import Support

/// Shared preparations publish each options change once, even when several callers wait for the result.
final class IndexPreparationChanges: Sendable {
    private let targets: CrossPlatformLock<[XcodeTargetIdentifier]>

    init(_ targets: [XcodeTargetIdentifier]) {
        self.targets = CrossPlatformLock(initialState: targets)
    }

    func take() -> [XcodeTargetIdentifier] {
        targets.withLock {
            let result = $0
            $0.removeAll()
            return result
        }
    }
}

public protocol XcodeIndexingBackend: Sendable {
    var indexStoreURL: URL { get }
    var indexDatabaseURL: URL { get }
    func compilerArguments(for target: XcodeTargetIdentifier, file: URL) async throws -> [String]
    func prepare(targets: [XcodeTargetIdentifier], log: (@Sendable (String) -> Void)?) async throws
        -> [XcodeTargetIdentifier]
    func invalidateInputs() async
    func shutdown() async
}

public struct XcodeIndexingConfiguration: Decodable, Sendable, Equatable {
    public let prepareForIndexing: Bool

    public init(prepareForIndexing: Bool = false) {
        self.prepareForIndexing = prepareForIndexing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.prepareForIndexing = try container.decodeIfPresent(Bool.self, forKey: .prepareForIndexing) ?? false
    }

    private enum CodingKeys: String, CodingKey { case prepareForIndexing }

    public static func load(
        root: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self {
        let file = root.appendingPathComponent(".sourcekit-bsp/project.json")
        let configuration = try FileManager.default.fileExists(atPath: file.path)
            ? JSONDecoder().decode(Self.self, from: Data(contentsOf: file)) : Self()
        if let value = environment["SOURCEKIT_BSP_PREPARE_FOR_INDEXING"] {
            switch value.lowercased() {
            case "1", "true": return Self(prepareForIndexing: true)
            case "0", "false": return Self(prepareForIndexing: false)
            default:
                throw XcodeProjectError.invalidConfig(
                    "SOURCEKIT_BSP_PREPARE_FOR_INDEXING must be 1, 0, true, or false: \(value)"
                )
            }
        }
        return configuration
    }

    public static func makeBackend(snapshot: XcodeProjectSnapshot) async throws -> (any XcodeIndexingBackend)? {
        try await makeBackend(snapshot: snapshot, serviceExecutable: nil)
    }

    static func makeBackend(snapshot: XcodeProjectSnapshot, serviceExecutable: URL?) async throws
        -> (any XcodeIndexingBackend)? {
        guard try load(root: snapshot.rootURL).prepareForIndexing else {
            return nil
        }
        #if SWIFT_BUILD_INDEXING
        return try SwiftBuildIndexingBackend(snapshot: snapshot, serviceExecutable: serviceExecutable)
        #else
        throw XcodeProjectError.invalidConfig(
            "prepareForIndexing requires a server built with SOURCEKIT_BSP_SWIFT_BUILD=1 "
                + "and its matching SWBBuildServiceBundle."
        )
        #endif
    }
}
