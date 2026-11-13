import Foundation
import JSONRPCConnection
import SourceKitBSPProtocol

actor BuildDiagnosticsStore {
    private struct TargetState {
        var owner: String?
        var files: [URL: [Diagnostic]] = [:]
    }

    private var targets: [BSPBuildTargetIdentifier: TargetState] = [:]
    private var pending: Task<Void, Never>?

    func begin(
        task: BSPTask, targets identifiers: [BSPBuildTargetIdentifier], service: (any BSPNotificationService)?
    ) async {
        var resets: [PublishDiagnosticsParams] = []
        for id in identifiers {
            for file in targets[id]?.files.keys ?? [URL: [Diagnostic]]().keys {
                resets.append(params(file: file, target: id, originId: task.originId, diagnostics: []))
            }
            targets[id] = TargetState(owner: task.taskId)
        }
        await send(resets, service: service)
    }

    func publish(
        _ values: [BuildOutputDiagnostic], task: BSPTask, service: (any BSPNotificationService)?
    ) async {
        var changed: [BSPBuildTargetIdentifier: Set<URL>] = [:]
        for value in values {
            let file = value.file
            let target = value.target
            let diagnostic = value.diagnostic
            guard targets[target]?.owner == task.taskId else { continue }
            let existing = targets[target]?.files[file] ?? []
            let encoded = try? JSONEncoder().encode(diagnostic)
            if existing.contains(where: { (try? JSONEncoder().encode($0)) == encoded }) { continue }
            targets[target]?.files[file, default: []].append(diagnostic)
            changed[target, default: []].insert(file)
        }
        var notifications: [PublishDiagnosticsParams] = []
        for (target, files) in changed {
            for file in files {
                notifications.append(params(
                    file: file, target: target, originId: task.originId, diagnostics: targets[target]?.files[file] ?? []
                ))
            }
        }
        await send(notifications, service: service)
    }

    func end(taskId: String) {
        for id in targets.keys where targets[id]?.owner == taskId {
            targets[id]?.owner = nil
        }
    }

    private func params(
        file: URL, target: BSPBuildTargetIdentifier, originId: String?, diagnostics: [Diagnostic]
    ) -> PublishDiagnosticsParams {
        PublishDiagnosticsParams(
            textDocument: .init(URI(file)),
            buildTarget: target,
            originId: originId,
            diagnostics: diagnostics,
            reset: true
        )
    }

    private func send(_ params: [PublishDiagnosticsParams], service: (any BSPNotificationService)?) async {
        guard !params.isEmpty else { return }
        // Serialize writes across actor suspension points so an old build cannot overwrite a new reset.
        let previous = pending
        let write = Task {
            await previous?.value
            for value in params {
                try? await service?.sendNotification(ServerJSONRPCNotification(
                    method: PublishDiagnosticsParams.method, params: value
                ))
            }
        }
        pending = write
        await write.value
    }
}
