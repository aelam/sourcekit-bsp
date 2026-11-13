import Foundation
import SourceKitBSPProtocol
import Support

public extension XcodeProjectManager {
    func prepareDebugAttach(context: BuildContext, pid: Int?) async throws -> DebugSessionBackend {
        let timing = AttachTiming()
        do {
            let backend = try await AttachTiming.$current.withValue(timing) {
                try await timing.measure("prepare") {
                    try await prepareTimedDebugAttach(context: context, pid: pid, timing: timing)
                }
            }
            return timing.track(backend)
        } catch {
            await timing.finish(.failure(error))
            throw error
        }
    }

    private func prepareTimedDebugAttach(
        context: BuildContext, pid: Int?, timing: AttachTiming
    ) async throws -> DebugSessionBackend {
        guard context.operation == .debug, context.targets.count == 1,
              context.selection["xcode.debugMode"] == "run", let target = context.targets.first else {
            throw HostAttachError.invalid("Attach requires an application target. Test attach is not supported.")
        }
        guard !destinationDiscoveryStopped, let base = projectSnapshot else {
            throw HostAttachError.invalid("The project session is closed.")
        }
        let generation = buildGraphVersion
        let arguments = try contextArguments(context, arguments: nil)
        let product = try await timing.measure("build-settings") {
            try await resolveDebugProduct(
                xcodeTargetIdentifier: XcodeTargetIdentifier(rawValue: target.uri.stringValue), arguments: arguments
            )
        }
        if product.platform == .iOS {
            return try await prepareDeviceAttach(
                product: product,
                pid: pid,
                generation: generation,
                timing: timing,
                commands: DeviceCommandRunner(developerDirectory: base.xcodeInstallation.developerDir)
            )
        }
        let simulatorExecutable = simulatorAttachExecutable
        let identity = try await timing.measure("process-discovery") {
            try await XcodeDebugAttachResolver.identity(
                product: product,
                pid: pid,
                simulatorExecutable: { device, bundle in
                    try await simulatorExecutable(base.xcodeInstallation.developerDir, device, bundle)
                },
                processes: attachProcessLookup
            )
        }
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
    private func prepareDeviceAttach(
        product: DebugProduct, pid: Int?, generation: UUID, timing: AttachTiming, commands: DeviceCommandRunner
    ) async throws -> DebugSessionBackend {
        let discovery = DeviceAttachDiscovery(commands: commands)
        let identity = try await timing.measure("process-discovery") {
            try await discovery.resolve(product: product, pid: pid)
        }
        try validateAttachGeneration(generation)
        let manager = try getDebugSessionManager()
        let connection = try await manager.makeDeviceAttachConnection(identity: identity)
        do {
            try Task.checkCancellation()
            try validateAttachGeneration(generation)
            return DebugSessionBackend(
                connection: connection,
                validate: {
                    try await self.validateAttachGeneration(generation)
                    try await discovery.validate(identity)
                    try await self.validateAttachGeneration(generation)
                },
                stop: { await manager.stopConnection(uri: connection.uri) }
            )
        } catch {
            await manager.stopConnection(uri: connection.uri)
            throw error
        }
    }

    private func validateAttachGeneration(_ generation: UUID) throws {
        guard !destinationDiscoveryStopped, buildGraphVersion == generation else {
            throw HostAttachError.invalid("The project changed. Start attach again.")
        }
    }

    private func validateAttachIdentity(_ identity: HostProcessIdentity, generation: UUID) throws {
        try validateAttachGeneration(generation)
        try attachIdentityCheck(identity)
    }
}
