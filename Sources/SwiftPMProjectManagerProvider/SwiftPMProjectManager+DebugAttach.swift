import BuildServerProtocol
import Foundation
import Support

public extension SwiftPMProjectManager {
    func prepareDebugAttach(context: BuildContext, pid: Int?) async throws -> DebugSessionBackend {
        #if os(macOS)
        try await validateContext(context, operation: .debug, targets: context.targets)
        guard context.targets.count == 1, let target = context.targets.first,
              testModules[target] == nil, executableTargets[target] != nil else {
            throw HostAttachError.invalid("Attach requires a SwiftPM executable. Test attach is not supported.")
        }
        guard let debugAdapter else { throw SwiftPMProjectError.unsupported("debug sessions on this host") }
        let generation = debugGeneration
        let program = try await builtExecutable(
            for: target, arguments: contextBuildArguments(nil, context: context)
        ).resolvingSymlinksInPath().path
        let identity = try DebugAttachSelection.select(
            executable: program, pid: pid, processes: attachProcessLookup(program)
        )
        try validateAttachIdentity(identity, generation: generation)
        let endpoint = try await debugAdapter.start()
        do {
            try Task.checkCancellation()
            try validateAttachIdentity(identity, generation: generation)
            let id = UUID()
            debugEndpoints[id] = endpoint
            return DebugSessionBackend(
                connection: .init(uri: endpoint.uri, request: .attach, program: program, pid: identity.pid),
                validate: { try await self.validateAttachIdentity(identity, generation: generation) },
                stop: { await self.stopDebugSession(uri: endpoint.uri) }
            )
        } catch {
            endpoint.terminate()
            throw error
        }
        #else
        throw SwiftPMProjectError.unsupported("attach on this host")
        #endif
    }

    func stopDebugSession(uri: String) {
        let ids = debugEndpoints.filter { $0.value.uri == uri }.map(\.key)
        for id in ids {
            debugEndpoints.removeValue(forKey: id)?.terminate()
        }
    }
}

extension SwiftPMProjectManager {
    private func validateAttachIdentity(_ identity: HostProcessIdentity, generation: UUID) throws {
        guard !isShutDown, debugGeneration == generation else {
            throw HostAttachError.invalid("The project changed. Start attach again.")
        }
        try attachIdentityCheck(identity)
    }
}
