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

public struct XcodeIndexingConfiguration: Sendable, Equatable {
    public let enableBuildTargetPrepare: Bool

    public init(enableBuildTargetPrepare: Bool = false) {
        self.enableBuildTargetPrepare = enableBuildTargetPrepare
    }

    public func makeBackend(snapshot: XcodeProjectSnapshot) async throws -> (any XcodeIndexingBackend)? {
        try await makeBackend(snapshot: snapshot, serviceExecutable: nil)
    }

    func makeBackend(snapshot: XcodeProjectSnapshot, serviceExecutable: URL?) async throws
        -> (any XcodeIndexingBackend)? {
        guard enableBuildTargetPrepare else { return nil }
        return try SwiftBuildIndexingBackend(snapshot: snapshot, serviceExecutable: serviceExecutable)
    }
}
