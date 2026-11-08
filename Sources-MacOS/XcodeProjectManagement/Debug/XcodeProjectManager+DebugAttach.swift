import BuildServerProtocol
import Foundation
import Support

public extension XcodeProjectManager {
    func prepareDebugAttach(context: BuildContext, pid: Int?) async throws -> DebugSessionBackend {
        guard context.operation == .debug, context.targets.count == 1,
              context.selection["xcode.debugMode"] == "run", let target = context.targets.first else {
            throw HostAttachError.invalid("Attach requires an application target. Test attach is not supported.")
        }
        guard !destinationDiscoveryStopped, let base = projectSnapshot else {
            throw HostAttachError.invalid("The project session is closed.")
        }
        let generation = buildGraphVersion
        let arguments = try contextArguments(context, arguments: nil)
        let product = try await resolveDebugProduct(
            xcodeTargetIdentifier: XcodeTargetIdentifier(rawValue: target.uri.stringValue), arguments: arguments
        )
        let simulatorExecutable = simulatorAttachExecutable
        let identity = try await XcodeDebugAttachResolver.identity(
            product: product,
            pid: pid,
            simulatorExecutable: { device, bundle in
                try await simulatorExecutable(base.xcodeInstallation.developerDir, device, bundle)
            },
            processes: attachProcessLookup
        )
        try validateAttachIdentity(identity, generation: generation)
        let manager = try getDebugSessionManager()
        let connection = try await manager.makeAttachConnection(identity: identity)
        do {
            try Task.checkCancellation()
            try validateAttachIdentity(identity, generation: generation)
            return DebugSessionBackend(
                connection: connection,
                validate: { try await self.validateAttachIdentity(identity, generation: generation) },
                stop: { await manager.stopConnection(uri: connection.uri) }
            )
        } catch {
            await manager.stopConnection(uri: connection.uri)
            throw error
        }
    }

    func debugSessionDidStart(uri: String) async {
        await debugSessionManager?.didStartConnection(uri: uri)
    }

    func stopDebugSession(uri: String) async {
        await debugSessionManager?.stopConnection(uri: uri)
    }
}

extension XcodeProjectManager {
    private func validateAttachIdentity(_ identity: HostProcessIdentity, generation: UUID) throws {
        guard !destinationDiscoveryStopped, buildGraphVersion == generation else {
            throw HostAttachError.invalid("The project changed. Start attach again.")
        }
        try attachIdentityCheck(identity)
    }
}
