import Foundation

enum BuildServerError: Error, LocalizedError, CustomStringConvertible {
    var errorDescription: String? {
        description
    }

    case missingConfigFile
    case missingWorkspace
    case missingProject
    case invalidConfiguration(String)
    case xcodebuildExecutionFailed(String)
    case indexingPathsLoadFailed

    var description: String {
        switch self {
        case .missingConfigFile:
            "BSP configuration file not found"
        case .missingWorkspace:
            "No workspace specified in configuration"
        case .missingProject:
            "No project or workspace found"
        case let .invalidConfiguration(message):
            "Invalid configuration: \(message)"
        case let .xcodebuildExecutionFailed(output):
            "xcodebuild execution failed: \(output)"
        case .indexingPathsLoadFailed:
            "Failed to load indexing paths"
        }
    }
}
