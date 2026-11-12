import BuildServerProtocol
import Foundation
import JSONRPCConnection
import Logger
#if os(macOS)
import XcodeProjectManagement
#endif

extension BSPServerService {
    func startDebugSession(
        targets: [BSPBuildTargetIdentifier],
        originId: String? = nil,
        arguments: [String]?,
        executionContext reference: BuildContextReference? = nil
    ) async throws -> DebugSessionConnection {
        guard let projectManager else {
            throw BuildServerError.invalidConfiguration("Project manager not initialized")
        }
        let revision = buildContextRevision
        let context = try await executionContext(reference, operation: .debug, targets: targets)
        try validateDebugRevision(revision)
        let id = UUID()
        let session = DeferredDAPSession(prepare: { [weak self] request, pid in
            guard let self else { throw CancellationError() }
            try await self.validateDebugRevision(revision)
            if request == .attach {
                guard let context else {
                    throw BuildContextError.invalid("Attach requires a resolved debug executionContext.")
                }
                #if os(macOS)
                let report: @Sendable (String) async -> Void = { [weak self] message in
                    try? await self?.sendNotification(ServerJSONRPCNotification(
                        method: "build/logMessage",
                        params: BuildLogMessageParams(type: 3, originId: originId, message: message)
                    ))
                }
                return try await XcodeAttachTiming.$report.withValue(report) {
                    try await projectManager.prepareDebugAttach(context: context, pid: pid)
                }
                #else
                return try await projectManager.prepareDebugAttach(context: context, pid: pid)
                #endif
            }
            let connection = try await self.prepareDebugLaunch(
                projectManager: projectManager,
                targets: targets,
                originId: originId,
                arguments: arguments,
                context: context
            )
            return DebugSessionBackend(
                connection: connection,
                validate: { try await self.validateDebugRevision(revision) },
                didStart: { await projectManager.debugSessionDidStart(uri: connection.uri) },
                stop: { await projectManager.stopDebugSession(uri: connection.uri) }
            )
        }, onClose: { [weak self] in
            await self?.removeDebugSession(id)
        })
        let uri = try await session.start()
        debugSessions[id] = session
        do {
            try Task.checkCancellation()
            try validateDebugRevision(revision)
            return DebugSessionConnection(uri: uri)
        } catch {
            await session.stop()
            debugSessions[id] = nil
            throw error
        }
    }

    func stopDebugSessions() async {
        invalidateBuildContexts()
        let sessions = Array(debugSessions.values)
        debugSessions.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask { await session.stop() }
            }
        }
    }

    private func validateDebugRevision(_ revision: Int) throws {
        guard revision == buildContextRevision else {
            throw BuildContextError.invalid("The project changed. Resolve a new debug context.")
        }
    }

    private func removeDebugSession(_ id: UUID) {
        debugSessions[id] = nil
    }

    private func prepareDebugLaunch(
        projectManager: any ProjectManager,
        targets: [BSPBuildTargetIdentifier],
        originId: String?,
        arguments: [String]?,
        context: BuildContext?
    ) async throws -> DebugSessionConnection {
        let root = await projectManager.rootURL
        let directory = await projectManager.project?.buildRootURL ?? root
            .appendingPathComponent(".sourcekit-bsp")
        let buildContext = BuildOutputContext(
            rootURL: root, logDirectory: directory.appendingPathComponent("Logs/sourcekit-bsp")
        )
        return try await taskManager.executeDebugWithProgress(
            originId: originId,
            buildContext: buildContext,
            cancellationCleanup: { await projectManager.stopDebugSession(uri: $0.uri) },
            operation: { progress, log in
                if let context {
                    return try await projectManager.startDebugSession(
                        targetIdentifiers: targets,
                        arguments: arguments,
                        logHandler: log,
                        progressHandler: progress,
                        context: context
                    )
                }
                return try await projectManager.startDebugSession(
                    targetIdentifiers: targets,
                    arguments: arguments,
                    logHandler: log,
                    progressHandler: progress
                )
            }
        )
    }
}
