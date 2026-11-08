import Foundation
import Support

/// Resolves one existing process without building or changing device state.
enum XcodeDebugAttachResolver {
    static func identity(
        product: DebugProduct,
        pid: Int?,
        simulatorExecutable: @Sendable (String, String) async throws -> String,
        processes: @Sendable (String) throws -> [HostProcessIdentity]
    ) async throws -> HostProcessIdentity {
        let executable: String
        switch product.platform {
        case .iOSSimulator:
            guard let device = product.destinationID, let bundle = product.bundleId else {
                throw HostAttachError.invalid("Select an iOS simulator and an application bundle.")
            }
            executable = try await simulatorExecutable(device, bundle)
        case .macOS:
            executable = URL(fileURLWithPath: product.binaryPath).resolvingSymlinksInPath().path
        default:
            throw HostAttachError
                .invalid(
                    "Attach does not support \(product.platform.rawValue). " +
                        "Select an iOS simulator or macOS host for local process lookup."
                )
        }
        return try DebugAttachSelection.select(executable: executable, pid: pid, processes: processes(executable))
    }
}
