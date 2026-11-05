import BuildServerProtocol
import Foundation
import JSONRPCConnection
import Testing
@testable import BSPServer

private protocol WorkspaceProjectManagerStub: ProjectManager {}

private actor RefreshProjectManager: WorkspaceProjectManagerStub {
    let rootURL = URL(fileURLWithPath: "/tmp/BSPWorkspace")
    nonisolated let projectType = "test"
    var revision = 0
    var inputInvalidations = 0
    var capabilities = Set(ProjectManagerCapability.allCases)
    var watchedFileRoots: [URL] {
        [rootURL, rootURL.deletingLastPathComponent().appendingPathComponent("SharedPackage")]
    }

    func setCapabilities(_ capabilities: ProjectManagerCapabilities) {
        self.capabilities = capabilities
    }

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
}

private extension WorkspaceProjectManagerStub {
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
        logHandler: (@Sendable (String) -> Void)?,
        progressHandler: (@Sendable (String) async -> Void)?
    ) async throws -> DebugSessionConnection {
        throw BuildServerError.invalidConfiguration("Unused test method")
    }
}

private actor FileChangeProjectManager: WorkspaceProjectManagerStub {
    let rootURL = URL(fileURLWithPath: "/tmp/BSPWorkspace")
    nonisolated let projectType = "test"
    let project: BSPProject? = nil
    var receivedChanges: [[ProjectFileChange]] = []
    var revision = 0
    var reloadRequired = false

    func setReloadRequired(_ required: Bool) {
        reloadRequired = required
    }

    func shouldReloadProject(for changes: [ProjectFileChange]) -> Bool {
        receivedChanges.append(changes)
        return reloadRequired
    }

    func getProjectState() -> ProjectState {
        .init()
    }

    func initialize() async throws {}

    func updateBuildGraph() async throws {
        revision += 1
    }
}

private actor PendingReloadProjectManager: WorkspaceProjectManagerStub {
    let rootURL = URL(fileURLWithPath: "/tmp/BSPPendingReload")
    nonisolated let projectType = "test"
    let project: BSPProject? = nil
    var didShutdown = false
    private var reloadContinuation: CheckedContinuation<Void, any Error>?
    private var startContinuation: CheckedContinuation<Void, Never>?

    func getProjectState() -> ProjectState {
        .init()
    }

    func initialize() async throws {}

    func updateBuildGraph() async throws {
        try await withCheckedThrowingContinuation { continuation in
            reloadContinuation = continuation
            startContinuation?.resume()
            startContinuation = nil
        }
    }

    func waitForReload() async {
        if reloadContinuation != nil { return }
        await withCheckedContinuation { startContinuation = $0 }
    }

    func shutdown() async {
        didShutdown = true
        reloadContinuation?.resume(throwing: CancellationError())
        reloadContinuation = nil
    }
}

private extension BSPServerService {
    func useTestManager(_ manager: any ProjectManager) {
        projectManager = manager
    }
}

struct WorkspaceLifecycleTests {
    private struct Harness<Manager: ProjectManager> {
        let service: BSPServerService
        let handler: BSPMessageHandler
        let manager: Manager
        let transport: MemoryTransport
    }

    private func setup() async -> Harness<RefreshProjectManager> {
        await setup(manager: RefreshProjectManager())
    }

    private func setup<Manager: ProjectManager>(manager: Manager) async -> Harness<Manager> {
        let transport = MemoryTransport()
        let handler = BSPMessageHandler()
        let connection = JSONRPCConnection(transport: transport, messageRegistry: bspRegistry, messageHandler: handler)
        let service = BSPServerService(projectManagerProvider: ProjectManagerFactory(), jsonrpcConnection: connection)
        await service.useTestManager(manager)
        handler.setBSPServerService(service)
        return Harness(service: service, handler: handler, manager: manager, transport: transport)
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownCancelsPendingProjectReload() async throws {
        let harness = await setup(manager: PendingReloadProjectManager())
        let reload = Task { try await harness.service.reloadProject() }
        await harness.manager.waitForReload()
        await harness.service.shutdownProject()
        await #expect(throws: CancellationError.self) { try await reload.value }
        #expect(await harness.manager.didShutdown)
        #expect(await harness.transport.sent.isEmpty)
    }

    @Test
    func fileChangesUseTheProviderDecision() async throws {
        let harness = await setup(manager: FileChangeProjectManager())
        let root = harness.manager.rootURL
        let events: [WorkspaceDidChangeWatchedFilesNotification.FileEvent] = [
            .init(uri: URI(root.appendingPathComponent("build.custom")), type: .created),
            .init(uri: URI(root.appendingPathComponent("input.custom")), type: .changed),
            .init(uri: URI(root.appendingPathComponent("removed.custom")), type: .deleted)
        ]
        let expected: [ProjectFileChange] = [
            .init(uri: events[0].uri, kind: .created),
            .init(uri: events[1].uri, kind: .changed),
            .init(uri: events[2].uri, kind: .deleted)
        ]
        try await harness.service.filesDidChange(events)
        #expect(await harness.manager.receivedChanges == [expected])
        #expect(await harness.manager.revision == 0)
        #expect(await harness.transport.sent.isEmpty)

        await harness.manager.setReloadRequired(true)
        try await harness.service.filesDidChange(events)
        #expect(await harness.manager.receivedChanges == [expected, expected])
        #expect(await harness.manager.revision == 1)
        #expect(await harness.transport.sent.count == 1)
    }

    @Test(arguments: [
        "Package.swift", "build.gradle.kts", "BUILD.bazel", "Sources/Main.kt",
        "DerivedData/Generated.swift", ".build/Input.swift",
        "App.xcodeproj/xcshareddata/xcschemes/sourcekit-bsp-App.xcscheme"
    ])
    func defaultProviderReloadsForUnknownFiles(path: String) async throws {
        let harness = await setup()
        let file = harness.manager.rootURL.appendingPathComponent(path)
        for kind in [WorkspaceDidChangeWatchedFilesNotification.FileEvent.Kind.created, .changed, .deleted] {
            try await harness.service.filesDidChange([.init(uri: URI(file), type: kind)])
        }
        #expect(await harness.manager.revision == 3)
        #expect(await harness.transport.sent.count == 3)
    }

    @Test
    func defaultProviderIgnoresEmptyBatches() async throws {
        let harness = await setup()
        try await harness.service.filesDidChange([])
        #expect(await harness.manager.revision == 0)
        #expect(await harness.transport.sent.isEmpty)
    }

    @Test
    func fileEventsReloadTargetsAndInvalidSavesCanBeRetried() async throws {
        let harness = await setup()
        let service = harness.service
        let handler = harness.handler
        let manager = harness.manager
        let transport = harness.transport
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
    func loadingOnlyProviderDoesNotAdvertiseBuildOperations() async throws {
        let harness = await setup()
        await harness.manager.setCapabilities([])
        let data = Data(
            #"{"id":1,"params":{"rootUri":"file:///tmp/BSPWorkspace","capabilities":{"languageIds":["swift"]}}}"#
                .utf8
        )
        let request = try JSONDecoder().decode(BuildInitializeRequest.self, from: data)
        let response = try #require(await request.handle(
            contextualHandler: harness.handler, id: .int(1)
        ) as? BuildInitializeResponse)
        let capabilities = response.result.capabilities
        #expect(capabilities.compileProvider == nil)
        #expect(capabilities.testProvider == nil)
        #expect(capabilities.runProvider == nil)
        #expect(capabilities.debugProvider == nil)
        #expect(capabilities.outputPathsProvider == false)
        #expect(capabilities.canReload == true)
        #expect(response.result.data.prepareProvider == false)
        #expect(response.result.data.sourceKitOptionsProvider == false)
        #expect(response.result.data.debugWithoutBuildingProvider == false)
        #expect(response.result.data.watchers.contains { $0.globPattern.hasPrefix("/tmp/SharedPackage/") })
        await #expect(throws: BuildServerError.self) {
            try await harness.service.outputPaths(for: [])
        }
        await #expect(throws: BuildServerError.self) {
            try await harness.service.cleanBuildTargetCaches(targets: [])
        }
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
