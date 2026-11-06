import Foundation

public enum SwiftPMProjectError: Error, LocalizedError {
    case invalidPackage(String)
    case executableNotFound(String)
    case commandFailed(command: String, status: Int32, output: String)
    case launchFailed(String)
    case invalidMetadata(package: String, details: String)
    case notInitialized
    case shutDown
    case unknownTarget(String)
    case unsupported(String)
    case invalidArguments(String)
    case productNotBuilt(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPackage(path):
            "No Package.swift file was found at \(path)."
        case let .executableNotFound(details):
            "Cannot find an executable Swift toolchain. \(details)"
        case let .commandFailed(command, status, output):
            "SwiftPM command failed (exit \(status)): \(command)\n\(output)"
        case let .launchFailed(details):
            "Cannot run the SwiftPM command: \(details)"
        case let .invalidMetadata(package, details):
            "Invalid SwiftPM metadata for \(package): \(details)"
        case .notInitialized:
            "The SwiftPM project has not been loaded."
        case .shutDown:
            "The SwiftPM project manager has shut down."
        case let .unknownTarget(identifier):
            "Unknown SwiftPM build target: \(identifier)"
        case let .unsupported(operation):
            "The SwiftPM provider does not support \(operation)."
        case let .invalidArguments(message):
            message
        case let .productNotBuilt(path):
            "Build product not found: \(path). Compile the target with the same build arguments first."
        }
    }
}
