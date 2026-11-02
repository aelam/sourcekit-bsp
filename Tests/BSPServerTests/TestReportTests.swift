import BuildServerProtocol
import Foundation
import JSONRPCConnection
import Testing
@testable import BSPServer

private actor TestNotifications: BSPNotificationService {
    private(set) var messages: [Data] = []

    func sendNotification(_ notification: ServerJSONRPCNotification<some Codable & Sendable>) async throws {
        try Task.checkCancellation()
        try messages.append(JSONEncoder().encode(notification))
    }
}

struct TestReportTests {
    @Test
    func emitsJSONReportsWithDistinctTargetsAndPairedChildTasks() async throws {
        let service = TestNotifications()
        let manager = BSPTaskManager(notificationService: service)
        let targets = try ["First", "Second"].map { try BSPBuildTargetIdentifier(uri: URI(string: "file:///\($0)")) }
        let result = try await manager.executeTestsWithProgress(originId: "tests-1", context: .init()) { _, events in
            for target in targets {
                await events(.started(target))
                let tests = [
                    TestCaseResult(displayName: "sameName", status: .passed),
                    TestCaseResult(displayName: "failure", status: .failed, message: "Expected true"),
                    TestCaseResult(displayName: "skipped", status: .skipped),
                    TestCaseResult(displayName: "ignored", status: .ignored),
                    TestCaseResult(displayName: "cancelled", status: .cancelled)
                ]
                await events(.finished(target, .error, .init(tests: tests, time: 1250)))
            }
            return .error
        }
        #expect(result == .error)
        let messages = try await service.messages.map {
            try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        var active: Set<String> = []
        var summaries: [[String: Any]] = []
        var testStatuses: [Int] = []
        for message in messages {
            let method = message["method"] as? String
            guard method == "build/taskStart" || method == "build/taskFinish" else { continue }
            let params = try #require(message["params"] as? [String: Any])
            let task = try #require(params["taskId"] as? [String: Any])
            let id = try #require(task["id"] as? String)
            #expect(params["originId"] as? String == "tests-1")
            for parent in task["parents"] as? [String] ?? [] {
                #expect(active.contains(parent))
            }
            if method == "build/taskStart" {
                #expect(active.insert(id).inserted)
            } else {
                #expect(active.remove(id) != nil)
            }
            if params["dataKind"] != nil { #expect(params["data"] is [String: Any]) }
            let data = params["data"] as? [String: Any]
            if params["dataKind"] as? String == "test-report", let data { summaries.append(data) }
            if params["dataKind"] as? String == "test-finish" {
                try testStatuses.append(#require(data?["status"] as? Int))
            }
        }
        #expect(active.isEmpty)
        #expect(summaries.count == 2)
        #expect(testStatuses == [1, 2, 5, 3, 4, 1, 2, 5, 3, 4])
        for (index, summary) in summaries.enumerated() {
            #expect((summary["target"] as? [String: Any])?["uri"] as? String == targets[index].uri.stringValue)
            for field in ["passed", "failed", "ignored", "cancelled", "skipped"] {
                #expect(summary[field] as? Int == 1)
            }
            #expect(summary["time"] as? Int == 1250)
        }
        #expect(manager.getActiveTasks().isEmpty)
    }

    @Test(arguments: [false, true])
    func failureAndCancellationCloseTargetAndRootWithoutInventingResults(cancel: Bool) async throws {
        let service = TestNotifications()
        let manager = BSPTaskManager(notificationService: service)
        let target = try BSPBuildTargetIdentifier(uri: URI(string: "file:///Tests"))
        let operation = Task {
            try await manager.executeTestsWithProgress(originId: "cancel", context: .init()) { _, events in
                await events(.started(target))
                if cancel {
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw CancellationError()
                }
                throw BuildServerError.invalidConfiguration("Build failed before tests")
            }
        }
        await #expect(throws: (any Error).self) { try await operation.value }
        let messages = try await service.messages.map {
            try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        let finishes = messages.filter { $0["method"] as? String == "build/taskFinish" }
        #expect(finishes.count == 2)
        for finish in finishes {
            let params = try #require(finish["params"] as? [String: Any])
            #expect(params["status"] as? Int == (cancel ? 3 : 2))
            #expect(params["dataKind"] == nil)
        }
        #expect(manager.getActiveTasks().isEmpty)
    }

    @Test
    func cancellationDuringResultDeliveryStillClosesChildren() async throws {
        let service = TestNotifications()
        let manager = BSPTaskManager(notificationService: service)
        let target = try BSPBuildTargetIdentifier(uri: URI(string: "file:///Tests"))
        let operation = Task {
            try await manager.executeTestsWithProgress(originId: "late-cancel", context: .init()) { _, events in
                await events(.started(target))
                withUnsafeCurrentTask { $0?.cancel() }
                await events(.finished(target, .cancelled, .init(tests: [
                    TestCaseResult(displayName: "interrupted", status: .cancelled)
                ])))
                return .cancelled
            }
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
        let messages = try await service.messages.map {
            try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        let starts = messages.filter { $0["method"] as? String == "build/taskStart" }
        let finishes = messages.filter { $0["method"] as? String == "build/taskFinish" }
        #expect(starts.count == 3)
        #expect(finishes.count == 3)
        for finish in finishes {
            #expect((finish["params"] as? [String: Any])?["status"] as? Int == 3)
        }
        #expect(manager.getActiveTasks().isEmpty)
    }

    @Test
    func projectStateMessagesUseTheBSPMethod() async throws {
        let transport = MemoryTransport()
        let handler = BSPMessageHandler()
        let connection = JSONRPCConnection(transport: transport, messageRegistry: bspRegistry, messageHandler: handler)
        let service = BSPServerService(projectManagerProvider: ProjectManagerFactory(), jsonrpcConnection: connection)
        await service.onProjectStateChanged(.projectLoadStateChanged(
            from: .uninitialized, to: .loading(projectPath: "/tmp/Hello")
        ))
        let data = try #require(await transport.sent.first)
        let message = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(message["method"] as? String == "build/showMessage")
        let params = try #require(message["params"] as? [String: Any])
        #expect(params["type"] as? Int == 3)
        #expect((params["message"] as? String)?.contains("Hello") == true)
    }
}
