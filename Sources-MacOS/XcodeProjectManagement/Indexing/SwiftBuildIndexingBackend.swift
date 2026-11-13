#if SWIFT_BUILD_INDEXING
import Foundation
import Logger
import SwiftBuild

actor SwiftBuildIndexingBackend: XcodeIndexingBackend {
    nonisolated let indexStoreURL: URL
    nonisolated let indexDatabaseURL: URL
    private let snapshot: XcodeProjectSnapshot
    private let selection: XcodeIndexingSelection?
    private let arena: URL
    private let serviceExecutable: URL
    private var service: SWBBuildService?
    private var session: SWBBuildServiceSession?
    private var request = SWBBuildRequest()
    private var targetInfos: [SWBTargetInfo] = []
    private var workspaceLoaded = false
    private let initialization = IndexPreparationCoordinator<String>()
    /// Each plan owns one native retain. In-flight queries keep it alive after cache eviction.
    private final class Plan: Sendable {
        let request: SWBBuildRequest
        let descriptionID: SWBBuildDescriptionID
        let target: SWBConfiguredTargetIdentifier
        private let session: SWBBuildServiceSession

        init(
            request: SWBBuildRequest,
            descriptionID: SWBBuildDescriptionID,
            target: SWBConfiguredTargetIdentifier,
            session: SWBBuildServiceSession
        ) {
            self.request = request
            self.descriptionID = descriptionID
            self.target = target
            self.session = session
        }

        deinit {
            let session = session
            let descriptionID = descriptionID
            Task { await session.releaseBuildDescription(id: descriptionID) }
        }
    }

    private let planning = SharedIndexPreparationCoordinator<XcodeTargetIdentifier, Plan>()
    private var plans: [XcodeTargetIdentifier: Plan] = [:]
    private var planAccessOrder: [XcodeTargetIdentifier] = []
    private var targetGUIDs: [XcodeTargetIdentifier: String] = [:]
    private struct SourcePaths {
        let descriptionID: SWBBuildDescriptionID
        let paths: [URL: AbsolutePath]
    }

    private var sourcePaths: [XcodeTargetIdentifier: SourcePaths] = [:]
    private struct OptionsKey: Hashable {
        let target: XcodeTargetIdentifier
        let file: URL
    }

    private var publishedOptions: [OptionsKey: [String]] = [:]
    private var stopped = false
    private struct PreparationKey: Hashable, Sendable {
        let targets: [XcodeTargetIdentifier]
        let generation: UUID
    }

    private var generation = UUID()
    private let preparation = SharedIndexPreparationCoordinator<PreparationKey, IndexPreparationChanges>()
    private struct Pending {
        let cancel: @Sendable () -> Void
        let completion: Task<Void, Never>
    }

    private var pending: [UUID: Pending] = [:]

    init(snapshot: XcodeProjectSnapshot, serviceExecutable: URL? = nil) throws {
        self.snapshot = snapshot
        self.serviceExecutable = serviceExecutable ?? URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("SWBBuildServiceBundle")
        self.selection = try XcodeIndexingSelection.load(in: snapshot.xcodeGlobalSettings.derivedDataPath)
        self.arena = snapshot.xcodeGlobalSettings.derivedDataPath.appendingPathComponent("Index.noindex")
        self.indexStoreURL = snapshot.xcodeGlobalSettings.indexStoreURL
        self.indexDatabaseURL = snapshot.xcodeGlobalSettings.indexDatabaseURL
    }

    private func ensureLoaded() async throws {
        guard !stopped else { throw CancellationError() }
        guard !workspaceLoaded else { return }
        _ = try await initialization.prepare(for: "workspace") { _ in
            try await self.perform("load workspace") { backend in
                guard !backend.workspaceLoaded else { return true }
                do {
                    try await backend.load()
                    backend.workspaceLoaded = true
                    return true
                } catch {
                    await backend.closeSession()
                    throw error
                }
            }
        }
    }

    private func load() async throws {
        let bundle = serviceExecutable
        guard FileManager.default.isExecutableFile(atPath: bundle.path) else {
            throw XcodeProjectError.invalidConfig("Missing matching Swift Build service: \(bundle.path)")
        }
        // The service must match the linked framework, not Xcode's bundled framework version.
        setenv("SWBBUILDSERVICE_PATH", bundle.path, 1)
        setenv("UseSynchronousBuildDescriptionSerialization", "YES", 1)
        let service = try await SWBBuildService(connectionMode: .outOfProcess)
        self.service = service
        let (result, diagnostics) = await service.createSession(
            name: "sourcekit-bsp-indexing", developerPath: snapshot.xcodeInstallation.developerDir.path,
            cachePath: nil, inferiorProductsPath: nil, environment: nil
        )
        for diagnostic in diagnostics {
            logger.debug("Swift Build: \(diagnostic)")
        }
        let session = try result.get()
        self.session = session
        try await session.loadWorkspace(containerPath: snapshot.projectLocation.workspaceOrProjectFileURL.path)
        try await session.setSystemInfo(.default())
        targetInfos = try await session.workspaceInfo().targetInfos
        request = makeRequest()
    }

    private func plan(for target: XcodeTargetIdentifier) async throws -> Plan {
        try await ensureLoaded()
        if let cached = cachedPlan(for: target) { return cached }
        return try await planning.prepare(for: target) { _ in
            try await self.perform("plan \(target.targetName)") { backend in
                if let cached = backend.cachedPlan(for: target) { return cached }
                return try await backend.createPlan(for: target)
            }
        }
    }

    private func createPlan(for target: XcodeTargetIdentifier) async throws -> Plan {
        guard let session else { throw XcodeProjectError.invalidConfig("Swift Build is not ready") }
        let (targetRequest, guid) = try await makeTargetRequest(for: target)
        let operation = try await session.createBuildOperationForBuildDescriptionOnly(
            request: targetRequest, delegate: IndexPlanningDelegate(), retainBuildDescription: true
        )
        let plan = try await consumePlan(operation, request: targetRequest, guid: guid) {
            logger.debug("Index planning: \($0)")
        }
        cache(plan, for: target)
        return plan
    }

    private func makeTargetRequest(for target: XcodeTargetIdentifier) async throws -> (SWBBuildRequest, String) {
        let guid = try await resolveGUID(target)
        var targetRequest = request
        targetRequest.add(target: SWBConfiguredTarget(guid: guid))
        targetRequest.buildCommand = .prepareForIndexing(buildOnlyTheseTargets: [guid], enableIndexBuildArena: true)
        return (targetRequest, guid)
    }

    private func cachedPlan(for target: XcodeTargetIdentifier) -> Plan? {
        guard let plan = plans[target] else { return nil }
        planAccessOrder.removeAll { $0 == target }
        planAccessOrder.append(target)
        return plan
    }

    private func cache(_ plan: Plan, for target: XcodeTargetIdentifier) {
        plans[target] = plan
        sourcePaths[target] = nil
        planAccessOrder.removeAll { $0 == target }
        planAccessOrder.append(target)
        // Match the engine's default cache count without retaining every target in a large workspace.
        while planAccessOrder.count > 4 {
            let evicted = planAccessOrder.removeFirst()
            plans[evicted] = nil
            sourcePaths[evicted] = nil
        }
    }

    private func consumePlan(
        _ operation: SWBBuildOperation, request: SWBBuildRequest, guid: String,
        log: (@Sendable (String) -> Void)?
    ) async throws -> Plan {
        guard let session else { throw XcodeProjectError.invalidConfig("Swift Build is not ready") }
        var identifier: String?
        do {
            try await consume(operation, log: log) { event in
                if case let .reportBuildDescription(info) = event { identifier = info.buildDescriptionID }
            }
            guard let identifier
            else { throw XcodeProjectError.invalidConfig("Swift Build returned no build description") }
            return try await makePlan(request: request, descriptionID: SWBBuildDescriptionID(identifier), guid: guid)
        } catch {
            if let identifier { await session.releaseBuildDescription(id: SWBBuildDescriptionID(identifier)) }
            throw error
        }
    }

    private func makePlan(
        request: SWBBuildRequest,
        descriptionID: SWBBuildDescriptionID,
        guid: String
    ) async throws -> Plan {
        guard let session else { throw XcodeProjectError.invalidConfig("Swift Build is not ready") }
        let targets = try await session.selectConfiguredTargetsForIndex(
            targets: [SWBTargetGUID(rawValue: guid)], buildDescription: descriptionID, buildRequest: request
        )
        guard targets.count == 1, let identifier = targets.first else {
            throw XcodeProjectError.invalidConfig("Swift Build cannot select one index configuration: \(guid)")
        }
        return Plan(request: request, descriptionID: descriptionID, target: identifier, session: session)
    }

    private func makeRequest() -> SWBBuildRequest {
        var request = SWBBuildRequest()
        request.parameters.configurationName = selection?.configuration ?? snapshot.configuration
        request.parameters.action = "indexbuild"
        request.buildCommand = .prepareForIndexing(buildOnlyTheseTargets: nil, enableIndexBuildArena: true)
        request.enableIndexBuildArena = true
        request.continueBuildingAfterErrors = true
        request.parameters.arenaInfo = SWBArenaInfo(
            derivedDataPath: snapshot.xcodeGlobalSettings.derivedDataPath.path,
            buildProductsPath: arena.appendingPathComponent("Build/Products").path,
            buildIntermediatesPath: arena.appendingPathComponent("Build/Intermediates.noindex").path,
            pchPath: arena.appendingPathComponent("Build/Intermediates.noindex/PrecompiledHeaders").path,
            indexRegularBuildProductsPath: snapshot.xcodeGlobalSettings.symRoot.path,
            indexRegularBuildIntermediatesPath: snapshot.xcodeGlobalSettings.objRoot.path,
            indexPCHPath: arena.appendingPathComponent("PrecompiledHeaders").path,
            indexDataStoreFolderPath: indexStoreURL.path,
            indexEnableDataStore: true
        )
        let platforms = Set(snapshot.xcodeTargets.map(\.xcodeTargetPlatform.simulatorVariant.rawValue))
        let platform = selection?.platform
            ?? (platforms.count == 1 ? platforms.first! : "iphonesimulator")
        #if arch(arm64)
        let hostArchitecture = "arm64"
        #else
        let hostArchitecture = "x86_64"
        #endif
        let deviceArchitecture = platform == "watchos" ? "arm64_32" : "arm64"
        let architecture = selection?.architecture
            ?? (platform == "macosx" || platform.hasSuffix("simulator") ? hostArchitecture : deviceArchitecture)
        request.parameters.activeRunDestination = SWBRunDestinationInfo(
            platform: platform, sdk: platform, sdkVariant: nil, targetArchitecture: architecture,
            supportedArchitectures: [architecture], disableOnlyActiveArch: false
        )
        var overrides = SWBSettingsTable()
        overrides.set(value: "YES", for: "ONLY_ACTIVE_ARCH")
        overrides.set(value: "NO", for: "INDEX_ENABLE_OPTIMIZATION_LEVEL_OVERRIDE")
        overrides.set(value: "NO", for: "CODE_SIGNING_ALLOWED")
        request.parameters.overrides.commandLine = overrides
        return request
    }

    func compilerArguments(for target: XcodeTargetIdentifier, file: URL) async throws -> [String] {
        let plan = try await plan(for: target)
        return try await perform("compiler arguments", serializeBuild: false) { backend in
            try await backend.publishArguments(for: target, file: file, plan: plan)
        }
    }

    private func publishArguments(for target: XcodeTargetIdentifier, file: URL, plan: Plan) async throws -> [String] {
        let result = try await arguments(for: target, file: file, plan: plan)
        publishedOptions[OptionsKey(target: target, file: file)] = result
        return result
    }

    private func arguments(for target: XcodeTargetIdentifier, file: URL, plan: Plan) async throws -> [String] {
        defer { withExtendedLifetime(plan) {} }
        guard let session else { throw XcodeProjectError.invalidConfig("Swift Build is not ready") }
        if sourcePaths[target]?.descriptionID != plan.descriptionID {
            let sources = try await session.sources(
                of: [plan.target],
                buildDescription: plan.descriptionID,
                buildRequest: plan.request
            )
            let paths = Dictionary(sources.flatMap(\.sourceFiles).map {
                (URL(fileURLWithPath: $0.path.pathString).resolvingSymlinksInPath(), $0.path)
            }, uniquingKeysWith: { first, _ in first })
            sourcePaths[target] = SourcePaths(descriptionID: plan.descriptionID, paths: paths)
        }
        // PIF loading can spell symlinked paths differently from the client's document URI.
        let path = try sourcePaths[target]?.paths[file.resolvingSymlinksInPath()] ?? AbsolutePath(validating: file.path)
        return try await session.indexCompilerArguments(
            of: path, in: plan.target,
            buildDescription: plan.descriptionID, buildRequest: plan.request
        )
    }

    private func resolveGUID(_ target: XcodeTargetIdentifier) async throws -> String {
        if let cached = targetGUIDs[target] { return cached }
        guard let session else { throw XcodeProjectError.invalidConfig("Swift Build is not ready") }
        var matches: [SWBTargetInfo] = []
        for candidate in targetInfos where candidate.targetName == target.targetName {
            let project = try await session.evaluateMacroAsString(
                "PROJECT_FILE_PATH", level: .target(candidate.guid), buildParameters: request.parameters, overrides: nil
            )
            if URL(fileURLWithPath: project).standardizedFileURL.resolvingSymlinksInPath()
                == URL(fileURLWithPath: target.projectFilePath).standardizedFileURL.resolvingSymlinksInPath() {
                matches.append(candidate)
            }
        }
        guard matches.count == 1, let match = matches.first else {
            throw XcodeProjectError.invalidConfig("Swift Build target match count \(matches.count): \(target.rawValue)")
        }
        targetGUIDs[target] = match.guid
        return match.guid
    }

    func prepare(
        targets: [XcodeTargetIdentifier],
        log: (@Sendable (String) -> Void)?
    ) async throws -> [XcodeTargetIdentifier] {
        let targets = Array(Set(targets)).sorted { $0.rawValue < $1.rawValue }
        guard !targets.isEmpty else { return [] }
        let key = PreparationKey(targets: targets, generation: generation)
        let changes = try await preparation.prepare(for: key, logHandler: log) { sharedLog in
            try await self.ensureLoaded()
            let targets = try await self.perform("prepare") { backend in
                try await backend.prepareOperation(targets: targets, log: sharedLog)
            }
            return IndexPreparationChanges(targets)
        }
        return changes.take()
    }

    func invalidateInputs() {
        generation = UUID()
    }

    private func prepareOperation(
        targets: [XcodeTargetIdentifier], log: @escaping @Sendable (String) -> Void
    ) async throws -> [XcodeTargetIdentifier] {
        guard let session else { throw XcodeProjectError.invalidConfig("Swift Build is not ready") }
        var changed: Set<XcodeTargetIdentifier> = []
        for target in targets {
            try Task.checkCancellation()
            let (targetRequest, guid) = try await makeTargetRequest(for: target)
            let operation = try await session.createBuildOperation(
                request: targetRequest,
                delegate: IndexPlanningDelegate(), retainBuildDescription: true
            )
            let prepared = try await consumePlan(
                operation, request: targetRequest, guid: guid, log: log
            )
            cache(prepared, for: target)
            // Refresh this target before another preparation can evict its description.
            // Unrelated targets can hold expired IDs and must not fail this preparation.
            let previousOptions = publishedOptions.filter { $0.key.target == target }
            for (key, previous) in previousOptions {
                let current = try await arguments(for: target, file: key.file, plan: prepared)
                if current != previous { changed.insert(target) }
                publishedOptions[key] = current
            }
        }
        return changed.sorted { $0.rawValue < $1.rawValue }
    }

    private func consume(
        _ operation: SWBBuildOperation, log: (@Sendable (String) -> Void)?,
        eventHandler: (SwiftBuildMessage) -> Void
    ) async throws {
        try await withTaskCancellationHandler {
            // A failed start has no completion event to wait for.
            let events: AsyncStream<SwiftBuildMessage>
            do {
                try Task.checkCancellation()
                events = try await operation.start()
            } catch {
                operation.cancel()
                throw error
            }
            do {
                for await event in events {
                    eventHandler(event)
                    switch event {
                    case let .taskStarted(info): log?(info.executionDescription)
                    case let .targetStarted(info): log?("Preparing \(info.targetName)")
                    case let .taskDiagnostic(info): log?(info.message)
                    case let .buildDiagnostic(info): log?(info.message)
                    case let .diagnostic(info): log?(info.message)
                    default: break
                    }
                }
                await operation.waitForCompletion()
                try Task.checkCancellation()
                guard operation.state == .succeeded else {
                    throw XcodeProjectError.invalidConfig("Swift Build indexing failed: \(operation.state)")
                }
            } catch {
                operation.cancel()
                await operation.waitForCompletion()
                throw error
            }
        } onCancel: { operation.cancel() }
    }

    private func perform<Result: Sendable>(
        _ name: String,
        serializeBuild: Bool = true,
        _ body: @escaping @Sendable (isolated SwiftBuildIndexingBackend) async throws -> Result
    ) async throws -> Result {
        guard !stopped else { throw CancellationError() }
        let id = UUID()
        let start = ContinuousClock.now
        if serializeBuild { logger.info("Swift Build \(name): queued") }
        let task = Task {
            try Task.checkCancellation()
            if serializeBuild {
                return try await XcodeBuildScheduler.shared
                    .withBuild(in: snapshot.xcodeGlobalSettings.derivedDataPath) {
                        try Task.checkCancellation()
                        logger.info("Swift Build \(name): started after \(ContinuousClock.now - start)")
                        return try await body(self)
                    }
            }
            return try await body(self)
        }
        pending[id] = Pending(cancel: { task.cancel() }, completion: Task { _ = await task.result })
        defer {
            pending[id] = nil
            if serializeBuild {
                logger.info("Swift Build \(name): \(ContinuousClock.now - start)")
            } else {
                logger.debug("Swift Build \(name): \(ContinuousClock.now - start)")
            }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func shutdown() async {
        stopped = true
        await preparation.stop()
        await planning.stop()
        await initialization.stop()
        let operations = Array(pending.values)
        for operation in operations {
            operation.cancel()
        }
        for operation in operations {
            await operation.completion.value
        }
        await closeSession()
    }

    private func closeSession() async {
        plans.removeAll()
        planAccessOrder.removeAll()
        try? await session?.close()
        await service?.close()
        session = nil
        service = nil
        workspaceLoaded = false
        targetGUIDs.removeAll()
        sourcePaths.removeAll()
    }
}

private final class IndexPlanningDelegate: SWBPlanningOperationDelegate, Sendable {
    func provisioningTaskInputs(
        targetGUID: String, provisioningSourceData: SWBProvisioningTaskInputsSourceData
    ) async -> SWBProvisioningTaskInputs {
        SWBProvisioningTaskInputs()
    }

    func executeExternalTool(
        commandLine: [String], workingDirectory: String?, environment: [String: String]
    ) async throws -> SWBExternalToolResult {
        .deferred
    }
}
#endif
