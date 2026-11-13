import Foundation
import JSONRPCConnection
import SourceKitBSPProtocol

actor TestReportReporter {
    let task: BSPTask
    let service: BSPNotificationService?
    private var targets: [BSPBuildTargetIdentifier: String] = [:]
    private var counter = 0

    init(task: BSPTask, service: BSPNotificationService?) {
        self.task = task
        self.service = service
    }

    func consume(_ event: TestExecutionEvent) async {
        switch event {
        case let .warning(message):
            try? await service?.sendNotification(ServerJSONRPCNotification(
                method: "build/logMessage",
                params: BuildLogMessageParams(type: 2, originId: task.originId, message: message)
            ))
        case let .started(target):
            guard targets[target] == nil else { return }
            counter += 1
            let id = "\(task.taskId)-target-\(counter)"
            targets[target] = id
            await sendStart(.init(
                taskId: id,
                parents: [task.taskId],
                originId: task.originId,
                message: "Test \(target.uri.stringValue)",
                dataKind: .testTask,
                data: ["target": ["uri": .string(target.uri.stringValue)]]
            ))
        case let .finished(target, status, report):
            await finishTarget(target, status: status, report: report)
        }
    }

    func finish(status: StatusCode) async {
        for target in Array(targets.keys) {
            await finishTarget(target, status: status == .cancelled ? .cancelled : .error, report: nil)
        }
    }

    private func finishTarget(
        _ target: BSPBuildTargetIdentifier, status: StatusCode, report: TestExecutionReport?
    ) async {
        guard let id = targets.removeValue(forKey: target) else { return }
        for (index, test) in (report?.tests ?? []).enumerated() {
            let caseID = "\(id)-case-\(index)"
            var startData: [String: LSPAny] = ["displayName": .string(test.displayName)]
            if let testId = test.testId { startData["testId"] = .string(testId) }
            await sendStart(.init(
                taskId: caseID,
                parents: [id],
                originId: task.originId,
                message: test.displayName,
                dataKind: .testStart,
                data: .dictionary(startData)
            ))
            await sendFinish(.init(
                taskId: caseID,
                parents: [id],
                originId: task.originId,
                message: "\(test.displayName): \(test.status)",
                status: taskStatus(test.status),
                dataKind: .TestFinish,
                data: json(test)
            ))
        }
        let summary = report.map { TestReport(target: target, results: $0.tests, time: $0.time) }
        await sendFinish(.init(
            taskId: id,
            parents: [task.taskId],
            originId: task.originId,
            message: summary.map { "Tests: \($0.passed) passed, \($0.failed) failed, \($0.skipped) skipped" }
                ?? "Test execution ended without a result report",
            status: status,
            dataKind: summary == nil ? nil : .TestReport,
            data: summary.flatMap { json($0) }
        ))
    }

    private func taskStatus(_ status: TestStatus) -> StatusCode {
        switch status {
        case .passed, .ignored, .skipped: .ok
        case .failed: .error
        case .cancelled: .cancelled
        }
    }

    private func json(_ value: some Encodable) -> LSPAny? {
        try? JSONDecoder().decode(LSPAny.self, from: JSONEncoder().encode(value))
    }

    private func sendStart(_ params: TaskStartParams) async {
        try? await service?.sendNotification(ServerJSONRPCNotification(method: TaskStartParams.method, params: params))
    }

    private func sendFinish(_ params: TaskFinishParams) async {
        try? await service?.sendNotification(ServerJSONRPCNotification(method: TaskFinishParams.method, params: params))
    }
}
