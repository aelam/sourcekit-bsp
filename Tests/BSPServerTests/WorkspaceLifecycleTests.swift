import BuildServerProtocol
import Foundation
import JSONRPCConnection
import Testing
@testable import BSPServer

private actor RefreshProjectManager: ProjectManager {
    let rootURL = URL(fileURLWithPath: "/tmp/BSPWorkspace")
    nonisolated let projectType = "test"
    var revision = 0
    var inputInvalidations = 0

    func invalidateIndexInputs() {
        inputInvalidations += 1
    }

    var failReload = false
    var project: BSPProject? {
        BSPProject(
            rootURL: rootURL,
            name: "Test",
            targets: makeTargets(),
            buildRootURL: rootURL.appendingPathComponent("DerivedData"),
            indexStoreURL: rootURL.appendingPathComponent("IndexStore"),
            indexDatabaseURL: rootURL.appendingPathComponent("IndexDatabase")
        )
    }

    func setFailure(_ fail: Bool) {
        failReload = fail
    }

    func getProjectState() -> ProjectState {
        .init()
    }

    func initialize() async throws {}
    func updateBuildGraph() async throws {
        if failReload { throw BuildServerError.invalidConfiguration("Incomplete project") }
        revision += 1
    }

    private func makeTargets() -> [BSPBuildTarget] {
        ["Keep", revision == 0 ? "Removed" : "Added"].map {
            BSPBuildTarget(
                id: .init(uri: URI(rootURL.appendingPathComponent($0))),
                tags: [],
                languageIds: [.swift],
                dependencies: [],
                capabilities: .init()
            )
        }
    }

    func getSourceFileList(targetIdentifiers: [BSPBuildTargetIdentifier]) async throws -> [SourcesItem] {
        []
    }

    func getCompileArguments(targetIdentifier: String, sourceFileURL: URL) async throws -> [String] {
        []
    }

    func buildIndex(for targetIdentifiers: [BSPBuildTargetIdentifier]) async throws -> [BSPBuildTargetIdentifier] {
        []
    }

    func startBuild(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        logHandler: (@Sendable (String) -> Void)?
    ) async throws -> StatusCode {
        .ok
    }

    func run(
        targetIdentifier: BSPBuildTargetIdentifier,
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?
    ) async throws -> StatusCode {
        .ok
    }

    func test(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        logHandler: (@Sendable (String) -> Void)?
    ) async throws -> StatusCode {
        logHandler?("Test runner output")
        return .error
    }

    // swiftlint:disable:next function_parameter_count
    func test(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        logHandler: (@Sendable (String) -> Void)?,
        testEventHandler: (@Sendable (TestExecutionEvent) async -> Void)?
    ) async throws -> StatusCode {
        for target in targetIdentifiers {
            await testEventHandler?(.started(target))
            await testEventHandler?(.finished(target, .error, .init(tests: [
                TestCaseResult(displayName: "example", status: .failed, message: "Expected true")
            ])))
        }
        return try await test(
            targetIdentifiers: targetIdentifiers,
            arguments: arguments,
            environmentVariables: environmentVariables,
            workingDirectory: workingDirectory,
            logHandler: logHandler
        )
    }

    func startDebugSession(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        buildBeforeLaunch: Bool,
        logHandler: (@Sendable (String) -> Void)?,
        progressHandler: (@Sendable (String) async -> Void)?
    ) async throws -> DebugSessionConnection {
        throw BuildServerError.invalidConfiguration("Unused test method")
    }
}

private extension BSPServerService {
    func useTestManager(_ manager: any ProjectManager) {
        projectManager = manager
    }
}

struct WorkspaceLifecycleTests {
    private struct Harness {
        let service: BSPServerService
        let handler: BSPMessageHandler
        let manager: RefreshProjectManager
        let transport: MemoryTransport
    }

    private func setup() async -> Harness {
        let transport = MemoryTransport()
        let handler = BSPMessageHandler()
        let connection = JSONRPCConnection(transport: transport, messageRegistry: bspRegistry, messageHandler: handler)
        let service = BSPServerService(projectManagerProvider: ProjectManagerFactory(), jsonrpcConnection: connection)
        let manager = RefreshProjectManager()
        await service.useTestManager(manager)
        handler.setBSPServerService(service)
        return Harness(service: service, handler: handler, manager: manager, transport: transport)
    }

    @Test
    func fileEventsReloadTargetsAndInvalidSavesCanBeRetried() async throws {
        let harness = await setup()
        let service = harness.service
        let handler = harness.handler
        let manager = harness.manager
        let transport = harness.transport
        let ignored = #"{"params":{"changes":[{"uri":"file:///tmp/BSPWorkspace/DerivedData/Generated.swift","type":1},{"uri":"file:///tmp/BSPWorkspace/.build/Input.swift","type":3},{"uri":"file:///tmp/BSPWorkspace/Edited.swift","type":2}]}}"#
        let notification = try JSONDecoder().decode(
            WorkspaceDidChangeWatchedFilesNotification.self,
            from: Data(ignored.utf8)
        )
        try await notification.handle(contextualHandler: handler)
        #expect(await manager.revision == 0)
        let changed = #"{"params":{"changes":[{"uri":"file:///tmp/BSPWorkspace/New.swift","type":1}]}}"#
        let update = try JSONDecoder().decode(WorkspaceDidChangeWatchedFilesNotification.self, from: Data(changed.utf8))
        try await update.handle(contextualHandler: handler)
        try await service.waitForBuildSystemUpdates()
        #expect(await manager.revision == 1)
        let data = try #require(await transport.sent.first)
        let event = try JSONDecoder().decode(
            ServerJSONRPCNotification<BuildTargetDidChangeNotification.Params>.self,
            from: data
        )
        let changes = try #require(event.params.changes)
        let kinds = Dictionary(uniqueKeysWithValues: changes.map { (
            $0.target.uri.fileURL?.lastPathComponent,
            $0.kind
        ) })
        #expect(kinds["Added"] == .created)
        #expect(kinds["Removed"] == .deleted)
        #expect(kinds["Keep"] == .changed)

        await manager.setFailure(true)
        await #expect(throws: (any Error).self) { try await update.handle(contextualHandler: handler) }
        #expect(await manager.revision == 1)
        await #expect(throws: (any Error).self) { try await service.waitForBuildSystemUpdates() }
        await manager.setFailure(false)
        let reload = WorkspaceReloadRequest(jsonrpc: "2.0", id: .int(1), params: nil)
        #expect(await reload.handle(contextualHandler: handler, id: .int(1)) is VoidResponse)
        try await service.waitForBuildSystemUpdates()
        #expect(await manager.revision == 2)
    }

    @Test
    func unsupportedSelectionDoesNotRunTheWholeTarget() async throws {
        let harness = await setup()
        let request = BuildTargetTestRequest(
            id: .int(9),
            jsonrpc: "2.0",
            params: .init(targets: [], dataKind: "unknown-selection", data: .dictionary([:]))
        )
        let response = try #require(await request.handle(
            contextualHandler: harness.handler, id: .int(9)
        ) as? BuildTargetTestResponse)
        #expect(response.result.statusCode == .error)
        #expect(await harness.transport.sent.isEmpty)
    }

    @Test
    func requestPublishesProviderReportsWithTheRequestOrigin() async throws {
        let harness = await setup()
        let target = try BSPBuildTargetIdentifier(uri: URI(string: "file:///tmp/BSPWorkspace/Keep"))
        let request = BuildTargetTestRequest(
            id: .int(8),
            jsonrpc: "2.0",
            params: .init(targets: [target], originId: "test-report-origin")
        )
        let response = try #require(await request.handle(
            contextualHandler: harness.handler, id: .int(8)
        ) as? BuildTargetTestResponse)
        #expect(response.result.statusCode == .error)
        let messages = try await harness.transport.sent.map {
            try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        let report = try #require(messages.compactMap { $0["params"] as? [String: Any] }.first {
            $0["dataKind"] as? String == "test-report"
        })
        #expect(report["originId"] as? String == "test-report-origin")
        let data = try #require(report["data"] as? [String: Any])
        #expect(data["failed"] as? Int == 1)
        #expect((data["target"] as? [String: Any])?["uri"] as? String == target.uri.stringValue)
    }

    @Test
    func capabilitiesMatchHandlersAndTestsReportFailureWithLogs() async throws {
        let harness = await setup()
        let handler = harness.handler
        let transport = harness.transport
        let data = Data(
            #"{"id":1,"params":{"rootUri":"file:///tmp/BSPWorkspace","capabilities":{"languageIds":["swift"]}}}"#
                .utf8
        )
        let initialize = try JSONDecoder().decode(BuildInitializeRequest.self, from: data)
        let response = try #require(await initialize.handle(
            contextualHandler: handler,
            id: .int(1)
        ) as? BuildInitializeResponse)
        let capabilities = response.result.capabilities
        #expect(capabilities.inverseSourcesProvider == false)
        #expect(capabilities.dependencySourcesProvider == false)
        #expect(capabilities.resourcesProvider == false)
        #expect(capabilities.canReload == true)
        #expect(response.result.data.debugWithoutBuildingProvider == true)
        #expect(bspRegistry.requestType(for: "workspace/reload") != nil)
        #expect(response.result.data.watchers.allSatisfy { !$0.globPattern.hasPrefix("!") })
        let request = BuildTargetTestRequest(
            id: .int(2),
            jsonrpc: "2.0",
            params: .init(targets: [], originId: "test-origin")
        )
        let result = try #require(await request.handle(
            contextualHandler: handler,
            id: .int(2)
        ) as? BuildTargetTestResponse)
        #expect(result.result.statusCode == .error)
        #expect(result.result.originId == "test-origin")
        let notifications = try await transport.sent
            .map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(notifications.first??["method"] as? String == "build/taskStart")
        #expect(notifications.last??["method"] as? String == "build/taskFinish")
        #expect(notifications.contains { $0?["method"] as? String == "build/logMessage" })
    }

    @Test
    func fileEventsInvalidatePreparationInputs() async throws {
        let harness = await setup()
        let source = harness.manager.rootURL.appendingPathComponent("Edited.swift")
        let edited = WorkspaceDidChangeWatchedFilesNotification(params: .init(changes: [
            .init(uri: URI(source), type: .changed)
        ]))
        try await edited.handle(contextualHandler: harness.handler)
        #expect(await harness.manager.inputInvalidations == 1)
        let empty = WorkspaceDidChangeWatchedFilesNotification(params: .init(changes: []))
        try await empty.handle(contextualHandler: harness.handler)
        #expect(await harness.manager.inputInvalidations == 1)
    }
}
