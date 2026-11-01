import BuildServerProtocol
import Foundation
import JSONRPCConnection
import Testing
@testable import BSPServer

private actor BuildNotifications: BSPNotificationService {
    private(set) var messages: [Data] = []

    func sendNotification(_ notification: ServerJSONRPCNotification<some Codable & Sendable>) async throws {
        try messages.append(JSONEncoder().encode(notification))
    }
}

struct BuildOutputTests {
    private func context(root: URL, names: [String] = ["Hello"]) -> BuildOutputContext {
        let file = root.appendingPathComponent("A file.swift")
        let targets = names.map { name in
            BSPBuildTarget(
                id: .init(uri: URI(root.appendingPathComponent(name))), displayName: name, capabilities: .init()
            )
        }
        return BuildOutputContext(
            rootURL: root,
            logDirectory: root.appendingPathComponent("logs"),
            targets: targets,
            sources: targets.map { SourcesItem(
                target: $0.id,
                sources: [.init(uri: URI(file), kind: .file, generated: false)]
            ) },
            affectedTargets: targets.map(\.id)
        )
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test
    func parsesUnicodeLocationsAndKeepsDiagnosticContext() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "let 文😀 = missing\n".write(
            to: root.appendingPathComponent("A file.swift"),
            atomically: true,
            encoding: .utf8
        )
        var parser = XcodeBuildOutputParser(context: context(root: root))
        let result = parser.parse("A file.swift:1:15: error: cannot find 'missing' in scope")
        let diagnostic = try #require(result.diagnostic?.diagnostic)
        #expect(diagnostic.range.start.line == 0)
        #expect(diagnostic.range.start.character == 10)
        #expect(diagnostic.severity == .error)
        #expect(parser.parse("    |     ^ error context").message != nil)
        #expect(parser.parse("    custom script failure details").message != nil)
        #expect(parser.parse("    /usr/bin/swiftc -very-long-options").message == nil)
        #expect(parser.parse("ld: error: undefined symbols").type == 1)
    }

    @Test
    func sharedSourcesRequireUnambiguousOwnership() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = context(root: root, names: ["App", "Tests"])
        var parser = XcodeBuildOutputParser(context: context)
        _ = parser.parse("SwiftCompile normal arm64 (in target 'App' from project 'Hello')")
        #expect(parser.parse("A file.swift:1:2: warning: ambiguous owner").diagnostic == nil)
        let result = parser.parse("A file.swift:1:2: warning: unused (in target 'Tests' from project 'Hello')")
        #expect(result.diagnostic?.target == context.targets[1].id)
        #expect(result.diagnostic?.diagnostic.message == "unused")
        #expect(result.type == 2)
    }

    @Test
    func countsBuildStepsWithoutInventingATotal() {
        var parser = XcodeBuildOutputParser(context: .init())
        #expect(parser.parse("ComputeTargetDependencyGraph").progress == "Resolve build dependencies")
        #expect(parser.parse("SwiftCompile normal arm64 (in target 'Hello' from project 'Hello')")
            .progress == "Compile Swift — Hello")
        #expect(parser.steps == 2)
        #expect(parser.parse("Test Case '-[HelloTests testExample]' passed (0.1 seconds).").progress != nil)
        #expect(parser.steps == 2)
    }

    @Test
    func streamsProgressAndDiagnosticsBeforeFinishAndPreservesRawLog() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = BuildNotifications()
        let manager = BSPTaskManager(notificationService: service)
        let command = "    /usr/bin/swiftc -module-name Hello"
        let context = context(root: root)
        let status = try await manager
            .executeWithProgress(originId: "compile-1", message: "Compile", context: context) { log in
                log("SwiftCompile normal arm64 (in target 'Hello' from project 'Hello')")
                log(command)
                log("A file.swift:1:2: warning: unused value")
                return .ok
            }
        #expect(status == .ok)
        let messages = try await service.messages
            .map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] ?? [:] }
        #expect(messages.first?["method"] as? String == "build/taskStart")
        #expect(messages.last?["method"] as? String == "build/taskFinish")
        let start = try #require(messages.first?["params"] as? [String: Any])
        #expect((start["taskId"] as? [String: Any])?["id"] is String)
        #expect((start["eventTime"] as? Int64 ?? 0) > 1_000_000_000_000)
        let progress = messages.filter { $0["method"] as? String == "build/taskProgress" }
        #expect(progress.count >= 2)
        #expect((progress.last?["params"] as? [String: Any])?["total"] == nil)
        #expect((progress.last?["params"] as? [String: Any])?["progress"] as? Double == 1)
        #expect(messages.contains { $0["method"] as? String == "build/publishDiagnostics" })
        let logs = messages.filter { $0["method"] as? String == "build/logMessage" }
            .compactMap { $0["params"] as? [String: Any] }
        #expect(logs.contains { $0["type"] as? Int == 2 })
        #expect(!logs.contains { ($0["message"] as? String ?? "").contains(command) })
        let files = try FileManager.default.contentsOfDirectory(
            at: context.logDirectory,
            includingPropertiesForKeys: nil
        )
        let raw = try String(contentsOf: #require(files.first), encoding: .utf8)
        #expect(raw.contains(command))
        #expect(raw.contains("warning: unused value"))
        #expect(manager.getActiveTasks().isEmpty)
    }

    @Test
    func newBuildClearsDiagnosticsAndRejectsLateOutputFromOldBuild() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = context(root: root, names: ["App", "Tests"])
        let service = BuildNotifications()
        let store = BuildDiagnosticsStore()
        let old = BSPTask(taskId: "old", originId: "old", message: nil)
        let new = BSPTask(taskId: "new", originId: "new", message: nil)
        let file = root.appendingPathComponent("A file.swift")
        let position = Diagnostic.Position(line: 0, character: 0)
        let diagnostic = Diagnostic(range: .init(start: position, end: position), message: "old error")
        await store.begin(task: old, targets: context.affectedTargets, service: service)
        await store.publish(
            context.affectedTargets.map { BuildOutputDiagnostic(file: file, target: $0, diagnostic: diagnostic) },
            task: old,
            service: service
        )
        await store.begin(task: new, targets: [context.targets[0].id], service: service)
        let count = await service.messages.count
        await store.publish(
            [BuildOutputDiagnostic(file: file, target: context.targets[0].id, diagnostic: diagnostic)],
            task: old,
            service: service
        )
        #expect(await service.messages.count == count)
        let last = try #require(await service.messages.last)
        let envelope = try JSONSerialization.jsonObject(with: last) as? [String: Any]
        let params = try #require(envelope?["params"] as? [String: Any])
        #expect((params["diagnostics"] as? [Any])?.isEmpty == true)
        #expect(params["originId"] as? String == "new")
        #expect((params["buildTarget"] as? [String: String])?["uri"] == context.targets[0].id.uri.stringValue)
    }

    @Test
    func cancellationFlushesOutputAndFinishesTheTask() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = BuildNotifications()
        let manager = BSPTaskManager(notificationService: service)
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let context = context(root: root)
        let operation = Task {
            try await manager.executeWithProgress(originId: "cancel", message: "Test", context: context) { log in
                log("Test Case 'example' started.")
                continuation.yield(())
                try await Task.sleep(for: .seconds(60))
                return .ok
            }
        }
        for await _ in started {
            break
        }
        operation.cancel()
        do {
            _ = try await operation.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        let messages = try await service.messages
            .map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] ?? [:] }
        #expect((messages.last?["params"] as? [String: Any])?["status"] as? Int == 3)
        #expect(messages.contains { $0["method"] as? String == "build/taskProgress" })
        #expect(manager.getActiveTasks().isEmpty)
    }
}
