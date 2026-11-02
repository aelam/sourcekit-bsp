import BuildServerProtocol
import Foundation
import JSONRPCConnection
import Testing
@testable import BSPServer

private actor DebugNotifications: BSPNotificationService {
    private(set) var messages: [Data] = []
    func sendNotification(_ notification: ServerJSONRPCNotification<some Codable & Sendable>) async throws {
        try Task.checkCancellation()
        try messages.append(JSONEncoder().encode(notification))
    }
}

struct DebugProgressTests {
    @Test
    func reportsPreparationWithoutClaimingAnAttachedDebugger() async throws {
        let notifications = DebugNotifications()
        let manager = BSPTaskManager(notificationService: notifications)
        let result = try await manager.executeDebugWithProgress(originId: "debug-1") { progress in
            await progress("Installing Hello")
            await progress("Waiting for DAP attach")
            return DebugSessionConnection(uri: "tcp://127.0.0.1:9999", request: .attach, pid: 42)
        }
        #expect(result.pid == 42)
        let messages = try await notifications.messages.map {
            try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        #expect(messages.map { $0["method"] as? String } == [
            "build/taskStart", "build/taskProgress", "build/logMessage",
            "build/taskProgress", "build/logMessage", "build/taskFinish"
        ])
        for message in messages {
            let params = try #require(message["params"] as? [String: Any])
            #expect(params["originId"] as? String == "debug-1")
        }
        let finish = try #require(messages.last?["params"] as? [String: Any])
        #expect(finish["status"] as? Int == 1)
        #expect(finish["message"] as? String == "Debug adapter ready; waiting for DAP attach")
        #expect(manager.getActiveTasks().isEmpty)
    }

    @Test(arguments: [false, true])
    func failureAndCancellationFinishTheTask(cancel: Bool) async throws {
        let notifications = DebugNotifications()
        let manager = BSPTaskManager(notificationService: notifications)
        let operation = Task {
            try await manager.executeDebugWithProgress(originId: "debug-2") { _ in
                if cancel {
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw CancellationError()
                }
                throw BuildServerError.invalidConfiguration("Device needs to be unlocked")
            }
        }
        await #expect(throws: (any Error).self) { try await operation.value }
        let messages = try await notifications.messages.map {
            try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        let finished = messages.count { $0["method"] as? String == "build/taskFinish" }
        #expect(finished == 1)
        let finish = try #require(messages.last?["params"] as? [String: Any])
        #expect(finish["status"] as? Int == (cancel ? 3 : 2))
        #expect(manager.getActiveTasks().isEmpty)
    }
}
