import Foundation
import JSONRPCConnection
import SourceKitBSPProtocol
import Testing
@testable import BSPServer

struct BuildContextTests {
    @Test
    func debugStartCreatesOnlyADeferredEndpoint() async throws {
        let harness = try await setup()
        let resolved = try await harness.service.resolveContext(.init(operation: .debug, buildPolicy: .build))
        let connection = try await harness.service.startDebugSession(
            targets: [harness.manager.target], arguments: nil, executionContext: .init(id: resolved.id)
        )
        #expect(connection.request == nil)
        #expect(await harness.manager.executions.isEmpty)
        let json = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(DebugSessionStartResponse(connection: connection).result)
        ) as? [String: Any])
        #expect(Set(json.keys) == ["uri"])
        await harness.service.shutdownProject()
    }

    private struct Harness {
        let service: BSPServerService
        let handler: BSPMessageHandler
        let manager: ContextTestManager
        let initialization: BuildInitializeResponse
    }

    private func setup(
        version: String? = "0.1", supported: Bool = true, reuse: Bool = true
    ) async throws -> Harness {
        let manager = ContextTestManager(supported: supported, reuse: reuse)
        let handler = BSPMessageHandler()
        let connection = JSONRPCConnection(
            transport: MemoryTransport(),
            messageRegistry: bspRegistry,
            messageHandler: handler
        )
        let service = BSPServerService(projectManagerProvider: ProjectManagerFactory(), jsonrpcConnection: connection)
        await service.useContextTestManager(manager)
        handler.setBSPServerService(service)
        var params: [String: Any] = [
            "rootUri": manager.rootURL.absoluteString,
            "capabilities": ["languageIds": ["swift"]]
        ]
        if let version { params["data"] = ["bspExtensions": [BuildContextExtension.name: ["version": version]]] }
        let request = try JSONDecoder().decode(
            BuildInitializeRequest.self,
            from: JSONSerialization.data(withJSONObject: [
                "id": 1, "jsonrpc": "2.0", "params": params
            ])
        )
        let initialization = try #require(await request.handle(
            contextualHandler: handler,
            id: .int(1)
        ) as? BuildInitializeResponse)
        return Harness(service: service, handler: handler, manager: manager, initialization: initialization)
    }

    @Test
    func destinationMetadataPreservesTypedAndUnknownPayloads() throws {
        let destination = BuildContextDestination(
            kind: "simulator",
            platform: .init(id: "ios", label: "iOS"),
            osVersion: "26.0",
            architecture: "arm64",
            state: "booted",
            identifier: .init(label: "UDID", value: "SIMULATOR-UDID")
        )
        let option = BuildContextOption(
            id: "simulator-id",
            label: "iPhone",
            description: "iOS Simulator",
            dataKind: BuildContextDestination.dataKind,
            data: destination.encodeToLSPAny()
        )
        let encoded = try JSONEncoder().encode(option)
        let decoded = try JSONDecoder().decode(BuildContextOption.self, from: encoded)
        #expect(decoded == option)
        let metadata = try #require(decoded.data)
        let typed = try JSONDecoder().decode(BuildContextDestination.self, from: JSONEncoder().encode(metadata))
        #expect(typed == destination)
        #expect(typed.identifier == .init(label: "UDID", value: "SIMULATOR-UDID"))
        #expect(decoded.id == "simulator-id")
        let legacyMetadata = try JSONDecoder().decode(
            BuildContextDestination.self,
            from: Data(#"{"kind":"host","platform":{"id":"macos","label":"macOS"}}"#.utf8)
        )
        #expect(legacyMetadata.identifier == nil)
        let legacyObject = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(legacyMetadata)
        ) as? [String: Any])
        #expect(legacyObject["identifier"] == nil)
        let future = BuildContextDestination(kind: "vendor-device", platform: .init(id: "vendor", label: "Vendor OS"))
        #expect(try JSONDecoder().decode(BuildContextDestination.self, from: JSONEncoder().encode(future))
            .kind == "vendor-device")
        let unknown = BuildContextOption(
            id: "future",
            label: "Future destination",
            dataKind: "vendor-destination",
            data: .dictionary(["vendorKey": .string("value")])
        )
        #expect(try JSONDecoder().decode(BuildContextOption.self, from: JSONEncoder().encode(unknown)) == unknown)
        let legacy = try JSONDecoder().decode(
            BuildContextOption.self,
            from: Data(#"{"id":"host","label":"Host"}"#.utf8)
        )
        #expect(legacy.dataKind == nil)
        #expect(legacy.data == nil)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        #expect(Set(object.keys) == ["id", "label"])
    }

    @Test
    func disabledDimensionsRoundTripWithoutChangingLegacyPayloads() throws {
        let dimension = BuildContextDimension(
            id: "configuration",
            label: "Configuration",
            required: false,
            options: [],
            enabled: false,
            reason: "Select a scheme first."
        )
        let encoded = try JSONEncoder().encode(dimension)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["enabled"] as? Bool == false)
        #expect(object["reason"] as? String == "Select a scheme first.")
        #expect(object["required"] as? Bool == false)
        #expect((object["options"] as? [Any])?.isEmpty == true)
        #expect(try JSONDecoder().decode(BuildContextDimension.self, from: encoded) == dimension)
        let previous = Data(
            #"{"id":"configuration","label":"Configuration","kind":"enum","required":false,"options":[]}"#
                .utf8
        )
        let decoded = try JSONDecoder().decode(BuildContextDimension.self, from: previous)
        #expect(decoded.enabled == nil)
        #expect(decoded.reason == nil)
        let compatible = try #require(JSONSerialization
            .jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(compatible["enabled"] == nil)
        #expect(compatible["reason"] == nil)
    }

    @Test
    func optionsHaveNoOperationAndResolveRequiresOne() async throws {
        let harness = try await setup()
        let data = try JSONSerialization.data(withJSONObject: [
            "id": 3, "jsonrpc": "2.0", "params": ["scope": ["workspaceUri": harness.manager.rootURL.absoluteString]]
        ])
        let request = try JSONDecoder().decode(WorkspaceContextOptionsRequest.self, from: data)
        let encodedParams = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(request.params)
        ) as? [String: Any])
        #expect(encodedParams["operation"] == nil)
        #expect(Set(encodedParams.keys) == ["scope"])
        let response = try #require(await request.handle(contextualHandler: harness.handler, id: .int(3)))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["operations"] as? [String] == BuildContextOperation.allCases.map(\.rawValue))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(WorkspaceResolveContextRequest.self, from: data)
        }
    }

    @Test
    func initializationNegotiatesOnlyMatchingSupportedExtension() async throws {
        let supported = try await setup()
        let capability = try #require(supported.initialization.result.data.bspExtensions?[BuildContextExtension.name])
        #expect(capability.version == "0.1")
        #expect(capability.required)
        #expect(Set(capability.operations) == Set(BuildContextOperation.allCases))
        for harness in try await [setup(version: nil), setup(version: "9.0"), setup(supported: false)] {
            #expect(harness.initialization.result.data.bspExtensions == nil)
            #expect(try await harness.service.executionContext(
                nil,
                operation: .compile,
                targets: [harness.manager.target]
            ) == nil)
            await #expect(throws: BuildContextError.self) {
                try await harness.service.contextOptions(.init())
            }
            await #expect(throws: BuildContextError.self) {
                try await harness.service.executionContext(
                    .init(id: "unnegotiated"),
                    operation: .compile,
                    targets: [harness.manager.target]
                )
            }
        }
    }

    @Test
    func standardOperationsRejectDroppedContextsAndRetainLegacyExecution() async throws {
        let harness = try await setup()
        let target = harness.manager.target
        let scope = ["uri": target.uri.stringValue]
        let requests: [(String, [String: Any])] = [
            ("buildTarget/compile", ["targets": [scope]]),
            ("buildTarget/run", ["target": scope]),
            ("buildTarget/test", ["targets": [scope]]),
            ("debugSession/start", ["targets": [scope]]),
        ]
        for (method, params) in requests {
            let data = try JSONSerialization.data(withJSONObject: ["id": 2, "jsonrpc": "2.0", "params": params])
            let response: ResponseType? = switch method {
            case "buildTarget/compile":
                try await (JSONDecoder().decode(BuildTargetCompileRequest.self, from: data))
                    .handle(contextualHandler: harness.handler, id: .int(2))
            case "buildTarget/run":
                try await (JSONDecoder().decode(BuildTargetRunRequest.self, from: data))
                    .handle(contextualHandler: harness.handler, id: .int(2))
            case "buildTarget/test":
                try await (JSONDecoder().decode(BuildTargetTestRequest.self, from: data))
                    .handle(contextualHandler: harness.handler, id: .int(2))
            default:
                try await (JSONDecoder().decode(DebugSessionStartRequest.self, from: data))
                    .handle(contextualHandler: harness.handler, id: .int(2))
            }
            let error = try #require(response as? JSONRPCErrorResponse)
            let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(error)) as? [String: Any])
            #expect((object["error"] as? [String: Any])?["code"] as? Int == -32602)
        }
        #expect(await harness.manager.executions.isEmpty)
        let legacy = try await setup(version: nil)
        #expect(try await legacy.service.compileTargets([legacy.manager.target]) == .ok)
        #expect(await legacy.manager.executions == ["legacy-compile"])
    }

    @Test
    func runWithBuildOutputUsesTheExistingProviderMethod() async throws {
        let harness = try await setup()
        let resolved = try await harness.service.resolveContext(.init(operation: .run, buildPolicy: .reuse))
        let status = try await harness.service.run(
            targetIdentifier: harness.manager.target,
            originId: "context-run",
            arguments: nil,
            environmentVariables: nil,
            workingDirectory: nil,
            executionContext: .init(id: resolved.id)
        )
        #expect(status == .ok)
        #expect(await harness.manager.executions == ["context-run"])
    }

    @Test
    func contextsAreReusableBoundToTargetsAndOperationsAndRevalidated() async throws {
        let harness = try await setup()
        let target = harness.manager.target
        let resolved = try await harness.service.resolveContext(.init(
            operation: .compile,
            selection: ["configuration": "release"]
        ))
        let reference = BuildContextReference(id: resolved.id)
        #expect(resolved.targets == [target])
        for _ in 0 ..< 2 {
            #expect(try await harness.service.compileTargets([target], executionContext: reference) == .ok)
        }
        #expect(await harness.manager.executions == ["context-release", "context-release"])
        await #expect(throws: BuildContextError.self) {
            try await harness.service.executionContext(reference, operation: .test, targets: [target])
        }
        await #expect(throws: BuildContextError.self) {
            try await harness.service.executionContext(reference, operation: .compile, targets: [])
        }
        await #expect(throws: BuildContextError.self) {
            try await harness.service.executionContext(reference, operation: .compile, targets: [target, target])
        }
        let unknown = BSPBuildTargetIdentifier(uri: URI(harness.manager.rootURL.appendingPathComponent("Other")))
        await #expect(throws: BuildContextError.self) {
            try await harness.service.executionContext(reference, operation: .compile, targets: [unknown])
        }
        await harness.manager.disableRelease()
        await #expect(throws: BuildContextError.self) {
            try await harness.service.executionContext(reference, operation: .compile, targets: [target])
        }
    }

    @Test
    func validatesScopeAndSelectionAndExpiresOldContexts() async throws {
        let harness = try await setup()
        let target = harness.manager.target
        for targets in [[BSPBuildTargetIdentifier](), [target, target]] {
            await #expect(throws: BuildContextError.self) {
                try await harness.service.resolveContext(.init(scope: .init(targets: targets), operation: .compile))
            }
        }
        await #expect(throws: BuildContextError.self) {
            try await harness.service.resolveContext(.init(
                scope: .init(workspaceUri: URI(URL(fileURLWithPath: "/other"))),
                operation: .compile
            ))
        }
        await #expect(throws: BuildContextError.self) {
            try await harness.service.resolveContext(.init(operation: .compile, selection: ["unknown": "value"]))
        }
        let first = try await harness.service.resolveContext(.init(operation: .compile))
        for _ in 0 ..< 128 {
            _ = try await harness.service.resolveContext(.init(operation: .compile))
        }
        #expect(await harness.service.contextCacheCount() == 128)
        await #expect(throws: BuildContextError.self) {
            try await harness.service.executionContext(.init(id: first.id), operation: .compile, targets: [target])
        }
        let current = try await harness.service.resolveContext(.init(operation: .compile))
        try await harness.service.reloadProject()
        await #expect(throws: BuildContextError.self) {
            try await harness.service.executionContext(.init(id: current.id), operation: .compile, targets: [target])
        }
    }
}

extension BuildContextTests {
    @Test
    func omittedBuildPolicyDefaultsToBuildAndUnknownPoliciesFail() throws {
        let oldRequest = Data(#"{"operation":"run","selection":{}}"#.utf8)
        let params = try JSONDecoder().decode(BuildContextParams.self, from: oldRequest)
        #expect(params.buildPolicy == .build)
        let reuse = Data(#"{"operation":"run","buildPolicy":"reuse"}"#.utf8)
        #expect(try JSONDecoder().decode(BuildContextParams.self, from: reuse).buildPolicy == .reuse)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                BuildContextParams.self,
                from: Data(#"{"operation":"run","buildPolicy":"auto"}"#.utf8)
            )
        }
    }

    @Test
    func reuseRequiresNegotiationAndCannotCompile() async throws {
        let harness = try await setup(reuse: false)
        let descriptor = try #require(harness.initialization.result.data.bspExtensions?[BuildContextExtension.name])
        #expect(descriptor.buildPolicies == [.build])
        await #expect(throws: BuildContextError.self) {
            try await harness.service.resolveContext(.init(operation: .run, buildPolicy: .reuse))
        }
        let supported = try await setup()
        #expect(supported.initialization.result.data.bspExtensions?[BuildContextExtension.name]?
            .buildPolicies == [.build, .reuse])
        await #expect(throws: BuildContextError.self) {
            try await supported.service.resolveContext(.init(operation: .compile, buildPolicy: .reuse))
        }
        #expect(await supported.manager.resolvedPolicies.isEmpty)
    }

    @Test
    func freezesAndRevalidatesPolicyWithoutDowngradingIt() async throws {
        let harness = try await setup()
        let resolved = try await harness.service.resolveContext(.init(operation: .run, buildPolicy: .reuse))
        #expect(resolved.buildPolicy == .reuse)
        let reference = BuildContextReference(id: resolved.id)
        let context = try await harness.service.executionContext(
            reference, operation: .run, targets: resolved.targets
        )
        #expect(context?.buildPolicy == .reuse)
        #expect(await harness.manager.resolvedPolicies == [.reuse, .reuse])
        await harness.manager.overridePolicy(.build)
        await #expect(throws: BuildContextError.self) {
            try await harness.service.executionContext(reference, operation: .run, targets: resolved.targets)
        }
        await #expect(throws: BuildContextError.self) {
            try await harness.service.resolveContext(.init(operation: .run, buildPolicy: .reuse))
        }
    }
}

private extension BSPServerService {
    func useContextTestManager(_ manager: any ProjectManager) {
        projectManager = manager
    }

    func contextCacheCount() -> Int {
        buildContexts.count
    }
}

private actor ContextTestManager: ProjectManager {
    let rootURL = URL(fileURLWithPath: "/tmp/ContextPackage")
    nonisolated let projectType = "test"
    let supportsBuildContexts: Bool
    let supportedBuildPolicies: [BuildContextBuildPolicy]
    var returnedPolicy: BuildContextBuildPolicy?
    var resolvedPolicies: [BuildContextBuildPolicy] = []
    let capabilities: ProjectManagerCapabilities = [.compile, .run, .test, .debug]
    let target = BSPBuildTargetIdentifier(uri: URI(URL(fileURLWithPath: "/tmp/ContextPackage/App")))
    var executions: [String] = []
    var releaseAvailable = true

    init(supported: Bool, reuse: Bool) {
        supportsBuildContexts = supported
        supportedBuildPolicies = reuse ? [.build, .reuse] : [.build]
    }

    func overridePolicy(_ policy: BuildContextBuildPolicy) {
        returnedPolicy = policy
    }

    func disableRelease() {
        releaseAvailable = false
    }

    var project: BSPProject? {
        let targets = [
            BSPBuildTarget(
                id: target,
                tags: [],
                languageIds: [.swift],
                dependencies: [],
                capabilities: .init(canCompile: true, canTest: true, canRun: true, canDebug: true)
            )
        ]
        return BSPProject(
            rootURL: rootURL,
            name: "Context",
            targets: targets,
            buildRootURL: rootURL,
            indexStoreURL: rootURL,
            indexDatabaseURL: rootURL
        )
    }

    func contextOptions(_ params: BuildContextOptionsParams) async throws -> BuildContextOptionsResult {
        let context = try await resolveContext(.init(
            scope: params.scope,
            operation: .compile,
            selection: params.selection
        ))
        return .init(dimensions: [], selection: context.selection, operations: BuildContextOperation.allCases)
    }

    func resolveContext(_ params: BuildContextParams) async throws -> BuildContext {
        let selection = params.selection ?? ["configuration": "debug"]
        guard Set(selection.keys) == ["configuration"], let value = selection["configuration"],
              value == "debug" || (value == "release" && releaseAvailable),
              params.scope?.targets == nil || params.scope?.targets == [target] else {
            throw BuildContextError.invalid("The selection is unavailable.")
        }
        resolvedPolicies.append(params.buildPolicy)
        return .init(
            operation: params.operation,
            targets: [target],
            selection: selection,
            buildPolicy: returnedPolicy ?? params.buildPolicy
        )
    }

    func startBuild(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        logHandler: (@Sendable (String) -> Void)?,
        context: BuildContext
    ) async throws -> StatusCode {
        executions.append("context-" + (context.selection["configuration"] ?? "missing"))
        return .ok
    }

    func startBuild(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        logHandler: (@Sendable (String) -> Void)?
    ) async throws -> StatusCode {
        executions.append("legacy-compile")
        return .ok
    }

    // swiftlint:disable:next function_parameter_count
    func run(
        targetIdentifier: BSPBuildTargetIdentifier,
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        progressHandler: (@Sendable (String) async -> Void)?,
        context: BuildContext
    ) async throws -> StatusCode {
        executions.append("context-run")
        return .ok
    }

    func getProjectState() -> ProjectState {
        .init()
    }

    func initialize() async throws {}
    func updateBuildGraph() async throws {}
    func getSourceFileList(targetIdentifiers: [BSPBuildTargetIdentifier]) async throws -> [SourcesItem] {
        []
    }

    func getCompileArguments(targetIdentifier: String, sourceFileURL: URL) async throws -> [String] {
        []
    }

    func buildIndex(for targetIdentifiers: [BSPBuildTargetIdentifier]) async throws -> [BSPBuildTargetIdentifier] {
        []
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
        .ok
    }

    func startDebugSession(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        logHandler: (@Sendable (String) -> Void)?,
        progressHandler: (@Sendable (String) async -> Void)?,
        context: BuildContext
    ) async throws -> DebugSessionConnection {
        executions.append("context-debug")
        return .init(uri: "tcp://127.0.0.1:12345", request: .launch)
    }

    func startDebugSession(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        logHandler: (@Sendable (String) -> Void)?,
        progressHandler: (@Sendable (String) async -> Void)?
    ) async throws
        -> DebugSessionConnection {
        executions.append("legacy-debug")
        return .init(uri: "tcp://127.0.0.1:12345", request: .launch)
    }
}
