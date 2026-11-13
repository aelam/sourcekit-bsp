import Foundation
import SourceKitBSPProtocol

extension BSPTaskManager {
    func executeTestsWithProgress(
        originId: String?,
        context: BuildOutputContext,
        operation: @Sendable (
            @escaping @Sendable (String) -> Void,
            @escaping @Sendable (TestExecutionEvent) async -> Void
        ) async throws -> StatusCode
    ) async throws -> StatusCode {
        try await executeTask(originId: originId, message: "Run tests", context: context) { task, log in
            let reporter = TestReportReporter(task: task, service: self.notificationService)
            do {
                let status = try await operation(log) { event in
                    await Task { await reporter.consume(event) }.value
                }
                await Task { await reporter.finish(status: status) }.value
                return (status, status)
            } catch {
                await Task {
                    await reporter.finish(status: error is CancellationError ? .cancelled : .error)
                }.value
                throw error
            }
        }
    }
}
