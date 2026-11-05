import Foundation

/// The project store replaces this cache when the build graph changes.
struct CompilerSettingsCache {
    struct Key: Hashable {
        let target: XcodeTargetIdentifier
        let configuration: String
        let developerDirectory: URL
        let buildVersion: String
        let derivedData: URL
    }

    private var values: [Key: [String: String]] = [:]

    mutating func settings(for key: Key, load: () throws -> [String: String]) rethrows -> [String: String] {
        if let value = values[key] { return value }
        let value = try load()
        values[key] = value
        return value
    }

    mutating func invalidate() {
        values.removeAll()
    }
}
