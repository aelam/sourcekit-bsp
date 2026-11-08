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
    @Test(arguments: [false, true])
    func flushesBuildOutputBeforeDebugFinishes(fail: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notifications = DebugNotifications()
        let manager = BSPTaskManager(notificationService: notifications)
        do {
            _ = try await manager.executeDebugWithProgress(
                originId: "debug-build", buildContext: BuildOutputContext(logDirectory: directory)
            ) { progress, log in
                await progress("Building app")
                log("Command line invocation:")
                log("xcodebuild -scheme CustomApp build")
                log(fail ? "error: build failed" : "** BUILD SUCCEEDED **")
                if fail { throw BuildServerError.invalidConfiguration("build failed") }
                return DebugSessionConnection(uri: "tcp://127.0.0.1:9999", request: .attach, pid: 42)
            }
            #expect(!fail)
        } catch {
            #expect(fail)
        }
        let messages = try await notifications.messages.map {
            try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        let logs = messages
            .filter { $0["method"] as? String == "build/logMessage" }
            .compactMap {
                ($0["params"] as? [String: Any])?["message"] as? String
            }
            .joined(separator: "\n")
        #expect(logs.contains("xcodebuild -scheme CustomApp build"))
        #expect(logs.contains(fail ? "build failed" : "BUILD SUCCEEDED"))
        #expect(messages.last?["method"] as? String == "build/taskFinish")
        let raw = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first)
        #expect(try String(contentsOf: raw, encoding: .utf8).contains("xcodebuild -scheme CustomApp build"))
        #expect(manager.getActiveTasks().isEmpty)
    }

    @Test
    func reportsPreparationWithoutClaimingAnAttachedDebugger() async throws {
        let notifications = DebugNotifications()
        let manager = BSPTaskManager(notificationService: notifications)
        let result = try await manager.executeDebugWithProgress(originId: "debug-1") { progress, _ in
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
        #expect(finish["message"] as? String == "Debug adapter ready")
        #expect(manager.getActiveTasks().isEmpty)
    }

    @Test(arguments: [false, true])
    func failureAndCancellationFinishTheTask(cancel: Bool) async throws {
        let notifications = DebugNotifications()
        let manager = BSPTaskManager(notificationService: notifications)
        let operation = Task {
            try await manager.executeDebugWithProgress(originId: "debug-2") { _, _ in
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
