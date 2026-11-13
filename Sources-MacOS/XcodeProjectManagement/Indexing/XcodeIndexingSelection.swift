import Foundation
import SourceKitBSPProtocol

/// The indexing inputs derived from the client's shared build selection.
public struct XcodeIndexingSelection: Codable, Equatable, Sendable {
    public let platform: String?
    public let architecture: String?
    public let configuration: String?

    public init(platform: String?, architecture: String? = nil, configuration: String? = nil) {
        self.platform = platform
        self.architecture = architecture
        self.configuration = configuration
    }

    public static func file(in derivedData: URL) -> URL {
        derivedData.appendingPathComponent("Logs/sourcekit-bsp/indexing-selection.json")
    }

    public static func load(in derivedData: URL) throws -> Self? {
        let file = file(in: derivedData)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }

    public func save(in derivedData: URL) throws -> Bool {
        guard try Self.load(in: derivedData) != self else { return false }
        let file = Self.file(in: derivedData)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)
        return true
    }
}

public extension XcodeProjectManager {
    func indexingSelection(_ context: BuildContext) throws -> XcodeIndexingSelection {
        let selection = context.selection
        guard let id = selection["xcode.destination"] else {
            return XcodeIndexingSelection(platform: nil, configuration: selection["xcode.configuration"])
        }
        guard let destination = destinationLoader.allDestinations.first(where: { $0.id == id }) else {
            throw BuildContextError.invalid("The selected destination is unavailable")
        }
        let devicePlatform: Platform = switch destination.platform {
        case .iOS: .iOS
        case .macOS: .macOS
        case .watchOS: .watchOS
        case .tvOS: .tvOS
        case .visionOS: .visionOS
        }
        let platform = destination.type == .simulator ? devicePlatform.simulatorVariant : devicePlatform
        return XcodeIndexingSelection(
            platform: platform.rawValue,
            architecture: destination.buildContextMetadata.architecture,
            configuration: selection["xcode.configuration"]
        )
    }
}
