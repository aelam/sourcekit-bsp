import BuildServerProtocol
import Foundation
import JSONRPCConnection
import Testing
@testable import BSPServer

struct BuildTargetRunTests {
    @Test
    func cancelledRunReturnsCancelledWithoutAConfigurationError() async throws {
        let service = BSPServerService.createStdioService(projectManagerProvider: ProjectManagerFactory())
        let handler = BSPMessageHandler()
        handler.setBSPServerService(service)
        let request = try BuildTargetRunRequest(
            id: .int(20),
            jsonrpc: "2.0",
            params: .init(target: BSPBuildTargetIdentifier(uri: URI(string: "file:///Hello")), originId: "run-cancel")
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await request.handle(contextualHandler: handler, id: .int(20))
        }
        let response = try #require(await task.value as? BuildTargetRunResponse)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        let result = try #require(json["result"] as? [String: Any])
        #expect(result["statusCode"] as? Int == StatusCode.cancelled.rawValue)
        #expect(result["originId"] as? String == "run-cancel")
    }
}

private actor RunNotifications: BSPNotificationService {
    private(set) var messages: [Data] = []

    func sendNotification(_ notification: ServerJSONRPCNotification<some Codable & Sendable>) async throws {
        try Task.checkCancellation()
        try messages.append(JSONEncoder().encode(notification))
    }
}

struct RunProgressTests {
    @Test(arguments: [StatusCode.ok, .error, .cancelled])
    func reportsStagesAndFinishesWithTheOperationStatus(status: StatusCode) async throws {
        let notifications = RunNotifications()
        let manager = BSPTaskManager(notificationService: notifications)
        let result = try await manager.executeRunWithProgress(originId: "run-1") { progress in
            await progress("Installing Hello")
            await progress("Launching Hello")
            let messages = await notifications.messages
            #expect(messages.count == 5)
            return status
        }
        #expect(result == status)
        let messages = try await notifications.messages.map {
            try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        #expect(messages.map { $0["method"] as? String } == [
            "build/taskStart", "build/taskProgress", "build/logMessage",
            "build/taskProgress", "build/logMessage", "build/taskFinish"
        ])
        for message in messages {
            let params = try #require(message["params"] as? [String: Any])
            #expect(params["originId"] as? String == "run-1")
            #expect(params["total"] == nil)
        }
        let finish = try #require(messages.last?["params"] as? [String: Any])
        #expect(finish["status"] as? Int == status.rawValue)
        #expect(manager.getActiveTasks().isEmpty)
    }

    @Test(arguments: [false, true])
    func failureAndCancellationAlwaysFinish(cancel: Bool) async throws {
        let notifications = RunNotifications()
        let manager = BSPTaskManager(notificationService: notifications)
        let operation = Task {
            try await manager.executeRunWithProgress(originId: "run-failure") { progress in
                await progress("Installing Hello")
                if cancel {
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw CancellationError()
                }
                throw BuildServerError.invalidConfiguration("Install failed")
            }
        }
        await #expect(throws: (any Error).self) { try await operation.value }
        let messages = try await notifications.messages.map {
            try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        let finishedTasks = messages.count { $0["method"] as? String == "build/taskFinish" }
        #expect(finishedTasks == 1)
        let finish = try #require(messages.last?["params"] as? [String: Any])
        #expect(finish["status"] as? Int == (cancel ? 3 : 2))
        #expect((finish["message"] as? String)?.contains(cancel ? "cancelled" : "Install failed") == true)
        #expect(manager.getActiveTasks().isEmpty)
    }
}
